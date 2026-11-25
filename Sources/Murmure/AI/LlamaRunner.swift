import Foundation
import llama

/// Exécute un LLM GGUF en local avec llama.cpp (Metal sur Apple Silicon).
/// Aucune requête réseau : le texte ne quitte jamais le Mac.
actor LlamaRunner {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private(set) var loadedPath: String?

    private static let backendReady: Void = { llama_backend_init() }()

    func load(path: String) throws {
        if loadedPath == path, context != nil { return }
        unload()
        _ = Self.backendReady

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw MurmureError.llm("impossible de charger le modèle.")
        }
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 4096
        ctxParams.n_batch = 4096
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        ctxParams.n_threads = threads
        ctxParams.n_threads_batch = threads
        guard let c = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            throw MurmureError.llm("impossible de créer le contexte.")
        }
        model = m
        context = c
        vocab = llama_model_get_vocab(m)
        loadedPath = path
    }

    func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil; model = nil; vocab = nil; loadedPath = nil
    }

    func generate(messages: [(role: String, content: String)], maxTokens: Int, temperature: Float = 0) throws -> String {
        guard let model, let context, let vocab else { throw MurmureError.llm("modèle non chargé.") }

        let prompt = formatChat(model: model, messages: messages)
        var tokens = tokenize(vocab: vocab, text: prompt)
        let nCtx = Int(llama_n_ctx(context))
        guard tokens.count + maxTokens < nCtx else { throw MurmureError.llm("texte trop long pour le modèle local.") }

        llama_memory_clear(llama_get_memory(context), true)

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if temperature > 0.05 {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        }

        var status = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard status == 0 else { throw MurmureError.llm("échec du décodage (\(status)).") }

        var output = [UInt8]()
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { output += piece[0..<Int(n)].map { UInt8(bitPattern: $0) } }
            status = llama_decode(context, llama_batch_get_one(&token, 1))
            if status != 0 { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func tokenize(vocab: OpaquePointer, text: String) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        let needed = -llama_tokenize(vocab, text, utf8Count, nil, 0, true, true)
        var tokens = [llama_token](repeating: 0, count: Int(max(needed, 1)))
        let n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    /// Applique le gabarit de conversation du modèle (ChatML pour Qwen, Gemma, etc.).
    private func formatChat(model: OpaquePointer, messages: [(role: String, content: String)]) -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer { (roles + contents).forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: $0.0, content: $0.1) }
        let total = messages.reduce(0) { $0 + $1.content.utf8.count }
        var buffer = [CChar](repeating: 0, count: total * 2 + 1024)
        var n = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(buffer.count))
        if n > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard n > 0 else {
            return messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
        }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

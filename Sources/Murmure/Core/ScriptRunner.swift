import Foundation

/// Scripts zsh d'un mode, avant ou après l'IA.
/// Le texte arrive sur l'entrée standard, la sortie standard devient le texte de l'étape suivante.
/// Le script peut écrire des directives dans $MURMURE_CONTROL_FILE :
///   skip_ai=1 · output_mode=paste|paste_and_send|copy|history_only · switch_mode=<nom ou id>
enum ScriptRunner {
    struct Result {
        var output: String
        var skipAI = false
        var outputMode: OutputMode?
        var switchMode: String?
    }

    static let timeout: TimeInterval = 30

    static func run(_ script: String, input: String, context: DictationContext, mode: Mode,
                    audioDuration: TimeInterval?, audioFile: URL?) async throws -> Result {
        let control = FileManager.default.temporaryDirectory.appendingPathComponent("murmure-control-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: control.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: control) }

        var env = ProcessInfo.processInfo.environment
        let values = Dictionary(context.values(for: mode).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        env["MURMURE_ACTIVE_APP"] = mode.includeActiveApp ? (context.appName ?? "") : ""
        env["MURMURE_ACTIVE_APP_BUNDLE_ID"] = mode.includeActiveApp ? (context.appBundleID ?? "") : ""
        env["MURMURE_CLIPBOARD"] = values["CLIPBOARD"] ?? ""
        env["MURMURE_SELECTED_TEXT"] = values["SELECTED_TEXT"] ?? ""
        env["MURMURE_TEXT_BEFORE_CURSOR"] = values["TEXT_BEFORE_CURSOR"] ?? ""
        env["MURMURE_TEXT_AFTER_CURSOR"] = values["TEXT_AFTER_CURSOR"] ?? ""
        env["MURMURE_ACTIVE_BROWSER_URL"] = values["URL"] ?? ""
        env["MURMURE_MODE"] = mode.name
        env["MURMURE_CONTROL_FILE"] = control.path
        if let audioDuration { env["MURMURE_AUDIO_DURATION"] = String(format: "%.2f", audioDuration) }
        if let audioFile { env["MURMURE_AUDIO_FILE"] = audioFile.path }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", script]
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error); return
                }
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()

                let deadline = DispatchTime.now() + timeout
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()

                if process.terminationReason == .uncaughtSignal {
                    cont.resume(throwing: MurmureError.unsupported("Le script a dépassé \(Int(timeout)) secondes."))
                    return
                }
                if process.terminationStatus != 0 {
                    let message = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: MurmureError.unsupported("Script : \(message.isEmpty ? "code \(process.terminationStatus)" : message)"))
                    return
                }
                var result = Result(output: String(data: out, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                let directives = (try? String(contentsOf: control, encoding: .utf8)) ?? ""
                for line in directives.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "skip_ai": result.skipAI = parts[1] == "1" || parts[1] == "true"
                    case "output_mode": result.outputMode = OutputMode.fromDirective(parts[1])
                    case "switch_mode": result.switchMode = parts[1]
                    default: break
                    }
                }
                cont.resume(returning: result)
            }
        }
    }
}

extension OutputMode {
    static func fromDirective(_ value: String) -> OutputMode? {
        switch value {
        case "paste", "auto_insert": return .paste
        case "paste_and_send": return .pasteAndSend
        case "copy", "copy_to_clipboard": return .copy
        case "history_only": return .historyOnly
        default: return nil
        }
    }
}

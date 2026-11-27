#!/bin/zsh
# Fusionne un point de sauvegarde MLX, le convertit en GGUF (Q8_0 et Q4_K_M) et l'évalue avec llama-server.
#   training/cleanup-1/checkpoint.sh runs/full-v1 0000400 [q8|q4]
# Dossier de travail : ~/murmure-cleanup (venv, base/qwen05, dl/llama, data).
set -e
cd ~/murmure-cleanup
run=$1; step=$2; quant=${3:-q8}
here=${0:A:h}
name=$(basename $run)-$step
tmp=ck/$name; mkdir -p $tmp gguf results
cp $run/adapter_config.json $tmp/
cp $run/${step}_adapters.safetensors $tmp/adapters.safetensors
./venv/bin/python -m mlx_lm fuse --model base/qwen05 --adapter-path $tmp --save-path fused/$name > /dev/null
PYTHONPATH=dl/llama/src/gguf-py ./venv/bin/python dl/llama/src/convert_hf_to_gguf.py fused/$name --outtype f16 --outfile gguf/$name-f16.gguf > /dev/null 2>&1
dl/llama/llama-b12728/llama-quantize gguf/$name-f16.gguf gguf/$name-q8.gguf Q8_0 > /dev/null 2>&1
dl/llama/llama-b12728/llama-quantize gguf/$name-f16.gguf gguf/$name-q4km.gguf Q4_K_M > /dev/null 2>&1
rm -rf gguf/$name-f16.gguf $tmp
model=gguf/$name-$quant.gguf
[ $quant = q4 ] && model=gguf/$name-q4km.gguf
port=18990
dl/llama/llama-b12728/llama-server -m $model --port $port -c 2048 -ngl 99 --log-disable > /dev/null 2>&1 &
srv=$!
trap "kill $srv 2>/dev/null" EXIT
for i in $(seq 1 60); do curl -s http://127.0.0.1:$port/health | grep -q ok && break; sleep 1; done
for f in eval:$here/../../Tests/cleanup-bench/eval.jsonl test:data-v2/test_clean.meta.jsonl; do
  ./venv/bin/python $here/evaluate.py ${f#*:} --method server --url http://127.0.0.1:$port --prompt cleanup1 \
    --out results/$name-$quant-${f%%:*}.jsonl
done
ls -la gguf/$name-*.gguf

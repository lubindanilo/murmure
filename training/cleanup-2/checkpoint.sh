#!/bin/zsh
# Fusionne un point de sauvegarde MLX, le convertit en GGUF Q6_K (la quantification publiée) et l'évalue.
#   training/cleanup-2/checkpoint.sh runs/full-v3 0000600
# Dossier de travail : ~/murmure-cleanup. Bancs : dictées réalistes, test propre v2, test v3 (monologues)
# et, s'il existe, le banc privé des vraies dictées (bench-real/, jamais versionné).
set -e
here=${0:A:h}
cd ~/murmure-cleanup
run=$1; step=$2
name=$(basename $run)-$step
tmp=ck/$name; mkdir -p $tmp gguf results
cp $run/adapter_config.json $tmp/
cp $run/${step}_adapters.safetensors $tmp/adapters.safetensors
./venv/bin/python -m mlx_lm fuse --model base/qwen05 --adapter-path $tmp --save-path fused/$name > /dev/null
PYTHONPATH=dl/llama/src/gguf-py ./venv/bin/python dl/llama/src/convert_hf_to_gguf.py fused/$name --outtype f16 --outfile gguf/$name-f16.gguf > /dev/null 2>&1
dl/llama/llama-b12728/llama-quantize gguf/$name-f16.gguf gguf/$name-q6k.gguf Q6_K > /dev/null 2>&1
rm -rf gguf/$name-f16.gguf $tmp fused/$name
model=gguf/$name-q6k.gguf
port=18992
dl/llama/llama-b12728/llama-server -m $model --port $port -c 2048 -ngl 99 --log-disable > /dev/null 2>&1 &
srv=$!
trap "kill $srv 2>/dev/null" EXIT
for i in $(seq 1 60); do curl -s http://127.0.0.1:$port/health | grep -q ok && break; sleep 1; done
for f in eval:$here/../../Tests/cleanup-bench/eval.jsonl test:data-v2/test_clean.meta.jsonl mono:data-v3/test.meta.jsonl; do
  ./venv/bin/python $here/evaluate.py ${f#*:} --method server --url http://127.0.0.1:$port --prompt cleanup1 \
    --out results/$name-${f%%:*}.jsonl
done
[ -f bench-real/real.jsonl ] && ./venv/bin/python bench-real/score.py --method server --url http://127.0.0.1:$port --out results/$name-real.jsonl
ls -la $model

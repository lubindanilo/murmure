import json, sys, time, subprocess, urllib.request, os, signal
BIN = os.path.expanduser("~/murmure-llm/llama-b12728/llama-server")
MODELS = sys.argv[1].split(",")
PROMPT = sys.argv[2]  # fichier JSON : {"system": "...", "shots": [[user, assistant], ...], "wrap": "{text}"}
cfg = json.load(open(PROMPT))
cases = [l.strip() for l in open("cases.txt") if l.strip()]
for m in MODELS:
    p = subprocess.Popen([BIN, "-m", os.path.expanduser(f"~/murmure-llm/models/{m}"), "--port", "18999", "-c", "4096", "-t", "6", "--log-disable"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        try:
            urllib.request.urlopen("http://127.0.0.1:18999/health", timeout=1); break
        except Exception: time.sleep(1)
    print(f"===== {m}", flush=True)
    for i, c in enumerate(cases, 1):
        msgs = [{"role": "system", "content": cfg["system"]}]
        for u, a in cfg.get("shots", []):
            msgs += [{"role": "user", "content": cfg.get("wrap", "{text}").format(text=u)}, {"role": "assistant", "content": a}]
        msgs.append({"role": "user", "content": cfg.get("wrap", "{text}").format(text=c)})
        body = json.dumps({"messages": msgs, "temperature": 0, "max_tokens": 300}).encode()
        t = time.time()
        r = json.load(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18999/v1/chat/completions", body, {"Content-Type": "application/json"})))
        out = r["choices"][0]["message"]["content"].strip()
        print(f"#{i} [{time.time()-t:.1f}s] {out}", flush=True)
    p.send_signal(signal.SIGTERM); p.wait()

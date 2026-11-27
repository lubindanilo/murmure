"""Données de Murmure Cleanup 2 : bruit façon Parakeet sur des dictées longues.

Ce qu'on a vu sur de vraies dictées (novembre 2026) : Parakeet rend un texte déjà ponctué et en majuscules
(96 % des cas), long (médiane 41 mots, 15 % au-delà de 100), avec peu d'hésitations mais des mots doublés
(« très très », « du du »), des faux départs (« La seule Le seul obstacle »), des virgules manquantes, des
points de trop au milieu d'une phrase (« mais par contre. le relief »), des « ? » oubliés et parfois des
nombres en chiffres bruts. Cleanup 1, entraîné sur du texte court et souvent sans ponctuation, en faisait
trop : il sautait d'une reprise à l'autre et perdait le passage du milieu.

Ici la cible reste le texte propre ; l'entrée est ce que Parakeet en aurait fait. Le corpus de monologues
(corpus/*.txt) contient exprès des groupes de mots repris à distance : tout ce qui est entre deux reprises
doit ressortir.

    python gen3.py corpus-v3 ancien-corpus data-v2 sortie [--seed 3]
"""
import json, random, sys, unicodedata
from pathlib import Path
import regex as re

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "cleanup-1"))
import gen as g  # noqa: E402

FR_DET_RESTARTS = [("La", "Le"), ("Le", "La"), ("la", "le"), ("le", "la"), ("un", "une"), ("une", "un"),
                   ("les", "le"), ("des", "les"), ("du", "de la"), ("ce", "cette")]
LIGHT_FILLERS = {"fr": [("euh", 6), ("bah", 2), ("ben", 2), ("hum", 1)], "en": [("um", 5), ("uh", 5)]}


def double_words(words, rng, n):
    """« très très », « du du », « et et » : un mot (ou deux) dit deux fois, sans ponctuation entre."""
    for _ in range(n):
        if len(words) < 4:
            break
        i = rng.randint(0, len(words) - 2)
        k = 1 if rng.random() < 0.8 else 2
        span = words[i:i + k]
        if any(re.search(r"[.?!,;:…]$", w) for w in span):
            continue
        words[i:i] = span
    return words


def det_restart(words, rng):
    """Faux départ sur le déterminant : « la seule le seul obstacle » ; la cible garde le second."""
    if len(words) < 3:
        return words, False
    for _ in range(6):
        i = rng.randint(0, len(words) - 2)
        for a, b in FR_DET_RESTARTS:
            if words[i] == b:
                nxt = re.sub(r"[.,;:!?…]+$", "", words[i + 1])
                words[i:i] = [a, nxt]
                return words, True
    return words, False


def phrase_restart(words, rng):
    """Faux départ collé : « on va faire on va juste configurer » (2 ou 3 mots repris aussitôt)."""
    if len(words) < 5:
        return words, False
    for _ in range(6):
        i = rng.randint(0, max(0, len(words) - 5))
        k = rng.choice([2, 2, 3])
        span = words[i:i + k + 1]
        if len(span) < k + 1 or any(re.search(r"[.?!,;:…]$", w) for w in span):
            continue
        # La version abandonnée : les k premiers mots plus un mot qui partait ailleurs (pris plus loin).
        far = rng.choice(words)
        far = re.sub(r"[.,;:!?…]+$", "", far)
        words[i:i] = words[i:i + k] + [far]
        return words, True
    return words, False


def parakeet_punct(text, rng, lang):
    """Ponctuation façon Parakeet : la plupart des marques restent, certaines tombent ou se déplacent."""
    out = []
    toks = text.split(" ")
    for idx, w in enumerate(toks):
        m = re.search(r"[,;:]$", w)
        if m and rng.random() < 0.45:            # virgules souvent absentes
            w = w[:-1]
        if w.endswith("?") and rng.random() < 0.25:  # « ? » oublié ou devenu point
            w = w[:-1] + ("." if rng.random() < 0.5 else "")
            if w.endswith(" "):
                w = w[:-1]
        if idx == len(toks) - 1 and re.search(r"[.?!]$", w) and rng.random() < 0.35:
            w = re.sub(r"[.?!]+$", "", w)        # fin sans point
        out.append(w)
    s = " ".join(x for x in out if x)
    s = re.sub(r" ([?!:;])", r"\1" if rng.random() < 0.6 else r" \1", s) if lang == "fr" and rng.random() < 0.5 else s
    # Point de trop au milieu d'une phrase, suivi d'une minuscule : « mais par contre. le relief ».
    if rng.random() < 0.12:
        ws = s.split(" ")
        cands = [i for i in range(2, len(ws) - 2) if not re.search(r"[.?!,;:…]$", ws[i])]
        if cands:
            i = rng.choice(cands)
            ws[i] += "."
            s = " ".join(ws)
    # Coupure de phrase en trop avec majuscule : « …dans un sous-menu. Enfin dans un sous-truc ».
    if rng.random() < 0.12:
        ws = s.split(" ")
        cands = [i for i in range(3, len(ws) - 3) if not re.search(r"[.?!,;:…]$", ws[i]) and ws[i + 1][:1].islower()
                 and ws[i + 1] not in ("je", "j'ai")]
        if cands:
            i = rng.choice(cands)
            ws[i] += "."
            ws[i + 1] = ws[i + 1][:1].upper() + ws[i + 1][1:]
            s = " ".join(ws)
    # Deux phrases recollées sans ponctuation.
    if rng.random() < 0.15:
        s = re.sub(r"\. (\p{Lu})", lambda m: " " + (m.group(1).lower() if rng.random() < 0.5 else m.group(1)), s, count=1)
    return s


def make_raw_parakeet(clean, lang, rng, vocab):
    kind = []
    if rng.random() < 0.15:
        return clean, ["identique"]
    text = clean
    if rng.random() < 0.10:
        c = g.add_correction(text, lang, rng)
        if c:
            text = c; kind.append("correction")
    # Nombres : Parakeet écrit souvent les chiffres lui-même ; parfois en toutes lettres.
    if rng.random() < 0.35:
        text, had = g.verbalize(text, lang, rng, p_words=rng.choice([0.3, 0.6]))
        if had:
            kind.append("nombres")
    if rng.random() < 0.3:
        text = g.brand_noise(text, rng)
    text = parakeet_punct(text, rng, lang)
    words = text.split()
    nw = len(words)
    if lang == "fr" and rng.random() < 0.15:
        words, ok = det_restart(words, rng)
        if ok:
            kind.append("faux départ")
    if rng.random() < 0.2:
        words, ok = phrase_restart(words, rng)
        if ok:
            kind.append("faux départ")
    if rng.random() < 0.6:
        words = double_words(words, rng, rng.randint(1, max(1, nw // 40)))
        kind.append("mots doublés")
    if rng.random() < 0.3:
        for _ in range(rng.randint(1, 2)):
            i = rng.randint(1, max(1, len(words) - 1))
            words.insert(i, g.wchoice(rng, LIGHT_FILLERS[lang]))
        kind.append("hésitations")
    raw = re.sub(r"\s+", " ", " ".join(words)).strip()
    if raw[:1].islower() and rng.random() < 0.9:
        raw = raw[0].upper() + raw[1:]
    return raw, kind or ["ponctuation"]


def chat(raw, clean):
    return {"messages": [{"role": "system", "content": g.SYSTEM}, {"role": "user", "content": raw},
                         {"role": "assistant", "content": clean}]}


def main():
    corpus3, corpus1, old, out = map(Path, sys.argv[1:5])
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 3
    rng = random.Random(seed)
    long_lines = g.load_lines(corpus3)
    short_lines = g.load_lines(corpus1)
    vocab = g.build_vocab(long_lines + short_lines)
    # Monologues : 8 % en test, 4 % en validation, jamais vus à l'entraînement.
    idx = list(range(len(long_lines)))
    rng.shuffle(idx)
    n_test = len(idx) * 8 // 100
    test_ids, valid_ids = set(idx[:n_test]), set(idx[n_test:n_test + n_test // 2])
    # Phrases de test de Cleanup 1 : toujours tenues à l'écart.
    old_test = {json.loads(l)["ref"] for l in open(old / "test.meta.jsonl", encoding="utf-8")}
    split = {"train": [], "valid": [], "test": []}
    for i, (lang, clean, src) in enumerate(long_lines):
        part = "test" if i in test_ids else "valid" if i in valid_ids else "train"
        for _ in range(7 if part == "train" else 1):
            raw, kind = make_raw_parakeet(clean, lang, rng, vocab)
            split[part].append({**chat(raw, clean), "lang": lang, "kind": kind + ["monologue"]})
        # Deux monologues d'une traite (dictée de deux minutes).
        if part == "train" and rng.random() < 0.3:
            other = long_lines[rng.choice([j for j in idx[n_test + n_test // 2:]])]
            joined = clean + " " + other[1]
            if other[0] == lang and len(joined.split()) <= 260:
                raw, kind = make_raw_parakeet(joined, lang, rng, vocab)
                split[part].append({**chat(raw, joined), "lang": lang, "kind": kind + ["monologue", "long"]})
        # Ancien style (sans ponctuation, beaucoup d'hésitations) sur les monologues : le modèle doit savoir les deux.
        if part == "train" and rng.random() < 0.5:
            pool = [l[1] for l in short_lines if l[0] == lang]
            raw, kind = g.make_raw(clean, lang, rng, vocab, pool)
            split[part].append({**chat(raw, clean), "lang": lang, "kind": kind + ["monologue", "ancien bruit"]})
    # Textes courts de l'ancien corpus, bruités façon Parakeet (souvent déjà propres : ne rien abîmer).
    for lang, clean, src in short_lines:
        if clean in old_test:
            continue
        if rng.random() < 0.6:
            raw, kind = make_raw_parakeet(clean, lang, rng, vocab)
            split["train"].append({**chat(raw, clean), "lang": lang, "kind": kind + ["court"]})
    n_new = len(split["train"])
    # Une part des données v2 (bruit d'origine) pour ne rien perdre de ce que Cleanup 1 savait faire.
    v2 = [json.loads(l) for l in open(old / "train.jsonl", encoding="utf-8")]
    rng.shuffle(v2)
    for r in v2[:int(n_new * 0.9)]:
        split["train"].append({**r, "lang": "", "kind": ["v2"]})
    out.mkdir(parents=True, exist_ok=True)
    for part, rows in split.items():
        rng.shuffle(rows)
        with open(out / f"{part}.jsonl", "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps({"messages": r["messages"]}, ensure_ascii=False) + "\n")
        with open(out / f"{part}.meta.jsonl", "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps({"raw": r["messages"][1]["content"], "ref": r["messages"][2]["content"],
                                    "lang": r["lang"], "kind": r["kind"]}, ensure_ascii=False) + "\n")
        print(part, len(rows))




# --------------------------------------------------------------------------- quatrième passe (fragments)

OPEN_WORDS = re.compile(r"(?i)^(de|d'|du|des|que|qu'|qui|c'est|le|la|les|l'|un|une|à|au|aux|et|mais|pour|sur|dans|avec|"
                        r"on|je|j'|tu|il|elle|nous|vous|est-ce|si|parce|comme|en|ma|mon|mes|ton|ta|ce|cette|"
                        r"the|to|a|an|and|of|my|your|is|that|for|with|in|on|but|so|I|we|you|it|can|if)$")

def make_fragment(clean, lang, rng, vocab):
    """Dictée coupée en pleine phrase (on relâche la touche trop tôt) : la cible garde les mots et finit par
    « ... ». Le modèle ne doit jamais inventer la suite."""
    words = clean.split()
    if len(words) < 3:
        return None
    # Coupure après un mot qui appelle une suite (« de », « que », « c'est », « the »…) : la phrase est
    # visiblement inachevée. Une dictée courte mais complète (« Merci. ») ne doit pas gagner de « ... ».
    ends = [k for k in range(2, min(len(words), rng.choice([5, 9, 16, 41]))) if OPEN_WORDS.search(words[k - 1])]
    if not ends:
        return None
    k = rng.choice(ends)
    cut = " ".join(words[:k]).rstrip(",;:")
    if re.search(r"[.?!…]$", cut):
        return None
    ref = cut + "..."
    raw, kind = make_raw_parakeet(cut, lang, rng, vocab)
    raw = re.sub(r"[.…]+$", "", raw)
    r = rng.random()
    if r < 0.2:
        raw += "."
    elif r < 0.3 and lang == "fr":
        raw += " ?" if rng.random() < 0.5 else "?"
    elif r < 0.4:
        raw += "..."
    return raw, ref


def main_fragments():
    """python gen3.py --fragments corpus-v3 ancien-corpus data-v3 sortie : data-v3 + fragments."""
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    corpus3, corpus1, base, out = map(Path, a[:4])
    rng = random.Random(4)
    lines = g.load_lines(corpus3) + g.load_lines(corpus1)
    vocab = g.build_vocab(lines)
    held = {json.loads(l)["ref"] for f in ("test.meta.jsonl", "valid.meta.jsonl") for l in open(base / f, encoding="utf-8")}
    held |= {json.loads(l)["ref"] for l in open(Path.home() / "murmure-cleanup/data-v2/test.meta.jsonl", encoding="utf-8")}
    extra = []
    for lang, clean, src in lines:
        if any(clean in h or h in clean for h in held if len(h) > 30) or clean in held:
            continue
        if rng.random() < 0.45:
            f = make_fragment(clean, lang, rng, vocab)
            if f:
                extra.append(chat(*f))
        if src == "fr_non":
            for _ in range(6):
                raw, _ = make_raw_parakeet(clean, lang, rng, vocab)
                extra.append(chat(raw, clean))
    rows = [json.loads(l) for l in open(base / "train.jsonl", encoding="utf-8")]
    rows += extra
    rng.shuffle(rows)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "train.jsonl", "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps({"messages": r["messages"]}, ensure_ascii=False) + "\n")
    for part in ("valid", "test"):
        for suffix in (".jsonl", ".meta.jsonl"):
            (out / (part + suffix)).write_text((base / (part + suffix)).read_text(encoding="utf-8"), encoding="utf-8")
    print("fragments et « non » ajoutés :", len(extra), "train :", len(rows))


if __name__ == "__main__":
    main_fragments() if "--fragments" in sys.argv else main()

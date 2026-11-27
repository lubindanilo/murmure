"""Génère les paires (dictée brute → texte propre) pour Murmure Cleanup 1.

On part de textes PROPRES (corpus/*.txt, une ligne = un texte) et on fabrique la dictée brute
telle que Parakeet la rendrait : hésitations, répétitions, corrections orales, nombres et adresses
dits en toutes lettres, ponctuation et majuscules partielles. La cible est le texte propre d'origine,
donc juste par construction.

    python gen.py <dossier corpus> <dossier sortie> [--variants 6] [--seed 1]
"""
import json, random, re, sys, unicodedata
from pathlib import Path
from num2words import num2words

SYSTEM = "Nettoie cette dictée."

# --------------------------------------------------------------------------- nombres

def n2w(n, lang, to="cardinal"):
    w = num2words(n, lang=lang, to=to)
    return w.replace(",", "") if lang == "en" else w

def int_of(s):
    return int(re.sub(r"[\s  ,]", "", s))

def digits_plain(s):
    """Forme « Parakeet » d'un nombre : chiffres sans séparateur de milliers."""
    return re.sub(r"[\s  ]", "", s)

# --------------------------------------------------------------------------- verbalisation

TLDS = r"(?:com|fr|io|ai|so|app|studio|org|net|dev|co|be|ch|eu|me|tv|uk|us|ca|de|es|it|xyz)"
EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
URL = re.compile(r"(?:https?://)?(?:www\.)?[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\." + TLDS + r"(?:/[\w/.-]*[\w/])?(?![\w])")

def spell_addr(s, lang, rng):
    fr = lang == "fr"
    out = []
    i = 0
    proto = re.match(r"https?://", s)
    if proto:
        out.append(("h t t p s" if s.startswith("https") else "h t t p") + (" deux points slash slash" if fr else " colon slash slash"))
        s = s[proto.end():]
    for tok in re.split(r"([.@/_+-])", s):
        if tok == "":
            continue
        if tok == ".":
            out.append("point" if fr else "dot")
        elif tok == "@":
            out.append("arobase" if fr else "at")
        elif tok == "/":
            out.append("slash")
        elif tok == "-":
            out.append("tiret" if fr else rng.choice(["dash", "hyphen"]))
        elif tok == "_":
            out.append("tiret du bas" if fr else "underscore")
        elif tok == "+":
            out.append("plus")
        elif tok == "www":
            out.append(rng.choice(["w w w", "www"]))
        elif tok.isdigit():
            out.append(" ".join(n2w(int(c), lang) for c in tok) if len(tok) > 2 else n2w(int(tok), lang))
        else:
            out.append(tok.lower())
    return " ".join(out)

FR_PATTERNS = [
    ("email", EMAIL),
    ("url", URL),
    ("phone", re.compile(r"(?<![\d])0\d(?:[ .]\d\d){4}(?![\d])")),
    ("time", re.compile(r"(?<![\w])(\d{1,2})h(\d{2})?(?![\w])")),
    ("money", re.compile(r"(?<![\w,])(\d{1,3}(?:[   ]\d{3})+|\d+)(?:,(\d{1,2}))?[   ]?€")),
    ("percent", re.compile(r"(?<![\w,])(\d+)(?:,(\d+))?[   ]?%")),
    ("ord", re.compile(r"(?<![\w])1er(?![\w])")),
    ("decimal", re.compile(r"(?<![\w,.])(\d+),(\d+)(?![\w,]|\.\d)")),
    ("int", re.compile(r"(?<![\w,.\-/€$])(\d{1,3}(?:[   ]\d{3})+|\d+)(?![\w,\-/]|\.\d)")),
]
EN_PATTERNS = [
    ("email", EMAIL),
    ("url", URL),
    ("phone", re.compile(r"(?<![\d])\d{3}-\d{3}-\d{4}(?![\d])")),
    ("time", re.compile(r"(?<![\w:])(\d{1,2})(?::(\d{2}))?\s?(am|pm|a\.m\.|p\.m\.)(?![\w])", re.I)),
    ("money", re.compile(r"([$€£])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?(?:\s(million|billion|k))?")),
    ("percent", re.compile(r"(?<![\w.])(\d+)(?:\.(\d+))?%")),
    ("ord", re.compile(r"(?<![\w])(\d+)(st|nd|rd|th)(?![\w])")),
    ("decimal", re.compile(r"(?<![\w,.])(\d+)\.(\d+)(?![\w.]|,\d)")),
    ("int", re.compile(r"(?<![\w,.\-/$€£:])(\d{1,3}(?:,\d{3})+|\d+)(?![\w\-/:%]|[.,]\d)")),
]

def is_year(s):
    return re.fullmatch(r"(19|20)\d\d", s) is not None

def fr_spoken(kind, m, rng, words):
    """Forme dite d'un nombre en français. words=False : forme chiffrée « brute » façon Parakeet."""
    g = m.group(0)
    if kind == "phone":
        pairs = re.split(r"[ .]", g)
        if not words:
            return rng.choice([g.replace(".", " "), "".join(pairs)])
        return " ".join(("zéro " + n2w(int(p[1]), "fr")) if p[0] == "0" else n2w(int(p), "fr") for p in pairs)
    if kind == "time":
        h, mn = int(m.group(1)), m.group(2)
        if not words:
            return rng.choice([f"{h} heures" + (f" {mn}" if mn else ""), f"{h} h" + (f" {mn}" if mn else ""), g])
        hw = "une heure" if h == 1 else f"{n2w(h, 'fr')} heures"
        if h == 12 and not mn and rng.random() < 0.3:
            hw = "douze heures"
        if mn:
            if mn == "30" and rng.random() < 0.4:
                return hw + " et demie"
            if mn == "15" and rng.random() < 0.3:
                return hw + " et quart"
            return hw + " " + n2w(int(mn), "fr")
        return hw
    if kind == "money":
        n, cents = int_of(m.group(1)), m.group(2)
        if not words:
            base = digits_plain(m.group(1)) + ("," + cents if cents else "")
            return base + rng.choice([" euros", " euros", "€", " €"])
        w = n2w(n, "fr")
        if cents:
            c = n2w(int(cents.ljust(2, "0")), "fr")
            return rng.choice([f"{w} euros {c}", f"{w} virgule {c} euros"])
        return w + (" euro" if n == 1 else " euros")
    if kind == "percent":
        a, b = m.group(1), m.group(2)
        if not words:
            return (a + ("," + b if b else "")) + rng.choice([" pour cent", "%", " %"])
        return n2w(int(a), "fr") + (" virgule " + n2w(int(b), "fr") if b else "") + " pour cent"
    if kind == "ord":
        return "premier"
    if kind == "decimal":
        if not words:
            return g
        return n2w(int(m.group(1)), "fr") + " virgule " + " ".join([n2w(int(m.group(2)), "fr")] if not m.group(2).startswith("0") else [n2w(int(c), "fr") for c in m.group(2)])
    if kind == "int":
        s = m.group(1)
        if not words:
            return digits_plain(s)
        n = int_of(s)
        if len(s) == 4 and is_year(s) and rng.random() < 0.9:
            return n2w(n, "fr")
        if s.startswith("0") and len(s) > 1:
            return " ".join(n2w(int(c), "fr") for c in s)
        return n2w(n, "fr")
    return g

def en_spoken(kind, m, rng, words):
    g = m.group(0)
    if kind == "phone":
        if not words:
            return rng.choice([g, g.replace("-", " ")])
        return ", ".join(" ".join(n2w(int(c), "en") for c in part) for part in g.split("-"))
    if kind == "time":
        h, mn, ap = int(m.group(1)), m.group(2), m.group(3).lower().replace(".", "")
        apw = rng.choice([ap, " ".join(ap), ap + ""]) if words else rng.choice([ap, ap.upper(), " ".join(ap) ])
        if not words:
            return f"{h}" + (f":{mn}" if mn else "") + " " + apw
        hw = n2w(h, "en")
        if mn:
            mw = ("oh " + n2w(int(mn), "en")) if mn.startswith("0") else n2w(int(mn), "en")
            return f"{hw} {mw} {apw}"
        return f"{hw} {apw}" if rng.random() < 0.8 else f"{hw} o'clock {apw}"
    if kind == "money":
        cur, num, cents, mult = m.group(1), m.group(2), m.group(3), m.group(4)
        name = {"$": "dollars", "€": "euros", "£": "pounds"}[cur]
        n = int(num.replace(",", ""))
        if not words:
            return num.replace(",", "") + ("." + cents if cents else "") + (" " + mult if mult else "") + " " + name
        w = n2w(n, "en")
        if mult:
            return f"{w} {mult if mult != 'k' else 'thousand'} {name}"
        if cents:
            return rng.choice([f"{w} {name} and {n2w(int(cents), 'en')} cents", f"{w} {n2w(int(cents), 'en')}"])
        return w + " " + (name if n != 1 else name[:-1])
    if kind == "percent":
        a, b = m.group(1), m.group(2)
        if not words:
            return a + ("." + b if b else "") + rng.choice([" percent", "%"])
        return n2w(int(a), "en") + (" point " + " ".join(n2w(int(c), "en") for c in b) if b else "") + " percent"
    if kind == "ord":
        if not words:
            return g
        return n2w(int(m.group(1)), "en", to="ordinal")
    if kind == "decimal":
        if not words:
            return g
        return n2w(int(m.group(1)), "en") + " point " + " ".join(n2w(int(c), "en") for c in m.group(2))
    if kind == "int":
        s = m.group(1)
        if not words:
            return s.replace(",", "")
        n = int(s.replace(",", ""))
        if is_year(s) and rng.random() < 0.9:
            return n2w(n, "en", to="year")
        return n2w(n, "en")
    return g

def verbalize(text, lang, rng, p_words):
    patterns = FR_PATTERNS if lang == "fr" else EN_PATTERNS
    spans = []
    for kind, rx in patterns:
        for m in rx.finditer(text):
            if any(not (m.end() <= a or m.start() >= b) for a, b, _ in spans):
                continue
            if kind in ("email", "url"):
                rep = spell_addr(m.group(0), lang, rng) if rng.random() < 0.92 else m.group(0)
            else:
                spoken = fr_spoken if lang == "fr" else en_spoken
                rep = spoken(kind, m, rng, rng.random() < p_words)
            spans.append((m.start(), m.end(), rep))
    for a, b, rep in sorted(spans, reverse=True):
        text = text[:a] + rep + text[b:]
    return text, bool(spans)

# --------------------------------------------------------------------------- corrections orales

FR_DAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
EN_DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
FR_MONTHS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
EN_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
NAMES = ["Louis", "Axel", "Thomas", "Marie", "Inès", "Karim", "Chloé", "Arthur", "Léa", "Mehdi", "Sarah", "Julien",
         "Camille", "Nathan", "Emma", "Hugo", "Manon", "Yanis", "Zoé", "Lucas", "Jade", "Paul", "Alice", "Marc", "Julie",
         "Antoine", "Clara", "Maxime", "Lina", "Victor", "Jean-Baptiste", "Nina", "Samir", "Pauline", "Adam", "John",
         "Emily", "Mike", "Jessica", "David", "Rachel", "Tom", "Kevin", "Laura", "Chris", "Anna", "Ben", "Olivia"]
FR_MARKERS = [", enfin non, ", ", non pardon, ", ", pardon, ", ", enfin, ", ", je veux dire, ", ", non attends, ",
              ", ou plutôt ", ", euh non, ", ", non, ", ", enfin non plutôt ", ", non en fait, ", ", attends non, ",
              ", euh, enfin, ", ", non, je me trompe, "]
EN_MARKERS = [", I mean, ", ", sorry, ", ", no wait, ", ", actually, ", ", or rather ", ", no, ", ", uh no, ",
              ", scratch that, ", ", no sorry, ", ", I mean actually "]
PREPS = {"fr": {"à", "avant", "le", "la", "les", "de", "pour", "vers", "chez", "avec", "après", "dès", "jusqu'à", "en", "du", "au", "et", "à"},
         "en": {"at", "on", "before", "by", "to", "with", "for", "after", "in", "the", "from", "until", "and"}}

def slot_candidates(text, lang):
    days = FR_DAYS if lang == "fr" else EN_DAYS
    months = FR_MONTHS if lang == "fr" else EN_MONTHS
    rx = []
    flags = re.I if lang == "fr" else 0
    rx.append(("day", re.compile(r"(?<![\w])(" + "|".join(days) + r")(?![\w])", flags)))
    rx.append(("month", re.compile(r"(?<![\w])(" + "|".join(months) + r")(?![\w])", flags)))
    rx.append(("name", re.compile(r"(?<![\w-])(" + "|".join(NAMES) + r")(?![\w-])")))
    if lang == "fr":
        rx.append(("time", re.compile(r"(?<![\w])\d{1,2}h(\d{2})?(?![\w])")))
        rx.append(("money", re.compile(r"(?<![\w,])\d[\d ]*(,\d+)? ?€")))
        rx.append(("percent", re.compile(r"(?<![\w,])\d+(,\d+)? ?%")))
        rx.append(("num", re.compile(r"(?<![\w,.])\d{2,3}(?![\w,.]) (?=\w)")))
    else:
        rx.append(("time", re.compile(r"(?<![\w:])\d{1,2}(:\d{2})? ?(am|pm)(?![\w])")))
        rx.append(("money", re.compile(r"\$\d[\d,]*(\.\d\d)?")))
        rx.append(("percent", re.compile(r"(?<![\w.])\d+%")))
        rx.append(("num", re.compile(r"(?<![\w,.$])\d{2,3}(?![\w,.%]) (?=\w)")))
    out = []
    for kind, r in rx:
        for m in r.finditer(text):
            out.append((kind, m.start(), m.end(), m.group(0)))
    return out

def alt_value(kind, value, lang, rng):
    days = FR_DAYS if lang == "fr" else EN_DAYS
    months = FR_MONTHS if lang == "fr" else EN_MONTHS
    if kind in ("day", "month"):
        pool = days if kind == "day" else months
        low = value.lower()
        choices = [d for d in pool if d.lower() != low]
        d = rng.choice(choices)
        return d.capitalize() if value[0].isupper() else (d if lang == "en" else d.lower())
    if kind == "name":
        return rng.choice([n for n in NAMES if n != value])
    def bump(n):
        deltas = [d for d in (-3, -2, -1, 1, 2, 3, 5, 10) if n + d > 0]
        return n + rng.choice(deltas) if n < 30 else int(n * rng.choice([0.5, 0.8, 1.2, 1.5, 2]))
    if kind == "time":
        if lang == "fr":
            m = re.match(r"(\d{1,2})h(\d{2})?", value)
            h = int(m.group(1)); h2 = max(1, min(23, h + rng.choice([-2, -1, 1, 2])))
            return f"{h2}h" + (m.group(2) or "") if rng.random() < 0.6 else f"{h2}h"
        m = re.match(r"(\d{1,2})(:\d{2})? ?(am|pm)", value)
        h = int(m.group(1)); h2 = max(1, min(12, h + rng.choice([-2, -1, 1, 2])))
        return f"{h2}{m.group(2) or ''} {m.group(3)}"
    if kind == "money":
        if lang == "fr":
            n = int_of(re.match(r"[\d ]+", value).group(0))
            n2 = max(1, bump(n))
            s = f"{n2:,}".replace(",", " ") if n2 >= 1000 else str(n2)
            return s + " €"
        n = int(re.sub(r"[^\d]", "", value.split(".")[0]))
        n2 = max(1, bump(n))
        return "$" + f"{n2:,}"
    if kind == "percent":
        n = int(re.match(r"\d+", value).group(0))
        return f"{max(1, bump(n))}" + (" %" if lang == "fr" else "%")
    if kind == "num":
        n = int(value.strip())
        return f"{max(10, bump(n))} "
    return value

def add_correction(text, lang, rng):
    cands = slot_candidates(text, lang)
    if not cands:
        return None
    kind, a, b, value = rng.choice(cands)
    wrong = alt_value(kind, value, lang, rng)
    if wrong == value:
        return None
    trailing = ""
    if value.endswith(" "):
        value, wrong, trailing = value[:-1], wrong.rstrip(), " "
        b -= 1
    before = text[:a]
    # Répète la préposition : « avant vendredi, enfin non, avant jeudi ».
    mprep = re.search(r"(\S+) $", before)
    prep = ""
    if mprep and mprep.group(1).lower().strip("'’") in PREPS[lang] and rng.random() < 0.75:
        prep = mprep.group(1) + " "
    marker = rng.choice(FR_MARKERS if lang == "fr" else EN_MARKERS)
    plutot = ""
    if lang == "fr" and marker in (", enfin, ", ", pardon, ") and rng.random() < 0.35:
        plutot = ", plutôt"
    raw = before + wrong + marker + prep + value + plutot + text[b:]
    return raw

def add_restart(text, other, lang, rng):
    """Faux départ : « on pourrait, non attends, il faudrait… » → seule la phrase gardée reste."""
    w = other.split()
    if len(w) < 3:
        return None
    frag = " ".join(w[: rng.randint(2, min(5, len(w) - 1))]).rstrip(",.;:!?")
    marker = rng.choice(FR_MARKERS if lang == "fr" else EN_MARKERS)
    return frag + marker + text[0].lower() + text[1:] if text[:1].isupper() and not text.split()[0] in NAMES else frag + marker + text

# --------------------------------------------------------------------------- bruit oral

FR_FILLERS = [("euh", 40), ("heu", 4), ("euh euh", 3), ("hum", 8), ("hmm", 2), ("bah", 6), ("ben", 6), ("genre", 7),
              ("tu vois", 3), ("euh bah", 2), ("hein", 2), ("euh ben", 1)]
EN_FILLERS = [("um", 30), ("uh", 30), ("uhm", 4), ("er", 3), ("like", 8), ("you know", 6), ("um like", 2), ("hmm", 3)]
START_FILLERS = {"fr": [("euh", 10), ("bah", 3), ("ben", 3), ("hum", 3), ("euh euh", 1), ("hum euh", 1)],
                 "en": [("um", 10), ("uh", 8), ("uh um", 1), ("hmm", 2)]}

def wchoice(rng, items):
    tot = sum(w for _, w in items)
    r = rng.random() * tot
    for v, w in items:
        r -= w
        if r <= 0:
            return v
    return items[-1][0]

def insert_fillers(words, lang, rng, n):
    for _ in range(n):
        if rng.random() < 0.2:
            words.insert(0, wchoice(rng, START_FILLERS[lang]))
            continue
        i = rng.randint(1, max(1, len(words) - 1))
        f = wchoice(rng, FR_FILLERS if lang == "fr" else EN_FILLERS)
        words.insert(i, f)
    return words

def add_repetitions(words, rng, n):
    for _ in range(n):
        if len(words) < 3:
            break
        k = rng.choice([1, 1, 1, 2, 2, 3])
        i = rng.randint(0, max(0, len(words) - k - 1))
        span = words[i:i + k]
        if any(re.search(r"[.?!]$", w) for w in span):
            continue
        span = [re.sub(r"[,;:]$", "", w) for w in span]
        extra = [wchoice(rng, [("euh", 3), ("", 6)])] if rng.random() < 0.3 else []
        words[i:i] = span + [e for e in extra if e]
    return words

PUNCT = re.compile(r"\s*[.,;:!?…]+(?=\s|$)")

def strip_punct(text, lower_vocab, rng, mode):
    """mode none : plus de ponctuation ni de majuscule de début de phrase ; partial : en partie."""
    if mode == "full":
        return text
    def lower_word(w):
        core = re.sub(r"^[\W_]+", "", w)
        key = core.lower().rstrip(".,;:!?…")
        if core[:1].isupper() and key in lower_vocab and not core.isupper():
            return w.replace(core[0], core[0].lower(), 1)
        return w
    out = []
    prev_end = True
    for w in text.split(" "):
        if w == "":
            continue
        if w in ("?", "!", ":", ";"):
            if mode == "none" or rng.random() < 0.6:
                continue
            out.append(w); continue
        sentence_start = prev_end
        prev_end = bool(re.search(r"[.!?…]$", w))
        if mode == "none":
            w2 = re.sub(r"[.,;:!?…]+$", "", w) if not re.search(r"\d[.,]\d", w[-3:]) else w
            if sentence_start:
                w2 = lower_word(w2)
            out.append(w2)
        else:
            m = re.search(r"[.,;:!?…]+$", w)
            if m and rng.random() < 0.5:
                p = m.group(0)
                w2 = w[: m.start()]
                if p == "?" and rng.random() < 0.4:
                    w2 += "."
                elif p == "." and rng.random() < 0.3:
                    w2 += ","
                w = w2
            out.append(w)
    s = " ".join(out)
    if mode == "none" and out:
        s = lower_word(out[0]) + s[len(out[0]):]
    return s

BRAND_VARIANTS = {"GitHub": ["github", "Github", "git hub"], "ChatGPT": ["chat GPT", "Chat GPT", "chatgpt"],
                  "LinkedIn": ["linkedin", "Linkedin"], "HubSpot": ["hubspot", "Hubspot"], "WhatsApp": ["whatsapp", "Whatsapp"],
                  "Notion": ["notion"], "Slack": ["slack"], "Figma": ["figma"], "Stripe": ["stripe"], "Vercel": ["vercel"],
                  "TypeScript": ["typescript", "Typescript"], "JavaScript": ["javascript", "Javascript"],
                  "PostgreSQL": ["postgresql", "Postgres QL"], "iPhone": ["iphone", "Iphone"], "macOS": ["mac OS", "MacOS"],
                  "YouTube": ["youtube", "Youtube"], "Airtable": ["airtable"], "Mibba": ["mibba", "Mibaa"],
                  "Hyperstack": ["hyperstack", "Hyper stack"], "Murmure": ["murmure"], "Claude": ["claude"],
                  "Next.js": ["next JS", "NextJS"], "Supabase": ["supabase", "Supa base"], "n8n": ["N8N", "n 8 n"],
                  "Zoom": ["zoom"], "Gmail": ["gmail"], "TikTok": ["tiktok", "Tiktok"], "Qonto": ["qonto"],
                  "Pennylane": ["penny lane", "Penny Lane"], "Webflow": ["webflow", "Web flow"], "API": ["api"],
                  "JSON": ["json", "Json"], "CSV": ["csv"], "PDF": ["pdf"], "SQL": ["sql"]}

def brand_noise(text, rng):
    for brand, variants in BRAND_VARIANTS.items():
        if brand in text and rng.random() < 0.35:
            text = re.sub(r"(?<![\w@./-])" + re.escape(brand) + r"(?![\w@-]|\.\w)", rng.choice(variants), text)
    return text

# --------------------------------------------------------------------------- assemblage

def make_raw(clean, lang, rng, lower_vocab, others):
    kind = []
    r = rng.random()
    if r < 0.10:
        return clean, ["identique"]
    text = clean
    if rng.random() < 0.22:
        c = add_correction(text, lang, rng)
        if c:
            text, _ = c, kind.append("correction")
    elif rng.random() < 0.04:
        c = add_restart(text, rng.choice(others), lang, rng)
        if c:
            text, _ = c, kind.append("faux départ")
    text, had_num = verbalize(text, lang, rng, p_words=rng.choice([0.9, 0.7, 0.5]))
    if had_num:
        kind.append("nombres")
    text = brand_noise(text, rng)
    mode = rng.choices(["none", "partial", "full"], [0.5, 0.33, 0.17])[0]
    text = strip_punct(text, lower_vocab, rng, mode)
    words = text.split()
    nw = len(words)
    if rng.random() < 0.75:
        n = rng.randint(1, max(1, nw // 7))
        words = insert_fillers(words, lang, rng, n)
        kind.append("hésitations")
    if rng.random() < 0.35:
        words = add_repetitions(words, rng, rng.randint(1, max(1, nw // 15)))
        kind.append("répétitions")
    raw = " ".join(words)
    if mode != "none":
        # Parakeet met souvent des virgules autour des hésitations.
        fl = "euh|heu|hum|bah|ben|um|uh|uhm"
        raw = re.sub(r"(?<=\w) (" + fl + r") (?=\w)", lambda m: (", " + m.group(1) + ", ") if rng.random() < 0.4 else m.group(0), raw)
    raw = re.sub(r"\s+", " ", raw).strip()
    if raw[:1].islower() and mode != "none":
        raw = raw[0].upper() + raw[1:]
    return raw, kind

def load_lines(folder):
    data = []
    for f in sorted(Path(folder).glob("*.txt")):
        lang = "en" if f.stem.startswith("en") else "fr"
        for line in f.read_text(encoding="utf-8").splitlines():
            line = unicodedata.normalize("NFC", line.strip())
            line = line.replace(" ", " ").replace(" ", " ").replace("’", "'")
            if len(line) >= 2:
                data.append((lang, line, f.stem))
    return data

def build_vocab(lines):
    """Mots écrits en minuscules quelque part : on peut les décapitaliser en début de phrase."""
    v = set()
    for _, t, _ in lines:
        for w in re.findall(r"[\w'-]+", t):
            if w.islower():
                v.add(w)
    for w in ["je", "j'ai", "on", "tu", "il", "elle", "nous", "vous", "ils", "salut", "bonjour", "merci", "est-ce", "c'est",
              "i'm", "we", "you", "hey", "hi", "can", "could", "the", "it's", "ok", "oui", "non", "alors", "donc", "et", "mais"]:
        v.add(w)
    v.discard("i")
    return v

def chat(raw, clean):
    return {"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": raw},
                         {"role": "assistant", "content": clean}]}

def main():
    corpus, out = Path(sys.argv[1]), Path(sys.argv[2])
    variants = int(sys.argv[sys.argv.index("--variants") + 1]) if "--variants" in sys.argv else 6
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    rng = random.Random(seed)
    lines = load_lines(corpus)
    vocab = build_vocab(lines)
    # Lignes de test tenues à l'écart : jamais vues à l'entraînement, même bruitées autrement.
    idx = list(range(len(lines)))
    rng.shuffle(idx)
    n_test = max(40, len(lines) // 14)
    test_ids, valid_ids = set(idx[:n_test]), set(idx[n_test:n_test + n_test // 2])
    split = {"train": [], "valid": [], "test": []}
    by_lang = {"fr": [l for l in lines if l[0] == "fr"], "en": [l for l in lines if l[0] == "en"]}
    for i, (lang, clean, src) in enumerate(lines):
        part = "test" if i in test_ids else "valid" if i in valid_ids else "train"
        pool = [l[1] for l in by_lang[lang]]
        nv = variants if part == "train" else 1
        for _ in range(nv):
            raw, kind = make_raw(clean, lang, rng, vocab, pool)
            split[part].append({**chat(raw, clean), "lang": lang, "kind": kind})
        # Messages composés de plusieurs lignes (dictées longues d'une traite).
        if part == "train" and rng.random() < 0.5:
            parts = [clean] + [rng.choice(pool) for _ in range(rng.randint(1, 3))]
            joined = " ".join(parts)
            if len(joined.split()) <= 170:
                raw, kind = make_raw(joined, lang, rng, vocab, pool)
                split[part].append({**chat(raw, joined), "lang": lang, "kind": kind + ["long"]})
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

if __name__ == "__main__":
    main()

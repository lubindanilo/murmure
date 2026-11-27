# Murmure Cleanup 2

Deuxième version du petit modèle local qui nettoie la dictée simple (voir [cleanup-1.md](cleanup-1.md)).
Même base (Qwen2.5-0.5B-Instruct), même prompt de 20 tokens, même fichier Q6_K de 506 Mo : **la vitesse
ne bouge pas**. Ce qui change : il garde le sens des dictées longues, et un nouveau garde-fou retombe sur
les règles quand un passage entier disparaît.

## Pourquoi

Rejoué sur les vraies dictées de l'historique de Lubin (72 dictées du 26 au 27 novembre 2026), Cleanup 1
perdait un passage entier dans une dictée sur six, sans que le garde-fou le voie (il ne contrôlait que les
mots ajoutés, jamais les mots perdus). Le mécanisme était presque toujours le même : quand un groupe de mots
revient deux fois (« faire une… / faire la demande », « mais donc… / mais donc »), le modèle sautait de la
première reprise à la seconde et effaçait tout le milieu. Il coupait aussi des phrases au mauvais endroit
(« depuis que j'ai arrêté ça. Va mieux »).

La cause : il avait appris sur autre chose que ce que Parakeet rend vraiment.

| | Longueur médiane | Plus de 100 mots | Déjà ponctué |
|---|---|---|---|
| Données de Cleanup 1 | 17 mots | 4 % | 51 % |
| Banc d'évaluation de Cleanup 1 | 14,5 mots | 0 % | 24 % |
| Vraies dictées | 41 mots | 15 % | 96 % |

## Ce qui a changé

1. **Garde-fou des passages perdus** (`CleanupModel.lostPassage`, `evaluate.py: lost_passage`) : on aligne
   la dictée et la sortie mot à mot ; si au moins quatre mots porteurs de sens d'affilée ont disparu, sans
   être des hésitations, une répétition collée, un faux départ ni une correction orale (marqueur « non »,
   « pardon », « plutôt », « I mean »… dans les trois derniers mots du passage), on garde les règles.
   Moins d'une milliseconde. Aucun faux positif sur les bancs (50 + 133 + 354 dictées, et les 72 vraies),
   un sur 3 000 exemples d'entraînement. Swift et Python donnent le même verdict sur 334 cas.
2. **Corpus de monologues** (`training/cleanup-2/corpus/`, 640 textes de 50 à 220 mots, 86 % en
   français) : consignes à une IA, comptes rendus de projet, questions perso, longs messages, réflexions à
   voix haute. Chaque texte contient exprès un groupe de mots repris à distance : tout ce qui est entre
   les deux reprises doit ressortir.
3. **Bruit façon Parakeet** (`gen3.py`) : texte déjà ponctué, virgules manquantes, « ? » oubliés, point
   de trop au milieu d'une phrase, phrases recollées, mots doublés (« très très »), faux départs
   (« la seule le seul »), peu d'hésitations ; 15 % des exemples déjà propres doivent ressortir identiques.
   Plus une part des données de Cleanup 1 pour ne rien perdre.
4. **Troisième passe** (`train-v3.yaml`) : 600 itérations à partir de Cleanup 1. Point retenu : 400
   (perte de validation 0,031 contre 0,030 à 600 ; le point 600 a été perdu, disque plein).

## Résultats (27 novembre 2026, M4, 16 Go)

Les deux modèles avec le nouveau garde-fou, sauf mention contraire. WER = taux d'erreur par mot, plus bas
c'est mieux ; « contenu » ignore ponctuation et majuscules.

**Vraies dictées (72)**, banc privé gardé hors du dépôt (`~/murmure-cleanup/bench-real/`), références
écrites à la main :

| | WER | WER contenu | Passages perdus | Coupures en trop | Replis sur les règles |
|---|---|---|---|---|---|
| Règles seules | 0,119 | 0,016 | 0 | 0 | — |
| Cleanup 1, ancien garde-fou (ce qui tournait) | 0,113 | 0,042 | 12 | 18 | 3 |
| Cleanup 1, nouveau garde-fou | 0,093 | 0,020 | 5 | 14 | 10 |
| **Cleanup 2** | 0,104 | **0,018** | 6 | **10** | **7** |
| Cleanup 2 sans aucun garde-fou | 0,107 | 0,020 | 7 | 10 | — |

Le modèle seul perd moitié moins de passages que Cleanup 1 seul (7 contre 12) et coupe moins de phrases à
tort. Le garde-fou rattrape le reste en retombant sur les règles : avec lui, Cleanup 1 se rapproche, mais
au prix de 10 dictées non nettoyées sur 72. Les passages « perdus » restants de Cleanup 2 sont surtout des
reprises que le modèle traite comme des corrections (« pour le prochain event, pour le prochain Cloud
Office Hours »), plus discutables.

**Bancs synthétiques** :

| | Dictées réalistes (50) | Test propre (133) | Monologues (51, nouveau) |
|---|---|---|---|
| | identiques / WER | identiques / WER | identiques / WER |
| Cleanup 1 | 50 % / 0,080 | 64 % / 0,049 | 2 % / 0,044 |
| **Cleanup 2** | 46 % / **0,069** | **67 %** / **0,048** | **12 %** / **0,026** |

**Dans l'app** (`Murmure --cleanuptest`, décodage spéculatif, Q6_K) :

| | Dictées réalistes : médiane / p90 | Vraies dictées : médiane / p90 | Replis (vraies) | Identiques (vraies) |
|---|---|---|---|---|
| Cleanup 1 | 0,107 s / 0,174 s | 0,147 s / 0,466 s | 9 | 13/72 |
| Cleanup 2 | 0,100 s / 0,158 s | 0,159 s / 0,461 s | 4 | 16/72 |

## Ce qu'on a essayé et laissé

**Quatrième passe** (`train-v4.yaml`, non publiée) : dictées coupées en pleine phrase (la cible finit par
« ... ») et « non » qui ont un vrai sens (« non bullshit », « non commités »). Elle n'invente plus de suite
aux fragments, mais elle oublie les corrections orales (« non je me trompe », « pardon » restent) et
ajoute « ... » à des phrases complètes (« Moi aussi... ») : WER du test propre 0,048 → 0,063. Gardée pour
mémoire ; une prochaine passe devra mêler fragments et corrections en proportions équilibrées.

## Limites connues

- **Fragments très courts** (« Yeah, I », « …c'est ») : le modèle invente parfois une suite. Le garde-fou
  l'a rattrapé dans les trois cas vus ; sur une dictée longue qui finit en suspens, un seul mot inventé
  passerait (un mot nouveau sur vingt est toléré).
- **Heures** : comme Cleanup 1, il se trompe parfois sur une heure corrigée à voix haute ; il lui arrive
  de perdre les minutes (« seize heures trente » → « 16h » dans un cas). Le garde-fou des nombres ne
  vérifie pas les minutes d'une heure.
- **Mots mal reconnus par Parakeet** (« Cloud » pour Claude, « slope » pour slop) : le modèle ne les
  devine pas et le garde-fou l'en empêche exprès. La piste est un dictionnaire personnel, pas le modèle.
- Le reste des limites de Cleanup 1 (nombres longs, langues, M1 non mesuré) tient toujours.

## Fichiers

- Modèle : `murmure-cleanup-2.gguf` (Q6_K, 505 736 384 octets, SHA-256 `d798e560…49e4e1`). Pas encore
  publié : l'app pointe vers la release `models-cleanup-2` de murmure-releases, à créer à la prochaine
  publication. D'ici là, la CI (`--cleanuptest`) ne peut pas le télécharger.
- Sur le Mac de Lubin : `~/Library/Application Support/Murmure/Models/llm/murmure-cleanup-2.gguf` ; l'ancien
  `murmure-cleanup-1.gguf` n'est plus utilisé.
- Atelier : `~/murmure-cleanup` (`data-v3/`, `data-v4/`, `gguf/full-v3-0000400-q6k.gguf`, `bench-real/`).
- Reproduire : `python gen3.py corpus ../cleanup-1/corpus data-v2 data-v3`, puis
  `python -m mlx_lm lora -c train-v3.yaml`, puis `checkpoint.sh runs/full-v3 0000400`.

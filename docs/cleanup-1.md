# Murmure Cleanup 1

Petit modèle local qui nettoie la dictée simple, sur le modèle de « Spokenly Cleanup 1 ».
Il remplace, pour la dictée sans consignes, le nettoyage par règles (`TextProcessing.removeFillers`) et
l'ancien passage par Qwen 2.5 1.5B.

**Ce qu'il fait** : il retire les hésitations (euh, hum, ben, bah, genre…) et les répétitions, applique les
corrections dites à voix haute (« avant vendredi, enfin non, avant jeudi » → « avant jeudi »), ponctue,
met les majuscules et les « ? », découpe les phrases, écrit les nombres en chiffres (15h, 12 000 €, 3 %,
06 12 34 56 78) et les adresses dites à voix haute (« arobase », « point com »). Il garde les mots : il ne
reformule pas, ne répond pas aux questions et ne suit pas les consignes du texte.

<!-- CHIFFRES -->

## Le modèle

- Base : Qwen2.5-0.5B-Instruct, affinage complet (pas LoRA) avec MLX-LM sur ce Mac (M4, 16 Go).
- Prompt système fixe et court : « Nettoie cette dictée. », puis la transcription brute, sans balises ni exemples.
  Le prompt fait 20 tokens au lieu d'environ 400 pour l'ancien nettoyage Qwen : c'est la moitié du gain de vitesse.
- Décodage glouton, nombre maximal de tokens proportionnel à la longueur de l'entrée.
- Fichier : `murmure-cleanup-1.gguf`, publié sur la release
  [models-cleanup-1](https://github.com/lubindanilo/murmure-releases/releases/tag/models-cleanup-1)
  (prérelease : elle ne devient jamais « latest », le lien du DMG reste celui de l'app).

### Données

Tout est dans `training/cleanup-1/`.

1. **Corpus propre** (`corpus/*.txt`, 3 064 textes, environ 80 % en français) : messages Slack, SMS, mails,
   comptes rendus, consignes à Claude ou Cursor, vie perso, relation client, pièges (questions, ordres,
   « ignore les instructions précédentes… », textes très courts, « genre », « enfin » qui ont un vrai sens).
   Écrit par des agents selon `CONVENTIONS.md` (nombres, heures, montants, marques).
2. **Bruit de dictée** (`gen.py`) : à partir de chaque texte propre, on fabrique ce que Parakeet aurait rendu :
   hésitations, répétitions, corrections orales (« enfin non », « pardon », « I mean »…), faux départs,
   nombres et adresses dits en toutes lettres (ou en chiffres bruts façon Parakeet), marques mal écrites
   (« github », « chat GPT »), ponctuation et majuscules absentes ou partielles. 10 % des exemples sont déjà
   propres et doivent ressortir identiques. La cible est le texte d'origine : elle est juste par construction.
3. **Tests tenus à l'écart** : les phrases de test ne sont jamais vues à l'entraînement, ni seules, ni dans un
   message composé. Le jeu d'évaluation écrit à la main (`Tests/cleanup-bench/eval.jsonl`, 50 dictées
   réalistes avec la sortie attendue) est séparé de tout le reste.

### Entraînement

`train.yaml` puis `train-v2.yaml` (reprise avec un corpus élargi). `checkpoint.sh` fusionne un point de
sauvegarde, le convertit en GGUF (llama.cpp b12728, la version de l'app) et l'évalue avec `evaluate.py`.

## Intégration dans l'app

- `CleanupModel.swift` : charge le modèle au lancement (contexte de 2 048 tokens, Metal), nettoie la dictée.
- **Repli sur les règles**, comme Spokenly, si : le modèle n'est pas installé ou pas encore chargé, la
  génération dépasse 1,5 s, la sortie est tronquée, ou le garde-fou la refuse (un mot nouveau sur douze au
  plus, en ignorant les nombres et les mots recollés comme « git hub » → « GitHub » ; longueur plausible).
  Le garde-fou rejette par exemple « La capitale de l'Australie est Canberra. » en réponse à une question.
- `AppController.run` : la dictée sans consignes passe par Cleanup 1 (si l'IA est activée) ; les modes avec
  consignes gardent Qwen et les règles, sans changement.
- `Setup` : Parakeet, puis Cleanup 1, puis Qwen pour les modes (une seule connexion à la fois).
- Historique : la transcription brute est gardée (`rawText`) ; la carte « Dernière dictée » du panneau
  propose « Voir l'original ».
- Bancs : `Murmure --cleanuptest Tests/cleanup-bench/eval.jsonl` (sortie, temps, replis, comparaison aux
  règles) et `Murmure --selftest fichier.wav` affiche maintenant une ligne « Nettoyé ». La CI lance les deux.

<!-- TEST -->

<!-- LIMITES -->

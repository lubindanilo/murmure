# Nettoyage local : comparatif des LLM (nuit du 25 au 26 novembre 2026)

**Retenu : Qwen 2.5 1.5B Instruct (Q4_K_M, 1,1 Go)**, avec trois protections :
1. retrait déterministe des « euh / hum / uh » et des mots répétés avant l'IA (`TextProcessing.removeFillers`) ;
2. consigne courte avec trois exemples et texte balisé `<dictée>` (`PostProcessor.cleanupSystemPrompt`) ;
3. garde-fou : si la sortie garde moins de 75 % des mots dictés ou change la longueur de plus de 40 %,
   on colle la transcription (`PostProcessor.isFaithful`). Il attrape les cas où le modèle traduit,
   répond à la question ou résume.

## Méthode

10 dictées françaises et anglaises (`Tests/llm-bench/cases.txt`) : hésitations, faux départs, une question
technique, un ordre (« rappelle-moi… »), une demande de traduction, une question de culture générale.
Le piège principal : un petit modèle a tendance à *répondre* au lieu de recopier.

- Tour 1 (CI macOS, VM sans GPU, ancienne consigne) : Qwen 2.5 1.5B, Gemma 3 1B, Qwen 2.5 3B, Gemma 3 4B.
- Tours 2 à 4 (VPS, llama.cpp b12728, même moteur que l'app, température 0) : consignes v2 à v4.
  Script : `Tests/llm-bench/bench.py`.

## Résultats

| Modèle | Ancienne consigne | Consigne v4 + pré-nettoyage | Garde-fou |
|---|---|---|---|
| Gemma 3 1B (0,8 Go) | répond à la question technique, invente | recopie les exemples dans la sortie (v2) | écarté |
| Qwen 2.5 1.5B (1,1 Go) | ne nettoie pas, répond « je ne peux pas » | 9/10 parfaits, traduit 1 fois | la traduction est rejetée : 10/10 sûrs |
| Qwen 2.5 3B (2,1 Go) | coupe des morceaux de phrases | non retenu (plus lent, pas meilleur) | |
| Gemma 3 4B (2,5 Go) | le plus fidèle | remplace « Louis » par « il », traduit 1 fois | 9/10, plus lent ×3 |

Les durées mesurées en CI (50 à 130 s par phrase) viennent d'une VM sans GPU et ne valent rien pour un vrai Mac.
Sur le VPS (CPU ARM, 6 cœurs) : 1,1 à 4 s par phrase pour Qwen 1.5B, 3 à 17 s pour Gemma 4B. Sur une puce Apple
avec Metal, Qwen 1.5B Q4 se compte en centaines de millisecondes pour une phrase.

**À vérifier sur un vrai Mac** : la latence réelle du nettoyage après relâchement de la touche.
Si elle gêne, `Settings.aiEnabled` se coupe dans Réglages > Général.

## Pistes

- Affiner Qwen 2.5 1.5B (LoRA) sur quelques centaines de paires « brut → propre » : c'est probablement ce
  qu'a fait Spokenly avec « Spokenly Cleanup 1 ».
- Proposer Gemma 3 4B en option « qualité » pour les modes e-mail et reformulation.

# Modes : spécification fonctionnelle (référence Spokenly)

Relevé le 2026-11-25 dans la doc publique de Spokenly (spokenly.app/docs/modes, /docs/modes/agentic-actions,
/docs/modes/bash-scripts, /docs/word-replacements, /docs/macos/deeplinks, llms-full.txt).
On reprend les fonctions, pas les textes ni la marque. [S] = écrit dans la doc, [I] = déduit.

## Ce qu'est un mode [S]
Une configuration de dictée enregistrée : instructions IA, modèles, sortie, et façons de l'activer.
Il existe toujours un mode principal ; l'utilisateur en ajoute d'autres. Un mode sans instructions IA,
sans actions ni scripts se contente de dicter.

Réglages d'un mode :
- Nom.
- Instructions IA (prompt).
- Modèle de dictée et modèle de texte par mode (chez nous : modèle unique Parakeet Ultra, LLM global).
- Modèle de texte de secours.
- Sortie : Coller au curseur (remplace la sélection), Coller puis Entrée, Copier, Historique seulement.
- Contexte (Mac) : presse-papiers, nom de l'app active, texte de la fenêtre active, URL de l'onglet,
  contexte du curseur (sélection et texte autour).
- Avancé : nettoyage local, espacement / paragraphes / majuscules intelligents ; avec clé ou IA locale :
  consigne système, température, effort de raisonnement.
- Activation : raccourci du mode, mot déclencheur, apps, sites.
- Actions agentiques (Mac, pas dans le mode principal) et scripts Bash avant / après l'IA.
- Nettoyage par mode (Défaut / Activé / Désactivé) et ton du nettoyage.

## Choix du mode actif [S]
Priorité : mot déclencheur > raccourci du mode > site > app > mode principal.
- Mot déclencheur : dit au début de la dictée, retiré du texte (« email hey John… » → mode Email sur « Hey John… »).
- Apps : « ou quand je suis dans ». Sites : Mac seulement.
- Sélecteur de mode dans la fenêtre d'enregistrement (on pointe le mode pour en changer).
- Liens : `spokenly://start?mode_id=`, `toggle?mode_id=`, `switch?mode_id=` (sans enregistrer),
  `tab/modes`. Id copiable par clic droit sur le mode.
- Script : directive `switch_mode=NOM` pour continuer dans un autre mode.

## Contexte pour l'IA [S]
Variables dans la consigne système : `{{CONTEXT}}`, `{{CONTEXT.CLIPBOARD}}` ; l'éditeur liste les clés
disponibles ; une clé ne marche que si le contexte correspondant est activé dans le mode.
La consigne système remplace celle de l'app ; les instructions du mode viennent après.
Variables d'environnement des scripts : app active (+ bundle id), presse-papiers, sélection, texte avant /
après le curseur, URL, durée audio, fichier WAV, fichier de contrôle (toujours défini).

## Ordre de traitement [S]
Script avant l'IA (stdin → stdout) → instructions IA → script après l'IA → sortie.
Directives lues après chaque script : `skip_ai=1`, `output_mode=`, `switch_mode=`.
Étape vide sautée ; un script qui ne sort rien arrête tout sans insérer. zsh login, 30 s max, stderr en alerte.
Remplacements de mots : avant, après, ou avant et après l'IA (réglage par mode).

## Écran des modes [S]
Liste (chaque ligne montre raccourcis, apps, actions), bouton Nouveau mode, menu ⋯ / clic droit
(copier l'id), éditeur : instructions (bouton Actions), Activation, Avancé, Sortie, Contexte, modèles.
Tests : « Test » pour les actions, « Test Script » avec transcription et contexte d'exemple.

## Actions agentiques (Mac) [S]
Recherche Google, YouTube, ouvrir un site, demander à ChatGPT / Claude, lancer / fermer des apps,
Raccourcis Apple, commande shell, touches clavier. Hors périmètre de Murmure v1 (LLM local trop petit
pour l'appel d'outils fiable) : à reconsidérer après le lancement.

## Gratuit / payant chez Spokenly [S]
Modes gratuits avec clés perso ou IA locale. Leur IA hébergée demande Pro ou l'essai.

## Ce que Murmure implémente (Sources/Murmure/Core/Mode.swift)
Tout ce qui précède sauf : actions agentiques, modèle par mode, ton du nettoyage, smart spacing/paragraphs.
Ajout : traduction d'Apple par mode (`translateTo`).

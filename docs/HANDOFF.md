# Murmure : reprise sur le VPS (nuit du 25 au 26 novembre 2026)

Lubin dort. Objectif : **demain matin, il envoie le lien à ~30 contacts très intéressés, ils installent
Murmure et ça marche**. Les offres payantes ouvrent demain (essai de 7 jours, donc personne ne paie avant
le 3 décembre environ : Paddle peut être branché demain avec Lubin, mais tout doit être prêt à le recevoir).

Travaille en autonomie jusqu'à ce que tout soit prêt. Ne publie rien d'irréversible au nom de Lubin
(pas de message envoyé, pas de compte créé chez un tiers). Pousser sur ce dépôt privé et déployer sur
son Vercel et son VPS est autorisé (il l'a demandé).

## Ce qu'est Murmure

App de dictée macOS façon Spokenly : maintenir une touche, parler, relâcher, le texte est collé au curseur.
Swift natif (SPM, SwiftUI + AppKit), barre de menus. Interface en français.

## Décisions de Lubin (ne pas rouvrir)

1. **Un seul modèle de transcription : Parakeet Ultra** (FluidAudio, 632 Mo, 25 langues), téléchargé
   automatiquement au premier lancement. Pas de choix de modèle pour l'utilisateur, pas de cloud.
2. **Nettoyage par LLM local** (llama.cpp, GGUF), zéro coût de tokens. Qwen 2.5 1.5B ou Gemma 3 1B :
   à trancher par le comparatif (voir Tâches). Installé automatiquement aussi.
3. **Traduction : Apple Translation** (macOS 15+, gratuit, hors ligne). Déjà branché par mode (`translateTo`).
4. **Modes exactement comme Spokenly** (fonctions, pas les textes) : spec dans `docs/spokenly-modes-spec.md`.
5. **Essai gratuit de 7 jours, puis payant.** Prix pas encore fixé (abonnement ou à vie : le serveur gère les deux).
6. **Paddle Billing** pour encaisser (Lemon Squeezy ferme le 31/03/2027, Paddle Classic fermé).
   Pas de clés de licence natives chez Paddle : notre serveur les gère.
7. **Serveur de licences sur le VPS** (`claude-vps`).
8. **Pas de compte Apple Developer** : app non notarisée, distribuée depuis une page web.
9. **Landing page sur le Vercel de Lubin** : ultra simple, droite au but, esthétique, très propre, façon Apple.
10. **Simplicité maximale** : onboarding inspiré de celui de Spokenly (que Lubin trouve exceptionnel),
    puis le moins de menus et de boutons possible dans l'app. Aller à l'essentiel.

## État du code (commit initial)

- `Sources/Murmure/` : app complète qui compile (CLT Swift 6.1, SDK macOS 15.5, cible macOS 15).
  - `Core/AppController.swift` : touche → enregistrement → transcription → mode (mot déclencheur, scripts,
    IA, traduction, remplacements) → sortie. Priorité des modes conforme à Spokenly.
  - `Core/Mode.swift` : modèle de mode, `ModeStore` (JSON dans Application Support), modèles de modes.
  - `Core/DictationContext.swift` : contexte (app, sélection et texte autour du curseur via AX,
    presse-papiers, URL d'onglet via AppleScript).
  - `Core/ScriptRunner.swift` : scripts zsh avant/après l'IA, directives `skip_ai`, `output_mode`, `switch_mode`.
  - `Core/Setup.swift` : installation au premier lancement (Parakeet Ultra + LLM).
  - `Core/License.swift` : essai 7 jours (Keychain + serveur), jeton Ed25519 vérifié dans l'app.
    Clé publique déjà embarquée. URL du serveur : `LicenseManager.server` (défaut `https://murmure.app`,
    surchargeable par `defaults write app.murmure.Murmure licenseServer <url>`). **À remplacer par l'URL réelle.**
  - `AI/LlamaRunner.swift`, `AI/PostProcessor.swift` (LLM intégré, ou Ollama / LM Studio), `AI/Translator.swift`.
  - `Engines/` : Parakeet (toutes variantes FluidAudio), Whisper (WhisperKit), Apple Speech, cloud BYOK.
    Le catalogue complet reste dans le code mais l'UI ne montre plus de choix de modèle.
  - `UI/` : panneau d'enregistrement (`HUD.swift`, avec sélecteur de mode), réglages (Général, Modes,
    IA locale, Dictionnaire, Historique, Licence). **À simplifier fortement** (décision 10).
  - `App/SelfTest.swift` : `Murmure --selftest audio.wav [--model id] [--llm id] [--mode nom]`
    et `Murmure --llmtest textes.txt --llm id1,id2` (comparatif sans micro ni UI).
- `Scripts/build-app.sh` : construit `build/Murmure.app` (Info.plist, llama.framework, signature ad hoc,
  schéma `murmure://`). Identité de signature via `MURMURE_SIGN_IDENTITY`.
- `server/src/server.mjs` : serveur de licences Node 24 sans dépendance (node:sqlite). Écrit, **jamais lancé**.
  Pages attendues dans `server/pages/` (`buy.html`, `message.html`) : **à écrire**.
  Clé privée : `server/.env` sur le VPS (hors git), variable `LICENSE_PRIVATE_KEY`.
- `landing/index.html` : page provisoire. Projet Vercel relié au dépôt, dossier racine `landing/`.
- `Tests/fixtures/dictees-brutes.txt` : 6 dictées françaises brutes pour le comparatif LLM.

**Rien n'a encore été testé à l'exécution** : ni dictée réelle, ni touche, ni collage, ni panneau,
ni traduction, ni modes, ni serveur.

## Contraintes techniques

- **Le VPS est Linux (arm64) : il ne compile pas l'app Mac.** Tout build/test Mac passe par
  **GitHub Actions** sur runner macOS (gratuit sur dépôt public, minutes limitées en privé ; macOS compte ×10).
  Prendre le runner macOS le plus récent disponible (vérifier `macos-26` / Xcode 26 ; sinon `macos-15`).
  La commande `say -v Thomas -o x.aiff "…"` puis `afconvert` donne de l'audio français pour `--selftest`.
- Le Mac de Lubin est fermé cette nuit. Pas de test micro/clavier réel possible : tester tout ce qui peut
  l'être en CI (compilation, selftest transcription + LLM, signature, bundle, script d'installation),
  et lister clairement ce qui reste à vérifier à la main demain.
- Sans Developer ID : Gatekeeper bloque l'app téléchargée par navigateur. Recommandé :
  **installation par une commande** `curl -fsSL https://<landing>/install.sh | bash` (un fichier téléchargé
  par curl n'a pas l'attribut de quarantaine) qui télécharge le zip de la dernière release GitHub (ou
  hébergé sur Vercel/Blob), l'installe dans /Applications et l'ouvre. Plus un DMG de secours avec la marche
  « Réglages Système > Confidentialité et sécurité > Ouvrir quand même ».
  Attention : si la release est sur un dépôt **privé**, elle n'est pas téléchargeable publiquement :
  publier les binaires ailleurs (Vercel Blob, ou un dépôt public `murmure-releases`).
- Signature ad hoc = l'autorisation Accessibilité saute à chaque mise à jour. Atténuation gratuite :
  **certificat de signature auto-signé** stable (créé une fois, stocké en secret GitHub, importé en CI) :
  l'exigence désignée reste la même d'une version à l'autre.
- Mise à jour de l'app : prévoir un contrôle simple de version au lancement (JSON sur la landing) qui
  propose de relancer la commande d'installation.
- VPS : exposer le serveur de licences en HTTPS sans ouvrir de port (ufw ferme tout) : **Tailscale Funnel**
  (`tailscale funnel`) puis réécriture Vercel `/api/*` → URL funnel, pour que l'app parle à
  `https://<landing>/api/...`. Limites mémoire VPS : voir `~/claude-vps/README-hardening.md`.
  Ne pas toucher aux stacks Mibba/BAP. Docker disponible.
- Le Mac n'a que les Command Line Tools (pas d'Xcode) : ne pas compter sur xcodebuild.
- Style (consignes de Lubin) : jamais de tiret long (—) dans les textes ; interface en français ;
  pour l'UI, charger les skills `impeccable` et `design-taste-frontend` s'ils sont disponibles.

## Tâches, dans l'ordre

1. **CI GitHub Actions (macOS)** : build release, `build-app.sh`, selftest transcription (Parakeet Ultra sur
   audio `say`) et `--llmtest` Qwen 2.5 1.5B vs Gemma 3 1B (et 3B/4B si le temps le permet) sur
   `Tests/fixtures/dictees-brutes.txt`. Mettre en cache `~/Library/Application Support/Murmure/Models`.
   Choisir le LLM par défaut (`Setup.defaultLLM`) sur qualité + latence, consigner le résultat dans
   `docs/llm-comparatif.md`.
2. **Onboarding façon Spokenly** : étudier le leur (docs, vidéos, captures publiques) et faire une fenêtre
   d'accueil en quelques étapes plein écran-fenêtre : bienvenue, micro, accessibilité (avec détection
   automatique de l'octroi), choix de la touche, téléchargement des modèles avec progression, essai
   guidé (« maintenez ⌥ et dites… » avec zone de texte d'essai), fin. Puis plus jamais visible.
3. **Simplifier l'app** : barre de menus minimale (état, mode, réglages, quitter) ; réglages réduits à
   l'essentiel (Général, Modes, Licence ; dictionnaire et historique fusionnés ou accessibles simplement).
   Retirer ce qui ne sert pas à 95 % des gens (choix Ollama/LM Studio, choix du LLM → avancé ou supprimé).
4. **Serveur de licences** : écrire `server/pages/*.html`, Dockerfile + compose, tester en local (curl :
   essai, jeton vérifié par l'app en CI, webhook Paddle signé simulé, restauration), déployer sur
   `claude-vps` (Docker, restart unless-stopped), exposer en HTTPS, mettre l'URL dans l'app.
   Paddle : variables vides tant que Lubin n'a pas créé son compte ; `/buy` affiche alors « bientôt ».
   Écrire `docs/paddle-setup.md` : les étapes exactes pour Lubin demain (compte, produit, prix, webhook
   vers `/api/v1/paddle/webhook`, client token, domaine approuvé, variables à coller).
5. **Distribution** : workflow de release (zip + DMG + `install.sh`, binaires publics), certificat
   auto-signé, contrôle de version. Tester le script d'installation en CI sur macOS (installe, lance
   `--selftest`).
6. **Landing page** (Vercel, dossier `landing/`) : façon Apple, très épurée. Un titre, une phrase, la commande
   d'installation copiable en un clic + bouton DMG, 3 points forts max (local et privé, modes, traduction),
   essai 7 jours, FAQ courte (sécurité Gatekeeper, prérequis macOS 15 + Apple Silicon). Clair/sombre.
   Pas de faux témoignages ni de chiffres inventés. Vérifier mobile.
7. **Recette finale** : tout le parcours en CI ; `docs/MORNING.md` pour Lubin : liens, ce qui est prêt,
   ce qu'il doit faire (Paddle, tester une dictée réelle), ce qui n'a pas pu être vérifié.

## Infos utiles

- Dépôt : `lubindanilo/murmure` (privé). Mac : `~/murmure`. VPS : `~/projects/murmure`.
- Spécificités des moteurs : FluidAudio 0.18.4 (`AsrModels.downloadAndLoad(to:version:.ultra)`), WhisperKit 1.1.1,
  llama.cpp b12728 (xcframework binaire, API `llama_batch_get_one` dépréciée mais OK).
- Comparatif des prestataires de paiement et spec Spokenly : faits le 25/11 (résumés ci-dessus et dans docs/).

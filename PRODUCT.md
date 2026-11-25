# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS (native, SwiftUI + AppKit). Not one of web / ios / android: follow Apple's macOS Human Interface Guidelines.

## Stack

Swift natif (choisi par l'utilisateur) : Swift Package Manager, SwiftUI pour les réglages, AppKit pour la barre de menus, le panneau d'enregistrement et le collage. Moteurs locaux : WhisperKit (Whisper), FluidAudio (Parakeet, Nemotron), Speech d'Apple ; LLM local : llama.cpp (framework officiel). Compile avec les seules Command Line Tools (pas d'Xcode).

## Users

Personnes qui écrivent beaucoup sur Mac (mails, messages, prompts pour agents IA, notes) et veulent dicter au lieu de taper, dans n'importe quelle app, en français ou dans une autre langue.

## Product Purpose

Maintenir une touche, parler, relâcher : le texte transcrit est collé là où se trouve le curseur. Murmure propose les mêmes familles de modèles que Spokenly : modèles locaux gratuits et hors ligne, modèles cloud avec la clé API de l'utilisateur, et un post-traitement IA (nettoyage, reformulation) qui tourne en local.

## Positioning

Le post-traitement IA ne rajoute aucun coût de tokens : il tourne sur le Mac (LLM embarqué via llama.cpp, ou Ollama / LM Studio). Les modèles cloud sont optionnels et passent par les clés de l'utilisateur, jamais par un abonnement Murmure.

## Operating Context

L'app vit dans la barre de menus. L'utilisateur est au milieu d'une autre tâche ; Murmure ne doit jamais prendre le focus. Seul le petit panneau d'enregistrement apparaît pendant la dictée. Les réglages s'ouvrent rarement : choix du modèle, du raccourci, du mode IA, du dictionnaire.

## Capabilities and Constraints

- Dictée au raccourci : maintenir pour parler, ou appuyer pour démarrer et arrêter. Échap annule.
- Sortie : coller au curseur (Accessibilité requise), copier seulement, ou historique seulement.
- Modèles locaux téléchargeables, modèles cloud BYOK, Apple Speech.
- Post-traitement IA local avec modes (prompts) éditables.
- Dictionnaire personnel et remplacements de mots.
- Historique local.
- Hors périmètre v1 : transcription de fichiers, enregistrement de réunions, version iPhone.
- Apple Speech Analyzer et Apple Intelligence (macOS 26) demandent un SDK macOS 26, donc Xcode 26 : à activer quand Xcode sera installé.

## Brand Commitments

Nom : Murmure. Interface en français.

## Evidence on Hand

Aucun témoignage, chiffre ou client. Ne rien inventer. Les notes de précision et de vitesse des modèles affichées dans l'app sont celles publiées par Spokenly sur sa page de comparaison et sont présentées comme telles.

## Product Principles

1. Ne jamais voler le focus : l'utilisateur reste dans son app.
2. Local d'abord : tout ce qui peut tourner sur le Mac tourne sur le Mac.
3. Zéro coût caché : pas de tokens facturés par Murmure.
4. Rapide à relâcher : le texte doit arriver en moins de temps qu'il n'en faut pour le taper.

## Accessibility & Inclusion

Respecter les réglages système : contraste augmenté, réduction des animations, VoiceOver sur les réglages.

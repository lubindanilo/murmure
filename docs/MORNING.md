# Murmure : point du matin (26 novembre 2026)

## Les liens

- **Landing** : https://murmure-mac.vercel.app
- **Commande d'installation** (à donner aux contacts) :
  `curl -fsSL https://murmure-mac.vercel.app/install.sh | bash`
- **DMG de secours** : https://github.com/lubindanilo/murmure-releases/releases/latest/download/Murmure.dmg
- Code : https://github.com/lubindanilo/murmure (privé). Binaires : https://github.com/lubindanilo/murmure-releases (public, rien d'autre dedans).

## Ce qui est prêt et vérifié cette nuit

| Élément | Vérification |
|---|---|
| App Murmure 0.2.0 (Swift natif, barre de menus, interface refaite le 26 au matin) | compilée et signée en CI sur macOS 15 |
| Transcription Parakeet Ultra, installée toute seule au 1er lancement | autotest en CI sur un audio français |
| Nettoyage par IA locale (Qwen 2.5 1.5B, 1,1 Go, installé tout seul) | comparatif de 4 modèles, voir `docs/llm-comparatif.md` |
| Garde-fou anti-dérapage de l'IA (si elle répond ou traduit, on colle la transcription) | testé sur 20 sorties réelles |
| Onboarding en 6 étapes (bienvenue, micro, accessibilité détectée toute seule, touche, essai, fin) | captures d'écran en CI |
| Modes façon Spokenly : mot déclencheur, touche dédiée, app, site, contexte, scripts, sortie | compile ; spec dans `docs/spokenly-modes-spec.md` |
| Traduction Apple par mode (ex. « Traduire en anglais ») | compile |
| Essai 7 jours par Mac + serveur de licences (VPS) | autotest en CI contre le serveur de production |
| Installation par commande, sans alerte Gatekeeper | testée en CI depuis la vraie URL (workflow `install-check`) |
| Mise à jour : le menu propose « Installer la mise à jour » quand `version.json` change | compile |
| Landing (claire/sombre, mobile), confidentialité, conditions, 404, image de partage | vérifiée en capture |

Réglages réduits à 5 écrans (Général, Modes, Dictionnaire, Historique, Licence). Menu de la barre :
dictée, mode (s'il y en a plusieurs), réglages, quitter. Plus aucun choix de modèle.

## À faire par toi avant d'envoyer le lien (15 minutes)

1. **Installer sur ton Mac** avec la commande ci-dessus et faire l'onboarding jusqu'au bout.
   C'est le seul vrai test : cette nuit, aucun micro, aucune touche et aucun collage réels n'ont pu
   être essayés (pas de Mac disponible). Vérifie en particulier :
   - la touche ⌘ droite maintenue lance bien le petit panneau en bas de l'écran ;
   - le texte se colle dans Notes, Slack, Mail, le navigateur ;
   - la latence du nettoyage IA après relâchement (si c'est trop lent : Réglages > Général > décocher
     « Nettoyer avec l'IA locale », et dis-le moi) ;
   - un mode « Traduire en anglais » (Réglages > Modes > Nouveau mode) : macOS demande de télécharger
     la langue la première fois.
2. Si un problème bloque : ouvre une session Claude sur le VPS dans `~/projects/murmure`, décris ce que
   tu vois ; `Scripts/publish-release.sh` republie en 2 minutes après correction (les apps installées
   proposent la mise à jour d'elles-mêmes, une fois par jour ou au lancement).

## Paiement : à brancher (Paddle)

Rien n'est encaissé tant que Paddle n'est pas configuré : le bouton « Acheter Murmure » affiche
« Bientôt disponible ». L'essai de 7 jours laisse jusqu'au 3 décembre pour le faire.

- Choix : **Paddle Billing** (Lemon Squeezy n'accepte plus de vendeurs et ferme le 31/03/2027).
  5 % + 0,50 $ par vente, TVA européenne gérée par Paddle.
- Procédure pas à pas : `docs/paddle-setup.md` (compte, produit, prix, webhook, 5 variables à coller).
- **Prix à décider** : le serveur gère l'abonnement et le paiement unique.

## Infos techniques

- **Serveur de licences** : VPS `claude-vps`, Docker Compose projet `murmure` dans `~/projects/murmure/server`
  (Node 24 + SQLite dans `server/data/`, Caddy en HTTPS sur `188-245-2-239.sslip.io`).
  La landing relaie `https://murmure-mac.vercel.app/api/*` vers lui. Ports 80 et 443 ouverts dans ufw
  sur l'IP publique uniquement (Tailscale Funnel est désactivé sur le tailnet).
  - Logs : `docker compose -p murmure logs -f licenses`
  - Redémarrer : `docker compose -p murmure up -d --build`
  - Clé privée de signature des licences : `server/.env` (hors git). **La perdre = toutes les licences
    à réémettre** : sauvegarde-la (gestionnaire de mots de passe).
- **Certificat de signature de l'app** (auto-signé, stable, garde l'autorisation Accessibilité d'une version
  à l'autre) : secrets GitHub `MURMURE_CERT_P12` / `MURMURE_CERT_PASSWORD`, copie dans
  `~/.config/murmure/` sur le VPS. À sauvegarder aussi.
- **Publier une version** : monter `VERSION`, pousser sur `main`, attendre la CI verte, puis
  `Scripts/publish-release.sh` sur le VPS.
- **Limites connues** :
  - Mac avec puce Apple et macOS 15 minimum.
  - App non notarisée : la commande Terminal évite l'alerte ; le DMG demande « Ouvrir quand même »
    dans Réglages Système. Un compte Apple Developer (99 $/an) supprimerait ce point, décision à toi.
  - Parakeet ne prend pas de vocabulaire personnalisé : le dictionnaire passe par l'IA locale et les
    remplacements.
  - Les mentions légales (éditeur du site, contact) manquent sur la landing : à ajouter avec tes infos
    avant d'ouvrir les ventes.
  - Minutes CI macOS : le dépôt est privé, chaque compilation consomme environ 50 minutes de quota
    (macOS compte ×10). Surveille l'onglet Billing de GitHub si tu itères beaucoup.

# Brancher Paddle (environ 20 minutes)

Le serveur de licences est déjà en ligne et attend seulement les clés Paddle. Tant qu'elles manquent,
le bouton « Acheter » de l'app affiche « Bientôt disponible » : l'essai de 14 jours fonctionne quand même.

## 1. Créer le compte (sandbox d'abord)

1. Ouvrir https://sandbox-vendors.paddle.com/signup (compte de test, gratuit, sans vérification).
2. Plus tard, refaire les mêmes étapes sur https://vendors.paddle.com pour la vraie vente
   (vérification de l'entreprise et du site : prévoir quelques heures à quelques jours).

## 2. Créer le produit et le prix

Catalogue > Produits > Nouveau produit : « Murmure », type standard, catégorie logiciel.
Ajouter **un seul prix** (décision du 26/11) :
- type : récurrent, **mensuel**, **9,99 EUR** (Paddle convertit pour les autres pays) ;
- **période d'essai : aucune**. Les 14 jours gratuits sont déjà gérés par notre serveur, sans carte.
  Un essai côté Paddle s'ajouterait aux 14 jours et demanderait la carte dès le départ.
- prix TTC ou HT : TTC conseillé pour que le client paie exactement 9,99 € en France.
Copier l'identifiant du prix (`pri_…`).

## 3. Approuver le domaine du paiement

Paramètres > Paiement > Domaines approuvés (en production) : ajouter `murmure-ai.com`.
Lien de paiement par défaut : `https://murmure-ai.com/api/buy`.

## 4. Clés

- Paramètres > Clés d'authentification > **Jeton client** (`test_…` en sandbox, `live_…` en production).
- Paramètres > Clés d'authentification > **Clé d'API** avec les droits lecture clients, abonnements,
  transactions et écriture « customer portal sessions ».

## 5. Webhook

Notifications > Nouvelle destination :
- URL : `https://murmure-ai.com/api/v1/paddle/webhook`
- Événements : `transaction.completed`, `subscription.created`, `subscription.activated`,
  `subscription.updated`, `subscription.past_due`, `subscription.paused`, `subscription.resumed`,
  `subscription.canceled`, `adjustment.created`, `adjustment.updated`.
- Copier le **secret** (`pdl_ntfset_…`).

## 6. Coller les valeurs sur le VPS

```bash
ssh claude-vps
cd ~/projects/murmure/server
nano .env   # ajouter les lignes ci-dessous
docker compose -p murmure up -d
```

```
PADDLE_ENV=sandbox            # puis production
PADDLE_CLIENT_TOKEN=test_…
PADDLE_PRICE_ID=pri_…
PADDLE_WEBHOOK_SECRET=pdl_ntfset_…
PADDLE_API_KEY=pdl_…
```

Ou bien : donner ces valeurs à Claude dans une session sur le VPS, il les met en place et teste un achat sandbox
(carte de test Paddle `4242 4242 4242 4242`, date future, CVC `100`).

## 7. Vérifier

- `curl https://murmure-ai.com/api/buy` ne doit plus afficher « Bientôt disponible ».
- Dans l'app : Réglages > Licence > Acheter Murmure. Après le paiement, l'app passe en « Murmure est activé »
  en moins d'une minute (elle interroge le serveur toutes les 5 secondes pendant 15 minutes).

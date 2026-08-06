# 🍸 TAPZ — *Scanne. Commande. Trinque.*

SaaS multi-établissements de **commande par QR code** pour **bars & monde de la nuit**.

> **Aucun paiement en ligne.** Le client commande, le comptoir prépare, le client
> **règle au bar**. TAPZ génère une facture / récapitulatif et assure le suivi
> d'encaissement — rien de plus. Aucune fonction de paiement n'existe dans ce dépôt.

---

## Sommaire

- [Ce que fait TAPZ](#ce-que-fait-tapz)
- [Stack](#stack)
- [Architecture des fichiers](#architecture-des-fichiers)
- [👉 CE QUE VOUS DEVEZ FAIRE À LA MAIN](#-ce-que-vous-devez-faire-à-la-main)
- [Développement local](#développement-local)
- [Notes d'implémentation](#notes-dimplémentation)

---

## Ce que fait TAPZ

**Côté client (téléphone, sans installation)**
- Scan du QR → `/r/{bar_id}/t/{table_number}` (**format d'URL stable, jamais modifié**)
- Sur place / à emporter → carte par catégories, photos, badges « Populaire »
- Boissons composables : tunnel d'options (base alcool → sirop → garnitures) + ajouts payants
- Panier, note pour le comptoir, code promo / happy hour automatique
- Suivi temps réel : barre de progression, compte à rebours ETA réglable par le staff,
  sonnerie douce + vibration + Web Push quand c'est prêt (même écran verrouillé)
- Persistance au refresh (localStorage) : on retombe sur le suivi, pas au début
- **Facture / récapitulatif** affichée + téléchargeable en PDF, mention « À régler au bar »

**Côté comptoir / patron**
- Kanban temps réel (Realtime + polling de secours) : À accepter → Au shaker → Prête → Servie
- **Alarme sonore agressive** à chaque nouvelle commande, qui **ne s'arrête que** via « Accepter »
- Vue **Caisse** : additions par table, fusion de plusieurs commandes en une note,
  impression PDF de la note, marquage « réglé » (espèces / CB / autre)
- Gestion de carte : CRUD, réordonnancement des catégories, photos, stock, TVA,
  groupes d'options composables, **traduction automatique** (Edge Function Claude)
- **Copie de la carte** vers un autre bar du même compte (photos + sous-groupes inclus)
- Export carte : **PDF A4 imprimable** + **PNG format story**, avec **marge de prix
  réglable à l'export** (n'affecte jamais la carte réelle)
- Export de **tous les QR codes en un seul PDF A4** (6 par page, repères de découpe),
  compatible iPhone via la feuille de partage iOS
- CRM clients, avis, promotions / happy hour, réglages par établissement
- **Multi-établissements** (mode groupe) avec partage de réglages entre bars du compte

---

## Stack

| Couche | Choix |
|---|---|
| Front | React 19 + Vite (SPA), un gros `src/App.jsx`, styles en objets inline JS |
| Back | Supabase — PostgreSQL + RLS + Auth email/password + Realtime + Edge Functions (Deno) + Storage |
| QR | lib `qrcode` |
| PDF / images | **Canvas 2D natif + writer PDF maison** (`src/lib/pdf.js`) — *pas* de `html2canvas` (casse sur iOS Safari) |
| Déploiement | GitHub Pages via GitHub Actions, base path par `VITE_BASE_PATH` |

---

## Architecture des fichiers

```
src/
  App.jsx              ← tout l'applicatif (client + admin), styles inline
  main.jsx
  lib/
    supabase.js        client Supabase, erreurs Auth en français, tableUrl()
    theme.js           palette Electric Violet + styles partagés + formats FR
    pdf.js             writer PDF maison, helpers Canvas, partage iOS
    push.js            Web Push (VAPID) + vibration
    sound.js           sonnerie douce (client) + alarme comptoir (WebAudio)
public/
  sw.js                Service Worker (push + réveil de l'onglet suivi)
  manifest.webmanifest
supabase/
  migrations/
    0001_schema.sql    tables, types, triggers, RPC ensure_table
    0002_rls.sql       Row Level Security
    0003_realtime.sql  publication Realtime
    0004_storage.sql   bucket "tapz" (logos + photos)
  functions/
    send-push/         Web Push VAPID
    send-receipt/      e-mail récapitulatif (Resend)
    translate-menu/    traduction de la carte via l'API Claude
.github/workflows/deploy.yml
```

---

## 👉 CE QUE VOUS DEVEZ FAIRE À LA MAIN

### 1. Créer le projet Supabase

1. [supabase.com](https://supabase.com) → **New project** (région Europe de préférence).
2. Notez **Project URL** et **anon public key** (*Settings → API*).

### 2. Exécuter le SQL — dans cet ordre

*Supabase → SQL Editor → New query* → collez le contenu de chaque fichier, puis **Run** :

1. `supabase/migrations/0001_schema.sql`
2. `supabase/migrations/0002_rls.sql`
3. `supabase/migrations/0003_realtime.sql`
4. `supabase/migrations/0004_storage.sql`

> ⚠️ **Lisez le commentaire en haut de `0002_rls.sql`.** Pour que le suivi temps réel
> fonctionne, la lecture anonyme est autorisée sur les commandes **de moins de 12 h**
> (une policy RLS filtre des lignes, elle ne peut pas dépendre du filtre de la requête).
> L'app n'interroge jamais que par `id`, et aucune donnée de paiement n'est stockée.
> Si ce compromis ne vous convient pas, remplacez-le par une RPC `security definer`
> — vous perdrez alors le Realtime, le polling de secours prendra le relais.

### 3. Activer l'authentification

*Authentication → Providers → Email* : activer.

- Pour un démarrage sans friction : **désactiver « Confirm email »**
  (*Authentication → Sign In / Providers → Email → Confirm email = off*).
  Le compte est alors auto-confirmé et l'app connecte directement après inscription.
- Si vous laissez la confirmation active, l'app affiche « vérifiez votre boîte mail ».

### 4. Générer les clés VAPID (Web Push)

Sur votre machine :

```bash
npx web-push generate-vapid-keys
```

Vous obtenez une **clé publique** et une **clé privée**.

### 5. Configurer les secrets Supabase (Edge Functions)

*Project Settings → Edge Functions → Secrets*, ou en CLI :

```bash
supabase secrets set \
  VAPID_PUBLIC_KEY="BEl...votre clé publique..." \
  VAPID_PRIVATE_KEY="votre clé privée" \
  VAPID_SUBJECT="mailto:contact@votredomaine.fr" \
  ANTHROPIC_API_KEY="sk-ant-..." \
  RESEND_API_KEY="re_..." \
  RESEND_FROM="TAPZ <hello@votredomaine.fr>"
```

| Secret | Requis pour | Si absent |
|---|---|---|
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` | notifications push | l'app fonctionne, sans push |
| `ANTHROPIC_API_KEY` | traduction auto de la carte | bouton traduction en erreur |
| `RESEND_API_KEY` / `RESEND_FROM` | e-mail de récapitulatif | pas d'e-mail envoyé |

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont injectés automatiquement, ne les définissez pas.

### 6. Déployer les Edge Functions

```bash
npm install -g supabase
supabase login
supabase link --project-ref VOTRE_REF_PROJET

supabase functions deploy send-push
supabase functions deploy send-receipt
supabase functions deploy translate-menu
```

> `send-push` et `send-receipt` sont appelées par des **clients anonymes** (le téléphone
> du client, la tablette du comptoir). Si votre projet refuse les appels non
> authentifiés, déployez-les avec `--no-verify-jwt` :
> `supabase functions deploy send-push --no-verify-jwt`

### 7. Configurer les secrets GitHub

*Dépôt → Settings → Secrets and variables → Actions → New repository secret* :

| Nom | Valeur |
|---|---|
| `VITE_SUPABASE_URL` | l'URL de votre projet Supabase |
| `VITE_SUPABASE_ANON_KEY` | la clé **anon public** |
| `VITE_VAPID_PUBLIC_KEY` | la clé **publique** VAPID (étape 4) |

### 8. Activer GitHub Pages

*Dépôt → Settings → Pages → Build and deployment → Source : **GitHub Actions***.

Puis poussez sur `main` (ou lancez le workflow à la main). Le site sera sur
`https://<utilisateur>.github.io/<repo>/`.

> Le workflow calcule `VITE_BASE_PATH=/<nom-du-repo>/` automatiquement. Si vous
> déployez sur un Pages *user/org* (`<utilisateur>.github.io`), remplacez cette
> ligne du workflow par `VITE_BASE_PATH: /`.
>
> Le workflow copie `index.html` vers `404.html` : c'est ce qui fait fonctionner
> les liens profonds `/r/{bar_id}/t/{n}` sur GitHub Pages.

### 9. Premier lancement

1. Ouvrez le site → **Créer un compte** (choisissez « un seul bar » ou « groupe »).
2. Créez votre établissement : une carte de démarrage (cocktails, shots, bières,
   softs, snacks) et vos tables sont générées automatiquement.
3. Onglet **QR** → *Exporter les QR (PDF, 6/page)* → imprimez, découpez, collez.
4. Sur la tablette du comptoir : onglet **Live** → *Recevoir les alertes sur cet appareil*.
5. Scannez un QR avec un autre téléphone et passez une commande de test.

> 🔊 **L'alarme du comptoir** nécessite une première interaction sur la page
> (WebAudio est bloqué sinon, surtout sur iOS). Touchez un onglet une fois après
> avoir ouvert le tableau de bord — c'est fait automatiquement au premier tap.

---

## Développement local

```bash
cp .env.example .env     # remplir VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY
npm install
npm run dev              # http://localhost:5173
```

En local, `VITE_BASE_PATH` vaut `/`, donc une URL de table ressemble à
`http://localhost:5173/r/<bar_id>/t/3`.

---

## Notes d'implémentation

**URL de QR** — `/r/{bar_id}/t/{table_number}`. Format contractuel : le parseur de
route (`parseClientRoute`) et le générateur (`tableUrl`) sont les deux seuls endroits
qui le connaissent. Ne le changez pas : des QR sont déjà collés sur des tables.

**Table créée à la volée** — si un QR pointe vers un numéro de table inconnu, la RPC
`ensure_table` (security definer) la crée. Vous pouvez donc imprimer 50 QR et n'en
coller que 30.

**PDF maison** — `src/lib/pdf.js` rend chaque page dans un `<canvas>`, l'exporte en
JPEG et l'embarque comme XObject `/DCTDecode` dans un PDF assemblé octet par octet
(catalogue, pages, xref, trailer). Zéro dépendance, rendu identique partout.
`html2canvas` est volontairement absent : il casse sur iOS Safari.

**Partage iOS** — les exports passent par `navigator.share({ files })` quand
disponible (feuille de partage iOS), sinon par un téléchargement classique.

**TVA** — chaque article porte son taux (20 % alcool, 10 % soft/nourriture sur place,
5,5 % à emporter). Le récapitulatif PDF affiche le détail « dont TVA » par taux.
C'est un document informatif : **il ne vaut pas reçu de paiement**, et la mention
figure explicitement en pied de page.

**Modèle Claude** — `translate-menu` appelle `claude-opus-5` à effort `low` (tâche
routinière), avec sortie JSON contrainte par schéma et repli serveur automatique
(`fallbacks: "default"`) si un classifieur décline la requête.

---

*TAPZ ne traite aucun paiement en ligne. Le règlement se fait au bar.*

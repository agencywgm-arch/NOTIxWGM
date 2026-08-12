# Noti Calling — outil de commande par QR code

Plateforme de commande par QR code pour **soirée événementielle**, développée d'après la
feuille de route *v2.0 — août 2026* (cas pilote **Noti Club · Noti Calling**).

> **Principe validé : aucun paiement en ligne.** La plateforme affiche le prix,
> l'encaissement se fait **à 100 % au bar**, sur le système existant du lieu.
> C'est un outil de **commande + file + CRM + communication**, pas une caisse.

---

## Sommaire

- [Le schéma en 4 temps](#le-schéma-en-4-temps)
- [Ce qui est implémenté](#ce-qui-est-implémenté)
- [Stack & architecture](#stack--architecture)
- [👉 CE QUE VOUS DEVEZ FAIRE À LA MAIN](#-ce-que-vous-devez-faire-à-la-main)
- [Développement local](#développement-local)
- [Points d'attention & décisions](#points-dattention--décisions)
- [Reste à faire](#reste-à-faire)

---

## Le schéma en 4 temps

| | | |
|---|---|---|
| **1. Le client commande** | Il scanne le QR (entrée ou bar), s'identifie, commande — **sans payer**. |
| **2. Le staff reçoit** | La commande arrive instantanément au bar, avec le nom du client, le détail et le **code de retrait**. |
| **3. Le staff produit** | Il prépare, re-saisit dans le POS interne du lieu, puis notifie le client. |
| **4. Retrait & règlement** | Le client présente son code au bar, récupère et **règle sur place**. Le staff marque « réglé ». |

---

## Ce qui est implémenté

### Côté client — `/s/{scan_point_id}`

- Écran d'accueil aux couleurs Noti Calling (logo, contexte, point de scan)
- **Identification obligatoire** : Nom + Prénom + Mobile, **vérifié par code SMS (OTP)**
- **Consentements RGPD granulaires**, non pré-cochés, **horodatés** : CGU/CGV (obligatoire),
  prospection, transmission à l'établissement
- **Reconnaissance client au scan** : « Bon retour parmi nous », badge VIP, message dédié en cas
  d'incident (impayé passé)
- **Espace commande en 3 univers** : Boissons au verre · Food · Bouteilles, avec sous-catégories
- Formats multiples (12 cl / 75 cl / magnum) et options composables ; panier, note libre, code promo
- **Discipline de la file** : cumul autorisé tant que la commande est en préparation ;
  **blocage dès qu'une commande passe à « prête »**, jusqu'au retrait au bar
- Confirmation avec **code de retrait**, temps estimé et compte à rebours
- Suivi temps réel (WebSocket) + sonnerie douce + vibration + Web Push
- Récapitulatif PDF téléchargeable, mention « à régler au bar »
- Avis 5 étoiles + commentaire en fin de soirée
- Multilingue **FR / EN / ES** (pas de RTL)

### Côté bar & cuisine

- Écran de production temps réel : **Reçues → Prêtes → Retirées → Réglées**
- **Alarme sonore** sur nouvelle commande, qui ne s'arrête que sur accusé de réception explicite
- **Réglage du temps de préparation** selon le rush, répercuté sur le timer client
- **Article « épuisé » en un clic** — il reste visible sur la carte, grisé et non commandable
- **Impression de ticket** 80 mm — disponible, non obligatoire, non bloquante
- Vue **Caisse** : suivi d'encaissement par client, sélection multiple, marquage « réglé »
  (espèces / CB / autre), suivi des impayés

### Côté organisateur

- **Pilotage temps réel** : présents, commandes en cours, file d'attente, encaissé, impayés
- **Leaderboard temps réel** (qui commande le plus, panier cumulé)
- **Diffusion à toute la soirée** (avec modèles prêts à l'emploi) et **messagerie individuelle**
  organisateur → client
- **Base client cross-événement** : historique, nombre de soirées, taille du groupe,
  **tags & segmentation** (VIP / habitué / gros panier / incident) — tags automatiques inclus
- **Reporting post-événement** : panier moyen, top produits, pic horaire, nouveaux vs récurrents,
  note moyenne — export **PDF** et **CSV**
- **Clôture de soirée** : les commandes non réglées passent en « impayé », rattachées à
  l'identité vérifiée (preuve horodatée)

### Notifications (§09)

| Déclencheur | Canal |
|---|---|
| Commande reçue | Push + SMS |
| Commande prête | Push + SMS |
| **Relance auto à 5 min** si non retirée | Push + SMS (Edge Function `reminders`, cron) |
| **Relance renforcée 1 h avant fermeture** | Push + SMS, message impactant avec la conséquence explicite |
| Diffusion / message individuel | Push + SMS |

**Canal dégradé non bloquant** : un SMS qui échoue ne bloque jamais une commande. La plateforme
reste la source de vérité du suivi.

---

## Stack & architecture

| Couche | Choix |
|---|---|
| Front | React 19 + Vite (SPA), un gros `src/App.jsx`, styles en objets inline |
| Back | Supabase — PostgreSQL + RLS + Auth (OTP SMS clients / e-mail staff) + Realtime + Edge Functions (Deno) + Storage |
| QR | lib `qrcode` |
| PDF / images | **Canvas 2D natif + writer PDF maison** (`src/lib/pdf.js`) — *pas* de `html2canvas` |
| Déploiement | **Cloudflare Pages** (build depuis le dépôt), base path par `VITE_BASE_PATH` |

```
src/
  App.jsx                  tout l'applicatif (client + staff)
  lib/
    supabase.js            client, erreurs FR, scanUrl()
    theme.js               charte Noti Calling + formats FR + normalisation E.164
    pdf.js                 writer PDF maison, helpers Canvas, partage iOS
    push.js                Web Push (VAPID) + appel de la fonction notify
    sound.js               sonnerie client + alarme bar (WebAudio)
supabase/
  migrations/
    0001_schema.sql        tables, RPC (place_order, upsert_me, register_scan…), triggers
    0002_rls.sql           Row Level Security
    0003_realtime_reporting.sql  Realtime, vues de pilotage, event_report, close_event
    0004_storage.sql       bucket "noti"
    0005_seed_noti_menu.sql      carte du Noti Club
  functions/
    notify/                notification de statut / diffusion / message individuel
    reminders/             relances automatiques (cron)
    translate-menu/        traduction FR → EN / ES via l'API Claude
    _shared/               CORS, envoi SMS multi-fournisseurs, dispatch
```

---

## 👉 CE QUE VOUS DEVEZ FAIRE À LA MAIN

### 1. Créer le projet Supabase

[supabase.com](https://supabase.com) → **New project**, **région Europe** (obligation RGPD de la
feuille de route §10). Notez **Project URL** et **anon public key** (*Settings → API*).

### 2. Exécuter le SQL — dans cet ordre

*SQL Editor → New query* → coller chaque fichier → **Run** :

1. `supabase/migrations/0001_schema.sql`
2. `supabase/migrations/0002_rls.sql`
3. `supabase/migrations/0003_realtime_reporting.sql`
4. `supabase/migrations/0004_storage.sql`
5. `supabase/migrations/0005_seed_noti_menu.sql` *(crée la fonction ; la carte est injectée
   automatiquement à la création du lieu depuis l'app)*

### 3. Activer l'authentification

**Deux modes coexistent** — ne configurez pas que l'un des deux :

- **Staff** — *Authentication → Providers → **Email*** : activer.
  Pour démarrer sans friction, désactivez « Confirm email ».
- **Clients** — *Authentication → Providers → **Phone*** : activer, puis choisir le fournisseur SMS
  (Twilio, Twilio Verify, Vonage, MessageBird ou Textlocal) et renseigner ses identifiants.
  C'est Supabase qui envoie l'OTP — vous n'avez **rien à coder**.

> Sans le provider Phone configuré, le parcours client s'arrête à l'envoi du code.
> C'est le seul point réellement bloquant pour tester de bout en bout.

### 4. Générer les clés VAPID (Web Push)

```bash
npx web-push generate-vapid-keys
```

### 5. Configurer les secrets Supabase

*Project Settings → Edge Functions → Secrets*, ou en CLI :

```bash
supabase secrets set \
  VAPID_PUBLIC_KEY="BEl..." \
  VAPID_PRIVATE_KEY="..." \
  VAPID_SUBJECT="mailto:contact@votredomaine.fr" \
  CRON_SECRET="$(openssl rand -hex 24)" \
  SMS_PROVIDER="twilio" \
  SMS_SENDER="NotiCalling" \
  TWILIO_ACCOUNT_SID="AC..." \
  TWILIO_AUTH_TOKEN="..." \
  TWILIO_FROM="+33..." \
  ANTHROPIC_API_KEY="sk-ant-..."
```

| Secret | Sert à | Si absent |
|---|---|---|
| `VAPID_*` | notifications Web Push | l'app marche, sans push |
| `SMS_PROVIDER` + secrets du fournisseur | SMS de statut, relances, diffusion | les messages restent dans l'app (tracés, non envoyés) |
| `CRON_SECRET` | protéger la fonction `reminders` | la fonction refuse tout appel |
| `ANTHROPIC_API_KEY` | traduction auto FR → EN/ES | bouton de traduction en erreur |

`SMS_PROVIDER` accepte `twilio`, `vonage`, `brevo`, `ovh` ou `none`. Les quatre sont implémentés
derrière la même interface (`supabase/functions/_shared/sms.ts`) — vous basculez de l'un à l'autre
sans toucher au code. **Ce module ne sert qu'aux notifications métier** ; l'OTP d'identification
passe par Supabase Phone Auth (étape 3).

### 6. Déployer les Edge Functions

```bash
npm install -g supabase
supabase login
supabase link --project-ref VOTRE_REF_PROJET

supabase functions deploy notify
supabase functions deploy reminders --no-verify-jwt
supabase functions deploy translate-menu
```

`reminders` est appelée par un cron, pas par un utilisateur : elle se protège elle-même avec
`CRON_SECRET`, d'où le `--no-verify-jwt`.

### 7. Planifier les relances automatiques

Dans *SQL Editor*, activez `pg_cron` et `pg_net`, puis :

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'noti-reminders',
  '* * * * *',                      -- toutes les minutes
  $$
  select net.http_post(
    url     := 'https://VOTRE_REF.supabase.co/functions/v1/reminders',
    headers := '{"Content-Type":"application/json","x-cron-secret":"LE_MEME_CRON_SECRET"}'::jsonb,
    body    := '{}'::jsonb
  );
  $$
);
```

### 8. Déployer le front sur Cloudflare Pages

Le dépôt étant **privé en plan gratuit**, GitHub Pages n'est pas utilisable (il exige un plan
Pro/Team/Enterprise pour les dépôts privés). Le déploiement passe donc par **Cloudflare Pages** :
gratuit, dépôts privés acceptés, usage commercial autorisé, bande passante illimitée.

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → **Create** →
   onglet **Pages** → **Connect to Git**
2. Autoriser GitHub, sélectionner **`agencywgm-arch/NOTIxWGM`**
3. Configuration de build :

   | Réglage | Valeur |
   |---|---|
   | Production branch | `main` |
   | Framework preset | *None* |
   | Build command | `npm run build` |
   | Build output directory | `dist` |

4. **Environment variables** (section *Production* — et *Preview* si vous voulez tester les branches) :

   | Nom | Valeur |
   |---|---|
   | `VITE_SUPABASE_URL` | URL du projet Supabase |
   | `VITE_SUPABASE_ANON_KEY` | clé **anon public** |
   | `VITE_VAPID_PUBLIC_KEY` | clé **publique** VAPID (étape 4) |
   | `VITE_BASE_PATH` | `/` |
   | `NODE_VERSION` | `22` |

5. **Save and Deploy**

Le site sort sur `https://notixwgm.pages.dev` (ou le nom que vous choisissez). Pour un domaine
propre : onglet **Custom domains** → `commande.noticalling.fr` par exemple.

> ⚠️ **Les variables sont lues à la compilation**, pas à l'exécution : après toute modification
> d'une variable d'environnement, il faut **relancer un déploiement** (*Deployments → … →
> Retry deployment*) pour qu'elle soit prise en compte.

> Le fichier `public/_redirects` (`/* /index.html 200`) assure le routage SPA. Sans lui, un QR
> scanné renverrait une 404 au lieu d'ouvrir l'application. Il fonctionne aussi sur Netlify.

**Si vous préférez repasser sur GitHub Pages plus tard** (dépôt rendu public, ou plan payant) :
le workflow `.github/workflows/deploy-github-pages.yml` est prêt, en déclenchement manuel. Activez
*Settings → Pages → Source : GitHub Actions*, créez les trois secrets, puis lancez-le depuis
l'onglet Actions.

### 9. Vérifier le déploiement

Ouvrez l'URL Cloudflare :

- Si l'écran **« Configuration requise »** s'affiche → les variables `VITE_SUPABASE_*` ne sont pas
  arrivées dans le build. Vérifiez-les et relancez le déploiement.
- Sinon, l'écran de connexion **Espace équipe** apparaît : le front est en ligne.

### 10. Première soirée

1. Ouvrir le site → **Créer un compte** (staff, e-mail + mot de passe)
2. Créer le lieu (**Noti Club**) et la première soirée (**Noti Calling**) — la carte du club et
   deux points de scan (**Entrée** + **Bar**) sont créés automatiquement
3. Onglet **QR** → *Exporter les affiches (PDF)* → imprimer, plastifier, poser à l'entrée et au bar
4. Onglet **Réglages** → renseigner l'**heure de fermeture** (elle déclenche la relance renforcée)
5. Sur la tablette du bar : onglet **Bar** → *Alertes* pour recevoir les notifications
6. Scanner le QR avec un téléphone et passer une commande de test

> 🔊 L'alarme du bar nécessite une première interaction sur la page (WebAudio est bloqué sinon,
> surtout sur iOS). Un simple appui sur un onglet suffit.

---

## Développement local

```bash
cp .env.example .env     # remplir VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY
npm install
npm run dev              # http://localhost:5173
```

---

## Points d'attention & décisions

**URL de QR** — `/s/{scan_point_id}`. Format contractuel : `parseScanRoute` et `scanUrl` sont les
deux seuls endroits qui le connaissent. Le type `table` existe déjà dans `scan_points` pour que le
service à table (phase 2) n'impose aucune migration.

**Sécurité des prix** — les commandes ne sont jamais insérées directement par le client : elles
passent par la fonction `place_order()` (security definer), qui **recalcule tous les prix côté
serveur** depuis la carte et applique la discipline de file. Il n'existe volontairement aucune
policy d'`INSERT` sur `orders` / `order_items`.

**Codes promo non énumérables** — aucune lecture publique sur `promo_codes` : la validation se fait
côté serveur dans `place_order()`.

**RLS stricte** — le client porte un vrai JWT (Phone Auth), donc chacun ne voit que ses propres
commandes et le staff celles de ses événements. Rien n'est ouvert en lecture publique à part la
vitrine (soirée, points de scan, carte).

**Prix des vins** — vos deux cartes divergent : Minuty 12 cl à **8 €** (carte bar) vs **10 €**
(carte Noti Calling), 75 cl à **39 €** vs **50 €**. Le seed retient les prix *carte bar* au verre
et les prix *Noti Calling* à la bouteille. **À arbitrer** avant la première soirée
(`0005_seed_noti_menu.sql`).

**Mentions légales** — l'arrêté éthylotests est daté *24 août 2011* sur la carte bar et
*24 août 2021* sur la carte Noti Calling. C'est **2011** ; le récapitulatif PDF utilise cette date.
Corrigez aussi « **Ces** chèques ne sont pas acceptés » → « **Les** ».

**Typographies** — Playfair Display / Great Vibes / Oswald / Jost sont chargées depuis Google Fonts.
C'est un appel réseau externe : si vous voulez l'éviter (connectivité instable sur une péniche,
ou hébergement strictement UE), self-hostez les `.woff2` dans `public/fonts/`.

---

## Reste à faire

Ces points de la feuille de route ne sont **pas** dans ce livrable :

| Sujet | Phase | Note |
|---|---|---|
| Univers **Food** | 1 | Aucune donnée fournie (tapas, planches) — la structure existe, la carte est vide |
| Service à table (QR par table + routage) | 2 | `scan_points.kind = 'table'` déjà prévu |
| **Apple Wallet** (pass de commande) | 2 | PassKit, non commencé |
| Croisement avec la billetterie **Shotgun** | 3 | Côté interne |
| **API POS** du Noti Club | 3 | Re-saisie manuelle au lancement, comme validé |
| Assistant concierge (allergènes / compo) | 3 | Optionnel |

**Non testé en conditions réelles** : OTP SMS, Web Push, relances cron, envoi SMS et traduction
dépendent tous des secrets ci-dessus. Le build passe et le schéma est cohérent, mais le parcours
complet reste à valider sur un vrai projet Supabase.

---

*Noti Calling ne traite aucun paiement en ligne. Le règlement se fait au bar.*

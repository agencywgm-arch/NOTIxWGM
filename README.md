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
- **Identification obligatoire, une seule fois par appareil** : prénom, nom, **téléphone, code
  postal, date de naissance** (obligatoires) + e-mail et Instagram (**optionnels**, complétables
  plus tard) — la commande ne peut pas être envoyée sans les champs obligatoires, exploitables
  ensuite côté CRM (relances, historique, segmentation géographique/âge). Le téléphone sert
  d'**ancre d'identité** : un même numéro sur un nouvel appareil (réinstallation, stockage vidé)
  reprend la fiche existante au lieu d'en créer une seconde. Une session anonyme Supabase
  (`signInAnonymously`) porte le JWT et **persiste** : aux venues suivantes, le scan du QR ouvre
  directement la carte, sans repasser par le formulaire. La présence est enregistrée au passage
- **Espace client** : le client y retrouve ses informations (nom, code postal, date de naissance)
  et peut modifier son téléphone ou compléter e-mail / Instagram quand il le souhaite — un
  rappel s'affiche dans l'app tant que les champs optionnels manquent
- **Reconnaissance client au premier scan** : « Bon retour parmi nous », badge VIP, message dédié
  en cas d'incident (impayé passé)
- **Espace commande en 3 univers** : Boissons au verre · Food · Bouteilles, avec sous-catégories
- Formats multiples (12 cl / 75 cl / magnum) et options composables ; panier, note libre
- **Illustration dessinée par article** (verre, bouteille ou assiette aux couleurs Noti Calling,
  une image distincte par ligne de carte — boissons, bouteilles **et plats**) — encodée
  directement en base, jamais de lien externe cassé
- **Un seul emplacement pour tout code** (réduction % / montant, ou cagnotte) — le client n'a pas
  à savoir de quel type il s'agit ; activé une fois, réappliqué automatiquement aux commandes
  suivantes, et deux codes différents se cumulent
- **Cagnotte en euros** : un code (vendu hors app, lien de paiement en amont) crédite chaque
  personne d'un montant en euros, **dépensé euro pour euro sur n'importe quel article** — aucune
  règle d'éligibilité, aucun jeton, aucune fenêtre horaire. Au-delà, le client règle la
  différence au bar. Le code est **limitable en nombre d'activations** (= la taille du groupe) et
  ne peut être activé qu'une fois par personne. Une commande annulée rend la cagnotte
- **Discipline de la file** : cumul autorisé tant que la commande est en préparation ;
  **blocage dès qu'une commande passe à « prête »**, jusqu'au retrait au bar
- Confirmation avec **code de retrait**, temps estimé et compte à rebours
- Suivi temps réel (WebSocket) + sonnerie douce + vibration + Web Push
- Récapitulatif PDF téléchargeable, mention « à régler au bar »
- Avis 5 étoiles + commentaire en fin de soirée
- Multilingue **FR / EN / ES** (pas de RTL)

### Côté bar & cuisine

- Écran de production temps réel : **Reçues → En préparation → Prêtes → Retirées → Réglées**
- **Alarme sonore** sur nouvelle commande, qui ne s'arrête que sur accusé de réception explicite
- **Réglage du temps de préparation** selon le rush, répercuté sur le timer client
- **Article « épuisé » en un clic** — il reste visible sur la carte, grisé et non commandable,
  et le basculement se propage **en direct** sur tous les téléphones connectés (Realtime, sans
  rechargement)
- **Retraits en retard** : une commande prête non retirée passe en alerte à **15 min** (bar +
  organisation), puis à **20 min** l'organisateur prend le relais et contacte le client. La
  relance automatique au client, elle, part dès **5 min** (Edge Function `reminders`)
- **Impression de ticket** 80 mm — disponible, non obligatoire, non bloquante
- Vue **Caisse** : suivi d'encaissement par client, sélection multiple, marquage « réglé »
  (espèces / CB / autre), suivi des impayés

### Côté organisateur

- **Pilotage temps réel** : présents, commandes en cours, file d'attente, encaissé, impayés
- **Leaderboard temps réel** (qui commande le plus, panier cumulé)
- **Diffusion à toute la soirée** (avec modèles prêts à l'emploi) et **messagerie individuelle**
  organisateur → client — reçus côté client dans un **canal de messages dédié** (onglet 💬,
  historique complet, pas seulement les non-lus)
- **Fiche client complète** : en un tap sur le leaderboard, tous les champs collectés (téléphone,
  e-mail, Instagram, code postal, date de naissance), tags, stats et codes promo utilisés
- **Base client** : historique, nombre de soirées, taille du groupe, **tags & segmentation**
  (VIP / habitué / gros panier / incident) — tags automatiques inclus. Le suivi cross-soirée
  repose désormais sur le **téléphone** (ancre d'identité) : il tient même si le client change
  d'appareil ou vide son stockage local
- **Historique des codes utilisés** par client dans l'export CSV (codes % / montant réellement
  appliqués sur ses commandes + codes à cagnotte activés, avec le montant reçu)
- **Équipe & rôles** : invitation par e-mail, rattachement automatique à la première connexion,
  et trois niveaux d'accès — propriétaire, manager, et un **accès réduit** pour l'équipe de bar
  (Bar, Caisse, Clients seulement)
- **Commentaire et signalement sur chaque commande**, à tout stade (note, à surveiller, geste
  commercial, incident) — interne à l'équipe, jamais visible du client ; un incident remonte
  automatiquement dans les tags de la fiche client
- **Fiche client** : historique complet des commandes, heure d'arrivée, taille du groupe,
  présence live, cagnotte restante, signalements de l'équipe — et envoi d'un message en un tap
- **Jauge d'affluence** alimentée par les scans : remplissage par rapport à la capacité de la
  salle, arrivées sur les 15 / 60 dernières minutes et courbe par tranche de 15 min
- **Reporting post-événement** : panier moyen, top produits, pic horaire, nouveaux vs récurrents,
  note moyenne — export **PDF** et **CSV**
- **Clôture de soirée** : les commandes non réglées passent en « impayé », rattachées à
  l'identité vérifiée (preuve horodatée)

### Notifications (§09)

| Déclencheur | Canal |
|---|---|
| Commande reçue | Push (+ SMS si un numéro est renseigné) |
| Commande prête | Push (+ SMS si un numéro est renseigné) |
| **Relance auto à 5 min** si non retirée | Push (+ SMS) — Edge Function `reminders`, cron |
| **Relance renforcée 1 h avant fermeture** | Push (+ SMS), message impactant avec la conséquence explicite |
| Diffusion / message individuel | Push (+ SMS) |

**Canal dégradé non bloquant** : un SMS qui échoue — ou l'absence de numéro, le client
n'en saisissant plus à l'identification — ne bloque jamais une commande. Le suivi temps réel
(WebSocket) et le Web Push restent le canal principal ; la plateforme reste la source de vérité.

---

## Stack & architecture

| Couche | Choix |
|---|---|
| Front | React 19 + Vite (SPA), un gros `src/App.jsx`, styles en objets inline |
| Back | Supabase — PostgreSQL + RLS + Auth (session anonyme clients / e-mail staff) + Realtime + Edge Functions (Deno) + Storage |
| QR | lib `qrcode` |
| PDF / images | **Canvas 2D natif + writer PDF maison** (`src/lib/pdf.js`) — *pas* de `html2canvas` |
| Déploiement | **Vercel** (build depuis le dépôt), routage SPA via `vercel.json`, base path par `VITE_BASE_PATH` |

```
src/
  App.jsx                  tout l'applicatif (client + staff)
  lib/
    supabase.js            client, erreurs FR, scanUrl()
    theme.js               charte Noti Calling + formats FR
    pdf.js                 writer PDF maison, helpers Canvas, partage iOS
    push.js                Web Push (VAPID) + appel de la fonction notify
    sound.js               sonnerie client + alarme bar (WebAudio)
supabase/
  migrations/
    0001_schema.sql        tables, RPC (place_order, upsert_me, register_scan…), triggers
    0002_rls.sql           Row Level Security
    0003_realtime_reporting.sql  Realtime, vues de pilotage, event_report, close_event
    0004_storage.sql       bucket "noti"
    0005_seed_noti_menu.sql      carte du Noti Club (rentrée 2026)
    0006_simplify_identity.sql   retrait de l'obligation de téléphone (patch, installs existantes)
    0007_reload_menu_idempotent.sql  carte rechargeable sans doublons (patch, installs existantes)
    0008_promo_preview.sql       aperçu code promo au checkout (patch, installs existantes)
    0009_require_profile.sql     prénom + nom + e-mail obligatoires (patch, installs existantes)
    0010_in_prep_status.sql      étape « En préparation » (patch, installs existantes)
    0011_in_prep_close_event.sql clôture de soirée adaptée à « En préparation » (patch, installs existantes)
    0012_menu_rentree_2026.sql   nouveaux prix carte Noti Club (patch, installs existantes)
    0013_forfaits_credits.sql    Forfaits Groupes Noti : pass à crédits (patch, installs existantes)
    0014_realtime_products.sql   rupture de stock en direct côté client (patch, TOUTES installs)
    0015_profil_etendu.sql       téléphone/CP/naissance obligatoires, espace client, code unifié (patch, installs existantes)
    0016_profil_telephone_editable.sql  téléphone modifiable depuis l'espace client (patch, TOUTES installs)
    0017_illustrations_produits.sql     une illustration par article (patch, TOUTES installs)
    0018_profil_cp_naissance_editable.sql  code postal / naissance modifiables (patch, TOUTES installs)
    0019_illustrations_food.sql  carte food (8 plats) + leurs illustrations (patch, TOUTES installs)
    0020_equipe_cagnotte_suivi.sql  cagnotte €, équipe & rôles, suivi de commande, affluence (patch, TOUTES installs)
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
   automatiquement à la création du lieu depuis l'app, et rechargeable ensuite à volonté
   depuis l'onglet **Carte** → bouton **🍸 Carte Noti Club**)*
6. `supabase/migrations/0008_promo_preview.sql` *(aperçu du code promo au checkout — voir la note
   ci-dessous, le fichier 0006 n'est utile qu'aux bases déjà existantes)*

> **Installation déjà faite avant l'identification par simple prénom ?** Exécutez en plus
> `supabase/migrations/0006_simplify_identity.sql` — il retire l'obligation de téléphone sans
> toucher aux commandes déjà enregistrées.
>
> **Installation déjà faite avant que la carte soit rechargeable ?** Exécutez en plus
> `supabase/migrations/0007_reload_menu_idempotent.sql` — sans lui, cliquer sur **Carte Noti Club**
> une deuxième fois duplique tous les articles au lieu de les mettre à jour.
>
> **Installation déjà faite avant que nom et e-mail soient obligatoires ?** Exécutez en plus
> `supabase/migrations/0009_require_profile.sql` — sinon `upsert_me()` continue d'accepter le
> prénom seul.
>
> Une base qui n'a encore rien exécuté n'a besoin ni de 0006, ni de 0007, ni de 0009 :
> `0001_schema.sql` et `0005_seed_noti_menu.sql` contiennent déjà directement ces versions.
>
> **`0008_promo_preview.sql` s'exécute dans tous les cas**, base neuve ou existante — c'est un
> ajout pur (fonction `preview_promo`, aucune version antérieure à remplacer). Sans elle, le champ
> code promo au checkout reste fonctionnel (validé côté serveur par `place_order()`), mais sans
> aperçu ni message avant l'envoi de la commande.
>
> **Installation déjà faite avant l'étape « En préparation » ?** Exécutez, dans deux **Run**
> séparés (obligatoire — PostgreSQL interdit d'utiliser une nouvelle valeur d'enum dans la
> transaction qui vient de la créer) :
> 1. `supabase/migrations/0010_in_prep_status.sql`
> 2. `supabase/migrations/0011_in_prep_close_event.sql`
>
> Une base neuve n'en a pas besoin : `0001_schema.sql` et `0003_realtime_reporting.sql`
> contiennent déjà directement cette version.
>
> **Nouveaux prix carte Noti Club (rentrée 2026) ?** Exécutez
> `supabase/migrations/0012_menu_rentree_2026.sql`, puis dans l'onglet **Carte** côté app,
> cliquez sur **🍸 Carte Noti Club** pour appliquer les nouveaux prix aux articles déjà en
> base (le rechargement met à jour, il ne duplique pas). Une base neuve n'en a pas besoin :
> `0005_seed_noti_menu.sql` contient déjà directement cette version.
>
> **`0013_forfaits_credits.sql`** créait l'ancien système de crédits. Il reste dans la liste car
> il crée la table des portefeuilles, mais **son modèle de crédits est remplacé** par la cagnotte
> en euros de `0020` — inutile de s'y attarder, exécutez simplement les deux dans l'ordre.
>
> **`0014_realtime_products.sql` s'exécute dans tous les cas**, base neuve ou existante : il
> publie la table `products` en Realtime. Sans lui, marquer un article « épuisé » depuis la
> tablette ne se voit côté client qu'au rechargement de la page — un client peut donc commander
> un article épuisé pendant plusieurs minutes et se faire refuser sa commande à l'envoi.
>
> **`0015_profil_etendu.sql` s'exécute dans tous les cas**, base neuve ou existante : il change
> la signature de `upsert_me()` pour rendre téléphone / code postal / date de naissance
> obligatoires (e-mail et Instagram devenant optionnels), ajoute les colonnes correspondantes sur
> `customers`, et ajoute `update_my_optional_profile()` (espace client) /
> `validate_promo_code()` (saisie de code unifiée). `0001_schema.sql` contient encore l'ancienne
> version 3 arguments : sans `0015`, l'identification échouera dès que l'app enverra le
> téléphone/CP/naissance qu'elle collecte désormais.
>
> **`0016_profil_telephone_editable.sql` s'exécute dans tous les cas**, base neuve ou existante :
> il rend le téléphone modifiable depuis l'espace client (en plus d'e-mail / Instagram), avec un
> message clair si le numéro est déjà utilisé par une autre fiche.
>
> **`0017_illustrations_produits.sql` s'exécute dans tous les cas**, base neuve ou existante :
> une illustration dessinée (verre/bouteille aux couleurs Noti Calling, encodée en data URI —
> jamais de lien externe, jamais cassée) pour chaque article de la carte type. Fichier volumineux
> (~250 Ko) car chaque image est intégrée directement dans le SQL ; le collage peut prendre
> quelques secondes de plus que les autres blocs. Rejoué automatiquement à chaque clic sur
> **🍸 Carte Noti Club**, donc pas besoin de le recoller après un premier passage.
>
> **`0018_profil_cp_naissance_editable.sql` s'exécute dans tous les cas**, base neuve ou
> existante : code postal et date de naissance deviennent eux aussi modifiables depuis l'espace
> client (comme le téléphone, 0016) — indispensable pour les fiches créées avant l'ajout de ces
> deux champs (0015), qui les ont vides sans lui.
>
> **`0019_illustrations_food.sql` s'exécute dans tous les cas**, base neuve ou existante :
> l'univers **Food** ne faisait pas partie de la carte type — il restait donc vide tant qu'aucun
> plat n'avait été saisi à la main, et n'avait par conséquent aucune illustration à afficher. Ce
> patch sème les huit plats de la carte Noti Club (frites, houmous pistache, tempura poulet,
> croque truffé, stracciatella, fritto misto, planche charcuterie, planche fromages) avec leurs
> prix et une illustration chacun, dans le même style que les boissons. Fichier volumineux
> (~130 Ko) pour la même raison que 0017. Rejoué à chaque clic sur **🍸 Carte Noti Club** : les
> prix se mettent à jour sans jamais créer de doublon, et un plat déjà saisi sous un libellé
> proche récupère quand même son illustration.
>
> **`0020_equipe_cagnotte_suivi.sql` s'exécute dans tous les cas**, base neuve ou existante.
> Il apporte quatre choses :
>
> 1. **La cagnotte en euros remplace les crédits.** Plus de « 1 alcool = 2 crédits, 1 soft =
>    1 crédit », plus de jeton food ni de fenêtres à 22h/22h30 : un code promo de type
>    **cagnotte** verse un montant en euros, dépensé euro pour euro sur n'importe quel article,
>    et le client règle au bar la différence s'il dépasse. Le nombre d'activations du code est
>    limitable (= le nombre de personnes du groupe), et un même code ne peut être activé qu'une
>    fois par personne.
>    ⚠️ **Les soldes existants sont convertis à 5,00 € le crédit.** Si votre forfait valait autre
>    chose, changez `v_credit_eur` en haut du patch **avant** de l'exécuter — la conversion n'a
>    lieu qu'une fois.
> 2. **Équipe et rôles.** Invitation par e-mail depuis *Réglages → Équipe* (propriétaire
>    uniquement) : la personne crée son compte avec cette adresse et rejoint le lieu à sa
>    première connexion, sans e-mail à envoyer ni code à transmettre. Trois niveaux —
>    *propriétaire* (tout + équipe), *manager* (tout sauf l'équipe), *équipe* (version réduite :
>    Bar, Caisse, Clients).
> 3. **Suivi des commandes.** Un clic sur une commande, à n'importe quel stade, pour la commenter
>    ou la signaler (note, à surveiller, geste commercial, incident). Un incident taggue aussi la
>    fiche du client. Ces commentaires sont internes : jamais visibles côté client.
> 4. **Affluence.** Capacité de la salle (Réglages) + jauge de remplissage, rythme d'arrivée et
>    courbe des arrivées par tranche de 15 min dans l'onglet Orga, alimentés par les scans.
>
> Il corrige au passage deux défauts : le compteur « En prépa » du tableau de bord ignorait les
> commandes au stade *En préparation*, et une commande annulée ne rendait pas au client la part
> qu'il avait réglée avec sa cagnotte.

### 3. Activer l'authentification

**Deux modes coexistent** — ne configurez pas que l'un des deux :

- **Staff** — *Authentication → Providers → **Email*** : activer.
  Pour démarrer sans friction, désactivez « Confirm email ».
- **Clients** — *Authentication → Providers → **Anonymous*** : activer. Le client saisit son
  prénom, un clic déclenche `signInAnonymously()` — **aucun SMS, aucun compte, aucun fournisseur
  à configurer.**

> Sans le provider Anonymous activé, l'écran d'identification renvoie une erreur. C'est le seul
> point bloquant pour tester le parcours client de bout en bout — et il ne demande qu'un bouton à
> cocher dans le dashboard.

**Mot de passe oublié (staff)** — l'écran de connexion a un lien *Mot de passe oublié ?* qui envoie
un e-mail de réinitialisation (`resetPasswordForEmail`). Pour qu'il fonctionne :

- *Authentication → URL Configuration → Redirect URLs* : ajoutez l'URL de votre déploiement
  (`https://votre-site.vercel.app/*`) — sans elle, Supabase refuse de rediriger vers le lien de
  réinitialisation et l'e-mail échoue silencieusement.
- L'envoi passe par le service e-mail intégré de Supabase par défaut (volume limité, parfois classé
  en spam) ; pour un usage réel, configurez un SMTP dédié dans *Authentication → Settings → SMTP
  Settings*.

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
| `VAPID_*` | notifications Web Push — canal principal du suivi client | l'app marche, sans push |
| `SMS_PROVIDER` + secrets du fournisseur | SMS de statut, relances, diffusion — **optionnel** : le client n'a pas de numéro par défaut (identification par prénom/nom/e-mail, pas de téléphone), ce canal ne sert que si un téléphone est ajouté manuellement | les messages restent dans l'app (tracés, non envoyés) |
| `CRON_SECRET` | protéger la fonction `reminders` | la fonction refuse tout appel |
| `ANTHROPIC_API_KEY` | traduction auto FR → EN/ES | bouton de traduction en erreur |

`SMS_PROVIDER` accepte `twilio`, `vonage`, `brevo`, `ovh` ou `none`. Les quatre sont implémentés
derrière la même interface (`supabase/functions/_shared/sms.ts`) — vous basculez de l'un à l'autre
sans toucher au code. Laissez `none` (ou omettez le secret) tant qu'aucun téléphone client n'est
collecté : l'identification (étape 3) n'en a plus besoin, c'est une session anonyme Supabase.

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

### 8. Déployer le front sur Vercel

Le dépôt étant **privé en plan gratuit**, GitHub Pages n'est pas utilisable (il exige un plan
Pro/Team/Enterprise pour les dépôts privés). Le déploiement passe par **Vercel**, qui accepte les
dépôts privés sur son plan gratuit *Hobby* et détecte Vite nativement (zéro configuration de build).

> ⚠️ **Plan Hobby = usage non commercial.** Les conditions d'utilisation de Vercel réservent le
> plan gratuit *Hobby* aux projets personnels / non commerciaux ; une exploitation pour le compte
> d'un établissement qui facture ses clients (le cas du Noti Club) relève normalement du plan
> **Pro** (~20 $/mois). Continuez sur Hobby pour la mise au point et les tests, mais prévoyez de
> passer sur Pro avant la première vraie soirée facturée.

1. [vercel.com/new](https://vercel.com/new) → **Import Git Repository**
2. Autoriser l'accès GitHub, sélectionner **`agencywgm-arch/NOTIxWGM`**
3. Vercel détecte automatiquement le framework (**Vite**) — build command et dossier de sortie
   (`dist`) sont préremplis, rien à changer.
4. **Environment Variables** (cochez *Production*, *Preview* et *Development*) :

   | Nom | Valeur |
   |---|---|
   | `VITE_SUPABASE_URL` | URL du projet Supabase |
   | `VITE_SUPABASE_ANON_KEY` | clé **anon public** |
   | `VITE_VAPID_PUBLIC_KEY` | clé **publique** VAPID (étape 4) |
   | `VITE_BASE_PATH` | `/` |

5. **Deploy**

Le site sort sur `https://notixwgm.vercel.app` (ou le nom du projet choisi). Pour un domaine
propre : onglet **Settings → Domains** → `commande.noticalling.fr` par exemple.

> ⚠️ **Les variables sont lues à la compilation**, pas à l'exécution : après toute modification
> d'une variable d'environnement, il faut **redéployer** (*Deployments → … → Redeploy*) pour
> qu'elle soit prise en compte.

> Le fichier `vercel.json` (rewrite `/(.*) → /index.html`) assure le routage SPA. Sans lui, un QR
> scanné (`/s/{scan_point_id}`) renverrait une 404 au lieu d'ouvrir l'application. `public/_redirects`
> reste dans le dépôt pour Cloudflare Pages / Netlify, au cas où vous en changeriez plus tard.

**Si vous préférez repasser sur GitHub Pages plus tard** (dépôt rendu public, ou plan payant) :
le workflow `.github/workflows/deploy-github-pages.yml` est prêt, en déclenchement manuel. Activez
*Settings → Pages → Source : GitHub Actions*, créez les trois secrets, puis lancez-le depuis
l'onglet Actions.

### 9. Vérifier le déploiement

Ouvrez l'URL Vercel :

- Si l'écran **« Configuration requise »** s'affiche → les variables `VITE_SUPABASE_*` ne sont pas
  arrivées dans le build. Vérifiez-les et redéployez.
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

**RLS stricte** — le client porte un vrai JWT, même en session anonyme (`signInAnonymously`),
donc chacun ne voit que ses propres commandes et le staff celles de ses événements. Rien n'est
ouvert en lecture publique à part la vitrine (soirée, points de scan, carte).

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

**Non testé en conditions réelles** : session anonyme, Web Push, relances cron, envoi SMS et
traduction dépendent tous des réglages/secrets ci-dessus. Le build passe et le schéma est
cohérent, mais le parcours complet reste à valider sur un vrai projet Supabase.

---

*Noti Calling ne traite aucun paiement en ligne. Le règlement se fait au bar.*

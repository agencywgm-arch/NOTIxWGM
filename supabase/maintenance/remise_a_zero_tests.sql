-- ============================================================================
--  REMISE À ZÉRO DES DONNÉES DE TEST
--
--  ⚠️  CE SCRIPT EFFACE DÉFINITIVEMENT TOUTE L'ACTIVITÉ CLIENT.
--      Il n'y a pas de corbeille, pas d'annulation. À n'exécuter que sur une
--      base de test, ou avant une vraie mise en service.
--
--  ⚠️  CE N'EST PAS UNE MIGRATION. Il est volontairement rangé hors de
--      supabase/migrations/ : s'il y était, il s'exécuterait à chaque
--      installation et viderait la base d'un client en production.
--
--  ---------------------------------------------------------------------
--  CE QUI EST EFFACÉ (tout ce qu'un client a produit)
--
--    · les clients eux-mêmes et leurs fiches
--    · les commandes et leur contenu
--    · les scans / présences (donc l'affluence et la courbe)
--    · les forfaits, crédits, cadeaux et leur historique
--    · les entrées payantes comptabilisées dans « Encaissé »
--    · les messages, avis, commentaires de commande
--    · les conversations avec l'assistant
--    · les abonnements aux notifications des clients
--
--  CE QUI EST CONSERVÉ
--
--    · la carte (articles, prix, illustrations, traductions)
--    · l'établissement, les soirées, les points de scan et leurs QR codes
--    · les codes promo (leur compteur d'utilisation repart à zéro)
--    · l'équipe, les rôles et les invitations
--    · les étiquettes de segmentation que vous avez créées
--
--  Les comptes staff ne sont pas touchés : ils vivent dans auth.users et
--  staff_members, jamais dans customers.
--  ---------------------------------------------------------------------
--
--  MODE D'EMPLOI : SQL Editor → New query → coller ce fichier → Run.
--  Le récapitulatif final affiche ce qui reste.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. L'activité client.
--
--  Supprimer les clients suffirait presque : la plupart de ces tables les
--  référencent avec `on delete cascade`. On les vide quand même une par une,
--  explicitement — une table dont la contrainte serait en `set null` (ou
--  ajoutée plus tard sans cascade) laisserait sinon des lignes orphelines qui
--  continueraient de gonfler les compteurs.
-- ---------------------------------------------------------------------------
delete from public.client_assistant_messages;
delete from public.gift_redemptions;
delete from public.gift_entitlements;
delete from public.promo_redemptions;
delete from public.event_entries;
delete from public.event_passes;
delete from public.order_notes;
delete from public.reviews;
delete from public.order_items;
delete from public.orders;
delete from public.attendances;
delete from public.messages;

-- Seuls les abonnements des clients : ceux du staff gardent les tablettes du
-- bar branchées sur les alertes.
delete from public.push_subscriptions where role = 'customer' or customer_id is not null;

delete from public.customers;

-- ---------------------------------------------------------------------------
--  2. Les compteurs portés par des lignes qu'on conserve.
-- ---------------------------------------------------------------------------

-- Les codes promo redeviennent utilisables : sans ça, un code à
-- `max_uses = 50` resterait épuisé alors que plus personne ne l'a activé.
update public.promo_codes set uses_count = 0;

-- La carte repart entièrement disponible.
update public.products set sold_out = false;

commit;

-- ============================================================================
--  Récapitulatif : les compteurs à zéro, la carte intacte.
-- ============================================================================
select 'clients'            as element, count(*) as reste from public.customers
union all select 'commandes',           count(*) from public.orders
union all select 'présences (scans)',   count(*) from public.attendances
union all select 'forfaits',            count(*) from public.event_passes
union all select 'entrées payantes',    count(*) from public.event_entries
union all select 'messages',            count(*) from public.messages
union all select 'conv. assistant',     count(*) from public.client_assistant_messages
union all select '— — — — —',           null
union all select 'CONSERVÉ : articles', count(*) from public.products
union all select 'CONSERVÉ : soirées',  count(*) from public.events
union all select 'CONSERVÉ : codes',    count(*) from public.promo_codes
union all select 'CONSERVÉ : équipe',   count(*) from public.staff_members
union all select 'CONSERVÉ : segments', count(*) from public.customer_segments;

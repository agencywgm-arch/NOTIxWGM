-- ============================================================================
--  NOTI Calling — 0053_pause_verification_telephone.sql
--  Vérification du numéro : interrupteur par soirée, sans toucher au code.
--
--  La vérification était pilotée uniquement par la présence des variables
--  Firebase (VITE_FIREBASE_*) sur Vercel — la couper demandait de les retirer
--  et de redéployer, pas quelque chose qu'on fait en plein service. Un
--  interrupteur sur l'événement se bascule depuis Réglages en un clic, sans
--  redéploiement, et se réactive aussi facilement le lendemain.
-- ============================================================================

alter table public.events
  add column if not exists phone_verify_required boolean not null default true;

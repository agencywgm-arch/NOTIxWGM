-- ============================================================================
--  0026 — « Personnes présentes » : dire ce que le chiffre mesure
--
--  Retour terrain, 5.2 : « comment est calculé ce chiffre aujourd'hui ? Il faut
--  qu'on sache exactement ce que la métrique mesure avant de s'en servir. »
--
--  Réponse : jusqu'ici, « Présents » affichait la somme des group_size de tous
--  les scans depuis l'ouverture. C'est un CUMUL d'entrées — il ne redescend
--  jamais, et à 4 h du matin il annonce encore le maximum de la soirée.
--
--  Trois chiffres distincts, désormais nommés pour ce qu'ils sont :
--
--    headcount   — entrées cumulées depuis l'ouverture (somme des group_size)
--    scan_count  — personnes distinctes ayant scanné un QR
--    still_here  — personnes encore actives : un scan OU une commande dans les
--                  30 dernières minutes
--
--  `still_here` est l'estimation demandée. Le delta avec headcount donne
--  « qui est entré » contre « qui est encore là ».
--
--  POURQUOI UNE NOUVELLE VUE plutôt qu'étendre v_event_pulse : `create or
--  replace view` refuse de retirer des colonnes. En rejouant setup.sql, la
--  définition plus étroite de 0020 passerait après celle-ci et échouerait. Une
--  vue distincte évite ce piège — v_event_pulse reste intacte.
--
--  Idempotent.
-- ============================================================================

create or replace view public.v_event_presence
with (security_invoker = true) as
select
  e.id                                                                              as event_id,
  e.capacity                                                                        as capacity,
  -- Entrées cumulées depuis l'ouverture. Ne redescend jamais : c'est un total,
  -- pas une jauge.
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  -- Personnes distinctes ayant scanné, quel que soit le nombre de scans.
  (select count(*) from public.attendances a where a.event_id = e.id)               as scan_count,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '15 minutes')   as arrivals_15min,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '60 minutes')   as arrivals_60min,
  (select max(a.first_scan_at) from public.attendances a where a.event_id = e.id)   as last_arrival_at,
  -- Encore là : un scan OU une commande dans les 30 dernières minutes. Une
  -- personne qui commande sans re-scanner compte donc bien comme présente —
  -- c'est le cas le plus fréquent, on ne scanne qu'à l'entrée.
  (select count(*) from (
     select a.customer_id
       from public.attendances a
      where a.event_id = e.id
        and a.last_scan_at >= now() - interval '30 minutes'
     union
     select o.customer_id
       from public.orders o
      where o.event_id = e.id
        and o.created_at >= now() - interval '30 minutes'
        and o.status::text <> 'CANCELLED'
   ) actifs)                                                                        as still_here
from public.events e;

grant select on public.v_event_presence to authenticated;

comment on view public.v_event_presence is
  'Présence réelle. headcount = entrées cumulées ; scan_count = personnes ayant '
  'scanné ; still_here = encore actives (scan ou commande dans les 30 min).';

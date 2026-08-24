-- ============================================================================
--  0030 — Formule de présence affinée, et réglable par établissement
--
--  Retour terrain, 6.1 / 6.2 / 6.3 (méthode actée en point équipe) :
--
--  · « Scans QR = scans UNIQUES. Une personne qui rescanne pour se
--    reconnecter ne doit pas être recomptée. » — déjà le cas : attendances a
--    une ligne par (event_id, customer_id), donc scan_count (0026) compte
--    déjà des personnes, jamais des scans. Rien à changer côté scan_count.
--
--  · Formule « personnes présentes » :
--      a commandé un verre     → présente dans l'HEURE
--      a commandé une bouteille → présente dans l'HEURE
--      a utilisé l'outil (sans commander) → présente dans les 30 MIN
--    Rationale de la séance : la fenêtre d'une heure sur les consos évite de
--    sous-estimer (fréquence de consommation réelle inconnue) ; les 30 min
--    sur le seul usage de l'outil suffisent, puisqu'une fois parti on ne
--    consulte plus l'outil.
--
--  · « La fenêtre doit rester ajustable selon l'établissement — fort
--    turnover, on descend à 15-20 min. »
--
--  · « Mentionner explicitement estimation sous le chiffre, et rendre le mot
--    cliquable pour afficher la méthode de calcul. »  → côté texte/UI.
-- ============================================================================

alter table public.events
  add column if not exists presence_order_window_min int not null default 60,
  add column if not exists presence_scan_window_min  int not null default 30;

comment on column public.events.presence_order_window_min is
  'Fenêtre « présent » après une commande (minutes). Défaut 60.';
comment on column public.events.presence_scan_window_min is
  'Fenêtre « présent » sur simple usage de l''outil, sans commande (minutes). Défaut 30.';

alter table public.events
  add constraint events_presence_windows_positive
  check (presence_order_window_min > 0 and presence_scan_window_min > 0)
  not valid;
-- `not valid` : ne bloque pas les lignes déjà en base (toutes ont le défaut
-- valide de toute façon) ; validée à la prochaine occasion sans verrou long.
alter table public.events validate constraint events_presence_windows_positive;


create or replace view public.v_event_presence
with (security_invoker = true) as
select
  e.id                                                                              as event_id,
  e.capacity                                                                        as capacity,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select count(*) from public.attendances a where a.event_id = e.id)               as scan_count,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '15 minutes')   as arrivals_15min,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '60 minutes')   as arrivals_60min,
  (select max(a.first_scan_at) from public.attendances a where a.event_id = e.id)   as last_arrival_at,
  -- Encore là, au sens fin : une commande de boisson OU bouteille dans la
  -- fenêtre « commande », OU un simple usage (scan) dans la fenêtre « scan ».
  -- Les deux fenêtres sont celles de LA soirée, pas une constante partagée.
  (select count(*) from (
     select o.customer_id
       from public.orders o
      where o.event_id = e.id
        and o.status::text <> 'CANCELLED'
        and o.created_at >= now() - make_interval(mins => e.presence_order_window_min)
     union
     select a.customer_id
       from public.attendances a
      where a.event_id = e.id
        and a.last_scan_at >= now() - make_interval(mins => e.presence_scan_window_min)
   ) actifs)                                                                        as still_here,
  -- Ajoutées en fin de liste : `create or replace view` refuse de retirer ou
  -- de déplacer des colonnes existantes (voir déjà le choix fait en 0026
  -- pour la même raison). Exposées pour que l'écran staff puisse afficher la
  -- méthode exacte au clic sur « estimation ».
  e.presence_order_window_min                                                       as order_window_min,
  e.presence_scan_window_min                                                        as scan_window_min
from public.events e;

grant select on public.v_event_presence to authenticated;

comment on view public.v_event_presence is
  'Présence réelle. headcount = entrées cumulées ; scan_count = personnes '
  'ayant scanné ; still_here = commande boisson/bouteille dans la fenêtre '
  '« commande », ou simple usage dans la fenêtre « scan » (les deux réglables '
  'par soirée, events.presence_order_window_min / presence_scan_window_min).';

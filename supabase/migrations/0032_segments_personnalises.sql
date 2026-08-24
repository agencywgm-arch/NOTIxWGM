-- ============================================================================
--  0032 — Segmentations personnalisées
--
--  Retour terrain : « je veux dans la fiche client la possibilité de créer des
--  segmentations personnalisées ».
--
--  Jusqu'ici les étiquettes étaient une liste FIGÉE dans le code
--  (vip / habitué / gros panier / incident, cf. ALL_TAGS côté client). Le
--  stockage, lui, était déjà libre : `customers.tags` est un `text[]`, il
--  accepte n'importe quelle valeur. Il ne manquait donc qu'un endroit où
--  DÉCLARER les étiquettes d'un établissement, pour qu'elles s'affichent
--  partout comme les quatre autres.
--
--  Choix : les segments appartiennent au LIEU (comme la carte), pas à la
--  soirée — un « anniversaire » ou un « client Instagram » sert d'une soirée à
--  l'autre. Les quatre étiquettes historiques restent codées en dur côté
--  client : elles ne sont pas dans cette table, ne peuvent pas être
--  supprimées, et continuent d'alimenter les compteurs de l'onglet Clients.
-- ============================================================================

create table if not exists public.customer_segments (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references public.venues (id) on delete cascade,
  key        text not null,
  label      text not null,
  created_at timestamptz not null default now(),
  unique (venue_id, key)
);

-- `key` est la valeur réellement écrite dans customers.tags : on la contraint
-- au même format que les étiquettes historiques (minuscules sans accent,
-- underscore), pour qu'aucun segment ne puisse entrer en collision avec
-- 'vip' / 'habitue' / 'gros_panier' / 'incident' par une simple différence de
-- casse ou d'espace.
alter table public.customer_segments
  drop constraint if exists customer_segments_key_format;
alter table public.customer_segments
  add constraint customer_segments_key_format
  check (key ~ '^[a-z0-9_]{2,32}$');

alter table public.customer_segments
  drop constraint if exists customer_segments_key_not_builtin;
alter table public.customer_segments
  add constraint customer_segments_key_not_builtin
  check (key not in ('vip', 'habitue', 'gros_panier', 'incident'));

create index if not exists customer_segments_venue_idx
  on public.customer_segments (venue_id, created_at);

alter table public.customer_segments enable row level security;

-- Toute l'équipe du lieu lit et écrit : créer une étiquette fait partie du
-- travail de terrain, pas de l'administration du compte.
drop policy if exists customer_segments_staff on public.customer_segments;
create policy customer_segments_staff on public.customer_segments
  for all to authenticated
  using (public.is_staff(venue_id)) with check (public.is_staff(venue_id));

comment on table public.customer_segments is
  'Étiquettes de segmentation propres à un établissement, en plus des quatre '
  'historiques (vip, habitue, gros_panier, incident) qui restent codées en '
  'dur côté application. `key` est la valeur écrite dans customers.tags.';

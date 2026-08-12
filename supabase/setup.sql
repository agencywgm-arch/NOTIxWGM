-- ############################################################################
--
--   NOTI CALLING — INSTALLATION COMPLÈTE DE LA BASE
--
--   Copiez-collez CE FICHIER ENTIER dans :
--       Supabase → SQL Editor → New query → Run
--
--   Il regroupe les 5 migrations, dans le bon ordre. Il est idempotent :
--   vous pouvez le relancer sans casser une installation existante.
--
--   Contenu :
--     1. Schéma        — tables, types, fonctions RPC, triggers
--     2. RLS           — Row Level Security
--     3. Realtime      — publication + vues de pilotage + reporting
--     4. Storage       — bucket « noti » (logos, visuels produits)
--     5. Carte         — fonction seed_noti_menu() (carte du Noti Club, rejouable)
--
--   Après exécution, il reste à faire dans l'interface Supabase :
--     · Authentication → Providers → Email : activer (staff)
--     · Authentication → Providers → Anonymous : activer (clients — aucun
--       SMS, aucun compte : le client saisit juste son prénom)
--
--   NOTE — installation déjà existante (créée avant l'identification par
--   simple prénom) : exécutez en plus supabase/migrations/0006_simplify_identity.sql
--   une fois, pour retirer l'obligation de téléphone sur les commandes passées.
--   Idem pour supabase/migrations/0007_reload_menu_idempotent.sql si la carte
--   avait déjà été seedée avant ce fichier (pour pouvoir la recharger sans
--   dupliquer les articles).
--
-- ############################################################################

-- ============================================================================
--  0001_schema.sql
-- ============================================================================
-- ============================================================================
--  NOTI Calling — 0001_schema.sql
--  Outil de commande par QR code pour soirée événementielle.
--
--  PRINCIPE VALIDÉ : aucun paiement en ligne. La plateforme affiche le prix,
--  l'encaissement se fait à 100 % au bar sur le système existant du lieu.
--  Ce schéma est un outil de commande + file + CRM + communication, pas une caisse.
--
--  Phase 1 : QR à l'entrée et au bar uniquement — aucun QR sur les tables.
--  (Le service à table est prévu en phase 2 : le type 'table' existe déjà
--   dans scan_points pour ne pas avoir à migrer.)
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- ÉNUMÉRATIONS
do $$ begin
  create type public.order_status as enum (
    'RECEIVED',   -- reçue au bar
    'READY',      -- prête à retirer  → bloque toute nouvelle commande
    'PICKED_UP',  -- retirée par le client
    'PAID',       -- réglée au bar
    'UNPAID',     -- non réglée en fin de soirée (reste due)
    'CANCELLED'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.scan_kind as enum ('entrance', 'bar', 'table');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.universe as enum ('drinks', 'food', 'bottles');
exception when duplicate_object then null; end $$;

-- --------------------------------------------------------------------- LIEUX
-- White-label : un compte peut opérer plusieurs lieux et plusieurs événements.
create table if not exists public.venues (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text unique,
  owner_id    uuid not null references auth.users (id) on delete cascade,
  logo_url    text,
  address     text,
  city        text,
  phone       text,
  siret       text,
  tva_number  text,
  created_at  timestamptz not null default now()
);

create index if not exists venues_owner_idx on public.venues (owner_id);

-- Équipe : plusieurs comptes staff par lieu (bar, cuisine, orga).
create table if not exists public.staff_members (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references public.venues (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null default 'staff',   -- owner | manager | staff
  created_at timestamptz not null default now(),
  unique (venue_id, user_id)
);

-- --------------------------------------------------------------- ÉVÉNEMENTS
create table if not exists public.events (
  id                uuid primary key default gen_random_uuid(),
  venue_id          uuid not null references public.venues (id) on delete cascade,
  name              text not null,
  starts_at         timestamptz,
  closes_at         timestamptz,                 -- pilote la relance « 1 h avant fermeture »
  default_prep_min  int  not null default 1,     -- feuille de route §07 : défaut 1 min
  languages         text[] not null default '{fr,en,es}',
  accept_orders     boolean not null default true,
  service_message   text,
  welcome_message   text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);

create index if not exists events_venue_idx on public.events (venue_id, is_active);

-- ----------------------------------------------------------- POINTS DE SCAN
-- L'URL d'un QR est /s/{scan_point_id} — format stable, ne jamais casser.
create table if not exists public.scan_points (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events (id) on delete cascade,
  kind         public.scan_kind not null default 'entrance',
  label        text,
  table_number int,                              -- réservé phase 2
  created_at   timestamptz not null default now()
);

create index if not exists scan_points_event_idx on public.scan_points (event_id);

-- ----------------------------------------------------------------- LA CARTE
-- La carte appartient au LIEU : elle est réutilisée d'un événement à l'autre.
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues (id) on delete cascade,
  universe     public.universe not null default 'drinks',
  subcategory  text not null default 'Cocktails',
  name         text not null,
  description  text,
  price        numeric(10, 2) not null default 0,
  image_url    text,
  is_popular   boolean not null default false,
  sold_out     boolean not null default false,   -- reste VISIBLE, devient non commandable
  is_listed    boolean not null default true,    -- retiré de la carte (≠ épuisé)
  sort_order   int not null default 0,
  is_alcohol   boolean not null default true,
  vat_rate     numeric(5, 2) not null default 20.00,
  variants     jsonb not null default '[]'::jsonb,  -- [{id,label,price}] ex. 12cl/75cl/150cl
  option_groups jsonb not null default '[]'::jsonb, -- surtout pour la food
  translations jsonb not null default '{}'::jsonb,  -- {"en":{name,description},"es":{...}}
  created_at   timestamptz not null default now()
);

create index if not exists products_venue_idx on public.products (venue_id, universe, sort_order);

comment on column public.products.variants is
  'Formats vendus, ex. [{"id":"12cl","label":"12 cl","price":8}]. Si non vide, le choix est obligatoire.';
comment on column public.products.option_groups is
  '[{"id":"cuisson","name":"Cuisson","required":true,"min":1,"max":1,"options":[{"id":"s","name":"Saignant","price":0}]}]';

-- ------------------------------------------------------------------ CLIENTS
-- Identification légère : prénom + session anonyme Supabase (pas d'OTP SMS,
-- pas de compte). `phone` reste disponible pour une saisie manuelle future.
create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  phone         text unique,
  first_name    text,
  last_name     text,
  email         text,
  tags          text[] not null default '{}',    -- vip | habitue | gros_panier | incident
  consents      jsonb  not null default '{}'::jsonb,
  orders_count  int not null default 0,
  events_count  int not null default 0,
  total_spent   numeric(10, 2) not null default 0,
  unpaid_count  int not null default 0,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  staff_note    text,
  created_at    timestamptz not null default now()
);

create index if not exists customers_phone_idx on public.customers (phone);
create index if not exists customers_tags_idx  on public.customers using gin (tags);

comment on column public.customers.consents is
  'Consentements granulaires horodatés : {"cgu":{"granted":true,"at":"...","version":"1.0"},
   "prospection":{...}, "share_with_venue":{...}}';

-- --------------------------------------------------------------- PRÉSENCES
-- Un scan = une présence sur l'événement (compteur « personnes présentes »).
create table if not exists public.attendances (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events (id) on delete cascade,
  customer_id    uuid not null references public.customers (id) on delete cascade,
  scan_point_id  uuid references public.scan_points (id) on delete set null,
  group_size     int not null default 1,          -- « nombre de personnes ajoutées »
  first_scan_at  timestamptz not null default now(),
  last_scan_at   timestamptz not null default now(),
  unique (event_id, customer_id)
);

create index if not exists attendances_event_idx on public.attendances (event_id);

-- --------------------------------------------------------------- COMMANDES
create table if not exists public.orders (
  id                 uuid primary key default gen_random_uuid(),
  event_id           uuid not null references public.events (id) on delete cascade,
  customer_id        uuid not null references public.customers (id) on delete cascade,
  scan_point_id      uuid references public.scan_points (id) on delete set null,
  pickup_code        text not null,               -- code de retrait présenté au bar
  status             public.order_status not null default 'RECEIVED',
  subtotal           numeric(10, 2) not null default 0,
  discount           numeric(10, 2) not null default 0,
  total              numeric(10, 2) not null default 0,
  promo_code         text,
  note               text,
  estimated_ready_at timestamptz,
  ready_at           timestamptz,
  picked_up_at       timestamptz,
  paid_at            timestamptz,
  paid_method        text,                        -- especes | cb | autre
  reminder_5min_at   timestamptz,                 -- relance auto « pas retirée »
  reminder_closing_at timestamptz,                -- relance renforcée avant fermeture
  printed_at         timestamptz,                 -- impression ticket (optionnelle)
  created_at         timestamptz not null default now()
);

create index if not exists orders_event_status_idx on public.orders (event_id, status);
create index if not exists orders_customer_idx     on public.orders (customer_id, created_at desc);
create unique index if not exists orders_pickup_code_idx on public.orders (event_id, pickup_code);

create table if not exists public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders (id) on delete cascade,
  product_id    uuid references public.products (id) on delete set null,
  name_snapshot text not null default '',
  variant_label text,
  unit_price    numeric(10, 2) not null default 0,
  vat_rate      numeric(5, 2)  not null default 20.00,
  quantity      int not null default 1,
  detail        jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists order_items_order_idx on public.order_items (order_id);

-- ------------------------------------------------------------------ MESSAGES
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  kind        text not null default 'broadcast',   -- status | broadcast | individual
  body        text not null,
  customer_id uuid references public.customers (id) on delete cascade, -- null = diffusion
  order_id    uuid references public.orders (id) on delete set null,
  created_by  uuid references auth.users (id) on delete set null,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists messages_event_idx    on public.messages (event_id, created_at desc);
create index if not exists messages_customer_idx on public.messages (customer_id, created_at desc);

-- --------------------------------------------------------------------- AVIS
create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  customer_id uuid references public.customers (id) on delete set null,
  order_id    uuid references public.orders (id) on delete set null,
  rating      int not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now()
);

create index if not exists reviews_event_idx on public.reviews (event_id);

-- -------------------------------------------------------------- CODES PROMO
create table if not exists public.promo_codes (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events (id) on delete cascade,
  code       text not null,
  label      text not null default 'Promo',
  kind       text not null default 'percent',      -- percent | amount
  value      numeric(10, 2) not null default 0,
  min_total  numeric(10, 2) not null default 0,
  starts_at  timestamptz,
  ends_at    timestamptz,
  max_uses   int,
  uses_count int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (event_id, code)
);

-- ------------------------------------------------------- ABONNEMENTS PUSH
create table if not exists public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid references public.events (id) on delete cascade,
  customer_id uuid references public.customers (id) on delete cascade,
  venue_id    uuid references public.venues (id) on delete cascade,
  role        text not null default 'customer',    -- customer | staff
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

create index if not exists push_customer_idx on public.push_subscriptions (customer_id);
create index if not exists push_venue_idx    on public.push_subscriptions (venue_id);

-- ============================================================================
--  FONCTIONS
-- ============================================================================

/** Le client courant (identifié par prénom via une session anonyme Supabase). */
create or replace function public.my_customer_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select id from public.customers where auth_user_id = auth.uid();
$$;

/** L'utilisateur courant fait-il partie de l'équipe du lieu ? */
create or replace function public.is_staff(p_venue uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.venues v where v.id = p_venue and v.owner_id = auth.uid()
  ) or exists (
    select 1 from public.staff_members s where s.venue_id = p_venue and s.user_id = auth.uid()
  );
$$;

/** Idem, à partir d'un événement. */
create or replace function public.is_event_staff(p_event uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.events e where e.id = p_event and public.is_staff(e.venue_id)
  );
$$;

/** Code de retrait court, lisible à l'oral dans le bruit : 2 lettres + 2 chiffres. */
create or replace function public.gen_pickup_code()
returns text
language sql volatile
as $$
  select substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1)
      || substr('ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 24)::int, 1)
      || lpad(floor(random() * 100)::text, 2, '0');
$$;

-- ---------------------------------------------------------------------------
--  Inscription / mise à jour du client après identification.
--  Appelée par le front juste après signInAnonymously() : auth.uid() est déjà
--  le client, il n'y a rien d'autre à vérifier.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_me(p_first_name text)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row public.customers;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.customers (auth_user_id, first_name)
  values (auth.uid(), nullif(trim(p_first_name), ''))
  on conflict (auth_user_id) do update
    set first_name   = coalesce(excluded.first_name, public.customers.first_name),
        last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  Enregistrement d'un scan : marque la présence sur l'événement.
-- ---------------------------------------------------------------------------
create or replace function public.register_scan(p_scan_point uuid, p_group_size int default 1)
returns public.attendances
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_event uuid;
  v_cust  uuid := public.my_customer_id();
  v_row   public.attendances;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  select event_id into v_event from public.scan_points where id = p_scan_point;
  if v_event is null then raise exception 'unknown_scan_point'; end if;

  insert into public.attendances (event_id, customer_id, scan_point_id, group_size)
  values (v_event, v_cust, p_scan_point, greatest(1, coalesce(p_group_size, 1)))
  on conflict (event_id, customer_id) do update
    set last_scan_at = now(),
        scan_point_id = excluded.scan_point_id,
        group_size = greatest(public.attendances.group_size, excluded.group_size)
  returning * into v_row;

  update public.customers set last_seen_at = now() where id = v_cust;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  DISCIPLINE DE LA FILE (feuille de route §06)
--  · tant qu'une commande est en préparation (RECEIVED), on peut cumuler
--  · dès qu'une commande passe à READY, toute nouvelle commande est bloquée
--    jusqu'à son retrait au bar
-- ---------------------------------------------------------------------------
create or replace function public.can_order(p_event uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select not exists (
    select 1 from public.orders o
    where o.event_id = p_event
      and o.customer_id = public.my_customer_id()
      and o.status = 'READY'
  );
$$;

-- ---------------------------------------------------------------------------
--  PASSAGE DE COMMANDE
--  Les prix sont recalculés côté serveur depuis products : le client ne peut
--  pas les forger. Renvoie la commande créée.
--
--  p_items : [{ "product_id": uuid, "quantity": int, "variant_id": text,
--               "options": [{"id":..,"name":..,"price":..}] }]
-- ---------------------------------------------------------------------------
create or replace function public.place_order(
  p_event      uuid,
  p_scan_point uuid,
  p_items      jsonb,
  p_note       text default null,
  p_promo      text default null
)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust     uuid := public.my_customer_id();
  v_order    public.orders;
  v_item     jsonb;
  v_prod     public.products;
  v_qty      int;
  v_unit     numeric(10,2);
  v_variant  jsonb;
  v_vlabel   text;
  v_opt      jsonb;
  v_subtotal numeric(10,2) := 0;
  v_discount numeric(10,2) := 0;
  v_promo    public.promo_codes;
  v_prep     int;
  v_code     text;
  v_tries    int := 0;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  if not exists (select 1 from public.events e
                 where e.id = p_event and e.is_active and e.accept_orders) then
    raise exception 'orders_closed';
  end if;

  if not public.can_order(p_event) then
    raise exception 'pickup_pending';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart';
  end if;

  select default_prep_min into v_prep from public.events where id = p_event;

  -- Code de retrait unique sur l'événement
  loop
    v_code := public.gen_pickup_code();
    exit when not exists (
      select 1 from public.orders where event_id = p_event and pickup_code = v_code
    );
    v_tries := v_tries + 1;
    if v_tries > 40 then
      v_code := v_code || floor(random() * 10)::text;
      exit;
    end if;
  end loop;

  insert into public.orders (event_id, customer_id, scan_point_id, pickup_code, status,
                             note, estimated_ready_at)
  values (p_event, v_cust, p_scan_point, v_code, 'RECEIVED',
          nullif(trim(p_note), ''), now() + make_interval(mins => coalesce(v_prep, 1)))
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_prod from public.products
      where id = (v_item ->> 'product_id')::uuid and is_listed and not sold_out;
    if v_prod.id is null then raise exception 'product_unavailable'; end if;

    v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

    -- Format (12cl / 75cl / 150cl…) : prix pris dans le variant si fourni
    v_unit := v_prod.price;
    v_vlabel := null;
    if jsonb_array_length(coalesce(v_prod.variants, '[]'::jsonb)) > 0 then
      select value into v_variant
        from jsonb_array_elements(v_prod.variants)
        where value ->> 'id' = coalesce(v_item ->> 'variant_id', '')
        limit 1;
      if v_variant is null then raise exception 'variant_required'; end if;
      v_unit := (v_variant ->> 'price')::numeric;
      v_vlabel := v_variant ->> 'label';
    end if;

    -- Options : le prix est relu dans option_groups, jamais pris du client
    if v_item ? 'options' then
      for v_opt in select * from jsonb_array_elements(v_item -> 'options') loop
        v_unit := v_unit + coalesce((
          select (o ->> 'price')::numeric
          from jsonb_array_elements(v_prod.option_groups) g,
               jsonb_array_elements(g -> 'options') o
          where o ->> 'id' = v_opt ->> 'id'
          limit 1
        ), 0);
      end loop;
    end if;

    insert into public.order_items (order_id, product_id, name_snapshot, variant_label,
                                    unit_price, vat_rate, quantity, detail)
    values (v_order.id, v_prod.id, v_prod.name, v_vlabel, v_unit, v_prod.vat_rate, v_qty,
            jsonb_build_object('options', coalesce(v_item -> 'options', '[]'::jsonb)));

    v_subtotal := v_subtotal + v_unit * v_qty;
  end loop;

  -- Code promo (conditions horaire / montant vérifiées côté serveur)
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  update public.orders
     set subtotal = v_subtotal,
         discount = v_discount,
         total = greatest(0, v_subtotal - v_discount),
         promo_code = case when v_discount > 0 then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

grant execute on function public.is_staff(uuid)                        to authenticated;
grant execute on function public.is_event_staff(uuid)                  to authenticated;
grant execute on function public.upsert_me(text)                       to authenticated;
grant execute on function public.register_scan(uuid, int)              to authenticated;
grant execute on function public.can_order(uuid)                       to authenticated;
grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;
grant execute on function public.my_customer_id()                      to authenticated;

-- ============================================================================
--  TRIGGERS
-- ============================================================================

/** Horodatage automatique des transitions de statut + stats CRM. */
create or replace function public.touch_order_status()
returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'READY'     and new.ready_at     is null then new.ready_at := now(); end if;
    if new.status = 'PICKED_UP' and new.picked_up_at is null then new.picked_up_at := now(); end if;
    if new.status = 'PAID'      and new.paid_at      is null then new.paid_at := now(); end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_status on public.orders;
create trigger trg_orders_status
  before update on public.orders
  for each row execute function public.touch_order_status();

/** Alimente le CRM : compteurs, dépense, incident d'impayé. */
create or replace function public.sync_customer_stats()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'PAID' and old.status is distinct from 'PAID' then
    update public.customers
       set orders_count = orders_count + 1,
           total_spent  = total_spent + new.total,
           last_seen_at = now()
     where id = new.customer_id;

    -- Tag automatique « gros panier » au-delà de 150 € cumulés
    update public.customers
       set tags = array_append(tags, 'gros_panier')
     where id = new.customer_id
       and total_spent >= 150
       and not ('gros_panier' = any (tags));

  elsif new.status = 'UNPAID' and old.status is distinct from 'UNPAID' then
    update public.customers
       set unpaid_count = unpaid_count + 1,
           tags = case when 'incident' = any (tags) then tags else array_append(tags, 'incident') end
     where id = new.customer_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_stats on public.orders;
create trigger trg_orders_stats
  after update on public.orders
  for each row execute function public.sync_customer_stats();

/** Compte les événements distincts fréquentés (reconnaissance « déjà venu »). */
create or replace function public.sync_events_count()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.customers
     set events_count = (select count(distinct event_id) from public.attendances
                          where customer_id = new.customer_id),
         tags = case
                  when (select count(distinct event_id) from public.attendances
                         where customer_id = new.customer_id) >= 2
                       and not ('habitue' = any (tags))
                  then array_append(tags, 'habitue')
                  else tags
                end
   where id = new.customer_id;
  return new;
end;
$$;

drop trigger if exists trg_attendance_count on public.attendances;
create trigger trg_attendance_count
  after insert on public.attendances
  for each row execute function public.sync_events_count();

/** Le créateur d'un lieu en est automatiquement membre du staff. */
create or replace function public.venue_owner_is_staff()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_members (venue_id, user_id, role)
  values (new.id, new.owner_id, 'owner')
  on conflict (venue_id, user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_venue_staff on public.venues;
create trigger trg_venue_staff
  after insert on public.venues
  for each row execute function public.venue_owner_is_staff();

-- ============================================================================
--  0002_rls.sql
-- ============================================================================
-- ============================================================================
--  NOTI Calling — 0002_rls.sql
--
--  Le client est authentifié par OTP SMS (Supabase Phone Auth) : il porte un
--  vrai JWT. On peut donc écrire des policies strictes — chacun ne voit que ses
--  propres commandes, le staff voit celles de ses événements. Rien n'est ouvert
--  « en lecture publique » à part la vitrine (événement, points de scan, carte).
--
--  Les commandes ne sont JAMAIS insérées directement : elles passent par la
--  fonction place_order() (security definer), qui recalcule les prix côté
--  serveur et applique la discipline de file. Aucune policy d'insert n'existe
--  sur orders / order_items — c'est volontaire.
-- ============================================================================

alter table public.venues             enable row level security;
alter table public.staff_members      enable row level security;
alter table public.events             enable row level security;
alter table public.scan_points        enable row level security;
alter table public.products           enable row level security;
alter table public.customers          enable row level security;
alter table public.attendances        enable row level security;
alter table public.orders             enable row level security;
alter table public.order_items        enable row level security;
alter table public.messages           enable row level security;
alter table public.reviews            enable row level security;
alter table public.promo_codes        enable row level security;
alter table public.push_subscriptions enable row level security;

-- ------------------------------------------------------------------- VENUES
drop policy if exists venues_read on public.venues;
create policy venues_read on public.venues
  for select to anon, authenticated using (true);

drop policy if exists venues_insert on public.venues;
create policy venues_insert on public.venues
  for insert to authenticated with check (owner_id = auth.uid());

drop policy if exists venues_write on public.venues;
create policy venues_write on public.venues
  for update to authenticated
  using (public.is_staff(id)) with check (public.is_staff(id));

drop policy if exists venues_delete on public.venues;
create policy venues_delete on public.venues
  for delete to authenticated using (owner_id = auth.uid());

-- ------------------------------------------------------------ STAFF MEMBERS
drop policy if exists staff_read on public.staff_members;
create policy staff_read on public.staff_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_staff(venue_id));

drop policy if exists staff_write on public.staff_members;
create policy staff_write on public.staff_members
  for all to authenticated
  using (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()));

-- ------------------------------------------------------------------ EVENTS
-- Lecture publique : l'écran d'accueil du QR s'affiche avant identification.
drop policy if exists events_read on public.events;
create policy events_read on public.events
  for select to anon, authenticated using (true);

drop policy if exists events_write on public.events;
create policy events_write on public.events
  for all to authenticated
  using (public.is_staff(venue_id)) with check (public.is_staff(venue_id));

-- ------------------------------------------------------------- SCAN POINTS
drop policy if exists scan_points_read on public.scan_points;
create policy scan_points_read on public.scan_points
  for select to anon, authenticated using (true);

drop policy if exists scan_points_write on public.scan_points;
create policy scan_points_write on public.scan_points
  for all to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- ---------------------------------------------------------------- PRODUITS
drop policy if exists products_read on public.products;
create policy products_read on public.products
  for select to anon, authenticated using (true);

drop policy if exists products_write on public.products;
create policy products_write on public.products
  for all to authenticated
  using (public.is_staff(venue_id)) with check (public.is_staff(venue_id));

-- ---------------------------------------------------------------- CLIENTS
-- Chacun voit sa fiche. Le staff voit les clients présents sur SES événements.
drop policy if exists customers_self on public.customers;
create policy customers_self on public.customers
  for select to authenticated
  using (
    auth_user_id = auth.uid()
    or exists (
      select 1 from public.attendances a
      join public.events e on e.id = a.event_id
      where a.customer_id = customers.id and public.is_staff(e.venue_id)
    )
  );

drop policy if exists customers_self_update on public.customers;
create policy customers_self_update on public.customers
  for update to authenticated
  using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());

-- Le staff peut taguer / annoter un client de ses événements (CRM).
drop policy if exists customers_staff_update on public.customers;
create policy customers_staff_update on public.customers
  for update to authenticated
  using (
    exists (
      select 1 from public.attendances a
      join public.events e on e.id = a.event_id
      where a.customer_id = customers.id and public.is_staff(e.venue_id)
    )
  )
  with check (true);

-- -------------------------------------------------------------- PRÉSENCES
drop policy if exists attendances_read on public.attendances;
create policy attendances_read on public.attendances
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

drop policy if exists attendances_staff on public.attendances;
create policy attendances_staff on public.attendances
  for update to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- -------------------------------------------------------------- COMMANDES
-- Pas de policy INSERT : la création passe exclusivement par place_order().
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

drop policy if exists orders_staff_update on public.orders;
create policy orders_staff_update on public.orders
  for update to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

drop policy if exists orders_staff_delete on public.orders;
create policy orders_staff_delete on public.orders
  for delete to authenticated using (public.is_event_staff(event_id));

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items
  for select to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_items.order_id
        and (o.customer_id = public.my_customer_id() or public.is_event_staff(o.event_id))
    )
  );

drop policy if exists order_items_staff on public.order_items;
create policy order_items_staff on public.order_items
  for all to authenticated
  using (exists (select 1 from public.orders o
                 where o.id = order_items.order_id and public.is_event_staff(o.event_id)))
  with check (exists (select 1 from public.orders o
                      where o.id = order_items.order_id and public.is_event_staff(o.event_id)));

-- -------------------------------------------------------------- MESSAGES
-- Le client lit les diffusions de l'événement + les messages qui lui sont adressés.
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
  for select to authenticated
  using (
    public.is_event_staff(event_id)
    or customer_id = public.my_customer_id()
    or (
      customer_id is null
      and exists (
        select 1 from public.attendances a
        where a.event_id = messages.event_id and a.customer_id = public.my_customer_id()
      )
    )
  );

drop policy if exists messages_staff_write on public.messages;
create policy messages_staff_write on public.messages
  for all to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- Le client peut marquer un message comme lu.
drop policy if exists messages_mark_read on public.messages;
create policy messages_mark_read on public.messages
  for update to authenticated
  using (customer_id = public.my_customer_id())
  with check (customer_id = public.my_customer_id());

-- ------------------------------------------------------------------- AVIS
drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews
  for insert to authenticated
  with check (customer_id = public.my_customer_id());

drop policy if exists reviews_read on public.reviews;
create policy reviews_read on public.reviews
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- ------------------------------------------------------------- CODES PROMO
-- AUCUNE lecture publique : les codes ne doivent pas être énumérables.
-- La validation se fait dans place_order() côté serveur.
drop policy if exists promo_staff on public.promo_codes;
create policy promo_staff on public.promo_codes
  for all to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- ------------------------------------------------------------------- PUSH
drop policy if exists push_insert on public.push_subscriptions;
create policy push_insert on public.push_subscriptions
  for insert to authenticated with check (true);

drop policy if exists push_read on public.push_subscriptions;
create policy push_read on public.push_subscriptions
  for select to authenticated
  using (
    customer_id = public.my_customer_id()
    or (venue_id is not null and public.is_staff(venue_id))
  );

drop policy if exists push_delete on public.push_subscriptions;
create policy push_delete on public.push_subscriptions
  for delete to authenticated
  using (
    customer_id = public.my_customer_id()
    or (venue_id is not null and public.is_staff(venue_id))
  );

-- ============================================================================
--  0003_realtime_reporting.sql
-- ============================================================================
-- ============================================================================
--  NOTI Calling — 0003_realtime_reporting.sql
--  Temps réel (WebSocket, pas de polling — cf. feuille de route §14) + vues de
--  pilotage et de reporting post-événement.
-- ============================================================================

-- ----------------------------------------------------------------- REALTIME
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

alter table public.orders      replica identity full;
alter table public.order_items replica identity full;
alter table public.messages    replica identity full;
alter table public.attendances replica identity full;

do $$
begin
  begin alter publication supabase_realtime add table public.orders;      exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.order_items; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.messages;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.attendances; exception when duplicate_object then null; end;
end $$;

-- ------------------------------------------------------- LEADERBOARD TEMPS RÉEL
-- « Qui commande le plus, panier cumulé » (§08). security_invoker : la RLS des
-- tables sous-jacentes s'applique, donc seul le staff de l'événement voit tout.
create or replace view public.v_event_leaderboard
with (security_invoker = true) as
select
  o.event_id,
  c.id                     as customer_id,
  c.first_name,
  c.last_name,
  c.tags,
  count(*)                 as orders_count,
  sum(o.total)             as total_spent,
  max(o.created_at)        as last_order_at
from public.orders o
join public.customers c on c.id = o.customer_id
where o.status <> 'CANCELLED'
group by o.event_id, c.id, c.first_name, c.last_name, c.tags;

-- ------------------------------------------------------------ VUE DE PILOTAGE
create or replace view public.v_event_live
with (security_invoker = true) as
select
  e.id as event_id,
  (select count(*) from public.attendances a where a.event_id = e.id)              as present_count,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status = 'RECEIVED')                              as in_preparation,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status = 'READY')                                 as awaiting_pickup,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status in ('PICKED_UP', 'UNPAID'))                as awaiting_payment,
  (select coalesce(sum(o.total), 0) from public.orders o
    where o.event_id = e.id and o.status = 'PAID')                                  as revenue_paid,
  (select coalesce(sum(o.total), 0) from public.orders o
    where o.event_id = e.id and o.status in ('PICKED_UP', 'UNPAID'))                as revenue_pending,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status = 'UNPAID')                                as unpaid_count
from public.events e;

grant select on public.v_event_leaderboard to authenticated;
grant select on public.v_event_live        to authenticated;

-- ------------------------------------------------- REPORTING POST-ÉVÉNEMENT
-- Fiche exportable : panier moyen, top produits, pic horaire, nouveaux vs
-- récurrents, volume, chiffre estimé (§08).
create or replace function public.event_report(p_event uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_event_staff(p_event) then
    raise exception 'forbidden';
  end if;

  select jsonb_build_object(
    'event', (select jsonb_build_object('id', e.id, 'name', e.name,
                                        'starts_at', e.starts_at, 'closes_at', e.closes_at)
              from public.events e where e.id = p_event),

    'orders_total',   (select count(*) from public.orders o
                        where o.event_id = p_event and o.status <> 'CANCELLED'),
    'revenue_paid',   (select coalesce(sum(total), 0) from public.orders
                        where event_id = p_event and status = 'PAID'),
    'revenue_unpaid', (select coalesce(sum(total), 0) from public.orders
                        where event_id = p_event and status = 'UNPAID'),
    'average_basket', (select round(coalesce(avg(total), 0), 2) from public.orders
                        where event_id = p_event and status <> 'CANCELLED'),

    'attendees',      (select count(*) from public.attendances where event_id = p_event),
    'headcount',      (select coalesce(sum(group_size), 0) from public.attendances
                        where event_id = p_event),

    'new_customers',  (select count(*) from public.attendances a
                        join public.customers c on c.id = a.customer_id
                        where a.event_id = p_event and c.events_count <= 1),
    'returning_customers', (select count(*) from public.attendances a
                        join public.customers c on c.id = a.customer_id
                        where a.event_id = p_event and c.events_count > 1),

    'top_products',   (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                        select oi.name_snapshot as name,
                               sum(oi.quantity)::int as qty,
                               round(sum(oi.unit_price * oi.quantity), 2) as revenue
                        from public.order_items oi
                        join public.orders o on o.id = oi.order_id
                        where o.event_id = p_event and o.status <> 'CANCELLED'
                        group by oi.name_snapshot
                        order by qty desc
                        limit 15) t),

    'hourly',         (select coalesce(jsonb_agg(h order by h.hour), '[]'::jsonb) from (
                        select to_char(date_trunc('hour', o.created_at), 'HH24:00') as hour,
                               count(*)::int as orders,
                               round(sum(o.total), 2) as revenue
                        from public.orders o
                        where o.event_id = p_event and o.status <> 'CANCELLED'
                        group by date_trunc('hour', o.created_at)) h),

    'rating_avg',     (select round(avg(rating)::numeric, 2) from public.reviews
                        where event_id = p_event),
    'rating_count',   (select count(*) from public.reviews where event_id = p_event)
  ) into v;

  return v;
end;
$$;

grant execute on function public.event_report(uuid) to authenticated;

-- ----------------------------------------------- CLÔTURE : MARQUER LES IMPAYÉS
-- En fin de soirée, tout ce qui a été retiré sans être réglé devient « impayé »
-- et reste dû (traçabilité rattachée à l'identité vérifiée).
create or replace function public.close_event(p_event uuid)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not public.is_event_staff(p_event) then raise exception 'forbidden'; end if;

  update public.orders
     set status = 'UNPAID'
   where event_id = p_event
     and status in ('RECEIVED', 'READY', 'PICKED_UP');
  get diagnostics n = row_count;

  update public.events set accept_orders = false, is_active = false where id = p_event;
  return n;
end;
$$;

grant execute on function public.close_event(uuid) to authenticated;

-- ============================================================================
--  0004_storage.sql
-- ============================================================================
-- ============================================================================
--  NOTI Calling — 0004_storage.sql
--  Bucket public « noti » : logos de lieu + visuels produits.
--  Convention de chemin : {venue_id}/products/xxx.jpg — le premier segment
--  contrôle qui a le droit d'écrire.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'noti', 'noti', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists noti_read on storage.objects;
create policy noti_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'noti');

drop policy if exists noti_insert on storage.objects;
create policy noti_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists noti_update on storage.objects;
create policy noti_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );

drop policy if exists noti_delete on storage.objects;
create policy noti_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'noti'
    and public.is_staff(nullif(split_part(name, '/', 1), '')::uuid)
  );

-- ============================================================================
--  0005_seed_noti_menu.sql
-- ============================================================================
-- ============================================================================
--  NOTI Calling — 0005_seed_noti_menu.sql
--  Carte du NOTI CLUB, saisie depuis les cartes fournies (Drinks & Cocktails,
--  Spirits, Commandes de bouteilles).
--
--  Répartition dans les 3 univers de la feuille de route (§04) :
--   · drinks  = tout ce qui se sert au verre (spritz, cocktails, vins au verre,
--               bières, softs, spiritueux à la dose, digestifs, apéritifs)
--   · bottles = service bouteille de la soirée Noti Calling (vins 75/150 cl,
--               champagnes, bouteilles de spiritueux)
--   · food    = à compléter (tapas / planches) — aucune donnée fournie à ce jour
--
--  NOTE PRIX : les deux cartes fournies divergent sur les vins (Minuty 12 cl à
--  8 € sur la carte bar, 10 € sur la carte Noti Calling ; 75 cl à 39 € vs 50 €).
--  Retenu ici : prix « carte bar » au verre, prix « Noti Calling » à la
--  bouteille. À arbitrer avec l'établissement avant la première soirée.
--
--  Usage : select public.seed_noti_menu('<venue_id>');
-- ============================================================================

-- Rejouable à volonté (bouton « Recharger la carte Noti Club » côté app) : les
-- articles déjà présents sont mis à jour (prix, description, variantes...) au
-- lieu d'être dupliqués. Le statut « épuisé » / « retiré », lui, appartient au
-- staff et n'est jamais écrasé par un rechargement.
create unique index if not exists products_venue_universe_name_uniq
  on public.products (venue_id, universe, name);

create or replace function public.seed_noti_menu(p_venue uuid)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  n int;
begin
  if not public.is_staff(p_venue) then
    raise exception 'forbidden';
  end if;

  insert into public.products
    (venue_id, universe, subcategory, name, description, price, is_popular,
     is_alcohol, vat_rate, sort_order, variants)
  values
  -- ------------------------------------------------------------ BAR À SPRITZ (4 cl)
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',11,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',12,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',12,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',13,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',9,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',12,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',12,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','IGP Méditerranée — Ponton 7 2024','Rosé · 12 cl',6,false,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',8,true,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24','Blanc · 12 cl',6,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',8,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',6,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',8,false,true,20,6,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',11,false,true,20,7,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',16,true,true,20,8,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',6,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',8,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',8,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',7,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',7,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',6,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',6,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',6,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',6,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',6,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',6,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',6,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',6,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',7,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,13,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,18,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,20,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,13,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,15,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,17,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,18,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,19,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,20,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,13,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,16,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,22,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,24,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,16,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,25,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,27,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,35,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,13,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,20,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,12,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,12,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,12,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,12,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,12,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,12,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,13,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,15,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,15,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,18,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,7,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,7,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,7,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,7,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,7,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,7,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (service Noti Calling) =============
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50},{"id":"150cl","label":"Magnum 150 cl","price":90}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire',42,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":42}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais',42,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":42}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',60,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":60}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',160,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',180,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',180,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',180,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',180,false,true,20,5,'[]')
  on conflict (venue_id, universe, name) do update
    set subcategory = excluded.subcategory,
        description = excluded.description,
        price       = excluded.price,
        is_popular  = excluded.is_popular,
        is_alcohol  = excluded.is_alcohol,
        vat_rate    = excluded.vat_rate,
        sort_order  = excluded.sort_order,
        variants    = excluded.variants;

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;


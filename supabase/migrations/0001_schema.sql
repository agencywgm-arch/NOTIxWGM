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
    'IN_PREP',    -- en préparation au bar/cuisine
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
--  le client, il n'y a rien d'autre à vérifier. Prénom, nom et e-mail sont
--  obligatoires : c'est la fiche exploitée ensuite par le staff/CRM.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_me(p_first_name text, p_last_name text, p_email text)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row public.customers;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'missing_profile';
  end if;
  if p_email is null or trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  insert into public.customers (auth_user_id, first_name, last_name, email)
  values (auth.uid(), trim(p_first_name), trim(p_last_name), lower(trim(p_email)))
  on conflict (auth_user_id) do update
    set first_name   = excluded.first_name,
        last_name    = excluded.last_name,
        email        = excluded.email,
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
grant execute on function public.upsert_me(text, text, text)           to authenticated;
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

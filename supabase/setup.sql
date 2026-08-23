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
     and status in ('RECEIVED', 'IN_PREP', 'READY', 'PICKED_UP');
  get diagnostics n = row_count;

  update public.events set accept_orders = false, is_active = false where id = p_event;
  return n;
end;
$$;

grant execute on function public.close_event(uuid) to authenticated;


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
--  NOTI Calling — 0005_seed_noti_menu.sql
--  Carte du NOTI CLUB — RENTRÉE 2026.
--
--  Répartition dans les 3 univers de la feuille de route (§04) :
--   · drinks  = tout ce qui se sert au verre (spritz, cocktails, vins au verre,
--               bières, softs, spiritueux à la dose, digestifs, apéritifs)
--   · bottles = Commandes de bouteilles (service à table / entrée groupe) :
--               vins 75 cl (alignés 50 €), champagnes, bouteilles de spiritueux
--   · food    = non géré ici (saisi et maintenu à la main côté staff, carte
--               inchangée à la rentrée 2026 — aucune donnée à rejouer)
--
--  Logique de rentrée 2026 :
--   · Au bar (au verre + bouteilles au bar) : +15 % arrondi à l'euro supérieur.
--   · Tous les anciens items à 7 € → 10 € (Red Bull, détox, apéritifs).
--   · Commandes de bouteilles : prix fixes, vins alignés à 50 €.
--   · Rosé Chardonnay/Ecoterra et rosé Ponton 7 retirés de la carte des vins
--     au verre (delistés ci-dessous, jamais supprimés — historique conservé).
--
--  Usage : select public.seed_noti_menu('<venue_id>');
-- ============================================================================

-- Rejouable à volonté (bouton « Recharger la carte Noti Club » côté app) : les
-- articles déjà présents sont mis à jour (prix, description, variantes...) au
-- lieu d'être dupliqués. Le statut « épuisé » / « retiré », lui, appartient au
-- staff et n'est jamais écrasé par un rechargement — sauf action explicite de
-- delistage ci-dessous, pour les deux vins qui sortent de la carte 2026.
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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
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

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  -- Étiquetage des articles éligibles aux forfaits à crédits (cf. 0013).
  perform public.tag_credit_menu(p_venue);

  -- Illustration par article (cf. 0017).
  perform public.tag_product_illustrations(p_venue);

  -- Carte food (plats + illustrations, cf. 0019).
  perform public.seed_noti_food(p_venue);

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;


-- ============================================================================
--  NOTI Calling — 0008_promo_preview.sql
--
--  Jusqu'ici, un code promo invalide était silencieusement ignoré par
--  place_order() (comportement volontaire pour ne jamais bloquer une
--  commande) — mais côté client, rien n'indiquait si le code avait
--  fonctionné ou pas : le total affiché au checkout ne bougeait jamais.
--
--  Cette fonction permet au client de VÉRIFIER un code avant de commander,
--  sans exposer la table (toujours aucune lecture publique sur promo_codes,
--  cf. 0002_rls.sql) : elle ne renvoie que le résultat du calcul pour LE
--  code fourni, jamais la liste. C'est un aperçu, la source de vérité reste
--  place_order() qui revalide tout côté serveur à la commande.
-- ============================================================================

create or replace function public.preview_promo(p_event uuid, p_code text, p_subtotal numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo    public.promo_codes;
  v_discount numeric(10,2) := 0;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses)
      and min_total <= coalesce(p_subtotal, 0);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  v_discount := least(
    case when v_promo.kind = 'amount' then v_promo.value
         else round(coalesce(p_subtotal, 0) * v_promo.value / 100, 2) end,
    coalesce(p_subtotal, 0));

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'discount', v_discount
  );
end;
$$;

grant execute on function public.preview_promo(uuid, text, numeric) to authenticated;


-- ============================================================================
--  NOTI Calling — 0012_menu_rentree_2026.sql
--  Mise à jour de la carte Noti Club — RENTRÉE 2026 (patch, installs existantes).
--
--  Remplace seed_noti_menu() par la version « Rentrée 2026 » :
--   · Au bar (au verre + bouteilles au bar) : +15 % arrondi à l'euro supérieur.
--   · Tous les anciens items à 7 € → 10 € (Red Bull, détox, apéritifs).
--   · Commandes de bouteilles : prix fixes, vins alignés à 50 €.
--   · Food : inchangé (non géré par cette fonction).
--   · Rosé Chardonnay/Ecoterra et rosé Ponton 7 retirés de la carte (delistés,
--     pas supprimés — l'historique des commandes déjà passées est préservé).
--
--  Un nouvel environnement qui repart de zéro n'en a pas besoin : le fichier
--  0005_seed_noti_menu.sql à jour contient directement cette version.
--
--  Après avoir collé ce bloc : rouvrez l'onglet Carte côté app et cliquez sur
--  « 🍸 Carte Noti Club » pour appliquer les nouveaux prix aux articles déjà
--  en base (le rechargement met à jour, il ne duplique pas).
-- ============================================================================

-- Rejouable à volonté (bouton « Recharger la carte Noti Club » côté app) : les
-- articles déjà présents sont mis à jour (prix, description, variantes...) au
-- lieu d'être dupliqués. Le statut « épuisé » / « retiré », lui, appartient au
-- staff et n'est jamais écrasé par un rechargement — sauf action explicite de
-- delistage ci-dessous, pour les deux vins qui sortent de la carte 2026.
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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
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

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;


-- ============================================================================
--  NOTI Calling — 0013_forfaits_credits.sql
--  Forfaits Groupes Noti : pass à crédits (entrée + conso) vendu hors app
--  (lien de paiement en amont), activé par le client via un code dédié.
--
--  Modèle retenu : 1 alcool éligible = 2 crédits, 1 soft = 1 crédit (donc
--  1 alcool = 2 softs). Le jeton food vaut, s'il est converti, 2 crédits
--  fongibles (1 alcool OU 2 softs au choix du client) — pas besoin de suivre
--  « en quoi » il a été converti, juste d'ajouter 2 crédits au portefeuille.
--
--  · promo_codes.kind = 'credits' : nouveau type de code, en plus de
--    percent/amount. credits_per_person / food_tokens_per_person sont
--    crédités à CHAQUE personne qui active le code (max_uses = nombre de
--    personnes du groupe, chacune consommant 1 utilisation).
--  · event_passes : le portefeuille d'un client pour une soirée donnée —
--    un seul par (event, customer), jamais recrédité si déjà activé (donc
--    sans risque même si le client se réidentifie à chaque scan).
--  · products.credit_kind ('alcohol' | 'soft' | null) + credit_once (le
--    verre de Champagne Richard Brut, plafonné à 1 par forfait) déterminent
--    l'éligibilité, étiquetée automatiquement par seed_noti_menu().
--  · place_order() consomme le portefeuille en plus du code promo classique
--    (les deux sont cumulables, mais un forfait n'a normalement pas de code
--    promo à côté).
--
--  Fenêtres horaires (Europe/Paris) :
--   · conversion manuelle du jeton food → crédits : jusqu'à 22h00.
--   · arrivée après 22h30 (activation du pass) : jeton food auto-converti.
-- ============================================================================

alter table public.products
  add column if not exists credit_kind text,   -- 'alcohol' | 'soft' | null (non éligible)
  add column if not exists credit_once boolean not null default false; -- ex. 1 verre Richard

alter table public.promo_codes
  add column if not exists credits_per_person int not null default 0,
  add column if not exists food_tokens_per_person int not null default 0;

-- ----------------------------------------------------------- PORTEFEUILLE
create table if not exists public.event_passes (
  id                    uuid primary key default gen_random_uuid(),
  event_id              uuid not null references public.events (id) on delete cascade,
  customer_id           uuid not null references public.customers (id) on delete cascade,
  promo_code_id         uuid references public.promo_codes (id) on delete set null,
  credits_total         int not null default 0,
  credits_remaining     int not null default 0,
  food_token_total      int not null default 0,
  food_token_available  boolean not null default false,
  richard_used          boolean not null default false,
  created_at            timestamptz not null default now(),
  unique (event_id, customer_id)
);

alter table public.event_passes enable row level security;

drop policy if exists event_passes_select on public.event_passes;
create policy event_passes_select on public.event_passes for select
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- ---------------------------------------------------------------------------
--  Activation du forfait : idempotente (un seul pass par personne et par
--  soirée). Un second appel — inévitable puisque le client se réidentifie à
--  chaque scan — renvoie simplement le pass déjà actif, sans recréditer.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_pass  public.event_passes;
  v_now_paris time;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is not null then
    return v_pass;
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind = 'credits'
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses);
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

  v_now_paris := (now() at time zone 'Europe/Paris')::time;

  insert into public.event_passes
    (event_id, customer_id, promo_code_id, credits_total, credits_remaining,
     food_token_total, food_token_available)
  values (
    p_event, v_cust, v_promo.id,
    v_promo.credits_per_person, v_promo.credits_per_person,
    v_promo.food_tokens_per_person,
    v_promo.food_tokens_per_person > 0 and v_now_paris < time '22:30:00'
  )
  returning * into v_pass;

  -- Arrivée après 22h30 : le jeton food est automatiquement converti en
  -- crédits (2 crédits/jeton — cf. note de modèle en tête de fichier).
  if v_promo.food_tokens_per_person > 0 and v_now_paris >= time '22:30:00' then
    update public.event_passes
       set credits_total     = credits_total + v_promo.food_tokens_per_person * 2,
           credits_remaining = credits_remaining + v_promo.food_tokens_per_person * 2
     where id = v_pass.id
     returning * into v_pass;
  end if;

  update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;

  return v_pass;
end;
$$;

-- ---------------------------------------------------------------------------
--  Conversion manuelle du jeton food (avant 22h00) : +2 crédits fongibles,
--  dépensables ensuite en 1 alcool éligible ou 2 softs au choix du client.
-- ---------------------------------------------------------------------------
create or replace function public.convert_food_token(p_event uuid)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_pass public.event_passes;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if (now() at time zone 'Europe/Paris')::time >= time '22:00:00' then
    raise exception 'conversion_closed';
  end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is null then raise exception 'no_pass'; end if;
  if not v_pass.food_token_available then raise exception 'no_food_token'; end if;

  update public.event_passes
     set food_token_available = false,
         credits_total     = credits_total + 2,
         credits_remaining = credits_remaining + 2
   where id = v_pass.id
   returning * into v_pass;

  return v_pass;
end;
$$;

-- ---------------------------------------------------------------------------
--  place_order() — même signature qu'en 0001, remplacée pour consommer le
--  portefeuille forfait en plus du code promo classique (les deux sont
--  cumulables). Le prix catalogue reste affiché sur le ticket (unit_price
--  inchangé) : seule la remise finale absorbe la part couverte par le pass.
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
  v_pass         public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
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
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;

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

    -- ---- Forfait Noti : consommation du portefeuille (crédits / jeton food) ----
    if v_pass.id is not null then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining >= v_wallet_cost then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_qty, v_pass.credits_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable avec le forfait
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := v_discount + least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  if v_pass.id is not null then
    update public.event_passes
       set credits_remaining    = v_pass.credits_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.orders
     set subtotal = v_subtotal,
         discount = v_discount,
         total = greatest(0, v_subtotal - v_discount),
         promo_code = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

-- ---------------------------------------------------------------------------
--  Étiquetage crédits sur la carte Noti Club — rejoué à chaque appel de
--  seed_noti_menu(), donc appliqué aussi bien à un venue neuf qu'à un venue
--  existant qui clique sur « Recharger la carte Noti Club ».
--  Helper interne uniquement : jamais exposée aux clients (pas de grant à
--  authenticated) — seed_noti_menu() a déjà vérifié is_staff() avant de
--  l'appeler, et la ligne de rattrapage en bas de fichier tourne dans le
--  SQL Editor (rôle postgres, sans auth.uid()) donc sans contexte staff.
-- ---------------------------------------------------------------------------
create or replace function public.tag_credit_menu(p_venue uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.products set credit_kind = 'soft', credit_once = false
   where venue_id = p_venue and universe = 'drinks' and is_alcohol = false;

  update public.products set credit_kind = 'alcohol', credit_once = false
   where venue_id = p_venue and universe = 'drinks' and (
     subcategory = 'Bar à spritz'
     or (subcategory = 'Cocktails' and name in ('Moscow Mule', 'Rive Gauche'))
     or (subcategory = 'Vins au verre' and name in (
           'Côtes de Provence AOP — Minuty Prestige 2024',
           'Pouilly-Fumé AOP — Domaine Minet',
           'Bordeaux AOP — James Deschartrons 2021/22',
           'Saint-Amour AOP — Domaine des Pierres 2023/24'))
     or subcategory = 'Bières'
     or (subcategory = 'Vodka' and name = 'Absolut')
     or (subcategory = 'Gin' and name = 'Tanqueray')
     or (subcategory = 'Rhum' and name = 'Havana 3 ans')
     or (subcategory = 'Whisky' and name = 'Monkey Shoulder')
   );

  -- 1 verre de Champagne Richard Brut offert, une fois par forfait (2 crédits)
  update public.products set credit_kind = 'alcohol', credit_once = true
   where venue_id = p_venue and universe = 'drinks'
     and subcategory = 'Vins au verre' and name = 'Champagne AOP Richard — Brut';
end;
$$;

-- ---------------------------------------------------------------------------
--  seed_noti_menu() — redéfinie ici pour appeler tag_credit_menu() en fin de
--  rechargement (bouton « Recharger la carte Noti Club » côté app), afin que
--  l'étiquetage crédits reste à jour sans intervention SQL manuelle.
--  Copie exacte de 0005/0012, seule la dernière ligne avant `return n;`
--  change. Installation neuve : 0005_seed_noti_menu.sql contient déjà cette
--  version, cette redéfinition est alors un simple no-op identique.
-- ---------------------------------------------------------------------------
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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
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

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  -- Étiquetage des articles éligibles aux forfaits à crédits (cf. 0013).
  perform public.tag_credit_menu(p_venue);

  return n;
end;
$$;

grant execute on function public.redeem_pass(uuid, text)     to authenticated;
grant execute on function public.convert_food_token(uuid)    to authenticated;
grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;
grant execute on function public.seed_noti_menu(uuid)         to authenticated;

-- Rétroactif, pour les venues déjà en activité (le prochain rechargement de
-- carte l'aurait fait de toute façon) :
do $$
declare v_venue record;
begin
  for v_venue in select id from public.venues loop
    perform public.tag_credit_menu(v_venue.id);
  end loop;
end $$;


-- ============================================================================
--  NOTI Calling — 0014_realtime_products.sql
--
--  Rupture de stock en temps réel (retour terrain, point 3.1).
--
--  Le staff pouvait déjà marquer un article « épuisé » depuis la tablette,
--  mais la table products n'était pas publiée en Realtime : côté client, la
--  carte ne se mettait à jour qu'au rechargement de la page. Un client
--  pouvait donc commander un article épuisé plusieurs minutes durant, et se
--  faire refuser la commande au moment de l'envoi (product_unavailable).
--
--  Avec ce patch, le basculement « épuisé » se propage instantanément à tous
--  les téléphones connectés : l'article reste visible mais devient
--  non commandable, sans que personne n'ait à recharger quoi que ce soit.
-- ============================================================================

alter table public.products replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.products;
  exception when duplicate_object then null;
  end;
end $$;


-- ============================================================================
--  NOTI Calling — 0015_profil_etendu.sql
--
--  Retour terrain : nom + prénom + e-mail ne suffisent pas pour le fichier
--  client attendu (relances, segmentation géographique/âge). Nouvelle règle :
--
--    OBLIGATOIRE  : prénom, nom, téléphone, code postal, date de naissance
--    OPTIONNEL    : e-mail, Instagram (complétables plus tard, « espace client »)
--
--  Le téléphone devient l'ANCRE D'IDENTITÉ (il était déjà UNIQUE sur
--  customers, jamais exploité jusqu'ici) : si un client se réidentifie avec
--  le même numéro depuis un nouvel appareil (réinstallation, stockage vidé),
--  upsert_me() reprend sa fiche existante au lieu d'en créer une seconde.
--
--  Aussi dans ce patch :
--   · update_my_optional_profile() — l'« espace client » complète email /
--     Instagram après coup, sans re-saisir les champs obligatoires.
--   · validate_promo_code() — vérification immédiate d'un code % / montant
--     saisi AVANT d'avoir un panier (contrairement à preview_promo, qui a
--     besoin d'un sous-total pour le seuil « panier minimum »).
-- ============================================================================

alter table public.customers
  add column if not exists postal_code text,
  add column if not exists birthdate   date,
  add column if not exists instagram   text;

-- ---------------------------------------------------------------------------
--  upsert_me() — nouvelle signature. L'ancienne version (3 arguments) est
--  supprimée explicitement : sinon les deux coexisteraient (surcharge), avec
--  un risque d'appel ambigu.
-- ---------------------------------------------------------------------------
drop function if exists public.upsert_me(text, text, text);

create or replace function public.upsert_me(
  p_first_name  text,
  p_last_name   text,
  p_phone       text,
  p_postal_code text,
  p_birthdate   date,
  p_email       text default null,
  p_instagram   text default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row   public.customers;
  v_phone text := nullif(trim(p_phone), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'missing_profile';
  end if;
  if v_phone is null then
    raise exception 'missing_phone';
  end if;
  if nullif(trim(p_postal_code), '') is null then
    raise exception 'missing_postal_code';
  end if;
  if p_birthdate is null or p_birthdate > current_date then
    raise exception 'invalid_birthdate';
  end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  -- Le téléphone est l'ancre d'identité : un même numéro sur un nouvel
  -- appareil reprend la fiche existante plutôt que d'en créer une seconde.
  select * into v_row from public.customers where phone = v_phone;

  if v_row.id is not null then
    -- Libère l'auth_user_id courant s'il était déjà rattaché à une AUTRE
    -- fiche (contrainte unique sur customers.auth_user_id) — évite un
    -- conflit lors de la reprise de fiche par téléphone.
    update public.customers set auth_user_id = null
     where auth_user_id = auth.uid() and id <> v_row.id;

    update public.customers
       set auth_user_id = auth.uid(),
           first_name   = trim(p_first_name),
           last_name    = trim(p_last_name),
           postal_code  = trim(p_postal_code),
           birthdate    = p_birthdate,
           email        = coalesce(nullif(trim(p_email), ''), email),
           instagram    = coalesce(nullif(trim(p_instagram), ''), instagram),
           last_seen_at = now()
     where id = v_row.id
     returning * into v_row;

    return v_row;
  end if;

  insert into public.customers
    (auth_user_id, first_name, last_name, phone, postal_code, birthdate, email, instagram)
  values (
    auth.uid(), trim(p_first_name), trim(p_last_name), v_phone, trim(p_postal_code), p_birthdate,
    nullif(lower(trim(coalesce(p_email, ''))), ''), nullif(trim(coalesce(p_instagram, '')), '')
  )
  on conflict (auth_user_id) do update
    set first_name   = excluded.first_name,
        last_name    = excluded.last_name,
        phone        = excluded.phone,
        postal_code  = excluded.postal_code,
        birthdate    = excluded.birthdate,
        email        = coalesce(excluded.email, public.customers.email),
        instagram    = coalesce(excluded.instagram, public.customers.instagram),
        last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  « Espace client » : complète e-mail / Instagram après coup, sans re-passer
--  par les champs obligatoires déjà enregistrés.
-- ---------------------------------------------------------------------------
create or replace function public.update_my_optional_profile(
  p_email     text default null,
  p_instagram text default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.customers;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  update public.customers
     set email     = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
         instagram = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end
   where id = v_cust
   returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  Vérification immédiate d'un code % / montant, AVANT d'avoir un panier
--  (contrairement à preview_promo, qui a besoin d'un sous-total pour évaluer
--  le seuil « panier minimum »). Utilisé par la saisie de code unifiée.
-- ---------------------------------------------------------------------------
create or replace function public.validate_promo_code(p_event uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo public.promo_codes;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind in ('percent', 'amount')
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'min_total', v_promo.min_total
  );
end;
$$;

grant execute on function public.upsert_me(text, text, text, text, date, text, text) to authenticated;
grant execute on function public.update_my_optional_profile(text, text)             to authenticated;
grant execute on function public.validate_promo_code(uuid, text)                    to authenticated;


-- ============================================================================
--  NOTI Calling — 0016_profil_telephone_editable.sql
--
--  L'« espace client » ne permettait de compléter que e-mail / Instagram.
--  Le téléphone (obligatoire à l'identification) devient lui aussi
--  modifiable depuis l'espace client — un numéro peut changer entre deux
--  soirées. Le téléphone restant l'ancre d'identité (unique sur customers),
--  une tentative de reprendre le numéro d'un AUTRE client est bloquée avec
--  un message clair plutôt qu'une erreur Postgres brute.
-- ============================================================================

-- L'ancienne version (2 arguments) doit être supprimée explicitement, sinon
-- les deux coexisteraient (surcharge), avec un risque d'appel ambigu.
drop function if exists public.update_my_optional_profile(text, text);

create or replace function public.update_my_optional_profile(
  p_email     text default null,
  p_instagram text default null,
  p_phone     text default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.customers;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;
  if p_phone is not null and trim(p_phone) = '' then
    raise exception 'missing_phone';
  end if;

  begin
    update public.customers
       set email     = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
           instagram = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end,
           phone     = case when p_phone is null then phone else trim(p_phone) end
     where id = v_cust
     returning * into v_row;
  exception when unique_violation then
    raise exception 'phone_already_used';
  end;

  return v_row;
end;
$$;

grant execute on function public.update_my_optional_profile(text, text, text) to authenticated;


-- ============================================================================
--  NOTI Calling — 0017_illustrations_produits.sql
--
--  Une illustration par article de la carte (verres/bouteilles dessinés aux
--  couleurs Noti Calling, encodés en data URI — jamais de lien externe cassé).
--  Rejoué à chaque appel de seed_noti_menu(), donc appliqué aussi bien à un
--  venue neuf qu'à un venue existant qui recharge la carte.
-- ============================================================================

create or replace function public.tag_product_illustrations(p_venue uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxnXzI4Njg2Mjc4IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMTdlNDMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U4OTU1QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U4OTU1QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTU2IDQwIFE1MiAxMDggMTAwIDExOCBRMTQ4IDEwOCAxNDQgNDAgWiIgZmlsbD0idXJsKCNsZ18yODY4NjI3OCkiLz4KICAgIDxwYXRoIGQ9Ik02MiA3MSBRMTAwIDc3IDEzOCA3MSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utb3BhY2l0eT0iMC4zNSIgc3Ryb2tlLXdpZHRoPSIyIiBmaWxsPSJub25lIi8+CiAgICA8cGF0aCBkPSJNNTYgNDAgUTUyIDEwOCAxMDAgMTE4IFExNDggMTA4IDE0NCA0MCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY0IDQ2IFE2MiA5NiA4OCAxMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNMTAwIDExOCBMMTAwIDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc2IDE1MiBMMTI0IDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8Y2lyY2xlIGN4PSI4Ni4wIiBjeT0iODAuNSIgcj0iMS44IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iODguNiIgY3k9IjkxLjYiIHI9IjEuNCIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjkzLjQiIGN5PSIxMDUuMSIgcj0iMS44IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iOTIuOCIgY3k9IjY2LjciIHI9IjEuOSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjkzLjkiIGN5PSI2OC42IiByPSIxLjgiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE2IDEzMiA0NCkiPgogICAgICA8Y2lyY2xlIGN4PSIxMzIiIGN5PSI0NCIgcj0iMTIiIGZpbGw9IiNGMEE5NEUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KICAgICAgPGNpcmNsZSBjeD0iMTMyIiBjeT0iNDQiIHI9IjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjQiLz4KICAgICAgPHBhdGggZD0iTTEzMiA0NCBMMTQzLjA0IDQ0LjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMzkuODA2NDU4ODY0Mjk5NSA1MS44MDY0NTg4NjQyOTk0ODYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMzIuMCA1NS4wNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMzIgNDQgTDEyNC4xOTM1NDExMzU3MDA1MSA1MS44MDY0NTg4NjQyOTk0ODYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMjAuOTYgNDQuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMzIgNDQgTDEyNC4xOTM1NDExMzU3MDA1MSAzNi4xOTM1NDExMzU3MDA1MTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMzIuMCAzMi45NiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMzIgNDQgTDEzOS44MDY0NTg4NjQyOTk1IDM2LjE5MzU0MTEzNTcwMDUxNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Spritz';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuNyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxnXzE4OTIwNzMyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMmMyNTMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTU2IDQwIFE1MiAxMDggMTAwIDExOCBRMTQ4IDEwOCAxNDQgNDAgWiIgZmlsbD0idXJsKCNsZ18xODkyMDczMikiLz4KICAgIDxwYXRoIGQ9Ik02MiA3MCBRMTAwIDc2IDEzOCA3MCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utb3BhY2l0eT0iMC4zNSIgc3Ryb2tlLXdpZHRoPSIyIiBmaWxsPSJub25lIi8+CiAgICA8cGF0aCBkPSJNNTYgNDAgUTUyIDEwOCAxMDAgMTE4IFExNDggMTA4IDE0NCA0MCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY0IDQ2IFE2MiA5NiA4OCAxMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNMTAwIDExOCBMMTAwIDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc2IDE1MiBMMTI0IDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8Y2lyY2xlIGN4PSIxMDEuNSIgY3k9IjY1LjMiIHI9IjEuNSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjEwNS42IiBjeT0iOTIuNCIgcj0iMS41IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iMTA1LjYiIGN5PSI2My43IiByPSIxLjIiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSI5OS4wIiBjeT0iNzYuOSIgcj0iMi4wIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iOTMuOCIgY3k9IjkwLjEiIHI9IjEuNiIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMjcgMTMyIDQ0KSI+CiAgICAgIDxwYXRoIGQ9Ik0xMzIgNTggTDEzMiAzOCIgc3Ryb2tlPSIjNUM4QTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgPGVsbGlwc2UgY3g9IjEyNiIgY3k9IjM2IiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKC0yNSAxMjYgMzYpIi8+PGVsbGlwc2UgY3g9IjEzOCIgY3k9IjM0IiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKDIwIDEzOCAzNCkiLz48ZWxsaXBzZSBjeD0iMTMyIiBjeT0iMjYiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCAxMzIgMjYpIi8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Limoncello Spritz';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxnXzE2ODEyMDc2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMTRjNjMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U4NjM3QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U4NjM3QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTU2IDQwIFE1MiAxMDggMTAwIDExOCBRMTQ4IDEwOCAxNDQgNDAgWiIgZmlsbD0idXJsKCNsZ18xNjgxMjA3NikiLz4KICAgIDxwYXRoIGQ9Ik02MiA3MSBRMTAwIDc3IDEzOCA3MSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utb3BhY2l0eT0iMC4zNSIgc3Ryb2tlLXdpZHRoPSIyIiBmaWxsPSJub25lIi8+CiAgICA8cGF0aCBkPSJNNTYgNDAgUTUyIDEwOCAxMDAgMTE4IFExNDggMTA4IDE0NCA0MCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY0IDQ2IFE2MiA5NiA4OCAxMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNMTAwIDExOCBMMTAwIDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc2IDE1MiBMMTI0IDE1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuNyIgY3k9IjY1LjkiIHI9IjEuNSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjEwOS4yIiBjeT0iNzAuMCIgcj0iMS42IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iMTA0LjgiIGN5PSIxMDcuMyIgcj0iMS44IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iOTcuMSIgY3k9IjgzLjMiIHI9IjEuOSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjExMS43IiBjeT0iMTAyLjIiIHI9IjEuOSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNCAxMzIgNDQpIj4KICAgICAgPGNpcmNsZSBjeD0iMTMyIiBjeT0iNDQiIHI9IjEyIiBmaWxsPSIjRjBBOTRFIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxjaXJjbGUgY3g9IjEzMiIgY3k9IjQ0IiByPSI4IiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC40Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMzIgNDQgTDE0My4wNCA0NC4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEzMiA0NCBMMTM5LjgwNjQ1ODg2NDI5OTUgNTEuODA2NDU4ODY0Mjk5NDg2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEzMiA0NCBMMTMyLjAgNTUuMDQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMjQuMTkzNTQxMTM1NzAwNTEgNTEuODA2NDU4ODY0Mjk5NDg2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEzMiA0NCBMMTIwLjk2IDQ0LjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMjQuMTkzNTQxMTM1NzAwNTEgMzYuMTkzNTQxMTM1NzAwNTE0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEzMiA0NCBMMTMyLjAgMzIuOTYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTMyIDQ0IEwxMzkuODA2NDU4ODY0Mjk5NSAzNi4xOTM1NDExMzU3MDA1MTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Sarti Spritz';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGdfNTc2NTQ3OTIiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2I4Yzk4ZiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNTYgNDAgUTUyIDEwOCAxMDAgMTE4IFExNDggMTA4IDE0NCA0MCBaIiBmaWxsPSJ1cmwoI2xnXzU3NjU0NzkyKSIvPgogICAgPHBhdGggZD0iTTYyIDY4IFExMDAgNzQgMTM4IDY4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS1vcGFjaXR5PSIwLjM1IiBzdHJva2Utd2lkdGg9IjIiIGZpbGw9Im5vbmUiLz4KICAgIDxwYXRoIGQ9Ik01NiA0MCBRNTIgMTA4IDEwMCAxMTggUTE0OCAxMDggMTQ0IDQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNjQgNDYgUTYyIDk2IDg4IDExMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgMTE4IEwxMDAgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzYgMTUyIEwxMjQgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxjaXJjbGUgY3g9Ijg3LjQiIGN5PSIxMDQuOCIgcj0iMS41IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iOTcuNSIgY3k9IjcxLjkiIHI9IjEuMiIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9Ijg3LjgiIGN5PSI2NS4wIiByPSIxLjkiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSIxMDEuNCIgY3k9IjEwMi44IiByPSIxLjYiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSI4NS42IiBjeT0iODcuOSIgcj0iMi4xIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC0yOSAxMzIgNDQpIj4KICAgICAgPHBhdGggZD0iTTEzMiA1OCBMMTMyIDM4IiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICA8ZWxsaXBzZSBjeD0iMTI2IiBjeT0iMzYiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoLTI1IDEyNiAzNikiLz48ZWxsaXBzZSBjeD0iMTM4IiBjeT0iMzQiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgMTM4IDM0KSIvPjxlbGxpcHNlIGN4PSIxMzIiIGN5PSIyNiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgwIDEzMiAyNikiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Hugo Spritz';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzZBNUZENiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC4yIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGNfMjI2NzkzMzMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QxN2U0MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTg5NTVBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTg5NTVBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNDYgMzggTDE1NCAzOCBMMTAwIDk2IFoiIGZpbGw9InVybCgjbGNfMjI2NzkzMzMpIi8+CiAgICA8cGF0aCBkPSJNNjIgNDYgTDEzOCA0NiBMMTAwIDg4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNDYgMzggTDE1NCAzOCBMMTAwIDk2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTYgTDEwMCAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCAxNTAgTDEyNiAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE5IDExOCA0MCkiPgogICAgICA8cGF0aCBkPSJNMTE4IDM4IFExMjggMTggMTIyIDEwIiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIgZmlsbD0ibm9uZSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMTgiIGN5PSI0NCIgcj0iNyIgZmlsbD0iI0IyM0E0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgPGNpcmNsZSBjeD0iMTE1LjUiIGN5PSI0MS41IiByPSIxLjYiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC42IiBzdHJva2U9Im5vbmUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Mocktail Exotique';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMTIzNzI4ODAiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2M1Y2NkNSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRENFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRENFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMTIzNzI4ODApIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDcuOSA4NS4xIDEwMS43KSI+PHJlY3QgeD0iNzYuMCIgeT0iOTIuNiIgd2lkdGg9IjE4LjIiIGhlaWdodD0iMTguMiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijc5LjAiIHkxPSI5Ni42IiB4Mj0iODguMiIgeTI9IjEwMi44IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS41IDEwMC45IDEwOS4wKSI+PHJlY3QgeD0iOTEuOCIgeT0iOTkuOSIgd2lkdGg9IjE4LjEiIGhlaWdodD0iMTguMSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijk0LjgiIHkxPSIxMDMuOSIgeDI9IjEwMy45IiB5Mj0iMTEwLjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDEwLjMgMTA5LjAgMTAxLjEpIj48cmVjdCB4PSI5OC43IiB5PSI5MC44IiB3aWR0aD0iMjAuNiIgaGVpZ2h0PSIyMC42IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTAxLjciIHkxPSI5NC44IiB4Mj0iMTEzLjMiIHkyPSIxMDMuNCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDIwIDg4IDYwKSI+CiAgICAgIDxwYXRoIGQ9Ik03MiA2MCBBMTYgMTYgMCAwIDEgMTA0IDYwIFoiIGZpbGw9IiNDRkUwQTYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KICAgICAgPHBhdGggZD0iTTc5IDU4IEw4OCA0NyBNODggNDcgTDk3IDU4IE03NSA1OSBMODggNDYgTTEwMSA1OSBMODggNDYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjEiIG9wYWNpdHk9IjAuNTUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Moscow Mule';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzZBNUZENiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC43IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGNfMjU1NzY5MDMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzliMjMzMSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNDYgMzggTDE1NCAzOCBMMTAwIDk2IFoiIGZpbGw9InVybCgjbGNfMjU1NzY5MDMpIi8+CiAgICA8cGF0aCBkPSJNNjIgNDYgTDEzOCA0NiBMMTAwIDg4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNDYgMzggTDE1NCAzOCBMMTAwIDk2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTYgTDEwMCAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCAxNTAgTDEyNiAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE0IDExOCA0MCkiPgogICAgICA8cGF0aCBkPSJNMTE4IDM4IFExMjggMTggMTIyIDEwIiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIgZmlsbD0ibm9uZSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMTgiIGN5PSI0NCIgcj0iNyIgZmlsbD0iI0IyM0E0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgPGNpcmNsZSBjeD0iMTE1LjUiIGN5PSI0MS41IiByPSIxLjYiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC42IiBzdHJva2U9Im5vbmUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Rive Gauche';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy43IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHRfMzI5OTA3ODAiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QwOTJhZCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTdBOUM0IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTdBOUM0IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjYgNDIgUTY2IDkwIDEwMCA5NCBRMTM0IDkwIDEzNCA0MiBaIiBmaWxsPSJ1cmwoI2x0XzMyOTkwNzgwKSIvPgogICAgPHBhdGggZD0iTTc0IDUwIFE3NiA3OCA5NiA4OCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuNSIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTYyIDQwIFE2MiA5MiAxMDAgOTYgUTEzOCA5MiAxMzggNDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTYgTDEwMCAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCAxNTAgTDEyNiAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Côtes de Provence AOP — Minuty Prestige 2024';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx0XzMwMTU5MDk0IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMWMyODkiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U4RDlBMCIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U4RDlBMCIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY2IDQyIFE2NiA5MCAxMDAgOTQgUTEzNCA5MCAxMzQgNDIgWiIgZmlsbD0idXJsKCNsdF8zMDE1OTA5NCkiLz4KICAgIDxwYXRoIGQ9Ik03NCA1MCBRNzYgNzggOTYgODgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjUiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02MiA0MCBRNjIgOTIgMTAwIDk2IFExMzggOTIgMTM4IDQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNMTAwIDk2IEwxMDAgMTUwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzQgMTUwIEwxMjYgMTUwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Pouilly-Fumé AOP — Domaine Minet';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuOSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx0XzI2OTA1NTk0IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM0MzBiMWMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzVBMjIzMyIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzVBMjIzMyIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY2IDQyIFE2NiA5MCAxMDAgOTQgUTEzNCA5MCAxMzQgNDIgWiIgZmlsbD0idXJsKCNsdF8yNjkwNTU5NCkiLz4KICAgIDxwYXRoIGQ9Ik03NCA1MCBRNzYgNzggOTYgODgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjUiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02MiA0MCBRNjIgOTIgMTAwIDk2IFExMzggOTIgMTM4IDQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNMTAwIDk2IEwxMDAgMTUwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzQgMTUwIEwxMjYgMTUwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Bordeaux AOP — James Deschartrons 2021/22';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHRfMTQ0NTQ3MzMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzYzMGMxYyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjN0EyMzMzIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjN0EyMzMzIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjYgNDIgUTY2IDkwIDEwMCA5NCBRMTM0IDkwIDEzNCA0MiBaIiBmaWxsPSJ1cmwoI2x0XzE0NDU0NzMzKSIvPgogICAgPHBhdGggZD0iTTc0IDUwIFE3NiA3OCA5NiA4OCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuNSIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTYyIDQwIFE2MiA5MiAxMDAgOTYgUTEzOCA5MiAxMzggNDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTYgTDEwMCAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCAxNTAgTDEyNiAxNTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Saint-Amour AOP — Domaine des Pierres 2023/24';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuNyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxmXzc0NTIyOTY2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkN2IyNTgiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI2VlYzk2ZiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI2VlYzk2ZiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTg0IDMyIEw4NiAxMTggUTg2IDEzNiAxMDAgMTM4IFExMTQgMTM2IDExNCAxMTggTDExNiAzMiBaIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNODggNTggTDExMiA1OCBMMTE0IDExOCBRMTE0IDEzMCAxMDAgMTMyIFE4NiAxMzAgODYgMTE4IFoiIGZpbGw9InVybCgjbGZfNzQ1MjI5NjYpIi8+CiAgICA8cGF0aCBkPSJNODQgMzIgTDExNiAzMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTEwMCAxMzggTDEwMCAxNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04NCAxNTQgTDExNiAxNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTkxIDYyIEw5MSAxMTYiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjQ1Ii8+CiAgICA8Y2lyY2xlIGN4PSI5OS4zIiBjeT0iODMuNiIgcj0iMi4wIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iMTAxLjIiIGN5PSIxMDcuMSIgcj0iMS4yIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iMTA0LjUiIGN5PSI4My4xIiByPSIxLjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSIxMDguMyIgY3k9IjEwNS4xIiByPSIxLjkiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSIxMDEuNSIgY3k9Ijg5LjUiIHI9IjEuNSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjkyLjMiIGN5PSI3Ni45IiByPSIxLjkiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Champagne AOP Richard — Brut';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0YzQjZEOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTJDOEI4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGZfMTAyNzM2MjMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2NiYTY0YyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjZTJiZDYzIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjZTJiZDYzIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNODQgMzIgTDg2IDExOCBRODYgMTM2IDEwMCAxMzggUTExNCAxMzYgMTE0IDExOCBMMTE2IDMyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04OCA1OCBMMTEyIDU4IEwxMTQgMTE4IFExMTQgMTMwIDEwMCAxMzIgUTg2IDEzMCA4NiAxMTggWiIgZmlsbD0idXJsKCNsZl8xMDI3MzYyMykiLz4KICAgIDxwYXRoIGQ9Ik04NCAzMiBMMTE2IDMyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNMTAwIDEzOCBMMTAwIDE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg0IDE1NCBMMTE2IDE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNOTEgNjIgTDkxIDExNiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNDUiLz4KICAgIDxjaXJjbGUgY3g9IjEwMi41IiBjeT0iNzguMyIgcj0iMS4yIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iOTEuMSIgY3k9Ijg4LjQiIHI9IjEuNSIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjkzLjIiIGN5PSI2OC41IiByPSIxLjYiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgo8Y2lyY2xlIGN4PSIxMDguNiIgY3k9IjcwLjUiIHI9IjEuMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjU1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+CjxjaXJjbGUgY3g9IjEwMi4zIiBjeT0iOTYuMCIgcj0iMS4wIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz4KPGNpcmNsZSBjeD0iMTAxLjUiIGN5PSI3Ny4yIiByPSIxLjAiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPgogICAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjMyIiByeD0iMTgiIHJ5PSI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMi41Ii8+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Champagne AOP Moët & Chandon — Brut Impérial';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Q5QTQ0MSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS4wIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibG1fMjc4ODA1NzkiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2NjOWIzNCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTNCMjRCIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTNCMjRCIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjAgNTAgTDY0IDE0OCBRNjQgMTU4IDc2IDE1OCBMMTIyIDE1OCBRMTM0IDE1OCAxMzQgMTQ4IEwxMzggNTAgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY0IDc2IEwxMzQgNzYgTDEzMCAxNDggUTEzMCAxNTIgMTIyIDE1MiBMNzYgMTUyIFE2OCAxNTIgNjggMTQ4IFoiIGZpbGw9InVybCgjbG1fMjc4ODA1NzkpIi8+CiAgICA8cGF0aCBkPSJNNzIgODIgTDcyIDE0NCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02MCA1MCBROTkgNjAgMTM4IDUwIFExMzQgNjggOTkgNzAgUTY0IDY4IDYwIDUwIFoiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz4KICAgIDxwYXRoIGQ9Ik0xMzggODIgUTE2MCA4MiAxNjAgMTA0IFExNjAgMTI0IDEzOCAxMjIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'La Parisienne — Blonde';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Q5QTQ0MSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuOSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxtXzIyNjM3NzM3IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNiMjYzMTciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0M5N0EyRSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0M5N0EyRSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTYwIDUwIEw2NCAxNDggUTY0IDE1OCA3NiAxNTggTDEyMiAxNTggUTEzNCAxNTggMTM0IDE0OCBMMTM4IDUwIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NCA3NiBMMTM0IDc2IEwxMzAgMTQ4IFExMzAgMTUyIDEyMiAxNTIgTDc2IDE1MiBRNjggMTUyIDY4IDE0OCBaIiBmaWxsPSJ1cmwoI2xtXzIyNjM3NzM3KSIvPgogICAgPHBhdGggZD0iTTcyIDgyIEw3MiAxNDQiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjAgNTAgUTk5IDYwIDEzOCA1MCBRMTM0IDY4IDk5IDcwIFE2NCA2OCA2MCA1MCBaIiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi42Ii8+CiAgICA8cGF0aCBkPSJNMTM4IDgyIFExNjAgODIgMTYwIDEwNCBRMTYwIDEyNCAxMzggMTIyIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'La Parisienne — IPA';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Q5QTQ0MSIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibG1fMTYwMTU4MTUiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QzYzI5MSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRUFEOUE4IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRUFEOUE4IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjAgNTAgTDY0IDE0OCBRNjQgMTU4IDc2IDE1OCBMMTIyIDE1OCBRMTM0IDE1OCAxMzQgMTQ4IEwxMzggNTAgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY0IDc2IEwxMzQgNzYgTDEzMCAxNDggUTEzMCAxNTIgMTIyIDE1MiBMNzYgMTUyIFE2OCAxNTIgNjggMTQ4IFoiIGZpbGw9InVybCgjbG1fMTYwMTU4MTUpIi8+CiAgICA8cGF0aCBkPSJNNzIgODIgTDcyIDE0NCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02MCA1MCBROTkgNjAgMTM4IDUwIFExMzQgNjggOTkgNzAgUTY0IDY4IDYwIDUwIFoiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz4KICAgIDxwYXRoIGQ9Ik0xMzggODIgUTE2MCA4MiAxNjAgMTA0IFExNjAgMTI0IDEzOCAxMjIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'La Parisienne — Blanche';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzI4NjEwMzU2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMTdlNDMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U4OTU1QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U4OTU1QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzI4NjEwMzU2KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMC45IDExMi4zIDk2LjApIj48cmVjdCB4PSIxMDIuMiIgeT0iODUuOCIgd2lkdGg9IjIwLjMiIGhlaWdodD0iMjAuMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNS4yIiB5MT0iODkuOCIgeDI9IjExNi41IiB5Mj0iOTguMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi44IDEwMS4wIDExMC4xKSI+PHJlY3QgeD0iOTAuOCIgeT0iOTkuOSIgd2lkdGg9IjIwLjUiIGhlaWdodD0iMjAuNSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkzLjgiIHkxPSIxMDMuOSIgeDI9IjEwNS4zIiB5Mj0iMTEyLjQiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDQuMyA4Ny4xIDkzLjEpIj48cmVjdCB4PSI3OC44IiB5PSI4NC44IiB3aWR0aD0iMTYuNyIgaGVpZ2h0PSIxNi43IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODEuOCIgeTE9Ijg4LjgiIHgyPSI4OS40IiB5Mj0iOTMuNSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxwYXRoIGQ9Ik0xMTggMzQgTDk0IDE1OCIgc3Ryb2tlPSIjYjczZjRkIiBzdHJva2Utd2lkdGg9IjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMCAxMDAgMTAwKSIvPjxnIHRyYW5zZm9ybT0icm90YXRlKDE4IDg4IDYwKSI+CiAgICAgIDxwYXRoIGQ9Ik04OCA3NCBMODggNTQiIHN0cm9rZT0iIzVDOEE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICAgIDxlbGxpcHNlIGN4PSI4MiIgY3k9IjUyIiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKC0yNSA4MiA1MikiLz48ZWxsaXBzZSBjeD0iOTQiIGN5PSI1MCIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgyMCA5NCA1MCkiLz48ZWxsaXBzZSBjeD0iODgiIGN5PSI0MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgwIDg4IDQyKSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Limonaid bio fruits de la passion';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuNiAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzI2MzczODA2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMjNjNTQiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q5NTM2QiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q5NTM2QiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzI2MzczODA2KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS43IDEwOC43IDExNC4xKSI+PHJlY3QgeD0iOTkuNiIgeT0iMTA1LjEiIHdpZHRoPSIxOC4xIiBoZWlnaHQ9IjE4LjEiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDIuNiIgeTE9IjEwOS4xIiB4Mj0iMTExLjgiIHkyPSIxMTUuMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuMiAxMDYuNSA5My4yKSI+PHJlY3QgeD0iOTYuNyIgeT0iODMuMyIgd2lkdGg9IjE5LjYiIGhlaWdodD0iMTkuNiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijk5LjciIHkxPSI4Ny4zIiB4Mj0iMTEwLjMiIHkyPSI5NS4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMTAuNyAxMDEuOSAxMDAuMSkiPjxyZWN0IHg9IjkyLjEiIHk9IjkwLjMiIHdpZHRoPSIxOS43IiBoZWlnaHQ9IjE5LjciIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5NS4xIiB5MT0iOTQuMyIgeDI9IjEwNS43IiB5Mj0iMTAyLjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8cGF0aCBkPSJNMTE4IDM0IEw5NCAxNTgiIHN0cm9rZT0iI2I1M2Q0YiIgc3Ryb2tlLXdpZHRoPSI2IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHRyYW5zZm9ybT0icm90YXRlKC0zLjkgMTAwIDEwMCkiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSg0IDg4IDYwKSI+CiAgICAgIDxjaXJjbGUgY3g9Ijg4IiBjeT0iNjAiIHI9IjEyIiBmaWxsPSIjRjBBOTRFIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxjaXJjbGUgY3g9Ijg4IiBjeT0iNjAiIHI9IjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjQiLz4KICAgICAgPHBhdGggZD0iTTg4IDYwIEw5OS4wNCA2MC4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw5NS44MDY0NTg4NjQyOTk0OSA2Ny44MDY0NTg4NjQyOTk0OSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMODguMCA3MS4wNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMODAuMTkzNTQxMTM1NzAwNTEgNjcuODA2NDU4ODY0Mjk5NDkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDc2Ljk2IDYwLjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDgwLjE5MzU0MTEzNTcwMDUxIDUyLjE5MzU0MTEzNTcwMDUxNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMODguMCA0OC45NiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMOTUuODA2NDU4ODY0Mjk5NDkgNTIuMTkzNTQxMTM1NzAwNTE0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Limonaid bio orange sanguine';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi4yIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMjYxOTAyMDEiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzY2NTQ5NyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjN0Q2QkFFIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjN0Q2QkFFIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMjYxOTAyMDEpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDEuMiAxMDEuNiAxMDAuMCkiPjxyZWN0IHg9IjkyLjgiIHk9IjkxLjIiIHdpZHRoPSIxNy42IiBoZWlnaHQ9IjE3LjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5NS44IiB5MT0iOTUuMiIgeDI9IjEwNC40IiB5Mj0iMTAwLjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDAuMiA5MS44IDkyLjcpIj48cmVjdCB4PSI4My40IiB5PSI4NC40IiB3aWR0aD0iMTYuNyIgaGVpZ2h0PSIxNi43IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODYuNCIgeTE9Ijg4LjQiIHgyPSI5NC4xIiB5Mj0iOTMuMCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNS42IDk2LjEgMTA3LjUpIj48cmVjdCB4PSI4Ni4yIiB5PSI5Ny42IiB3aWR0aD0iMTkuOCIgaGVpZ2h0PSIxOS44IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODkuMiIgeTE9IjEwMS42IiB4Mj0iMTAwLjAiIHkyPSIxMDkuNCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxwYXRoIGQ9Ik0xMTggMzQgTDk0IDE1OCIgc3Ryb2tlPSIjYzM0YjU5IiBzdHJva2Utd2lkdGg9IjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgdHJhbnNmb3JtPSJyb3RhdGUoLTQuOSAxMDAgMTAwKSIvPjxnIHRyYW5zZm9ybT0icm90YXRlKDggODggNjApIj4KICAgICAgPHBhdGggZD0iTTg4IDc0IEw4OCA1NCIgc3Ryb2tlPSIjNUM4QTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgPGVsbGlwc2UgY3g9IjgyIiBjeT0iNTIiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoLTI1IDgyIDUyKSIvPjxlbGxpcHNlIGN4PSI5NCIgY3k9IjUwIiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKDIwIDk0IDUwKSIvPjxlbGxpcHNlIGN4PSI4OCIgY3k9IjQyIiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKDAgODggNDIpIi8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Teansai Tea — thé blanc myrtille';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzE5MzI4ODkyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiMzMzEzMDciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzRBMkExRSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzRBMkExRSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzE5MzI4ODkyKSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNi4wIDEwMy42IDk5LjApIj48cmVjdCB4PSI5My45IiB5PSI4OS4zIiB3aWR0aD0iMTkuMyIgaGVpZ2h0PSIxOS4zIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTYuOSIgeTE9IjkzLjMiIHgyPSIxMDcuMiIgeTI9IjEwMC43IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjcgOTYuNiA5OC43KSI+PHJlY3QgeD0iODcuNiIgeT0iODkuNyIgd2lkdGg9IjE4LjAiIGhlaWdodD0iMTguMCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkwLjYiIHkxPSI5My43IiB4Mj0iOTkuNSIgeTI9Ijk5LjciIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDguMyAxMDMuNSAxMDcuOCkiPjxyZWN0IHg9IjkzLjIiIHk9Ijk3LjUiIHdpZHRoPSIyMC43IiBoZWlnaHQ9IjIwLjciIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5Ni4yIiB5MT0iMTAxLjUiIHgyPSIxMDcuOSIgeTI9IjExMC4yIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgogICAgPHBhdGggZD0iTTExOCAzNCBMOTQgMTU4IiBzdHJva2U9IiNjNTRkNWIiIHN0cm9rZS13aWR0aD0iNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiB0cmFuc2Zvcm09InJvdGF0ZSgtMC41IDEwMCAxMDApIi8+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Coca-Cola';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzE4OTEzNjE3IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiMyMzEzMTMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzNBMkEyQSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzNBMkEyQSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzE4OTEzNjE3KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSg5LjMgMTA3LjkgMTA5LjIpIj48cmVjdCB4PSI5Ny4wIiB5PSI5OC4zIiB3aWR0aD0iMjEuNyIgaGVpZ2h0PSIyMS43IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTAwLjAiIHkxPSIxMDIuMyIgeDI9IjExMi43IiB5Mj0iMTEyLjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDAuMyAxMDUuMCAxMTUuMCkiPjxyZWN0IHg9Ijk0LjAiIHk9IjEwNC4wIiB3aWR0aD0iMjEuOSIgaGVpZ2h0PSIyMS45IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTcuMCIgeTE9IjEwOC4wIiB4Mj0iMTA5LjkiIHkyPSIxMTcuOSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoOC4yIDk2LjkgMTE1LjYpIj48cmVjdCB4PSI4OC43IiB5PSIxMDcuNCIgd2lkdGg9IjE2LjUiIGhlaWdodD0iMTYuNSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkxLjciIHkxPSIxMTEuNCIgeDI9Ijk5LjIiIHkyPSIxMTUuOCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxwYXRoIGQ9Ik0xMTggMzQgTDk0IDE1OCIgc3Ryb2tlPSIjYjUzZDRiIiBzdHJva2Utd2lkdGg9IjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgdHJhbnNmb3JtPSJyb3RhdGUoLTEuMiAxMDAgMTAwKSIvPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Coca-Cola Zéro';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzI5NTM0NzMyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMjgzMzciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q5OUE0RSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q5OUE0RSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzI5NTM0NzMyKSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMi4zIDkxLjUgOTIuOSkiPjxyZWN0IHg9IjgzLjMiIHk9Ijg0LjciIHdpZHRoPSIxNi41IiBoZWlnaHQ9IjE2LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4Ni4zIiB5MT0iODguNyIgeDI9IjkzLjgiIHkyPSI5My4yIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMTEuNCAxMDkuNiAxMTEuOCkiPjxyZWN0IHg9IjEwMC45IiB5PSIxMDMuMCIgd2lkdGg9IjE3LjUiIGhlaWdodD0iMTcuNSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwMy45IiB5MT0iMTA3LjAiIHgyPSIxMTIuNCIgeTI9IjExMi41IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSg4LjMgOTQuOSA5NS45KSI+PHJlY3QgeD0iODUuMSIgeT0iODYuMCIgd2lkdGg9IjE5LjciIGhlaWdodD0iMTkuNyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg4LjEiIHkxPSI5MC4wIiB4Mj0iOTguOCIgeTI9Ijk3LjciIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8cGF0aCBkPSJNMTE4IDM0IEw5NCAxNTgiIHN0cm9rZT0iI2EwMjgzNiIgc3Ryb2tlLXdpZHRoPSI2IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHRyYW5zZm9ybT0icm90YXRlKDcuMSAxMDAgMTAwKSIvPjxnIHRyYW5zZm9ybT0icm90YXRlKC0xMiA4OCA2MCkiPgogICAgICA8cGF0aCBkPSJNODggNzQgTDg4IDU0IiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICA8ZWxsaXBzZSBjeD0iODIiIGN5PSI1MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgtMjUgODIgNTIpIi8+PGVsbGlwc2UgY3g9Ijk0IiBjeT0iNTAiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgOTQgNTApIi8+PGVsbGlwc2UgY3g9Ijg4IiBjeT0iNDIiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCA4OCA0MikiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Lipton Ice Tea Pêche';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzcyMzQ2NTI3IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkOThiMjMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0YwQTIzQSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0YwQTIzQSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzcyMzQ2NTI3KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS45IDExNC4xIDk4LjEpIj48cmVjdCB4PSIxMDQuMCIgeT0iODcuOSIgd2lkdGg9IjIwLjMiIGhlaWdodD0iMjAuMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNy4wIiB5MT0iOTEuOSIgeDI9IjExOC4zIiB5Mj0iMTAwLjIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDMuNSAxMDEuMSAxMDkuOSkiPjxyZWN0IHg9IjkxLjciIHk9IjEwMC41IiB3aWR0aD0iMTguNyIgaGVpZ2h0PSIxOC43IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTQuNyIgeTE9IjEwNC41IiB4Mj0iMTA0LjQiIHkyPSIxMTEuMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuNSA4NS4xIDEwNC4zKSI+PHJlY3QgeD0iNzUuMyIgeT0iOTQuNSIgd2lkdGg9IjE5LjYiIGhlaWdodD0iMTkuNiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijc4LjMiIHkxPSI5OC41IiB4Mj0iODguOSIgeTI9IjEwNi4yIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgogICAgPHBhdGggZD0iTTExOCAzNCBMOTQgMTU4IiBzdHJva2U9IiNhMTI5MzciIHN0cm9rZS13aWR0aD0iNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiB0cmFuc2Zvcm09InJvdGF0ZSgtNC45IDEwMCAxMDApIi8+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Jus d''orange';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzkyNDA4NTI3IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMmFiMzciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzkyNDA4NTI3KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMC41IDEwNi40IDk3LjEpIj48cmVjdCB4PSI5Ni41IiB5PSI4Ny4yIiB3aWR0aD0iMTkuOCIgaGVpZ2h0PSIxOS44IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTkuNSIgeTE9IjkxLjIiIHgyPSIxMTAuMyIgeTI9Ijk5LjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC01LjYgMTA4LjggOTQuMykiPjxyZWN0IHg9Ijk5LjgiIHk9Ijg1LjMiIHdpZHRoPSIxNy45IiBoZWlnaHQ9IjE3LjkiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDIuOCIgeTE9Ijg5LjMiIHgyPSIxMTEuOCIgeTI9Ijk1LjIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC04LjUgODkuOCAxMDAuOSkiPjxyZWN0IHg9IjgwLjIiIHk9IjkxLjMiIHdpZHRoPSIxOS4yIiBoZWlnaHQ9IjE5LjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4My4yIiB5MT0iOTUuMyIgeDI9IjkzLjQiIHkyPSIxMDIuNSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxwYXRoIGQ9Ik0xMTggMzQgTDk0IDE1OCIgc3Ryb2tlPSIjYWYzNzQ1IiBzdHJva2Utd2lkdGg9IjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgdHJhbnNmb3JtPSJyb3RhdGUoLTEuMCAxMDAgMTAwKSIvPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Jus de pomme';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzExNzE0Njc5IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMmJmMzMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U5RDY0QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U5RDY0QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzExNzE0Njc5KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNS4yIDExMi4wIDk3LjMpIj48cmVjdCB4PSIxMDIuMSIgeT0iODcuMyIgd2lkdGg9IjE5LjkiIGhlaWdodD0iMTkuOSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNS4xIiB5MT0iOTEuMyIgeDI9IjExNi4wIiB5Mj0iOTkuMyIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoOS42IDkwLjggMTIxLjIpIj48cmVjdCB4PSI4Mi43IiB5PSIxMTMuMCIgd2lkdGg9IjE2LjMiIGhlaWdodD0iMTYuMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg1LjciIHkxPSIxMTcuMCIgeDI9IjkzLjAiIHkyPSIxMjEuNCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC4xIDExMS45IDExNi44KSI+PHJlY3QgeD0iMTAzLjUiIHk9IjEwOC40IiB3aWR0aD0iMTYuNyIgaGVpZ2h0PSIxNi43IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTA2LjUiIHkxPSIxMTIuNCIgeDI9IjExNC4zIiB5Mj0iMTE3LjIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8cGF0aCBkPSJNMTE4IDM0IEw5NCAxNTgiIHN0cm9rZT0iI2EyMmEzOCIgc3Ryb2tlLXdpZHRoPSI2IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHRyYW5zZm9ybT0icm90YXRlKDYuMSAxMDAgMTAwKSIvPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Jus d''ananas';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMTg2OTQ4NjUiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2I4Y2NkNSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQ0ZFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQ0ZFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMTg2OTQ4NjUpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDExLjkgMTExLjEgMTE5LjEpIj48cmVjdCB4PSIxMDMuMCIgeT0iMTExLjAiIHdpZHRoPSIxNi4yIiBoZWlnaHQ9IjE2LjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDYuMCIgeTE9IjExNS4wIiB4Mj0iMTEzLjIiIHkyPSIxMTkuMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNi4yIDExMy45IDEyMC40KSI+PHJlY3QgeD0iMTA1LjMiIHk9IjExMS44IiB3aWR0aD0iMTcuMiIgaGVpZ2h0PSIxNy4yIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTA4LjMiIHkxPSIxMTUuOCIgeDI9IjExNi41IiB5Mj0iMTIxLjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC05LjIgOTEuMyAxMDIuNCkiPjxyZWN0IHg9IjgxLjgiIHk9IjkyLjkiIHdpZHRoPSIxOS4wIiBoZWlnaHQ9IjE5LjAiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4NC44IiB5MT0iOTYuOSIgeDI9Ijk0LjgiIHkyPSIxMDMuOSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxwYXRoIGQ9Ik0xMTggMzQgTDk0IDE1OCIgc3Ryb2tlPSIjYmM0NDUyIiBzdHJva2Utd2lkdGg9IjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgdHJhbnNmb3JtPSJyb3RhdGUoLTcuOSAxMDAgMTAwKSIvPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Evian';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMTMxMDg1NTEiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2I4Y2NkNSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQ0ZFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQ0ZFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMTMxMDg1NTEpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC02LjEgMTA2LjQgMTA2LjkpIj48cmVjdCB4PSI5Ni4yIiB5PSI5Ni43IiB3aWR0aD0iMjAuNCIgaGVpZ2h0PSIyMC40IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTkuMiIgeTE9IjEwMC43IiB4Mj0iMTEwLjYiIHkyPSIxMDkuMSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTUuNSAxMDUuNSAxMDQuNykiPjxyZWN0IHg9Ijk3LjIiIHk9Ijk2LjMiIHdpZHRoPSIxNi42IiBoZWlnaHQ9IjE2LjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDAuMiIgeTE9IjEwMC4zIiB4Mj0iMTA3LjgiIHkyPSIxMDUuMCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuNiA5OC41IDEwOS44KSI+PHJlY3QgeD0iOTAuMCIgeT0iMTAxLjMiIHdpZHRoPSIxNi45IiBoZWlnaHQ9IjE2LjkiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5My4wIiB5MT0iMTA1LjMiIHgyPSIxMDAuOSIgeTI9IjExMC4yIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgogICAgPHBhdGggZD0iTTExOCAzNCBMOTQgMTU4IiBzdHJva2U9IiNjNDRjNWEiIHN0cm9rZS13aWR0aD0iNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiB0cmFuc2Zvcm09InJvdGF0ZSgwLjYgMTAwIDEwMCkiLz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Badoit';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuOSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzE3OTkxMDA1IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiMyMzQzNzMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzNBNUE4QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzNBNUE4QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzE3OTkxMDA1KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNi42IDEwOC40IDExNi4zKSI+PHJlY3QgeD0iOTcuNSIgeT0iMTA1LjUiIHdpZHRoPSIyMS42IiBoZWlnaHQ9IjIxLjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDAuNSIgeTE9IjEwOS41IiB4Mj0iMTEzLjIiIHkyPSIxMTkuMSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEwLjMgOTEuOSAxMTMuNSkiPjxyZWN0IHg9IjgxLjQiIHk9IjEwMi45IiB3aWR0aD0iMjEuMiIgaGVpZ2h0PSIyMS4yIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODQuNCIgeTE9IjEwNi45IiB4Mj0iOTYuNSIgeTI9IjExNi4xIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMTEuMSA4NS40IDExNy4wKSI+PHJlY3QgeD0iNzUuNiIgeT0iMTA3LjIiIHdpZHRoPSIxOS41IiBoZWlnaHQ9IjE5LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI3OC42IiB5MT0iMTExLjIiIHgyPSI4OS4yIiB5Mj0iMTE4LjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Red Bull';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfNTExMjUyODYiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2M1Y2NkNSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRENFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRENFM0VDIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDkwIEwxMzMgOTAgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfNTExMjUyODYpIi8+CiAgICA8cGF0aCBkPSJNNzYgOTYgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjMgODkuMSAxMDMuOSkiPjxyZWN0IHg9IjgwLjMiIHk9Ijk1LjEiIHdpZHRoPSIxNy41IiBoZWlnaHQ9IjE3LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4My4zIiB5MT0iOTkuMSIgeDI9IjkxLjgiIHkyPSIxMDQuNiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNS4yIDEwNS43IDEzNi4yKSI+PHJlY3QgeD0iOTUuNiIgeT0iMTI2LjEiIHdpZHRoPSIyMC4yIiBoZWlnaHQ9IjIwLjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5OC42IiB5MT0iMTMwLjEiIHgyPSIxMDkuOCIgeTI9IjEzOC4zIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSg5LjMgMTAwLjEgMTExLjApIj48cmVjdCB4PSI4OS4yIiB5PSIxMDAuMCIgd2lkdGg9IjIxLjkiIGhlaWdodD0iMjEuOSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkyLjIiIHkxPSIxMDQuMCIgeDI9IjEwNS4wIiB5Mj0iMTEzLjkiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Absolut';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzI5MTQ4NDAyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMWM5ZDMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q4RTBFQSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q4RTBFQSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NyA4OSBMMTMzIDg5IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzI5MTQ4NDAyKSIvPgogICAgPHBhdGggZD0iTTc2IDk1IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoOC40IDEwMi41IDExMC41KSI+PHJlY3QgeD0iOTQuMCIgeT0iMTAyLjAiIHdpZHRoPSIxNy4wIiBoZWlnaHQ9IjE3LjAiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5Ny4wIiB5MT0iMTA2LjAiIHgyPSIxMDUuMCIgeTI9IjExMS4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSg2LjggOTEuMyAxMjkuMCkiPjxyZWN0IHg9IjgyLjYiIHk9IjEyMC40IiB3aWR0aD0iMTcuMyIgaGVpZ2h0PSIxNy4zIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODUuNiIgeTE9IjEyNC40IiB4Mj0iOTMuOSIgeTI9IjEyOS42IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSg0LjIgOTUuNyAxMDIuMCkiPjxyZWN0IHg9Ijg1LjQiIHk9IjkxLjYiIHdpZHRoPSIyMC43IiBoZWlnaHQ9IjIwLjciIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4OC40IiB5MT0iOTUuNiIgeDI9IjEwMC4xIiB5Mj0iMTA0LjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Ketel One';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMTQwMTgzMzkiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2NjZDJkOSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTNFOUYwIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTNFOUYwIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDg3IEwxMzMgODcgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMTQwMTgzMzkpIi8+CiAgICA8cGF0aCBkPSJNNzYgOTMgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNC43IDg3LjIgMTEyLjUpIj48cmVjdCB4PSI3Ny4zIiB5PSIxMDIuNSIgd2lkdGg9IjIwLjAiIGhlaWdodD0iMjAuMCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjgwLjMiIHkxPSIxMDYuNSIgeDI9IjkxLjIiIHkyPSIxMTQuNSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Grey Goose';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMjQ3NDU1MTgiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QwZDVkYiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTdFQ0YyIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTdFQ0YyIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDk0IEwxMzMgOTQgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMjQ3NDU1MTgpIi8+CiAgICA8cGF0aCBkPSJNNzYgMTAwIEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTcuNSAxMDguNSAxMDYuNCkiPjxyZWN0IHg9Ijk4LjIiIHk9Ijk2LjEiIHdpZHRoPSIyMC42IiBoZWlnaHQ9IjIwLjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDEuMiIgeTE9IjEwMC4xIiB4Mj0iMTEyLjgiIHkyPSIxMDguNyIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuMSAxMTAuNiAxMjYuNikiPjxyZWN0IHg9IjEwMS41IiB5PSIxMTcuNSIgd2lkdGg9IjE4LjMiIGhlaWdodD0iMTguMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNC41IiB5MT0iMTIxLjUiIHgyPSIxMTMuOCIgeTI9IjEyNy44IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjwvZz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iNTgiIHJ4PSIzNiIgcnk9IjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Belvedere Pure';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNiAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzIzMzUzNTIyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNiOGNjYmYiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0NGRTNENiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0NGRTNENiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzIzMzUzNTIyKSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSg2LjIgOTIuMSAxMDEuMikiPjxyZWN0IHg9IjgzLjEiIHk9IjkyLjIiIHdpZHRoPSIxOC4wIiBoZWlnaHQ9IjE4LjAiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4Ni4xIiB5MT0iOTYuMiIgeDI9Ijk1LjEiIHkyPSIxMDIuMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoMTAuNyA5My42IDEwNC42KSI+PHJlY3QgeD0iODMuNCIgeT0iOTQuNCIgd2lkdGg9IjIwLjQiIGhlaWdodD0iMjAuNCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg2LjQiIHkxPSI5OC40IiB4Mj0iOTcuOCIgeTI9IjEwNi44IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNy44IDg5LjUgMTIwLjApIj48cmVjdCB4PSI4MC41IiB5PSIxMTEuMCIgd2lkdGg9IjE4LjAiIGhlaWdodD0iMTguMCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjgzLjUiIHkxPSIxMTUuMCIgeDI9IjkyLjYiIHkyPSIxMjEuMCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC01IDg4IDYwKSI+CiAgICAgIDxwYXRoIGQ9Ik03MiA2MCBBMTYgMTYgMCAwIDEgMTA0IDYwIFoiIGZpbGw9IiNDRkUwQTYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KICAgICAgPHBhdGggZD0iTTc5IDU4IEw4OCA0NyBNODggNDcgTDk3IDU4IE03NSA1OSBMODggNDYgTTEwMSA1OSBMODggNDYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjEiIG9wYWNpdHk9IjAuNTUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Tanqueray';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS40IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMzI5OTQwNTEiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QyYTk3MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTlDMDhBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTlDMDhBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMzI5OTQwNTEpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDkuOCA4Ny4zIDExNS43KSI+PHJlY3QgeD0iNzguNyIgeT0iMTA3LjEiIHdpZHRoPSIxNy4xIiBoZWlnaHQ9IjE3LjEiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4MS43IiB5MT0iMTExLjEiIHgyPSI4OS45IiB5Mj0iMTE2LjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC0wLjUgOTguNiAxMDEuNykiPjxyZWN0IHg9Ijg4LjEiIHk9IjkxLjIiIHdpZHRoPSIyMS4wIiBoZWlnaHQ9IjIxLjAiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5MS4xIiB5MT0iOTUuMiIgeDI9IjEwMy4yIiB5Mj0iMTA0LjIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDYuMSAxMTAuNyAxMDIuNikiPjxyZWN0IHg9IjEwMC43IiB5PSI5Mi42IiB3aWR0aD0iMjAuMCIgaGVpZ2h0PSIyMC4wIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTAzLjciIHkxPSI5Ni42IiB4Mj0iMTE0LjgiIHkyPSIxMDQuNiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDggODggNjApIj4KICAgICAgPGNpcmNsZSBjeD0iODgiIGN5PSI2MCIgcj0iMTIiIGZpbGw9IiNGMEE5NEUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KICAgICAgPGNpcmNsZSBjeD0iODgiIGN5PSI2MCIgcj0iOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNCIvPgogICAgICA8cGF0aCBkPSJNODggNjAgTDk5LjA0IDYwLjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDk1LjgwNjQ1ODg2NDI5OTQ5IDY3LjgwNjQ1ODg2NDI5OTQ5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw4OC4wIDcxLjA0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw4MC4xOTM1NDExMzU3MDA1MSA2Ny44MDY0NTg4NjQyOTk0OSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMNzYuOTYgNjAuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMODAuMTkzNTQxMTM1NzAwNTEgNTIuMTkzNTQxMTM1NzAwNTE0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw4OC4wIDQ4Ljk2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw5NS44MDY0NTg4NjQyOTk0OSA1Mi4xOTM1NDExMzU3MDA1MTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'G''Vine June Pêche';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC43IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMTI3MTc1MjMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2I4Yzk4ZiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMTI3MTc1MjMpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDYuOCA4Ny4xIDExMS43KSI+PHJlY3QgeD0iNzguMyIgeT0iMTAyLjkiIHdpZHRoPSIxNy42IiBoZWlnaHQ9IjE3LjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4MS4zIiB5MT0iMTA2LjkiIHgyPSI4OS45IiB5Mj0iMTEyLjUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDguNiA5My42IDEwMC45KSI+PHJlY3QgeD0iODQuMiIgeT0iOTEuNSIgd2lkdGg9IjE4LjciIGhlaWdodD0iMTguNyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg3LjIiIHkxPSI5NS41IiB4Mj0iOTYuOSIgeTI9IjEwMi4zIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS43IDk1LjggMTAzLjApIj48cmVjdCB4PSI4Ny42IiB5PSI5NC43IiB3aWR0aD0iMTYuNSIgaGVpZ2h0PSIxNi41IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTAuNiIgeTE9Ijk4LjciIHgyPSI5OC4xIiB5Mj0iMTAzLjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNiA4OCA2MCkiPgogICAgICA8cGF0aCBkPSJNODggNzQgTDg4IDU0IiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICA8ZWxsaXBzZSBjeD0iODIiIGN5PSI1MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgtMjUgODIgNTIpIi8+PGVsbGlwc2UgY3g9Ijk0IiBjeT0iNTAiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgOTQgNTApIi8+PGVsbGlwc2UgY3g9Ijg4IiBjeT0iNDIiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCA4OCA0MikiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'G''Vine Floraison';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuMCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzc5NDU4ODcxIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNiOGNjYmYiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0NGRTNENiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0NGRTNENiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzc5NDU4ODcxKSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS43IDEwNC45IDEwOC42KSI+PHJlY3QgeD0iOTYuMCIgeT0iOTkuNiIgd2lkdGg9IjE3LjkiIGhlaWdodD0iMTcuOSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijk5LjAiIHkxPSIxMDMuNiIgeDI9IjEwNy45IiB5Mj0iMTA5LjUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC00LjMgMTAxLjggOTQuNikiPjxyZWN0IHg9IjkyLjYiIHk9Ijg1LjMiIHdpZHRoPSIxOC41IiBoZWlnaHQ9IjE4LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5NS42IiB5MT0iODkuMyIgeDI9IjEwNS4xIiB5Mj0iOTUuOCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuOSA5NS4zIDExNC40KSI+PHJlY3QgeD0iODUuNiIgeT0iMTA0LjciIHdpZHRoPSIxOS4zIiBoZWlnaHQ9IjE5LjMiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4OC42IiB5MT0iMTA4LjciIHgyPSI5OC45IiB5Mj0iMTE2LjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMiA4OCA2MCkiPgogICAgICA8cGF0aCBkPSJNODggNzQgTDg4IDU0IiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICA8ZWxsaXBzZSBjeD0iODIiIGN5PSI1MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgtMjUgODIgNTIpIi8+PGVsbGlwc2UgY3g9Ijk0IiBjeT0iNTAiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgOTQgNTApIi8+PGVsbGlwc2UgY3g9Ijg4IiBjeT0iNDIiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCA4OCA0MikiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Hendrick''s';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzI0MTg3NzQ2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNiMjlmYzIiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0M5QjZEOSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0M5QjZEOSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzI0MTg3NzQ2KSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNi4yIDExMi40IDEwNC43KSI+PHJlY3QgeD0iMTA0LjIiIHk9Ijk2LjYiIHdpZHRoPSIxNi4zIiBoZWlnaHQ9IjE2LjMiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDcuMiIgeTE9IjEwMC42IiB4Mj0iMTE0LjYiIHkyPSIxMDQuOSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuMSA4OC4yIDk1LjgpIj48cmVjdCB4PSI3OS4wIiB5PSI4Ni42IiB3aWR0aD0iMTguNCIgaGVpZ2h0PSIxOC40IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODIuMCIgeTE9IjkwLjYiIHgyPSI5MS40IiB5Mj0iOTcuMCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy40IDk0LjcgMTAxLjEpIj48cmVjdCB4PSI4NS4wIiB5PSI5MS40IiB3aWR0aD0iMTkuNCIgaGVpZ2h0PSIxOS40IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODguMCIgeTE9Ijk1LjQiIHgyPSI5OC41IiB5Mj0iMTAyLjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxNiA4OCA2MCkiPgogICAgICA8cGF0aCBkPSJNODggNzQgTDg4IDU0IiBzdHJva2U9IiM1QzhBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICA8ZWxsaXBzZSBjeD0iODIiIGN5PSI1MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgtMjUgODIgNTIpIi8+PGVsbGlwc2UgY3g9Ijk0IiBjeT0iNTAiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgOTQgNTApIi8+PGVsbGlwc2UgY3g9Ijg4IiBjeT0iNDIiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCA4OCA0MikiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Hendrick''s Orbium';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuOSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxoXzY2MzM3NTEyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNhMmJmOGYiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0I5RDZBNiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0I5RDZBNiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTcwIDQ2IEw3OCAxNTYgUTc4IDE2NCA4OCAxNjQgTDExMiAxNjQgUTEyMiAxNjQgMTIyIDE1NiBMMTMwIDQ2IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03NCA3MCBMMTI2IDcwIEwxMjAgMTU2IFExMjAgMTYwIDExMiAxNjAgTDg4IDE2MCBRODAgMTYwIDgwIDE1NiBaIiBmaWxsPSJ1cmwoI2xoXzY2MzM3NTEyKSIvPgogICAgPHBhdGggZD0iTTgyIDc2IEw4MiAxNTIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSg2LjkgMTEzLjMgMTExLjEpIj48cmVjdCB4PSIxMDQuMCIgeT0iMTAxLjgiIHdpZHRoPSIxOC42IiBoZWlnaHQ9IjE4LjYiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDcuMCIgeTE9IjEwNS44IiB4Mj0iMTE2LjYiIHkyPSIxMTIuNCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoOC42IDk3LjggMTAxLjcpIj48cmVjdCB4PSI4OS41IiB5PSI5My40IiB3aWR0aD0iMTYuNiIgaGVpZ2h0PSIxNi42IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTIuNSIgeTE9Ijk3LjQiIHgyPSIxMDAuMiIgeTI9IjEwMi4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMi4xIDk1LjUgMTA0LjYpIj48cmVjdCB4PSI4NS45IiB5PSI5NS4wIiB3aWR0aD0iMTkuMiIgaGVpZ2h0PSIxOS4yIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODguOSIgeTE9Ijk5LjAiIHgyPSI5OS4xIiB5Mj0iMTA2LjIiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSg4IDg4IDYwKSI+CiAgICAgIDxwYXRoIGQ9Ik04OCA3NCBMODggNTQiIHN0cm9rZT0iIzVDOEE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICAgIDxlbGxpcHNlIGN4PSI4MiIgY3k9IjUyIiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKC0yNSA4MiA1MikiLz48ZWxsaXBzZSBjeD0iOTQiIGN5PSI1MCIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgyMCA5NCA1MCkiLz48ZWxsaXBzZSBjeD0iODgiIGN5PSI0MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgwIDg4IDQyKSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'The Botanist';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi4wIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMjAxODg2MzQiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2MxYjE3MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRDhDODhBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRDhDODhBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMjAxODg2MzQpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC05LjQgMTA5LjQgMTA3LjUpIj48cmVjdCB4PSI5OS44IiB5PSI5Ny45IiB3aWR0aD0iMTkuMSIgaGVpZ2h0PSIxOS4xIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTAyLjgiIHkxPSIxMDEuOSIgeDI9IjExMi45IiB5Mj0iMTA5LjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC0wLjcgOTcuNSAxMTAuNSkiPjxyZWN0IHg9Ijg4LjUiIHk9IjEwMS41IiB3aWR0aD0iMTguMCIgaGVpZ2h0PSIxOC4wIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTEuNSIgeTE9IjEwNS41IiB4Mj0iMTAwLjUiIHkyPSIxMTEuNSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTUuNiA5OC44IDEwNi4yKSI+PHJlY3QgeD0iODguOCIgeT0iOTYuMiIgd2lkdGg9IjIwLjEiIGhlaWdodD0iMjAuMSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkxLjgiIHkxPSIxMDAuMiIgeDI9IjEwMi45IiB5Mj0iMTA4LjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtOCA4OCA2MCkiPgogICAgICA8Y2lyY2xlIGN4PSI4OCIgY3k9IjYwIiByPSIxMiIgZmlsbD0iI0YwQTk0RSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8Y2lyY2xlIGN4PSI4OCIgY3k9IjYwIiByPSI4IiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC40Ii8+CiAgICAgIDxwYXRoIGQ9Ik04OCA2MCBMOTkuMDQgNjAuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik04OCA2MCBMOTUuODA2NDU4ODY0Mjk5NDkgNjcuODA2NDU4ODY0Mjk5NDkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDg4LjAgNzEuMDQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDgwLjE5MzU0MTEzNTcwMDUxIDY3LjgwNjQ1ODg2NDI5OTQ5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw3Ni45NiA2MC4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTg4IDYwIEw4MC4xOTM1NDExMzU3MDA1MSA1Mi4xOTM1NDExMzU3MDA1MTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDg4LjAgNDguOTYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNODggNjAgTDk1LjgwNjQ1ODg2NDI5OTQ5IDUyLjE5MzU0MTEzNTcwMDUxNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Lord Of Barbès';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMTE5OTc4NTAiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzg0YTI2MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOUJCOTdBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOUJCOTdBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMTE5OTc4NTApIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC00LjYgMTAzLjggMTE3LjIpIj48cmVjdCB4PSI5NS43IiB5PSIxMDkuMiIgd2lkdGg9IjE2LjIiIGhlaWdodD0iMTYuMiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijk4LjciIHkxPSIxMTMuMiIgeDI9IjEwNS44IiB5Mj0iMTE3LjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDQuMiAxMDYuOCA5My44KSI+PHJlY3QgeD0iOTguNCIgeT0iODUuMyIgd2lkdGg9IjE2LjkiIGhlaWdodD0iMTYuOSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwMS40IiB5MT0iODkuMyIgeDI9IjEwOS4zIiB5Mj0iOTQuMiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNS4zIDg3LjIgOTUuNikiPjxyZWN0IHg9Ijc5LjEiIHk9Ijg3LjUiIHdpZHRoPSIxNi4xIiBoZWlnaHQ9IjE2LjEiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4Mi4xIiB5MT0iOTEuNSIgeDI9Ijg5LjIiIHkyPSI5NS42IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE3IDg4IDYwKSI+CiAgICAgIDxwYXRoIGQ9Ik04OCA3NCBMODggNTQiIHN0cm9rZT0iIzVDOEE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICAgIDxlbGxpcHNlIGN4PSI4MiIgY3k9IjUyIiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKC0yNSA4MiA1MikiLz48ZWxsaXBzZSBjeD0iOTQiIGN5PSI1MCIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgyMCA5NCA1MCkiLz48ZWxsaXBzZSBjeD0iODgiIGN5PSI0MiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgwIDg4IDQyKSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Monkey 47';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjNCNkQ4IiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGhfMzM2NjAyNjQiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2I4Yzk4ZiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQ0ZFMEE2IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzAgNDYgTDc4IDE1NiBRNzggMTY0IDg4IDE2NCBMMTEyIDE2NCBRMTIyIDE2NCAxMjIgMTU2IEwxMzAgNDYgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTc0IDcwIEwxMjYgNzAgTDEyMCAxNTYgUTEyMCAxNjAgMTEyIDE2MCBMODggMTYwIFE4MCAxNjAgODAgMTU2IFoiIGZpbGw9InVybCgjbGhfMzM2NjAyNjQpIi8+CiAgICA8cGF0aCBkPSJNODIgNzYgTDgyIDE1MiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDUuOSAxMDUuNCAxMDguNykiPjxyZWN0IHg9Ijk1LjgiIHk9Ijk5LjEiIHdpZHRoPSIxOS4yIiBoZWlnaHQ9IjE5LjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5OC44IiB5MT0iMTAzLjEiIHgyPSIxMDkuMCIgeTI9IjExMC4zIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtOC4zIDEwMi42IDkyLjEpIj48cmVjdCB4PSI5NC40IiB5PSI4NC4wIiB3aWR0aD0iMTYuMyIgaGVpZ2h0PSIxNi4zIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTcuNCIgeTE9Ijg4LjAiIHgyPSIxMDQuNyIgeTI9IjkyLjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDAuNSAxMDEuOCAxMDkuNikiPjxyZWN0IHg9IjkxLjgiIHk9Ijk5LjUiIHdpZHRoPSIyMC4yIiBoZWlnaHQ9IjIwLjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5NC44IiB5MT0iMTAzLjUiIHgyPSIxMDUuOSIgeTI9IjExMS42IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMTYgODggNjApIj4KICAgICAgPHBhdGggZD0iTTcyIDYwIEExNiAxNiAwIDAgMSAxMDQgNjAgWiIgZmlsbD0iI0NGRTBBNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8cGF0aCBkPSJNNzkgNTggTDg4IDQ3IE04OCA0NyBMOTcgNTggTTc1IDU5IEw4OCA0NiBNMTAxIDU5IEw4OCA0NiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMSIgb3BhY2l0eT0iMC41NSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Belle Rives';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzEyMzQ2NzA4IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNiMjgzNDMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0M5OUE1QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0M5OUE1QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NiA4MCBMMTM0IDgwIEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzEyMzQ2NzA4KSIvPgogICAgPHBhdGggZD0iTTc2IDg2IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTcuOSAxMTUuNSAxMjYuMykiPjxyZWN0IHg9IjEwNC44IiB5PSIxMTUuNiIgd2lkdGg9IjIxLjQiIGhlaWdodD0iMjEuNCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNy44IiB5MT0iMTE5LjYiIHgyPSIxMjAuMiIgeTI9IjEyOS4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS42IDEwMi44IDEyNy42KSI+PHJlY3QgeD0iOTMuMiIgeT0iMTE4LjEiIHdpZHRoPSIxOS4wIiBoZWlnaHQ9IjE5LjAiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5Ni4yIiB5MT0iMTIyLjEiIHgyPSIxMDYuMyIgeTI9IjEyOS4xIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Havana 3 ans';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMTAwMzk2MjEiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2E5NzMzMyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQzA4QTRBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQzA4QTRBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY4IDk4IEwxMzIgOTggTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMTAwMzk2MjEpIi8+CiAgICA8cGF0aCBkPSJNNzYgMTA0IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Havana Club Especial';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzExNjkxNDcxIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM5MTRjMDciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0E4NjMxRSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0E4NjMxRSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02OCA5OCBMMTMyIDk4IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzExNjkxNDcxKSIvPgogICAgPHBhdGggZD0iTTc2IDEwNCBMNzYgMTQ4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTY0IDU4IEwxMzYgNTgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIAo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Bumbu — The Original';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzE5NzIyODUzIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM3MzQzMTQiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NiA4MiBMMTM0IDgyIEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzE5NzIyODUzKSIvPgogICAgPHBhdGggZD0iTTc2IDg4IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTguMyAxMDIuNiAxMzMuMykiPjxyZWN0IHg9IjkyLjgiIHk9IjEyMy41IiB3aWR0aD0iMTkuNiIgaGVpZ2h0PSIxOS42IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTUuOCIgeTE9IjEyNy41IiB4Mj0iMTA2LjQiIHkyPSIxMzUuMSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Diplomatico — Reserva Exclusiva';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS45IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMTExODIyMjMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzYzMzMwYiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjN0E0QTIyIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjN0E0QTIyIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY2IDc4IEwxMzQgNzggTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMTExODIyMjMpIi8+CiAgICA8cGF0aCBkPSJNNzYgODQgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgxMS42IDExMi40IDEyNi40KSI+PHJlY3QgeD0iMTAyLjAiIHk9IjExNi4wIiB3aWR0aD0iMjAuOCIgaGVpZ2h0PSIyMC44IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTA1LjAiIHkxPSIxMjAuMCIgeDI9IjExNi44IiB5Mj0iMTI4LjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC05LjMgOTcuMyAxMTEuNSkiPjxyZWN0IHg9Ijg3LjAiIHk9IjEwMS4yIiB3aWR0aD0iMjAuNSIgaGVpZ2h0PSIyMC41IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTAuMCIgeTE9IjEwNS4yIiB4Mj0iMTAxLjUiIHkyPSIxMTMuNyIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48cG9seWdvbiB0cmFuc2Zvcm09InJvdGF0ZSgxNyAxMjggNjIpIiBwb2ludHM9IjEzOC4wLDYyLjAgMTM1LjEsNjkuMSAxMjguMCw3Mi4wIDEyMC45LDY5LjEgMTE4LjAsNjIuMCAxMjAuOSw1NC45IDEyOC4wLDUyLjAgMTM1LjEsNTQuOSIgZmlsbD0iIzhBNUEyQiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Millionario 15 — Reserva Especial';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzMwMzUyODI5IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM2MzMzMGIiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzdBNEEyMiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzdBNEEyMiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02OCAxMDAgTDEzMiAxMDAgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMzAzNTI4MjkpIi8+CiAgICA8cGF0aCBkPSJNNzYgMTA2IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuOCAxMDAuMyAxMTUuMSkiPjxyZWN0IHg9IjkwLjciIHk9IjEwNS41IiB3aWR0aD0iMTkuMSIgaGVpZ2h0PSIxOS4xIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTMuNyIgeTE9IjEwOS41IiB4Mj0iMTAzLjgiIHkyPSIxMTYuNiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iNTgiIHJ4PSIzNiIgcnk9IjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Santa Teresa 1796';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuOCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzQyMzQ3Njk3IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM1MzI3MDUiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NyA4NSBMMTMzIDg1IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzQyMzQ3Njk3KSIvPgogICAgPHBhdGggZD0iTTc2IDkxIEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuOSAxMTQuNCAxMzcuMykiPjxyZWN0IHg9IjEwNC43IiB5PSIxMjcuNiIgd2lkdGg9IjE5LjQiIGhlaWdodD0iMTkuNCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNy43IiB5MT0iMTMxLjYiIHgyPSIxMTguMSIgeTI9IjEzOS4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgzLjAgMTExLjUgMTA1LjcpIj48cmVjdCB4PSIxMDIuOCIgeT0iOTcuMCIgd2lkdGg9IjE3LjQiIGhlaWdodD0iMTcuNCIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjEwNS44IiB5MT0iMTAxLjAiIHgyPSIxMTQuMSIgeTI9IjEwNi4zIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtOS40IDEwNC41IDEyNS4wKSI+PHJlY3QgeD0iOTQuNyIgeT0iMTE1LjMiIHdpZHRoPSIxOS41IiBoZWlnaHQ9IjE5LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5Ny43IiB5MT0iMTE5LjMiIHgyPSIxMDguMiIgeTI9IjEyNi44IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjxwb2x5Z29uIHRyYW5zZm9ybT0icm90YXRlKC02IDEyOCA2MikiIHBvaW50cz0iMTM4LjAsNjIuMCAxMzUuMSw2OS4xIDEyOC4wLDcyLjAgMTIwLjksNjkuMSAxMTguMCw2Mi4wIDEyMC45LDU0LjkgMTI4LjAsNTIuMCAxMzUuMSw1NC45IiBmaWxsPSIjOEE1QTJCIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PC9nPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSI1OCIgcng9IjM2IiByeT0iNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjIuNSIvPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Centenario Fundacion 20';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC45IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfNDQ2ODE2NzgiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzQ1MWQwMSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjNUMzNDE4IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjNUMzNDE4IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDg0IEwxMzMgODQgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfNDQ2ODE2NzgpIi8+CiAgICA8cGF0aCBkPSJNNzYgOTAgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8L2c+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjU4IiByeD0iMzYiIHJ5PSI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMi41Ii8+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Zacapa 23';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuOCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzI4ODk1NjgxIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNhMTYyMTciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0I4NzkyRSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0I4NzkyRSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02OCA5OSBMMTMyIDk5IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzI4ODk1NjgxKSIvPgogICAgPHBhdGggZD0iTTc2IDEwNSBMNzYgMTQ4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTY0IDU4IEwxMzYgNTgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDQuOSA5Ni4xIDEwOS40KSI+PHJlY3QgeD0iODguMCIgeT0iMTAxLjIiIHdpZHRoPSIxNi4yIiBoZWlnaHQ9IjE2LjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5MS4wIiB5MT0iMTA1LjIiIHgyPSI5OC4yIiB5Mj0iMTA5LjUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDMuMCA5OC42IDExNC44KSI+PHJlY3QgeD0iODguNSIgeT0iMTA0LjciIHdpZHRoPSIyMC4zIiBoZWlnaHQ9IjIwLjMiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5MS41IiB5MT0iMTA4LjciIHgyPSIxMDIuOCIgeTI9IjExNy4wIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Monkey Shoulder';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy43IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMjU1MzEzNzciIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzkxNGMwNyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQTg2MzFFIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQTg2MzFFIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDg3IEwxMzMgODcgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMjU1MzEzNzcpIi8+CiAgICA8cGF0aCBkPSJNNzYgOTMgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMi4xIDk5LjMgMTIwLjYpIj48cmVjdCB4PSI5MC45IiB5PSIxMTIuMiIgd2lkdGg9IjE2LjciIGhlaWdodD0iMTYuNyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkzLjkiIHkxPSIxMTYuMiIgeDI9IjEwMS42IiB5Mj0iMTIxLjAiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDExLjYgOTcuOSAxMzAuMikiPjxyZWN0IHg9Ijg4LjIiIHk9IjEyMC41IiB3aWR0aD0iMTkuNCIgaGVpZ2h0PSIxOS40IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTEuMiIgeTE9IjEyNC41IiB4Mj0iMTAxLjYiIHkyPSIxMzEuOSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Maker''s Mark';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy45IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMzI3MzkxMjciIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzgzNDMwYiIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOUE1QTIyIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOUE1QTIyIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY3IDg0IEwxMzMgODQgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMzI3MzkxMjcpIi8+CiAgICA8cGF0aCBkPSJNNzYgOTAgTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgyLjggMTAxLjIgMTM1LjgpIj48cmVjdCB4PSI5Mi43IiB5PSIxMjcuMyIgd2lkdGg9IjE3LjEiIGhlaWdodD0iMTcuMSIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijk1LjciIHkxPSIxMzEuMyIgeDI9IjEwMy44IiB5Mj0iMTM2LjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKDcuOSAxMDUuMyAxMTMuMykiPjxyZWN0IHg9Ijk0LjciIHk9IjEwMi43IiB3aWR0aD0iMjEuMiIgaGVpZ2h0PSIyMS4yIiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTcuNyIgeTE9IjEwNi43IiB4Mj0iMTA5LjkiIHkyPSIxMTUuOSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMSA4NC44IDEzMi40KSI+PHJlY3QgeD0iNzYuNyIgeT0iMTI0LjQiIHdpZHRoPSIxNi4xIiBoZWlnaHQ9IjE2LjEiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI3OS43IiB5MT0iMTI4LjQiIHgyPSI4Ni44IiB5Mj0iMTMyLjUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Bulleit Rye';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzIxMDI5MTM1IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNhOTczMjMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0MwOEEzQSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0MwOEEzQSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02OCA5NiBMMTMyIDk2IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzIxMDI5MTM1KSIvPgogICAgPHBhdGggZD0iTTc2IDEwMiBMNzYgMTQ4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTY0IDU4IEwxMzYgNTgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDAuMiA5OC42IDExOC45KSI+PHJlY3QgeD0iODguNyIgeT0iMTA4LjkiIHdpZHRoPSIxOS44IiBoZWlnaHQ9IjE5LjgiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5MS43IiB5MT0iMTEyLjkiIHgyPSIxMDIuNSIgeTI9IjEyMC44IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS45IDEwMi41IDEyNy45KSI+PHJlY3QgeD0iOTIuMCIgeT0iMTE3LjMiIHdpZHRoPSIyMS4yIiBoZWlnaHQ9IjIxLjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI5NS4wIiB5MT0iMTIxLjMiIHgyPSIxMDcuMSIgeTI9IjEzMC41IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDggMTI4IDYyKSI+CiAgICAgIDxjaXJjbGUgY3g9IjEyOCIgY3k9IjYyIiByPSIxMCIgZmlsbD0iI0YwQTk0RSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMjgiIGN5PSI2MiIgcj0iNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNCIvPgogICAgICA8cGF0aCBkPSJNMTI4IDYyIEwxMzcuMiA2Mi4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTM0LjUwNTM4MjM4NjkxNjI0IDY4LjUwNTM4MjM4NjkxNjI0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTI4LjAgNzEuMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMjggNjIgTDEyMS40OTQ2MTc2MTMwODM3NiA2OC41MDUzODIzODY5MTYyNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMjggNjIgTDExOC44IDYyLjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTI4IDYyIEwxMjEuNDk0NjE3NjEzMDgzNzYgNTUuNDk0NjE3NjEzMDgzNzYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTI4IDYyIEwxMjguMCA1Mi44IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTM0LjUwNTM4MjM4NjkxNjI0IDU1LjQ5NDYxNzYxMzA4Mzc2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Glenfiddich — Triple Oak 12 ans';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC4zIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMTY3OTYyMzciIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzczNDMxNCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY2IDgyIEwxMzQgODIgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMTY3OTYyMzcpIi8+CiAgICA8cGF0aCBkPSJNNzYgODggTDc2IDE0OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDxwYXRoIGQ9Ik02NCA1OCBMMTM2IDU4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMy43IDExMi40IDEwMy4yKSI+PHJlY3QgeD0iMTAyLjIiIHk9IjkzLjEiIHdpZHRoPSIyMC4zIiBoZWlnaHQ9IjIwLjMiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDUuMiIgeTE9Ijk3LjEiIHgyPSIxMTYuNSIgeTI9IjEwNS40IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPgo8ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNy4yIDk4LjIgMTMxLjUpIj48cmVjdCB4PSI4OS4xIiB5PSIxMjIuMyIgd2lkdGg9IjE4LjMiIGhlaWdodD0iMTguMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9IjkyLjEiIHkxPSIxMjYuMyIgeDI9IjEwMS40IiB5Mj0iMTMyLjYiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC0yLjAgOTUuMCAxMTcuNCkiPjxyZWN0IHg9Ijg1LjciIHk9IjEwOC4xIiB3aWR0aD0iMTguNiIgaGVpZ2h0PSIxOC42IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODguNyIgeTE9IjExMi4xIiB4Mj0iOTguMyIgeTI9IjExOC43IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Nikka from Barrel';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNiAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzE0MzU1MTE0IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM1MzI3MDUiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NyA4OSBMMTMzIDg5IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzE0MzU1MTE0KSIvPgogICAgPHBhdGggZD0iTTc2IDk1IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy4xIDExNS41IDEyMi41KSI+PHJlY3QgeD0iMTA1LjYiIHk9IjExMi42IiB3aWR0aD0iMTkuOCIgaGVpZ2h0PSIxOS44IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iMTA4LjYiIHkxPSIxMTYuNiIgeDI9IjExOS40IiB5Mj0iMTI0LjQiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+CjxnIHRyYW5zZm9ybT0icm90YXRlKC01LjAgOTIuMCAxMzcuOCkiPjxyZWN0IHg9IjgzLjYiIHk9IjEyOS4zIiB3aWR0aD0iMTYuOSIgaGVpZ2h0PSIxNi45IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iODYuNiIgeTE9IjEzMy4zIiB4Mj0iOTQuNSIgeTI9IjEzOC4yIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC43Ii8+PC9nPjwvZz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iNTgiIHJ4PSIzNiIgcnk9IjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIyLjUiLz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Lagavulin 8 ans';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1XzE3MTg2NDE2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM2MzMzMGIiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzdBNEEyMiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzdBNEEyMiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02OCA5NSBMMTMyIDk1IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1XzE3MTg2NDE2KSIvPgogICAgPHBhdGggZD0iTTc2IDEwMSBMNzYgMTQ4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLW9wYWNpdHk9IjAuNCIvPgogICAgPHBhdGggZD0iTTY0IDU4IEwxMzYgNTgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDEuMCA4NC43IDEwOC42KSI+PHJlY3QgeD0iNzQuNSIgeT0iOTguNSIgd2lkdGg9IjIwLjIiIGhlaWdodD0iMjAuMiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijc3LjUiIHkxPSIxMDIuNSIgeDI9Ijg4LjgiIHkyPSIxMTAuNyIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC45IDk1LjkgMTE4LjUpIj48cmVjdCB4PSI4Ni43IiB5PSIxMDkuMyIgd2lkdGg9IjE4LjMiIGhlaWdodD0iMTguMyIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg5LjciIHkxPSIxMTMuMyIgeDI9Ijk5LjAiIHkyPSIxMTkuNiIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Glann Ar Mor — Bourbon Barrel';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS4zIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHVfMjk3NjE1NTEiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzczNDMxNCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjQgNTggTDcwIDE1MCBRNzAgMTYwIDgyIDE2MCBMMTE4IDE2MCBRMTMwIDE2MCAxMzAgMTUwIEwxMzYgNTggWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTY4IDk5IEwxMzIgOTkgTDEyOCAxNTAgUTEyOCAxNTQgMTIwIDE1NCBMODAgMTU0IFE3MiAxNTQgNzIgMTUwIFoiIGZpbGw9InVybCgjbHVfMjk3NjE1NTEpIi8+CiAgICA8cGF0aCBkPSJNNzYgMTA1IEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuNSAxMDcuOCAxMzQuOSkiPjxyZWN0IHg9Ijk2LjkiIHk9IjEyNC4wIiB3aWR0aD0iMjEuOCIgaGVpZ2h0PSIyMS44IiByeD0iMyIgZmlsbD0iI0ZGRkZGRiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiLz48bGluZSB4MT0iOTkuOSIgeTE9IjEyOC4wIiB4Mj0iMTEyLjciIHkyPSIxMzcuOCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoNi43IDEwNy45IDEzNy45KSI+PHJlY3QgeD0iOTguMSIgeT0iMTI4LjIiIHdpZHRoPSIxOS41IiBoZWlnaHQ9IjE5LjUiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSIxMDEuMSIgeTE9IjEzMi4yIiB4Mj0iMTExLjciIHkyPSIxMzkuNyIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz4KPGcgdHJhbnNmb3JtPSJyb3RhdGUoOC44IDk1LjEgMTE3LjkpIj48cmVjdCB4PSI4NS4wIiB5PSIxMDcuOCIgd2lkdGg9IjIwLjIiIGhlaWdodD0iMjAuMiIgcng9IjMiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC41IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGxpbmUgeDE9Ijg4LjAiIHkxPSIxMTEuOCIgeDI9Ijk5LjEiIHkyPSIxMjAuMCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNyIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMTYgMTI4IDYyKSI+CiAgICAgIDxjaXJjbGUgY3g9IjEyOCIgY3k9IjYyIiByPSIxMCIgZmlsbD0iI0YwQTk0RSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMjgiIGN5PSI2MiIgcj0iNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNCIvPgogICAgICA8cGF0aCBkPSJNMTI4IDYyIEwxMzcuMiA2Mi4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTM0LjUwNTM4MjM4NjkxNjI0IDY4LjUwNTM4MjM4NjkxNjI0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTI4LjAgNzEuMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMjggNjIgTDEyMS40OTQ2MTc2MTMwODM3NiA2OC41MDUzODIzODY5MTYyNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMjggNjIgTDExOC44IDYyLjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTI4IDYyIEwxMjEuNDk0NjE3NjEzMDgzNzYgNTUuNDk0NjE3NjEzMDgzNzYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTI4IDYyIEwxMjguMCA1Mi44IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTEyOCA2MiBMMTM0LjUwNTM4MjM4NjkxNjI0IDU1LjQ5NDYxNzYxMzA4Mzc2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+CiAgICA8L2c+PC9nPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSI1OCIgcng9IjM2IiByeT0iNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjIuNSIvPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Chivas Regal 18 ans';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuNSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9Imx1Xzg2MDg5MjYwIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM0NTFkMDEiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzVDMzQxOCIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzVDMzQxOCIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY0IDU4IEw3MCAxNTAgUTcwIDE2MCA4MiAxNjAgTDExOCAxNjAgUTEzMCAxNjAgMTMwIDE1MCBMMTM2IDU4IFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik02NyA4NSBMMTMzIDg1IEwxMjggMTUwIFExMjggMTU0IDEyMCAxNTQgTDgwIDE1NCBRNzIgMTU0IDcyIDE1MCBaIiBmaWxsPSJ1cmwoI2x1Xzg2MDg5MjYwKSIvPgogICAgPHBhdGggZD0iTTc2IDkxIEw3NiAxNDgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyIiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8cGF0aCBkPSJNNjQgNTggTDEzNiA1OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuOSA5Mi45IDEyMS43KSI+PHJlY3QgeD0iODMuMyIgeT0iMTEyLjEiIHdpZHRoPSIxOS4yIiBoZWlnaHQ9IjE5LjIiIHJ4PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxsaW5lIHgxPSI4Ni4zIiB5MT0iMTE2LjEiIHgyPSI5Ni41IiB5Mj0iMTIzLjMiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjciLz48L2c+PC9nPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSI1OCIgcng9IjM2IiByeT0iNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjIuNSIvPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Johnnie Walker — Blue Label';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzI3Njk4NzgzIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkNmQzYzgiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzI3Njk4NzgzKSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxjaXJjbGUgY3g9Ijc4LjgiIGN5PSI2Mi40IiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iODAuNiIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI4NC4wIiBjeT0iNjAuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9Ijg4LjYiIGN5PSI2MC4zIiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iOTQuMSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjU5LjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDUuOSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTEuNCIgY3k9IjYwLjMiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTYuMCIgY3k9IjYwLjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTkuNCIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxIDExMiA2NikiPgogICAgICA8cGF0aCBkPSJNOTYgNjYgQTE2IDE2IDAgMCAxIDEyOCA2NiBaIiBmaWxsPSIjQ0ZFMEE2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMDMgNjQgTDExMiA1MyBNMTEyIDUzIEwxMjEgNjQgTTk5IDY1IEwxMTIgNTIgTTEyNSA2NSBMMTEyIDUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBvcGFjaXR5PSIwLjU1Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Vecindad';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNS42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHNfMjM0OTY0MDMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QxYzI4OSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRThEOUEwIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRThEOUEwIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzggNjIgTDg2IDE0NiBRODYgMTU2IDk2IDE1NiBMMTA0IDE1NiBRMTE0IDE1NiAxMTQgMTQ2IEwxMjIgNjIgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTgxIDg4IEwxMTkgODggTDExNCAxNDYgUTExNCAxNTIgMTA2IDE1MiBMOTQgMTUyIFE4NiAxNTIgODYgMTQ2IFoiIGZpbGw9InVybCgjbHNfMjM0OTY0MDMpIi8+CiAgICA8cGF0aCBkPSJNNzggNjIgTDEyMiA2MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGNpcmNsZSBjeD0iNzguOCIgY3k9IjYyLjQiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI4MC42IiBjeT0iNjEuNiIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9Ijg0LjAiIGN5PSI2MC45IiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iODguNiIgY3k9IjYwLjMiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI5NC4xIiBjeT0iNjAuMCIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjEwMC4wIiBjeT0iNTkuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjEwNS45IiBjeT0iNjAuMCIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExMS40IiBjeT0iNjAuMyIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExNi4wIiBjeT0iNjAuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExOS40IiBjeT0iNjEuNiIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxnIHRyYW5zZm9ybT0icm90YXRlKDAgMTEyIDY2KSI+CiAgICAgIDxjaXJjbGUgY3g9IjExMiIgY3k9IjY2IiByPSIxMSIgZmlsbD0iI0YwQTk0RSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMTIiIGN5PSI2NiIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNCIvPgogICAgICA8cGF0aCBkPSJNMTEyIDY2IEwxMjIuMTIgNjYuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTIgNjYgTDExOS4xNTU5MjA2MjU2MDc4NiA3My4xNTU5MjA2MjU2MDc4NiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTIgNjYgTDExMi4wIDc2LjEyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExMiA2NiBMMTA0Ljg0NDA3OTM3NDM5MjE0IDczLjE1NTkyMDYyNTYwNzg2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExMiA2NiBMMTAxLjg4IDY2LjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTEyIDY2IEwxMDQuODQ0MDc5Mzc0MzkyMTQgNTguODQ0MDc5Mzc0MzkyMTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTEyIDY2IEwxMTIuMCA1NS44Nzk5OTk5OTk5OTk5OTUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTEyIDY2IEwxMTkuMTU1OTIwNjI1NjA3ODYgNTguODQ0MDc5Mzc0MzkyMTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Mezcal Union — Uno Joven';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC4zIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHNfMjM1ODE5NjAiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2Q2ZDNjOCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRURFQURGIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRURFQURGIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzggNjIgTDg2IDE0NiBRODYgMTU2IDk2IDE1NiBMMTA0IDE1NiBRMTE0IDE1NiAxMTQgMTQ2IEwxMjIgNjIgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTgxIDg4IEwxMTkgODggTDExNCAxNDYgUTExNCAxNTIgMTA2IDE1MiBMOTQgMTUyIFE4NiAxNTIgODYgMTQ2IFoiIGZpbGw9InVybCgjbHNfMjM1ODE5NjApIi8+CiAgICA8cGF0aCBkPSJNNzggNjIgTDEyMiA2MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPGNpcmNsZSBjeD0iNzguOCIgY3k9IjYyLjQiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI4MC42IiBjeT0iNjEuNiIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9Ijg0LjAiIGN5PSI2MC45IiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iODguNiIgY3k9IjYwLjMiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI5NC4xIiBjeT0iNjAuMCIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjEwMC4wIiBjeT0iNTkuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjEwNS45IiBjeT0iNjAuMCIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExMS40IiBjeT0iNjAuMyIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExNi4wIiBjeT0iNjAuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9IjExOS40IiBjeT0iNjEuNiIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxnIHRyYW5zZm9ybT0icm90YXRlKDIwIDExMiA2NikiPgogICAgICA8cGF0aCBkPSJNOTYgNjYgQTE2IDE2IDAgMCAxIDEyOCA2NiBaIiBmaWxsPSIjQ0ZFMEE2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMDMgNjQgTDExMiA1MyBNMTEyIDUzIEwxMjEgNjQgTTk5IDY1IEwxMTIgNTIgTTEyNSA2NSBMMTEyIDUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBvcGFjaXR5PSIwLjU1Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Calle 23 — Blanco';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzMxNjg4MzU5IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMTkyMzciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q4QTk0RSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q4QTk0RSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzMxNjg4MzU5KSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC04IDExMiA2NikiPgogICAgICA8cGF0aCBkPSJNOTYgNjYgQTE2IDE2IDAgMCAxIDEyOCA2NiBaIiBmaWxsPSIjQ0ZFMEE2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMDMgNjQgTDExMiA1MyBNMTEyIDUzIEwxMjEgNjQgTTk5IDY1IEwxMTIgNTIgTTEyNSA2NSBMMTEyIDUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBvcGFjaXR5PSIwLjU1Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Calle 23 — Reposado';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzMzMTM1MDYxIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMmFiMzciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzMzMTM1MDYxKSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxjaXJjbGUgY3g9Ijc4LjgiIGN5PSI2Mi40IiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iODAuNiIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI4NC4wIiBjeT0iNjAuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9Ijg4LjYiIGN5PSI2MC4zIiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iOTQuMSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjU5LjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDUuOSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTEuNCIgY3k9IjYwLjMiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTYuMCIgY3k9IjYwLjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTkuNCIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgyMiAxMTIgNjYpIj4KICAgICAgPGNpcmNsZSBjeD0iMTEyIiBjeT0iNjYiIHI9IjExIiBmaWxsPSIjRjBBOTRFIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxjaXJjbGUgY3g9IjExMiIgY3k9IjY2IiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC40Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMTIgNjYgTDEyMi4xMiA2Ni4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExMiA2NiBMMTE5LjE1NTkyMDYyNTYwNzg2IDczLjE1NTkyMDYyNTYwNzg2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExMiA2NiBMMTEyLjAgNzYuMTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTEyIDY2IEwxMDQuODQ0MDc5Mzc0MzkyMTQgNzMuMTU1OTIwNjI1NjA3ODYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTEyIDY2IEwxMDEuODggNjYuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTIgNjYgTDEwNC44NDQwNzkzNzQzOTIxNCA1OC44NDQwNzkzNzQzOTIxNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTIgNjYgTDExMi4wIDU1Ljg3OTk5OTk5OTk5OTk5NSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTIgNjYgTDExOS4xNTU5MjA2MjU2MDc4NiA1OC44NDQwNzkzNzQzOTIxNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Mezcal Mahani';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzE1MjQzNjQ1IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkNmQzYzgiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzE1MjQzNjQ1KSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxjaXJjbGUgY3g9Ijc4LjgiIGN5PSI2Mi40IiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iODAuNiIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSI4NC4wIiBjeT0iNjAuOSIgcj0iMS4xNSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuNCIvPjxjaXJjbGUgY3g9Ijg4LjYiIGN5PSI2MC4zIiByPSIxLjE1IiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC40Ii8+PGNpcmNsZSBjeD0iOTQuMSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjU5LjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMDUuOSIgY3k9IjYwLjAiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTEuNCIgY3k9IjYwLjMiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTYuMCIgY3k9IjYwLjkiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48Y2lyY2xlIGN4PSIxMTkuNCIgY3k9IjYxLjYiIHI9IjEuMTUiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjQiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgyMSAxMTIgNjYpIj4KICAgICAgPHBhdGggZD0iTTk2IDY2IEExNiAxNiAwIDAgMSAxMjggNjYgWiIgZmlsbD0iI0NGRTBBNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8cGF0aCBkPSJNMTAzIDY0IEwxMTIgNTMgTTExMiA1MyBMMTIxIDY0IE05OSA2NSBMMTEyIDUyIE0xMjUgNjUgTDExMiA1MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMSIgb3BhY2l0eT0iMC41NSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Patron — Silver';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTYuMCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzE3NTQwMzgzIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMmMyNTMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzE3NTQwMzgzKSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDE0IDExMiA2NikiPgogICAgICA8cGF0aCBkPSJNOTYgNjYgQTE2IDE2IDAgMCAxIDEyOCA2NiBaIiBmaWxsPSIjQ0ZFMEE2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMDMgNjQgTDExMiA1MyBNMTEyIDUzIEwxMjEgNjQgTTk5IDY1IEwxMTIgNTIgTTEyNSA2NSBMMTEyIDUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBvcGFjaXR5PSIwLjU1Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Cachaça Leblon';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzMwOTc1NTU4IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkNmQzYzgiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0VERUFERiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzMwOTc1NTU4KSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC04IDExMiA2NikiPgogICAgICA8cGF0aCBkPSJNOTYgNjYgQTE2IDE2IDAgMCAxIDEyOCA2NiBaIiBmaWxsPSIjQ0ZFMEE2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMDMgNjQgTDExMiA1MyBNMTEyIDUzIEwxMjEgNjQgTTk5IDY1IEwxMTIgNTIgTTEyNSA2NSBMMTEyIDUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBvcGFjaXR5PSIwLjU1Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Pisco La Caravedo';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuNSAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzExMzY1MTg2IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMmMyNTMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U5RDk2QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzExMzY1MTg2KSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Limoncello Walcher';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuMCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzE1OTAyNTQwIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM0NTczMzMiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzVDOEE0QSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzVDOEE0QSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzE1OTAyNTQwKSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKDkgMTEyIDY2KSI+CiAgICAgIDxwYXRoIGQ9Ik0xMTIgODAgTDExMiA2MCIgc3Ryb2tlPSIjNUM4QTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgICAgPGVsbGlwc2UgY3g9IjEwNiIgY3k9IjU4IiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKC0yNSAxMDYgNTgpIi8+PGVsbGlwc2UgY3g9IjExOCIgY3k9IjU2IiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKDIwIDExOCA1NikiLz48ZWxsaXBzZSBjeD0iMTEyIiBjeT0iNDgiIHJ4PSI2IiByeT0iOSIgZmlsbD0iIzhGQkY2RiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIgdHJhbnNmb3JtPSJyb3RhdGUoMCAxMTIgNDgpIi8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'La Menteuse — Crème de Menthe';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy45IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHNfNzU0NTU5ODIiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QyYzI1MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTlEOTZBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTlEOTZBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzggNjIgTDg2IDE0NiBRODYgMTU2IDk2IDE1NiBMMTA0IDE1NiBRMTE0IDE1NiAxMTQgMTQ2IEwxMjIgNjIgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTgxIDg4IEwxMTkgODggTDExNCAxNDYgUTExNCAxNTIgMTA2IDE1MiBMOTQgMTUyIFE4NiAxNTIgODYgMTQ2IFoiIGZpbGw9InVybCgjbHNfNzU0NTU5ODIpIi8+CiAgICA8cGF0aCBkPSJNNzggNjIgTDEyMiA2MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'La Pulpeuse — Crème de citron';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTMuMCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxuXzI2MDI0MTY4IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM3MzQzMTQiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPGNsaXBQYXRoIGlkPSJjbl8yNjAyNDE2OCI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjkyIiByeD0iNDIiIHJ5PSI0MCIvPjwvY2xpcFBhdGg+CiAgICA8ZyBjbGlwLXBhdGg9InVybCgjY25fMjYwMjQxNjgpIj4KICAgICAgPHJlY3QgeD0iNTQiIHk9Ijk4IiB3aWR0aD0iOTIiIGhlaWdodD0iNTAiIGZpbGw9InVybCgjbG5fMjYwMjQxNjgpIi8+CiAgICA8L2c+CiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggNTggUTEwMCA0OCAxMjIgNTgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgMTMwIEwxMDAgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTUyIEwxMjIgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03MiA2NiBRNjggODggODQgMTA2IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Bas Armagnac';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibG5fMjM1MTE2OTMiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzYzMjczMyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjN0EzRTRBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjN0EzRTRBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8Y2xpcFBhdGggaWQ9ImNuXzIzNTExNjkzIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIi8+PC9jbGlwUGF0aD4KICAgIDxnIGNsaXAtcGF0aD0idXJsKCNjbl8yMzUxMTY5MykiPgogICAgICA8cmVjdCB4PSI1NCIgeT0iOTgiIHdpZHRoPSI5MiIgaGVpZ2h0PSI1MCIgZmlsbD0idXJsKCNsbl8yMzUxMTY5MykiLz4KICAgIDwvZz4KICAgIDxlbGxpcHNlIGN4PSIxMDAiIGN5PSI5MiIgcng9IjQyIiByeT0iNDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCA1OCBRMTAwIDQ4IDEyMiA1OCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTEwMCAxMzAgTDEwMCAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNTIgTDEyMiAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTcyIDY2IFE2OCA4OCA4NCAxMDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Vieille Prune';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuNiAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxuXzI0NDEzNzU5IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNjMmFiMzciIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0Q5QzI0RSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPGNsaXBQYXRoIGlkPSJjbl8yNDQxMzc1OSI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjkyIiByeD0iNDIiIHJ5PSI0MCIvPjwvY2xpcFBhdGg+CiAgICA8ZyBjbGlwLXBhdGg9InVybCgjY25fMjQ0MTM3NTkpIj4KICAgICAgPHJlY3QgeD0iNTQiIHk9Ijk4IiB3aWR0aD0iOTIiIGhlaWdodD0iNTAiIGZpbGw9InVybCgjbG5fMjQ0MTM3NTkpIi8+CiAgICA8L2c+CiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggNTggUTEwMCA0OCAxMjIgNTgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgMTMwIEwxMDAgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTUyIEwxMjIgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03MiA2NiBRNjggODggODQgMTA2IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Poire Williams';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS41IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibG5fMTA4ODAxMjUiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzczNDMxNCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOEE1QTJCIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8Y2xpcFBhdGggaWQ9ImNuXzEwODgwMTI1Ij48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIi8+PC9jbGlwUGF0aD4KICAgIDxnIGNsaXAtcGF0aD0idXJsKCNjbl8xMDg4MDEyNSkiPgogICAgICA8cmVjdCB4PSI1NCIgeT0iOTgiIHdpZHRoPSI5MiIgaGVpZ2h0PSI1MCIgZmlsbD0idXJsKCNsbl8xMDg4MDEyNSkiLz4KICAgIDwvZz4KICAgIDxlbGxpcHNlIGN4PSIxMDAiIGN5PSI5MiIgcng9IjQyIiByeT0iNDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCA1OCBRMTAwIDQ4IDEyMiA1OCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTEwMCAxMzAgTDEwMCAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNTIgTDEyMiAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTcyIDY2IFE2OCA4OCA4NCAxMDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Amaretto Walcher';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNC4zIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibHNfMjgwMzcxNDciIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2Q2ZDNjOCIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRURFQURGIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRURFQURGIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNzggNjIgTDg2IDE0NiBRODYgMTU2IDk2IDE1NiBMMTA0IDE1NiBRMTE0IDE1NiAxMTQgMTQ2IEwxMjIgNjIgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTgxIDg4IEwxMTkgODggTDExNCAxNDYgUTExNCAxNTIgMTA2IDE1MiBMOTQgMTUyIFE4NiAxNTIgODYgMTQ2IFoiIGZpbGw9InVybCgjbHNfMjgwMzcxNDcpIi8+CiAgICA8cGF0aCBkPSJNNzggNjIgTDEyMiA2MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Nardini Grappa';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgCiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxuXzUyMTA4MjQ1IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM3MzQzMTQiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzhBNUEyQiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPGNsaXBQYXRoIGlkPSJjbl81MjEwODI0NSI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjkyIiByeD0iNDIiIHJ5PSI0MCIvPjwvY2xpcFBhdGg+CiAgICA8ZyBjbGlwLXBhdGg9InVybCgjY25fNTIxMDgyNDUpIj4KICAgICAgPHJlY3QgeD0iNTQiIHk9Ijk4IiB3aWR0aD0iOTIiIGhlaWdodD0iNTAiIGZpbGw9InVybCgjbG5fNTIxMDgyNDUpIi8+CiAgICA8L2c+CiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggNTggUTEwMCA0OCAxMjIgNTgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgMTMwIEwxMDAgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTUyIEwxMjIgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03MiA2NiBRNjggODggODQgMTA2IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICAKPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Cognac Camus — VS';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibG5fMzk0NzQzMTUiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzkxNGMwNyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQTg2MzFFIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQTg2MzFFIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8Y2xpcFBhdGggaWQ9ImNuXzM5NDc0MzE1Ij48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIi8+PC9jbGlwUGF0aD4KICAgIDxnIGNsaXAtcGF0aD0idXJsKCNjbl8zOTQ3NDMxNSkiPgogICAgICA8cmVjdCB4PSI1NCIgeT0iOTgiIHdpZHRoPSI5MiIgaGVpZ2h0PSI1MCIgZmlsbD0idXJsKCNsbl8zOTQ3NDMxNSkiLz4KICAgIDwvZz4KICAgIDxlbGxpcHNlIGN4PSIxMDAiIGN5PSI5MiIgcng9IjQyIiByeT0iNDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCA1OCBRMTAwIDQ4IDEyMiA1OCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTEwMCAxMzAgTDEwMCAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNTIgTDEyMiAxNTIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTcyIDY2IFE2OCA4OCA4NCAxMDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Calvados Coquerel — XO';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQuMiAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxzXzEzMDM0MzQzIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM3OGE4NTgiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzhGQkY2RiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTc4IDYyIEw4NiAxNDYgUTg2IDE1NiA5NiAxNTYgTDEwNCAxNTYgUTExNCAxNTYgMTE0IDE0NiBMMTIyIDYyIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04MSA4OCBMMTE5IDg4IEwxMTQgMTQ2IFExMTQgMTUyIDEwNiAxNTIgTDk0IDE1MiBRODYgMTUyIDg2IDE0NiBaIiBmaWxsPSJ1cmwoI2xzXzEzMDM0MzQzKSIvPgogICAgPHBhdGggZD0iTTc4IDYyIEwxMjIgNjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Chartreuse Verte';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNCAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxuXzI3NDA4NjQ5IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiM1MzI3MDUiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzZBM0UxQyIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPGNsaXBQYXRoIGlkPSJjbl8yNzQwODY0OSI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjkyIiByeD0iNDIiIHJ5PSI0MCIvPjwvY2xpcFBhdGg+CiAgICA8ZyBjbGlwLXBhdGg9InVybCgjY25fMjc0MDg2NDkpIj4KICAgICAgPHJlY3QgeD0iNTQiIHk9Ijk4IiB3aWR0aD0iOTIiIGhlaWdodD0iNTAiIGZpbGw9InVybCgjbG5fMjc0MDg2NDkpIi8+CiAgICA8L2c+CiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iOTIiIHJ4PSI0MiIgcnk9IjQwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggNTggUTEwMCA0OCAxMjIgNTgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgMTMwIEwxMDAgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTUyIEwxMjIgMTUyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03MiA2NiBRNjggODggODQgMTA2IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC40Ii8+CiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iNTQiIHJ4PSI0NCIgcnk9IjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIyLjUiLz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Hennessy VS';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoNS4wIDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGFfMTY2MjAxMDQiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QxYzI4OSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRThEOUEwIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRThEOUEwIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9InVybCgjbGFfMTY2MjAxMDQpIi8+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTAgTDEwMCAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNDIgTDEyMiAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoOCAxMTYgNDQpIj4KICAgICAgPGNpcmNsZSBjeD0iMTE2IiBjeT0iNDQiIHI9IjEwIiBmaWxsPSIjRjBBOTRFIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi41Ii8+CiAgICAgIDxjaXJjbGUgY3g9IjExNiIgY3k9IjQ0IiByPSI2IiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC40Ii8+CiAgICAgIDxwYXRoIGQ9Ik0xMTYgNDQgTDEyNS4yIDQ0LjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTE2IDQ0IEwxMjIuNTA1MzgyMzg2OTE2MjQgNTAuNTA1MzgyMzg2OTE2MjQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTE2IDQ0IEwxMTYuMCA1My4yIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExNiA0NCBMMTA5LjQ5NDYxNzYxMzA4Mzc2IDUwLjUwNTM4MjM4NjkxNjI0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExNiA0NCBMMTA2LjggNDQuMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTYgNDQgTDEwOS40OTQ2MTc2MTMwODM3NiAzNy40OTQ2MTc2MTMwODM3NiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTYgNDQgTDExNi4wIDM0LjgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTE2IDQ0IEwxMjIuNTA1MzgyMzg2OTE2MjQgMzcuNDk0NjE3NjEzMDgzNzYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz4KICAgIDwvZz48L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'drinks' and name = 'Lillet blanc';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGFfMzIyMDU0ODkiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2QyYzI1MyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjRTlEOTZBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRTlEOTZBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9InVybCgjbGFfMzIyMDU0ODkpIi8+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTAgTDEwMCAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNDIgTDEyMiAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Dolin blanc';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMy42IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGFfMjg3NjI4NDIiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzczMjczMyIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjOEEzRTRBIiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjOEEzRTRBIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9InVybCgjbGFfMjg3NjI4NDIpIi8+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTAgTDEwMCAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNDIgTDEyMiAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Dolin Rouge';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTUuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxhXzE0OTY5MDkyIiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiNkMWMyODkiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iI0U4RDlBMCIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0U4RDlBMCIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY4IDQyIEwxMzIgNDIgTDEwMCA5MCBaIiBmaWxsPSJ1cmwoI2xhXzE0OTY5MDkyKSIvPgogICAgPHBhdGggZD0iTTY4IDQyIEwxMzIgNDIgTDEwMCA5MCBaIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNMTAwIDkwIEwxMDAgMTQyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTQyIEwxMjIgMTQyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxnIHRyYW5zZm9ybT0icm90YXRlKC01IDExNiA0NCkiPgogICAgICA8cGF0aCBkPSJNMTE2IDU4IEwxMTYgMzgiIHN0cm9rZT0iIzVDOEE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICAgIDxlbGxpcHNlIGN4PSIxMTAiIGN5PSIzNiIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgtMjUgMTEwIDM2KSIvPjxlbGxpcHNlIGN4PSIxMjIiIGN5PSIzNCIgcng9IjYiIHJ5PSI5IiBmaWxsPSIjOEZCRjZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40IiB0cmFuc2Zvcm09InJvdGF0ZSgyMCAxMjIgMzQpIi8+PGVsbGlwc2UgY3g9IjExNiIgY3k9IjI2IiByeD0iNiIgcnk9IjkiIGZpbGw9IiM4RkJGNkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjQiIHRyYW5zZm9ybT0icm90YXRlKDAgMTE2IDI2KSIvPgogICAgPC9nPjwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Ricard';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTAuMyAxMDAgMTAwKSI+CiAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxhXzE4MzUyMDI0IiB4MT0iMCIgeTE9IjAiIHgyPSIwIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0iMCUiIHN0b3AtY29sb3I9IiMzMzE3MGIiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICA8c3RvcCBvZmZzZXQ9IjU1JSIgc3RvcC1jb2xvcj0iIzRBMkUyMiIgc3RvcC1vcGFjaXR5PSIwLjkyIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzRBMkUyMiIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogICAgPHBhdGggZD0iTTY4IDQyIEwxMzIgNDIgTDEwMCA5MCBaIiBmaWxsPSJ1cmwoI2xhXzE4MzUyMDI0KSIvPgogICAgPHBhdGggZD0iTTY4IDQyIEwxMzIgNDIgTDEwMCA5MCBaIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNMTAwIDkwIEwxMDAgMTQyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNNzggMTQyIEwxMjIgMTQyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'drinks' and name = 'Cynar';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS44IDEwMCAxMDApIj4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0ibGFfMjY1NTE5NTQiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iIzliMjMzMSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOTIiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9InVybCgjbGFfMjY1NTE5NTQpIi8+CiAgICA8cGF0aCBkPSJNNjggNDIgTDEzMiA0MiBMMTAwIDkwIFoiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik0xMDAgOTAgTDEwMCAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik03OCAxNDIgTDEyMiAxNDIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMTIgMTE2IDQ0KSI+CiAgICAgIDxjaXJjbGUgY3g9IjExNiIgY3k9IjQ0IiByPSIxMCIgZmlsbD0iI0YwQTk0RSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNSIvPgogICAgICA8Y2lyY2xlIGN4PSIxMTYiIGN5PSI0NCIgcj0iNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNCIvPgogICAgICA8cGF0aCBkPSJNMTE2IDQ0IEwxMjUuMiA0NC4wIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExNiA0NCBMMTIyLjUwNTM4MjM4NjkxNjI0IDUwLjUwNTM4MjM4NjkxNjI0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExNiA0NCBMMTE2LjAgNTMuMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTYgNDQgTDEwOS40OTQ2MTc2MTMwODM3NiA1MC41MDUzODIzODY5MTYyNCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIG9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik0xMTYgNDQgTDEwNi44IDQ0LjAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTE2IDQ0IEwxMDkuNDk0NjE3NjEzMDgzNzYgMzcuNDk0NjE3NjEzMDgzNzYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBvcGFjaXR5PSIwLjUiLz48cGF0aCBkPSJNMTE2IDQ0IEwxMTYuMCAzNC44IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+PHBhdGggZD0iTTExNiA0NCBMMTIyLjUwNTM4MjM4NjkxNjI0IDM3LjQ5NDYxNzYxMzA4Mzc2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgb3BhY2l0eT0iMC41Ii8+CiAgICA8L2c+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'drinks' and name = 'Campari';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMi4yIDEwMCAxMDApIj4KICAgIDxwYXRoIGQ9Ik05MiAyMiBMOTIgNDggUTcwIDY0IDcwIDk2IEw3MCAxNjggUTcwIDE3OCA4MiAxNzggTDExOCAxNzggUTEzMCAxNzggMTMwIDE2OCBMMTMwIDk2IFExMzAgNjQgMTA4IDQ4IEwxMDggMjIgWiIKICAgICAgZmlsbD0iI0U3QTlDNCIgZmlsbC1vcGFjaXR5PSIwLjIyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNOTIgMjIgTDEwOCAyMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTk2IDI2IEw5NiA0NiIgc3Ryb2tlPSIjQjIzQTQ4IiBzdHJva2Utd2lkdGg9IjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTc4IDkwIEw3OCAxNjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjM1Ii8+CiAgICAKICAgIDxyZWN0IHg9IjcwIiB5PSIxMTgiIHdpZHRoPSI2MCIgaGVpZ2h0PSIzNiIgcng9IjQiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz4KICAgIDxsaW5lIHgxPSI3OCIgeTE9IjEyNyIgeDI9IjEyMiIgeTI9IjEyNyIgc3Ryb2tlPSIjQjIzQTQ4IiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGxpbmUgeDE9Ijc4IiB5MT0iMTQ1IiB4Mj0iMTIyIiB5Mj0iMTQ1IiBzdHJva2U9IiNCMjNBNDgiIHN0cm9rZS13aWR0aD0iMS42Ii8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjEzNi4wIiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiNCMjNBNDgiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgCiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'bottles' and name = 'Côtes de Provence AOP — Minuty Prestige 2024';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNiAxMDAgMTAwKSI+CiAgICA8cGF0aCBkPSJNOTIgMjIgTDkyIDQ4IFE3MCA2NCA3MCA5NiBMNzAgMTY4IFE3MCAxNzggODIgMTc4IEwxMTggMTc4IFExMzAgMTc4IDEzMCAxNjggTDEzMCA5NiBRMTMwIDY0IDEwOCA0OCBMMTA4IDIyIFoiCiAgICAgIGZpbGw9IiNFOEQ5QTAiIGZpbGwtb3BhY2l0eT0iMC4yMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTkyIDIyIEwxMDggMjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik05NiAyNiBMOTYgNDYiIHN0cm9rZT0iIzhBN0EyRSIgc3Ryb2tlLXdpZHRoPSI0IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03OCA5MCBMNzggMTY4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC4zNSIvPgogICAgCiAgICA8cmVjdCB4PSI3MCIgeT0iMTE4IiB3aWR0aD0iNjAiIGhlaWdodD0iMzYiIHJ4PSI0IiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40Ii8+CiAgICA8bGluZSB4MT0iNzgiIHkxPSIxMjciIHgyPSIxMjIiIHkyPSIxMjciIHN0cm9rZT0iIzhBN0EyRSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz4KICAgIDxsaW5lIHgxPSI3OCIgeTE9IjE0NSIgeDI9IjEyMiIgeTI9IjE0NSIgc3Ryb2tlPSIjOEE3QTJFIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGNpcmNsZSBjeD0iMTAwLjAiIGN5PSIxMzYuMCIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjOEE3QTJFIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIAogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'bottles' and name = 'Pouilly-Fumé AOP — Domaine Minet';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC45IDEwMCAxMDApIj4KICAgIDxwYXRoIGQ9Ik05MiAyMiBMOTIgNDggUTcwIDY0IDcwIDk2IEw3MCAxNjggUTcwIDE3OCA4MiAxNzggTDExOCAxNzggUTEzMCAxNzggMTMwIDE2OCBMMTMwIDk2IFExMzAgNjQgMTA4IDQ4IEwxMDggMjIgWiIKICAgICAgZmlsbD0iIzVBMjIzMyIgZmlsbC1vcGFjaXR5PSIwLjIyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNOTIgMjIgTDEwOCAyMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTk2IDI2IEw5NiA0NiIgc3Ryb2tlPSIjN0EyMzMzIiBzdHJva2Utd2lkdGg9IjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTc4IDkwIEw3OCAxNjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjM1Ii8+CiAgICAKICAgIDxyZWN0IHg9IjcwIiB5PSIxMTgiIHdpZHRoPSI2MCIgaGVpZ2h0PSIzNiIgcng9IjQiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz4KICAgIDxsaW5lIHgxPSI3OCIgeTE9IjEyNyIgeDI9IjEyMiIgeTI9IjEyNyIgc3Ryb2tlPSIjN0EyMzMzIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGxpbmUgeDE9Ijc4IiB5MT0iMTQ1IiB4Mj0iMTIyIiB5Mj0iMTQ1IiBzdHJva2U9IiM3QTIzMzMiIHN0cm9rZS13aWR0aD0iMS42Ii8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjEzNi4wIiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiM3QTIzMzMiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgCiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'bottles' and name = 'Saint-Amour AOP — Domaine des Pierres 2023/24';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuNyAxMDAgMTAwKSI+CiAgICA8cGF0aCBkPSJNOTQgMjAgTDk0IDQ2IFE3MiA2MiA3MiA5MiBMNzIgMTY4IFE3MiAxNzggODIgMTc4IEwxMTggMTc4IFExMjggMTc4IDEyOCAxNjggTDEyOCA5MiBRMTI4IDYyIDEwNiA0NiBMMTA2IDIwIFoiCiAgICAgIGZpbGw9IiM1QjZBM0EiIGZpbGwtb3BhY2l0eT0iMC4yNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg0IDIyIFExMDAgMTIgMTE2IDIyIiBmaWxsPSJub25lIiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMy41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik04MCA4OCBMODAgMTY4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC4zNSIvPgogICAgCiAgICA8cmVjdCB4PSI3MiIgeT0iMTIyIiB3aWR0aD0iNTYiIGhlaWdodD0iMzQiIHJ4PSI0IiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40Ii8+CiAgICA8bGluZSB4MT0iODAiIHkxPSIxMzEiIHgyPSIxMjAiIHkyPSIxMzEiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIxLjYiLz4KICAgIDxsaW5lIHgxPSI4MCIgeTE9IjE0NyIgeDI9IjEyMCIgeTI9IjE0NyIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGNpcmNsZSBjeD0iMTAwLjAiIGN5PSIxMzkuMCIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIAogICAgPHBhdGggZD0iTTg0IDIxIEExNiA5IDAgMCAwIDExNiAyMSIgZmlsbD0iI0M5QTI0QiIgZmlsbC1vcGFjaXR5PSIwLjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+CiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'bottles' and name = 'Champagne Richard — Brut';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMC45IDEwMCAxMDApIj4KICAgIDxwYXRoIGQ9Ik05NCAyMCBMOTQgNDYgUTcyIDYyIDcyIDkyIEw3MiAxNjggUTcyIDE3OCA4MiAxNzggTDExOCAxNzggUTEyOCAxNzggMTI4IDE2OCBMMTI4IDkyIFExMjggNjIgMTA2IDQ2IEwxMDYgMjAgWiIKICAgICAgZmlsbD0iIzVCNkEzQSIgZmlsbC1vcGFjaXR5PSIwLjI1IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNODQgMjIgUTEwMCAxMiAxMTYgMjIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5QTI0QiIgc3Ryb2tlLXdpZHRoPSIzLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgPHBhdGggZD0iTTgwIDg4IEw4MCAxNjgiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjM1Ii8+CiAgICAKICAgIDxyZWN0IHg9IjcyIiB5PSIxMjIiIHdpZHRoPSI1NiIgaGVpZ2h0PSIzNCIgcng9IjQiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz4KICAgIDxsaW5lIHgxPSI4MCIgeTE9IjEzMSIgeDI9IjEyMCIgeTI9IjEzMSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGxpbmUgeDE9IjgwIiB5MT0iMTQ3IiB4Mj0iMTIwIiB5Mj0iMTQ3IiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMS42Ii8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjEzOS4wIiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgCiAgICA8cGF0aCBkPSJNODQgMjEgQTE2IDkgMCAwIDAgMTE2IDIxIiBmaWxsPSIjQzlBMjRCIiBmaWxsLW9wYWNpdHk9IjAuNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIDwvZz4KPC9zdmc+'
   where venue_id = p_venue and universe = 'bottles' and name = 'Moët & Chandon — Brut Impérial';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS43IDEwMCAxMDApIj4KICAgIDxwYXRoIGQ9Ik04NCAyNiBMODQgNDQgUTY2IDUwIDY2IDY4IEw2NiAxNjggUTY2IDE3OCA3NiAxNzggTDEyNCAxNzggUTEzNCAxNzggMTM0IDE2OCBMMTM0IDY4IFExMzQgNTAgMTE2IDQ0IEwxMTYgMjYgWiIKICAgICAgZmlsbD0iI0RDRTNFQyIgZmlsbC1vcGFjaXR5PSIwLjMwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNODQgMjYgTDExNiAyNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg4IDI4IEwxMTIgMjgiIHN0cm9rZT0iIzNBNUE4QSIgc3Ryb2tlLXdpZHRoPSI0IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03NCA3NiBMNzQgMTY4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC4zNSIvPgogICAgCiAgICA8cmVjdCB4PSI3OCIgeT0iOTYiIHdpZHRoPSI0NCIgaGVpZ2h0PSI0MiIgcng9IjQiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz4KICAgIDxsaW5lIHgxPSI4NiIgeTE9IjEwNSIgeDI9IjExNCIgeTI9IjEwNSIgc3Ryb2tlPSIjM0E1QThBIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGxpbmUgeDE9Ijg2IiB5MT0iMTI5IiB4Mj0iMTE0IiB5Mj0iMTI5IiBzdHJva2U9IiMzQTVBOEEiIHN0cm9rZS13aWR0aD0iMS42Ii8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjExNy4wIiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiMzQTVBOEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgCiAgICA8L2c+Cjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'bottles' and name = 'Vodka Absolut';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoMS42IDEwMCAxMDApIj4KICAgIDxwYXRoIGQ9Ik04NCAyNiBMODQgNDQgUTY2IDUwIDY2IDY4IEw2NiAxNjggUTY2IDE3OCA3NiAxNzggTDEyNCAxNzggUTEzNCAxNzggMTM0IDE2OCBMMTM0IDY4IFExMzQgNTAgMTE2IDQ0IEwxMTYgMjYgWiIKICAgICAgZmlsbD0iI0UzRTlGMCIgZmlsbC1vcGFjaXR5PSIwLjMwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+CiAgICA8cGF0aCBkPSJNODQgMjYgTDExNiAyNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg4IDI4IEwxMTIgMjgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSI0IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgIDxwYXRoIGQ9Ik03NCA3NiBMNzQgMTY4IiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Utb3BhY2l0eT0iMC4zNSIvPgogICAgCiAgICA8cmVjdCB4PSI3OCIgeT0iOTYiIHdpZHRoPSI0NCIgaGVpZ2h0PSI0MiIgcng9IjQiIGZpbGw9IiNGN0YxRTkiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz4KICAgIDxsaW5lIHgxPSI4NiIgeTE9IjEwNSIgeDI9IjExNCIgeTI9IjEwNSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGxpbmUgeDE9Ijg2IiB5MT0iMTI5IiB4Mj0iMTE0IiB5Mj0iMTI5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42Ii8+CiAgICA8Y2lyY2xlIGN4PSIxMDAuMCIgY3k9IjExNy4wIiByPSI3IiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgCiAgICA8ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTc2IiByeD0iMzIiIHJ5PSI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNDOUEyNEIiIHN0cm9rZS13aWR0aD0iMi41Ii8+PC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'bottles' and name = 'Vodka Grey Goose';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuMSAxMDAgMTAwKSI+CiAgICA8cGF0aCBkPSJNODQgMjYgTDg0IDQ0IFE2NiA1MCA2NiA2OCBMNjYgMTY4IFE2NiAxNzggNzYgMTc4IEwxMjQgMTc4IFExMzQgMTc4IDEzNCAxNjggTDEzNCA2OCBRMTM0IDUwIDExNiA0NCBMMTE2IDI2IFoiCiAgICAgIGZpbGw9IiM4QTVBMkIiIGZpbGwtb3BhY2l0eT0iMC4zMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg0IDI2IEwxMTYgMjYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04OCAyOCBMMTEyIDI4IiBzdHJva2U9IiM0QTJBMUUiIHN0cm9rZS13aWR0aD0iNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNNzQgNzYgTDc0IDE2OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuMzUiLz4KICAgIAogICAgPHJlY3QgeD0iNzgiIHk9Ijk2IiB3aWR0aD0iNDQiIGhlaWdodD0iNDIiIHJ4PSI0IiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40Ii8+CiAgICA8bGluZSB4MT0iODYiIHkxPSIxMDUiIHgyPSIxMTQiIHkyPSIxMDUiIHN0cm9rZT0iIzRBMkExRSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz4KICAgIDxsaW5lIHgxPSI4NiIgeTE9IjEyOSIgeDI9IjExNCIgeTI9IjEyOSIgc3Ryb2tlPSIjNEEyQTFFIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGNpcmNsZSBjeD0iMTAwLjAiIGN5PSIxMTcuMCIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjNEEyQTFFIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIAogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'bottles' and name = 'Jack Daniel''s';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTEuNSAxMDAgMTAwKSI+CiAgICA8cGF0aCBkPSJNODQgMjYgTDg0IDQ0IFE2NiA1MCA2NiA2OCBMNjYgMTY4IFE2NiAxNzggNzYgMTc4IEwxMjQgMTc4IFExMzQgMTc4IDEzNCAxNjggTDEzNCA2OCBRMTM0IDUwIDExNiA0NCBMMTE2IDI2IFoiCiAgICAgIGZpbGw9IiNDRkUzRDYiIGZpbGwtb3BhY2l0eT0iMC4zMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg0IDI2IEwxMTYgMjYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04OCAyOCBMMTEyIDI4IiBzdHJva2U9IiMxQzZBNEEiIHN0cm9rZS13aWR0aD0iNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNNzQgNzYgTDc0IDE2OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuMzUiLz4KICAgIAogICAgPHJlY3QgeD0iNzgiIHk9Ijk2IiB3aWR0aD0iNDQiIGhlaWdodD0iNDIiIHJ4PSI0IiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40Ii8+CiAgICA8bGluZSB4MT0iODYiIHkxPSIxMDUiIHgyPSIxMTQiIHkyPSIxMDUiIHN0cm9rZT0iIzFDNkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz4KICAgIDxsaW5lIHgxPSI4NiIgeTE9IjEyOSIgeDI9IjExNCIgeTI9IjEyOSIgc3Ryb2tlPSIjMUM2QTRBIiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGNpcmNsZSBjeD0iMTAwLjAiIGN5PSIxMTcuMCIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUM2QTRBIiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIAogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'bottles' and name = 'Tanqueray';
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj4KICA8ZGVmcz4KICAgIDxyYWRpYWxHcmFkaWVudCBpZD0id2FzaCIgY3g9IjM2JSIgY3k9IjI2JSIgcj0iODAlIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz4KICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjRjRBNTdBIiBzdG9wLW9wYWNpdHk9IjAuMTQiLz4KICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAKICA8L2RlZnM+CiAgPHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz4KICA8Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+CiAgPGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEwIi8+CiAgPGcgdHJhbnNmb3JtPSJyb3RhdGUoLTIuOSAxMDAgMTAwKSI+CiAgICA8cGF0aCBkPSJNODQgMjYgTDg0IDQ0IFE2NiA1MCA2NiA2OCBMNjYgMTY4IFE2NiAxNzggNzYgMTc4IEwxMjQgMTc4IFExMzQgMTc4IDEzNCAxNjggTDEzNCA2OCBRMTM0IDUwIDExNiA0NCBMMTE2IDI2IFoiCiAgICAgIGZpbGw9IiM4QTVBMkIiIGZpbGwtb3BhY2l0eT0iMC4zMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPgogICAgPHBhdGggZD0iTTg0IDI2IEwxMTYgMjYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiLz4KICAgIDxwYXRoIGQ9Ik04OCAyOCBMMTEyIDI4IiBzdHJva2U9IiNCMjNBNDgiIHN0cm9rZS13aWR0aD0iNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICA8cGF0aCBkPSJNNzQgNzYgTDc0IDE2OCIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuMzUiLz4KICAgIAogICAgPHJlY3QgeD0iNzgiIHk9Ijk2IiB3aWR0aD0iNDQiIGhlaWdodD0iNDIiIHJ4PSI0IiBmaWxsPSIjRjdGMUU5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40Ii8+CiAgICA8bGluZSB4MT0iODYiIHkxPSIxMDUiIHgyPSIxMTQiIHkyPSIxMDUiIHN0cm9rZT0iI0IyM0E0OCIgc3Ryb2tlLXdpZHRoPSIxLjYiLz4KICAgIDxsaW5lIHgxPSI4NiIgeTE9IjEyOSIgeDI9IjExNCIgeTI9IjEyOSIgc3Ryb2tlPSIjQjIzQTQ4IiBzdHJva2Utd2lkdGg9IjEuNiIvPgogICAgPGNpcmNsZSBjeD0iMTAwLjAiIGN5PSIxMTcuMCIgcj0iNyIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQjIzQTQ4IiBzdHJva2Utd2lkdGg9IjIiLz4KICAgIAogICAgPC9nPgo8L3N2Zz4='
   where venue_id = p_venue and universe = 'bottles' and name = 'Rhum Havana 7 ans';
end;
$$;

-- Rétroactif, pour les venues déjà en activité :
do $$
declare v_venue record;
begin
  for v_venue in select id from public.venues loop
    perform public.tag_product_illustrations(v_venue.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
--  seed_noti_menu() — redéfinie ici pour appeler tag_product_illustrations()
--  en fin de rechargement (bouton « Recharger la carte Noti Club »), afin que
--  l'illustration reste à jour sans intervention SQL manuelle. Copie exacte
--  de 0005/0012/0013, seule la dernière ligne avant `return n;` change.
--  Installation neuve : 0005_seed_noti_menu.sql contient déjà cette version,
--  cette redéfinition est alors un simple no-op identique.
-- ---------------------------------------------------------------------------
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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
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

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  -- Étiquetage des articles éligibles aux forfaits à crédits (cf. 0013).
  perform public.tag_credit_menu(p_venue);

  -- Illustration par article (cf. 0017).
  perform public.tag_product_illustrations(p_venue);

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;


-- ============================================================================
--  NOTI Calling — 0018_profil_cp_naissance_editable.sql
--
--  Les fiches créées AVANT l'ajout du code postal / de la date de naissance
--  (patch 0015) ont ces deux champs vides, et rien ne permettait de les
--  compléter depuis l'espace client (affichés en lecture seule uniquement).
--  Ce patch les rend eux aussi modifiables, comme le téléphone (0016).
-- ============================================================================

-- L'ancienne version (3 arguments) doit être supprimée explicitement, sinon
-- les deux coexisteraient (surcharge), avec un risque d'appel ambigu.
drop function if exists public.update_my_optional_profile(text, text, text);

create or replace function public.update_my_optional_profile(
  p_email       text default null,
  p_instagram   text default null,
  p_phone       text default null,
  p_postal_code text default null,
  p_birthdate   date default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.customers;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;
  if p_phone is not null and trim(p_phone) = '' then
    raise exception 'missing_phone';
  end if;
  if p_postal_code is not null and trim(p_postal_code) = '' then
    raise exception 'missing_postal_code';
  end if;
  if p_birthdate is not null and p_birthdate > current_date then
    raise exception 'invalid_birthdate';
  end if;

  begin
    update public.customers
       set email       = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
           instagram   = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end,
           phone       = case when p_phone is null then phone else trim(p_phone) end,
           postal_code = case when p_postal_code is null then postal_code else trim(p_postal_code) end,
           birthdate   = coalesce(p_birthdate, birthdate)
     where id = v_cust
     returning * into v_row;
  exception when unique_violation then
    raise exception 'phone_already_used';
  end;

  return v_row;
end;
$$;

grant execute on function public.update_my_optional_profile(text, text, text, text, date) to authenticated;


-- ============================================================================
--  NOTI Calling — 0019_illustrations_food.sql
--
--  L'univers Food était vide : les plats n'ont jamais fait partie de la carte
--  type semée par seed_noti_menu(), et rien ne les avait saisis à la main —
--  d'où un onglet Food sans aucun article, et aucune illustration à y montrer.
--
--  Ce patch sème les huit plats de la carte Noti Club (prix de la rentrée
--  2026) et leur donne une illustration dessinée dans le même style que les
--  boissons, encodée en data URI — jamais de lien externe qui pourrait casser.
--
--  Idempotent : rejoué à chaque clic sur « Carte Noti Club », il met les prix
--  à jour sans jamais créer de doublon.
-- ============================================================================

create or replace function public.seed_noti_food(p_venue uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  insert into public.products
    (venue_id, universe, subcategory, name, description, price, is_popular,
     is_alcohol, vat_rate, sort_order, image_url)
  values
  (p_venue,'food','À grignoter','Cornet de frites','Frites fraîches, fleur de sel',5,true,false,10,1,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjQgMTAwIDEwMCkiPjxsaW5lYXJHcmFkaWVudCBpZD0iZmNfMjk0OTE0NDIiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAlIiBzdG9wLWNvbG9yPSIjOWIyMzMxIiBzdG9wLW9wYWNpdHk9IjAuOSIvPjxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOSIvPjxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0IyM0E0OCIgc3RvcC1vcGFjaXR5PSIxIi8+PC9saW5lYXJHcmFkaWVudD48ZWxsaXBzZSBjeD0iOTQiIGN5PSIxODAiIHJ4PSI1MiIgcnk9IjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTcwIDkyIEw1NCAxNzIgUTUzIDE4MiA2NCAxODIgTDEyNCAxODIgUTEzNSAxODIgMTM0IDE3MiBMMTE4IDkyIFoiIGZpbGw9IiNFM0MwOEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNNzAgOTIgTDExOCA5MiBMMTE0IDExMiBMNzQgMTEyIFoiIGZpbGw9IiM4QTVBMkIiIGZpbGwtb3BhY2l0eT0iMC4yIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxwYXRoIGQ9Ik03MiAxMjQgTDExNiAxMjQgTTY4IDE0NiBMMTIwIDE0NiBNNjUgMTY2IEwxMjMgMTY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQ2LjMgMTA1LjggOTYpIj48cmVjdCB4PSIxMDEuMyIgeT0iNDcuNiIgd2lkdGg9IjkiIGhlaWdodD0iNDguNCIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSIxMDMuMiIgeT0iNTIuNiIgd2lkdGg9IjIuNCIgaGVpZ2h0PSIzNi40IiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTM1LjkgOTggOTYpIj48cmVjdCB4PSI5My41IiB5PSI0Mi44IiB3aWR0aD0iOSIgaGVpZ2h0PSI1My4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk1LjQiIHk9IjQ3LjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDEuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yNi4zIDEwMC43IDk2KSI+PHJlY3QgeD0iOTYuMiIgeT0iMzUuOSIgd2lkdGg9IjkiIGhlaWdodD0iNjAuMSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5OC4xIiB5PSI0MC45IiB3aWR0aD0iMi40IiBoZWlnaHQ9IjQ4LjEiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMjAuNiA5NC45IDk2KSI+PHJlY3QgeD0iOTAuNCIgeT0iMzYiIHdpZHRoPSI5IiBoZWlnaHQ9IjYwIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9IjkyLjMiIHk9IjQxIiB3aWR0aD0iMi40IiBoZWlnaHQ9IjQ4IiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuOCA5OS44IDk2KSI+PHJlY3QgeD0iOTUuMyIgeT0iNDcuMSIgd2lkdGg9IjkiIGhlaWdodD0iNDguOSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5Ny4yIiB5PSI1Mi4xIiB3aWR0aD0iMi40IiBoZWlnaHQ9IjM2LjkiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxIDk2LjcgOTYpIj48cmVjdCB4PSI5Mi4yIiB5PSIzOS44IiB3aWR0aD0iOSIgaGVpZ2h0PSI1Ni4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk0LjEiIHk9IjQ0LjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDQuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDEyLjIgOTkuNCA5NikiPjxyZWN0IHg9Ijk0LjkiIHk9IjM2LjciIHdpZHRoPSI5IiBoZWlnaHQ9IjU5LjMiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iOTYuOCIgeT0iNDEuNyIgd2lkdGg9IjIuNCIgaGVpZ2h0PSI0Ny4zIiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoMTguOCAxMDMuNyA5NikiPjxyZWN0IHg9Ijk5LjIiIHk9IjM0LjQiIHdpZHRoPSI5IiBoZWlnaHQ9IjYxLjYiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iMTAxLjEiIHk9IjM5LjQiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDkuNiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDI1LjUgMTAxLjUgOTYpIj48cmVjdCB4PSI5NyIgeT0iNDcuNSIgd2lkdGg9IjkiIGhlaWdodD0iNDguNSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5OC45IiB5PSI1Mi41IiB3aWR0aD0iMi40IiBoZWlnaHQ9IjM2LjUiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgzNi4xIDEwNS4yIDk2KSI+PHJlY3QgeD0iMTAwLjciIHk9IjM5LjEiIHdpZHRoPSI5IiBoZWlnaHQ9IjU2LjkiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iMTAyLjYiIHk9IjQ0LjEiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDQuOSIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDQzLjEgOTkuNSA5NikiPjxyZWN0IHg9Ijk1IiB5PSI0OC44IiB3aWR0aD0iOSIgaGVpZ2h0PSI0Ny4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk2LjkiIHk9IjUzLjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iMzUuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxjaXJjbGUgY3g9IjE0MC41IiBjeT0iNzcuNSIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iOTQuNCIgY3k9Ijg4LjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjcxLjIiIGN5PSI2OS4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMTUuNiIgY3k9Ijc5LjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjcwLjYiIGN5PSI2MC4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSI1OS43IiBjeT0iODcuOSIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iOTQuNCIgY3k9IjYyLjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9Ijc1LjUiIGN5PSI2OS4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMjkuNiIgY3k9IjcwLjMiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9Ijg0LjgiIGN5PSI1Ni4xIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxNDEuMyIgY3k9IjY4LjUiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjExMS4yIiBjeT0iODQuOCIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iMTE4LjkiIGN5PSI2MS42IiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMTguMSIgY3k9Ijg3LjgiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxlbGxpcHNlIGN4PSIxNTgiIGN5PSIxNzYiIHJ4PSI5IiByeT0iNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTU4IiBjeT0iMTY2IiByeD0iMTciIHJ5PSIxNSIgZmlsbD0idXJsKCNmY18yOTQ5MTQ0MikiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz48ZWxsaXBzZSBjeD0iMTU4IiBjeT0iMTU3IiByeD0iMTMiIHJ5PSI2IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjwvZz48L3N2Zz4='),
  (p_venue,'food','À grignoter','Houmous pistache','Pois chiches, pistache, huile d’olive, pain grillé',12,false,false,10,2,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0NGRTBBNiIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNGM0I2RDgiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxLjIgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjYiIHJ4PSI1NiIgcnk9IjI4IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0zNiAxMDYgUTM0IDE1NCAxMDAgMTYwIFExNjYgMTU0IDE2NCAxMDYgUTEwMCAxMjIgMzYgMTA2IFoiIGZpbGw9IiNGREZCRjYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjQiIHJ5PSIxNSIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMyIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIvPjxjbGlwUGF0aCBpZD0iZmJfMTAxNzY4MzgiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMDYiIHJ4PSI2MiIgcnk9IjE0Ii8+PC9jbGlwUGF0aD48ZyBjbGlwLXBhdGg9InVybCgjZmJfMTAxNzY4MzgpIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIgZmlsbD0iI0NGRTBBNiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMDMiIHJ4PSI0MSIgcnk9IjciIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHBhdGggZD0iTTQ2IDEwOSBRNzQgMTAwIDEwMCAxMDggUTEyNiAxMTUgMTU0IDEwNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZGNlZGIzIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjEwMS4yIiBjeT0iOTguNSIgcj0iMS45IiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iNzIuMiIgY3k9IjEwMy4yIiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI0Ni4zIiBjeT0iOTcuMyIgcj0iMS40IiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iNDguOSIgY3k9Ijk3LjIiIHI9IjIuMyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9Ijk4LjIiIGN5PSIxMTAuOSIgcj0iMS4zIiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iMTM2LjciIGN5PSI5Ni42IiByPSIxLjQiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSIxMjIuMyIgY3k9IjEwNS40IiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI1MC4yIiBjeT0iMTEyLjUiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEyMi40IiBjeT0iOTgiIHI9IjEuNyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEwMS42IiBjeT0iOTkiIHI9IjEuNiIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEzMy40IiBjeT0iMTExLjgiIHI9IjEuNyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjE0NS43IiBjeT0iMTE2IiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSIxMTEuOCIgY3k9Ijk3LjciIHI9IjEuOCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExMi4yIiBjeT0iMTAwLjMiIHI9IjEuNiIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9Ijk2LjkiIGN5PSI5OC41IiByPSIxLjMiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI3OCIgY3k9IjExMC45IiByPSIxLjUiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI5OS42IiBjeT0iMTA5LjkiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExNS44IiBjeT0iMTA5LjgiIHI9IjIuMSIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjQ0LjgiIGN5PSIxMDMiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExNS41IiBjeT0iMTAxLjIiIHI9IjEuOSIgZmlsbD0iIzVDOEE0QSIvPjxwYXRoIGQ9Ik01OCAxMDIgUTgwIDExNCAxMDAgMTAzIFExMjAgMTE0IDE0MiAxMDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5OTQyQiIgc3Ryb2tlLXdpZHRoPSIyLjIiIHN0cm9rZS1vcGFjaXR5PSIwLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSIxMjMuMSIgY3k9IjEwMC45IiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0yMSAxMjMuMSAxMDAuOSkiLz48ZWxsaXBzZSBjeD0iNjguMyIgY3k9IjEwMy4yIiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKDI2IDY4LjMgMTAzLjIpIi8+PGVsbGlwc2UgY3g9Ijc1IiBjeT0iMTA2LjciIHJ4PSI0LjIiIHJ5PSIzIiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgdHJhbnNmb3JtPSJyb3RhdGUoNCA3NSAxMDYuNykiLz48ZWxsaXBzZSBjeD0iMTQxIiBjeT0iMTA3LjciIHJ4PSI0LjIiIHJ5PSIzIiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgdHJhbnNmb3JtPSJyb3RhdGUoMjMgMTQxIDEwNy43KSIvPjxlbGxpcHNlIGN4PSIxNDEuNyIgY3k9IjExMS4xIiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0xNyAxNDEuNyAxMTEuMSkiLz48ZWxsaXBzZSBjeD0iNjYuOCIgY3k9IjEwOS44IiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0zMCA2Ni44IDEwOS44KSIvPjwvZz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIvPjxlbGxpcHNlIGN4PSI5NiIgY3k9Ijk3IiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKC0yMiA5NiA5NykiLz48ZWxsaXBzZSBjeD0iMTA3IiBjeT0iMTAwIiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKDI0IDEwNyAxMDApIi8+PC9nPjwvc3ZnPg=='),
  (p_venue,'food','À grignoter','Tempura poulet','Poulet en tempura, sauce maison',12,false,false,10,3,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxLjcgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjIiIHJ4PSI3MiIgcnk9IjM0IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMTIiIHJ4PSI3OCIgcnk9IjQyIiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjExMiIgcng9IjYzIiByeT0iMzIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHN0cm9rZS1vcGFjaXR5PSIwLjMiLz48ZWxsaXBzZSBjeD0iNzAiIGN5PSIxMDkiIHJ4PSIxNyIgcnk9IjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTg4LjEgOTggUTg4LjggMTA0LjYgODguMyAxMDcuNCBRODEuOCAxMDkuMyA3Ny43IDExMS40IFE3Mi41IDExMi40IDY3IDExNC41IFE2MC43IDExMS44IDU2LjcgMTEwLjMgUTUyLjcgMTA4LjMgNTAuOSAxMDIuNSBRNTAgOTcuOSA1Mi45IDk0IFE1NC4xIDg5LjcgNTcuNSA4Ni40IFE2My4xIDgzLjcgNjcgODEuMyBRNzIuMiA4My40IDc4LjkgODIuNCBRODMuMiA4Ni45IDg0LjkgOTAuMyBRODYuNiA5Mi4zIDg4LjEgOTggWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MSA5NCBRNzAgODggNzkgOTMiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjYzLjIiIGN5PSIxMDQuMyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY3LjgiIGN5PSIxMDUuNCIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY4LjUiIGN5PSI5Mi42IiByPSIxLjMiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNjYuMyIgY3k9IjEwMyIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY3LjUiIGN5PSI5Ny43IiByPSIxIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxMTIiIGN5PSIxMDEuOSIgcng9IjE1LjMiIHJ5PSI1LjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEyOC42IDkyIFExMjYuMSA5NC42IDEyNi43IDk5LjYgUTEyMC43IDEwMS45IDExOC42IDEwMy41IFExMTIgMTAzLjIgMTA5LjQgMTA2LjYgUTEwNC41IDEwNiA5OS4yIDEwMy44IFE5Ny4yIDk5LjggOTQuNyA5Ni4xIFE5NC4yIDkwLjYgOTMuNyA4Ny43IFE5Ny41IDgyLjkgOTkuOSA4MC44IFExMDMuNSA3OC40IDEwOS43IDc5LjQgUTExMy4zIDc4LjEgMTE4LjYgODAuNSBRMTIxLjMgODMuNiAxMjcuMyA4NC4xIFExMjggODkuMyAxMjguNiA5MiBaIiBmaWxsPSIjRTNCMjRCIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTEwMy45IDg4LjQgUTExMiA4MyAxMjAuMSA4Ny41IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxMDEuMiIgY3k9Ijk3LjYiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTEuOSIgY3k9Ijg3LjgiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMDUuNCIgY3k9Ijk1LjQiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMjAuOSIgY3k9Ijg2LjciIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTUuNyIgY3k9IjkzLjEiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iOTYiIGN5PSIxMzQuNCIgcng9IjE2LjEiIHJ5PSI1LjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTExNS41IDEyNCBRMTE1LjIgMTI5LjQgMTExLjEgMTMxLjggUTEwNS44IDEzNC42IDEwMy4yIDEzNi43IFE5OS45IDEzOC45IDkzLjMgMTM5LjEgUTg4LjkgMTM3LjkgODQuNCAxMzQuNyBRODAuNCAxMzEgNzkuMyAxMjcuOSBRNzcuMSAxMjMuMiA3OC42IDExOS45IFE4MC4yIDExNy42IDgzLjcgMTEyLjYgUTg3LjYgMTExLjYgOTMuNiAxMTAuNyBRMTAwLjIgMTEwLjQgMTAzLjUgMTEwLjkgUTEwNy41IDExNS4xIDExMC44IDExNi40IFExMTQuNSAxMTguNSAxMTUuNSAxMjQgWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik04Ny41IDEyMC4yIFE5NiAxMTQuNSAxMDQuNSAxMTkuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iOTcuNyIgY3k9IjExOS40IiByPSIwLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iOTEuMSIgY3k9IjEzMS4xIiByPSIxLjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTA2LjIiIGN5PSIxMTYuMiIgcj0iMS4zIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijk5LjMiIGN5PSIxMjEuOSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEwNy4yIiBjeT0iMTE3LjEiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iMTM2IiBjeT0iMTI5LjMiIHJ4PSIxNC40IiByeT0iNS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0xNTEuNCAxMjAgUTE1MC44IDEyNS4yIDE0OC41IDEyNi40IFExNDUuNyAxMzAuMyAxNDMgMTMyLjIgUTEzOS44IDEzNC4zIDEzMy41IDEzMy45IFExMzEuMiAxMzMuNiAxMjUuMSAxMzAuMSBRMTI0LjIgMTI3LjkgMTIwLjQgMTIzLjcgUTEyMC45IDExOC4yIDExOC4xIDExNS44IFExMjEuOCAxMTMuNiAxMjYuMSAxMTAuOSBRMTI5LjcgMTA4LjQgMTMzLjYgMTA2LjcgUTEzNy4zIDEwNiAxNDMuOCAxMDYuNCBRMTQ2LjcgMTEwLjUgMTUwLjUgMTEyLjUgUTE1Mi4zIDExNyAxNTEuNCAxMjAgWiIgZmlsbD0iI0RDQTgzQSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMjguMyAxMTYuNiBRMTM2IDExMS41IDE0My43IDExNS44IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxMzMuNiIgY3k9IjEyMS42IiByPSIxLjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTQ1LjEiIGN5PSIxMjAuNyIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzMi4yIiBjeT0iMTE5LjgiIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxNDIuNCIgY3k9IjExMy45IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTM4LjEiIGN5PSIxMjEuMyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxNDgiIGN5PSIxMzAiIHJ4PSIxOSIgcnk9IjE2IiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi42Ii8+PGVsbGlwc2UgY3g9IjE0OCIgY3k9IjEzMCIgcng9IjEzIiByeT0iMTAiIGZpbGw9IiM3QTRBMjIiIGZpbGwtb3BhY2l0eT0iMC44Ii8+PGVsbGlwc2UgY3g9IjE0NCIgY3k9IjEyNiIgcng9IjUiIHJ5PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yMiA2MiAxMzQpIj48cGF0aCBkPSJNNDYgMTM0IEExNiAxNiAwIDAgMSA3OCAxMzQgWiIgZmlsbD0iI0U5RDY0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MiAxMzQgTDYyIDExOSBNNTMgMTMzIEw2MCAxMjAgTTcxIDEzMyBMNjQgMTIwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik00NiAxMzQgQTE2IDE2IDAgMCAxIDc4IDEzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPjwvZz48ZWxsaXBzZSBjeD0iNjAiIGN5PSI5NiIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjggNjAgOTYpIi8+PGVsbGlwc2UgY3g9IjY4IiBjeT0iOTIiIHJ4PSI1IiByeT0iOSIgZmlsbD0iIzVDOEE0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMiIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgNjggOTIpIi8+PC9nPjwvc3ZnPg=='),
  (p_venue,'food','À grignoter','Noti croque truffé','Croque au fromage fondu et éclats de truffe',14,false,false,10,4,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS42IDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTUyIiByeD0iNjgiIHJ5PSIyMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTQyIiByeD0iNzQiIHJ5PSIzMCIgZmlsbD0iI0ZERkJGNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxNDIiIHJ4PSI1OSIgcnk9IjIwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGVsbGlwc2UgY3g9Ijc2IiBjeT0iMTM5IiByeD0iMzYiIHJ5PSI1IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjbGlwUGF0aCBpZD0iY3ExXzIzMTM4MiI+PHBhdGggZD0iTTM4IDEzNiBMMTE0IDEzNiBMNzYgNzAgWiIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2NxMV8yMzEzODIpIj48cmVjdCB4PSIzNCIgeT0iMTE2LjIiIHdpZHRoPSI4NCIgaGVpZ2h0PSIxOS44IiBmaWxsPSIjRUZDMTcwIi8+PHJlY3QgeD0iMzQiIHk9IjEwOC4zIiB3aWR0aD0iODQiIGhlaWdodD0iNy45IiBmaWxsPSIjRTlDNDZBIi8+PHJlY3QgeD0iMzQiIHk9Ijk5IiB3aWR0aD0iODQiIGhlaWdodD0iOS4yIiBmaWxsPSIjRDk4QThBIi8+PHJlY3QgeD0iMzQiIHk9IjcwIiB3aWR0aD0iODQiIGhlaWdodD0iMjkiIGZpbGw9IiNGN0RCQTQiLz48cmVjdCB4PSIzNCIgeT0iMTE2LjIiIHdpZHRoPSI4NCIgaGVpZ2h0PSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHJlY3QgeD0iMzQiIHk9IjEwOC4zIiB3aWR0aD0iODQiIGhlaWdodD0iMS40IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxyZWN0IHg9IjM0IiB5PSI5OSIgd2lkdGg9Ijg0IiBoZWlnaHQ9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48Y2lyY2xlIGN4PSI1OS44IiBjeT0iMTIyLjkiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2Ni43IiBjeT0iMTI5LjciIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI5NS40IiBjeT0iMTE5LjgiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2OS4yIiBjeT0iMTI2LjMiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4My44IiBjeT0iMTMwLjUiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI3My42IiBjeT0iMTMzLjEiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4MC4zIiBjeT0iMTMyLjIiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2MyIgY3k9IjgxLjkiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI3MC43IiBjeT0iODQuMSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjgwLjEiIGN5PSI5MS42IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iNzUuOCIgY3k9IjgwLjkiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4MCIgY3k9IjkwLjIiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iNjQuOCIgY3k9IjExNC4xIiByeD0iMi41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMzQgNjQuOCAxMTQuMSkiLz48ZWxsaXBzZSBjeD0iOTcuNiIgY3k9IjExMS40IiByeD0iMy41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMSA5Ny42IDExMS40KSIvPjxlbGxpcHNlIGN4PSI2Ny4xIiBjeT0iMTA2LjUiIHJ4PSIzIiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSg1OCA2Ny4xIDEwNi41KSIvPjxlbGxpcHNlIGN4PSI5OC45IiBjeT0iMTEzLjUiIHJ4PSIzLjUiIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDY2IDk4LjkgMTEzLjUpIi8+PGVsbGlwc2UgY3g9IjY0LjIiIGN5PSIxMTEuNyIgcng9IjMuMiIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoNTUgNjQuMiAxMTEuNykiLz48ZWxsaXBzZSBjeD0iOTcuOSIgY3k9IjEwMi4zIiByeD0iMy4xIiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMTkgOTcuOSAxMDIuMykiLz48L2c+PHBhdGggZD0iTTM4IDEzNiBMNzYgNzAgTDExNCAxMzYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M1OEEzNCIgc3Ryb2tlLXdpZHRoPSI1IiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMzggMTM2IEwxMTQgMTM2IEw3NiA3MCBaIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSIxMjgiIGN5PSIxNDUiIHJ4PSIzMyIgcnk9IjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNsaXBQYXRoIGlkPSJjcTJfMjMxMzgyIj48cGF0aCBkPSJNOTQgMTQyIEwxNjIgMTQyIEwxMjggODQgWiIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2NxMl8yMzEzODIpIj48cmVjdCB4PSI5MCIgeT0iMTI0LjYiIHdpZHRoPSI3NiIgaGVpZ2h0PSIxNy40IiBmaWxsPSIjRUZDMTcwIi8+PHJlY3QgeD0iOTAiIHk9IjExNy42IiB3aWR0aD0iNzYiIGhlaWdodD0iNyIgZmlsbD0iI0U5QzQ2QSIvPjxyZWN0IHg9IjkwIiB5PSIxMDkuNSIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjguMSIgZmlsbD0iI0Q5OEE4QSIvPjxyZWN0IHg9IjkwIiB5PSI4NCIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjI1LjUiIGZpbGw9IiNGN0RCQTQiLz48cmVjdCB4PSI5MCIgeT0iMTI0LjYiIHdpZHRoPSI3NiIgaGVpZ2h0PSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHJlY3QgeD0iOTAiIHk9IjExNy42IiB3aWR0aD0iNzYiIGhlaWdodD0iMS40IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxyZWN0IHg9IjkwIiB5PSIxMDkuNSIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48Y2lyY2xlIGN4PSIxMTcuMyIgY3k9IjEzMi4yIiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iMTQzLjQiIGN5PSIxMzguMSIgcj0iMS45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjE0NS4yIiBjeT0iMTMyLjgiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzEuMyIgY3k9IjEzNy41IiByPSIxLjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iMTUwLjUiIGN5PSIxMzMuMSIgcj0iMS45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjEwNy44IiBjeT0iMTI3LjUiIHI9IjEuOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSIxMzkuNiIgcj0iMi4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjEyNi45IiBjeT0iMTA0LjYiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzQuMiIgY3k9Ijk5LjIiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzUuMiIgY3k9Ijk0LjIiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMjEuNyIgY3k9Ijk0LjciIHI9IjEuOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzQuNCIgY3k9IjEwMC41IiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGVsbGlwc2UgY3g9IjExNy4xIiBjeT0iMTE2LjMiIHJ4PSIyLjciIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDAgMTE3LjEgMTE2LjMpIi8+PGVsbGlwc2UgY3g9IjEzMy42IiBjeT0iMTE2LjEiIHJ4PSIyLjYiIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDUzIDEzMy42IDExNi4xKSIvPjxlbGxpcHNlIGN4PSIxMjguNSIgY3k9IjExNi43IiByeD0iMy41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSg1MyAxMjguNSAxMTYuNykiLz48ZWxsaXBzZSBjeD0iMTQ0LjEiIGN5PSIxMTQuNCIgcng9IjMuMiIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoMTc2IDE0NC4xIDExNC40KSIvPjxlbGxpcHNlIGN4PSIxMjYuMSIgY3k9IjExMS43IiByeD0iMi41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgyMCAxMjYuMSAxMTEuNykiLz48ZWxsaXBzZSBjeD0iMTEyLjUiIGN5PSIxMTkuNyIgcng9IjIuOSIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoMTM2IDExMi41IDExOS43KSIvPjwvZz48cGF0aCBkPSJNOTQgMTQyIEwxMjggODQgTDE2MiAxNDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M1OEEzNCIgc3Ryb2tlLXdpZHRoPSI1IiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNOTQgMTQyIEwxNjIgMTQyIEwxMjggODQgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48ZWxsaXBzZSBjeD0iMTYwIiBjeT0iMTE4IiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKDM0IDE2MCAxMTgpIi8+PHBhdGggZD0iTTQ2IDEyOCBRNDAgMTM2IDQ0IDE0NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzk5NDJCIiBzdHJva2Utd2lkdGg9IjIuMiIgc3Ryb2tlLW9wYWNpdHk9IjAuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PC9nPjwvc3ZnPg=='),
  (p_venue,'food','À partager','Straciatella','Stracciatella crémeuse, huile d’olive, basilic',15,false,false,10,1,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0NGRTBBNiIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNGM0I2RDgiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMi4yIDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTI2IiByeD0iNTYiIHJ5PSIyOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48cGF0aCBkPSJNMzYgMTA2IFEzNCAxNTQgMTAwIDE2MCBRMTY2IDE1NCAxNjQgMTA2IFExMDAgMTIyIDM2IDEwNiBaIiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjY0IiByeT0iMTUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjMiIHN0cm9rZS1vcGFjaXR5PSIwLjMiLz48Y2xpcFBhdGggaWQ9ImZiXzMzMDQxMjg4Ij48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2ZiXzMzMDQxMjg4KSI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjYyIiByeT0iMTQiIGZpbGw9IiNGM0VFRTIiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTAzIiByeD0iNDEiIHJ5PSI3IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxwYXRoIGQ9Ik00NiAxMDkgUTc0IDEwMCAxMDAgMTA4IFExMjYgMTE1IDE1NCAxMDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2U2ZTFkNSIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxNTMuMSIgY3k9Ijk3LjQiIHI9IjEuOSIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjQ1LjEiIGN5PSIxMTIiIHI9IjEuNiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjUzIiBjeT0iOTguNSIgcj0iMS41IiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iNzUuMSIgY3k9IjExMS42IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI5MS44IiBjeT0iOTYuMyIgcj0iMi4xIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iMTUwLjciIGN5PSIxMTUuMSIgcj0iMi4zIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iMTA4LjgiIGN5PSIxMDkuNyIgcj0iMS4zIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iODUuMyIgY3k9Ijk2LjgiIHI9IjEuNCIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjE0MC42IiBjeT0iMTA3LjQiIHI9IjEuNyIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9Ijc5IiBjeT0iMTEyLjQiIHI9IjEuNCIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjEwOC4yIiBjeT0iMTA4LjEiIHI9IjEuNyIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjEyNy45IiBjeT0iMTA4LjEiIHI9IjEuOSIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjExNC41IiBjeT0iMTA2IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSIxNDYuMSIgY3k9IjExMi4xIiByPSIyLjIiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI0Ny4zIiBjeT0iOTUuNyIgcj0iMiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjYyLjQiIGN5PSIxMDYuNSIgcj0iMi4xIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iOTcuMSIgY3k9IjExMS41IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSIxMTIuMyIgY3k9IjEwNC42IiByPSIxLjYiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI5OC4xIiBjeT0iMTE0LjUiIHI9IjEuNiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjE0My4xIiBjeT0iOTguMSIgcj0iMS45IiBmaWxsPSIjN0E5NDUwIi8+PHBhdGggZD0iTTU4IDEwMiBRODAgMTE0IDEwMCAxMDMgUTEyMCAxMTQgMTQyIDEwMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzk5NDJCIiBzdHJva2Utd2lkdGg9IjIuMiIgc3Ryb2tlLW9wYWNpdHk9IjAuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEyNS45IDExMyBxNi4yIDQuNiAxMi40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzLjciIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMjUuOSAxMTMgcTYuMiA0LjYgMTIuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNODguOSAxMDAuMiBxOC45IC0yLjcgMTcuOCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi45IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNODguOSAxMDAuMiBxOC45IC0yLjcgMTcuOCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTcuMyA5OCBxMTAuNiAzLjkgMjEuMiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy44IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTcuMyA5OCBxMTAuNiAzLjkgMjEuMiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTIzLjMgOTkuMyBxNy4xIC0xLjIgMTQuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTIzLjMgOTkuMyBxNy4xIC0xLjIgMTQuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTI0LjQgMTA1LjkgcTcuMyAyLjUgMTQuNiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEyNC40IDEwNS45IHE3LjMgMi41IDE0LjYgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuOCIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEzOS40IDk3LjEgcTcuMiA0LjIgMTQuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTM5LjQgOTcuMSBxNy4yIDQuMiAxNC40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMTEuNiAxMDUuOSBxMTAuMiAyLjYgMjAuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTExLjYgMTA1LjkgcTEwLjIgMi42IDIwLjQgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuOCIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEzNi41IDEwMC40IHE4LjggNC41IDE3LjYgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMzYuNSAxMDAuNCBxOC44IDQuNSAxNy42IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik05OC44IDEwNS4zIHE4LjYgMy43IDE3LjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTk4LjggMTA1LjMgcTguNiAzLjcgMTcuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTQuNiAxMDguMSBxMTEuNyAwIDIzLjUgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTU0LjYgMTA4LjEgcTExLjcgMCAyMy41IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMTguMiA5OSBxMTEuMSAtMS4zIDIyLjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuOSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTExOC4yIDk5IHExMS4xIC0xLjMgMjIuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTQxLjcgMTExLjMgcTguMiAtNC41IDE2LjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTE0MS43IDExMS4zIHE4LjIgLTQuNSAxNi4zIDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik01MS4zIDEwNi45IHE2LjcgMCAxMy40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik01MS4zIDEwNi45IHE2LjcgMCAxMy40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xNDEuOCAxMDcuMSBxOCAtMi4yIDE1LjkgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTE0MS44IDEwNy4xIHE4IC0yLjIgMTUuOSAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L2c+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjYyIiByeT0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz48ZWxsaXBzZSBjeD0iOTYiIGN5PSI5NyIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjIgOTYgOTcpIi8+PGVsbGlwc2UgY3g9IjEwNyIgY3k9IjEwMCIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgyNCAxMDcgMTAwKSIvPjwvZz48L3N2Zz4='),
  (p_venue,'food','À partager','Fritto misto','Friture de légumes et fruits de mer, citron',18,false,false,10,2,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS4yIDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTIyIiByeD0iNzIiIHJ5PSIzNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTEyIiByeD0iNzgiIHJ5PSI0MiIgZmlsbD0iI0ZERkJGNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMTIiIHJ4PSI2MyIgcnk9IjMyIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGVsbGlwc2UgY3g9IjY0IiBjeT0iMTA0LjIiIHJ4PSIxMi44IiByeT0iNC41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik03OC44IDk2IFE3OC43IDEwMC44IDc2LjkgMTAyLjYgUTc1LjIgMTAzLjEgNzAuMSAxMDYuNiBRNjcuMyAxMDUuMyA2Mi4xIDEwNi43IFE1Ny40IDEwNy4zIDUzLjQgMTA1LjggUTUyLjMgMTAzLjcgNDkuMiA5OS41IFE1MC4xIDk1LjYgNTAuNCA5Mi44IFE1MS40IDkwLjYgNTQuMiA4NyBRNTcuNyA4NC45IDYxLjkgODQuMSBRNjYuNyA4Mi44IDcwLjUgODQuNiBRNzQuMSA4Ny40IDc3LjMgODkuMiBRNzYuOCA5My40IDc4LjggOTYgWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik01Ny4yIDkzIFE2NCA4OC41IDcwLjggOTIuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iNzAuNCIgY3k9IjEwMCIgcj0iMC45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjcyLjEiIGN5PSI5MS45IiByPSIxLjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNTciIGN5PSIxMDEuNSIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjU4LjEiIGN5PSI5MC41IiByPSIxLjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNjMuNiIgY3k9Ijk4LjUiIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iOTAiIGN5PSI5Ny4yIiByeD0iMTEiIHJ5PSIzLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEwMi45IDkwIFExMDMuNCA5My4zIDEwMS43IDk2IFE5OS43IDk3LjIgOTQuOSA5OC41IFE5MC44IDk4LjYgODguMSAxMDAuNiBRODUuNSA5OS4zIDgxLjIgOTguMSBRNzguNCA5NSA3Ni43IDkzLjEgUTc1LjkgOTEuMSA3Ny4xIDg3IFE3OS40IDg0LjEgODEuMSA4MS44IFE4NC44IDgxLjMgODguMyA4MC40IFE5MC45IDgxLjIgOTQuOCA4MS42IFE5OC42IDgyLjggMTAxLjMgODQuMiBRMTAzLjkgODUuOSAxMDIuOSA5MCBaIiBmaWxsPSIjRjBENDhBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTg0LjIgODcuNCBROTAgODMuNSA5NS44IDg2LjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjkzLjUiIGN5PSI5MC4xIiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iOTYuOCIgY3k9Ijk0LjgiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSI4OC4xIiBjeT0iODUuMiIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjkzLjgiIGN5PSI4NS40IiByPSIxLjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iODcuMyIgY3k9IjkwLjMiIHI9IjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9IjExNiIgY3k9IjEwNC4yIiByeD0iMTIuOCIgcnk9IjQuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48cGF0aCBkPSJNMTMyLjEgOTYgUTEzMC40IDk4LjIgMTI5LjUgMTAyLjkgUTEyNS4xIDEwNC42IDEyMi41IDEwNy4zIFExMTcuNyAxMDguMyAxMTQuMSAxMDYuNyBRMTEyLjQgMTAzLjkgMTA3LjUgMTAzLjkgUTEwNC41IDEwMy4zIDEwMy4xIDk5IFExMDQuNyA5NS4zIDEwMy41IDkzLjEgUTEwMy41IDkwLjEgMTA3LjEgODcuNyBRMTA5LjggODQuMSAxMTMuOCA4My43IFExMTkuNSA4NC40IDEyMi4zIDg1IFExMjQuNCA4NS42IDEyOS4xIDg5LjMgUTEyOC44IDkxLjQgMTMyLjEgOTYgWiIgZmlsbD0iI0UzQjI0QiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMDkuMiA5MyBRMTE2IDg4LjUgMTIyLjggOTIuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iMTExLjUiIGN5PSI5Mi43IiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTIxLjYiIGN5PSI5OC41IiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTExLjkiIGN5PSI5MS40IiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTE1LjQiIGN5PSI5MC4zIiByPSIxLjMiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTA5LjYiIGN5PSI5NC42IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9IjE0MCIgY3k9IjExMS4yIiByeD0iMTEiIHJ5PSIzLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTE1MyAxMDQgUTE1My4zIDEwNS4xIDE1MiAxMTAuMiBRMTQ3LjUgMTEyLjkgMTQ1LjQgMTEzLjUgUTE0MS42IDExNC4yIDEzOCAxMTUuMyBRMTM2LjMgMTEzLjkgMTMyLjEgMTExLjMgUTEzMCAxMDkuMyAxMjYuNCAxMDcuMiBRMTI4LjQgMTA2IDEyNi42IDEwMC45IFExMzEuMSA5Ni45IDEzMi4zIDk2LjkgUTEzNC4yIDkzLjYgMTM4LjEgOTMuNCBRMTQxLjQgOTMuMSAxNDQuOSA5NS40IFExNDcuOSA5Ny41IDE1MS44IDk3LjkgUTE1My4zIDk5LjYgMTUzIDEwNCBaIiBmaWxsPSIjRENBODNBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTEzNC4yIDEwMS40IFExNDAgOTcuNSAxNDUuOCAxMDAuOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iMTQxLjYiIGN5PSIxMDMuMyIgcj0iMS42IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzNy4xIiBjeT0iMTA1LjQiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxNDMuNyIgY3k9IjEwMi4yIiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTM1LjMiIGN5PSIxMDQuOCIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzOS43IiBjeT0iMTA2LjUiIHI9IjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9Ijc4IiBjeT0iMTI3LjciIHJ4PSIxMS45IiByeT0iNC4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik05MiAxMjAgUTkwLjYgMTIzLjUgOTAuMyAxMjYuMyBRODguNCAxMjkuMSA4NCAxMzAuNiBRODAgMTMwLjQgNzYuMSAxMzAuNCBRNzEuMSAxMzAuOCA3MCAxMjcuNCBRNjUuOCAxMjcgNjQuOSAxMjMuMSBRNjcgMTE5LjcgNjUuMyAxMTcgUTY3LjIgMTEzLjggNjkuNyAxMTIuNCBRNzEuOCAxMDkuNSA3Ni4yIDEwOS44IFE4MC4zIDExMCA4My44IDEwOS44IFE4NS4yIDExMiA5MC40IDExMy42IFE5MS4xIDExNy44IDkyIDEyMCBaIiBmaWxsPSIjRTlDNDZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTcxLjcgMTE3LjIgUTc4IDExMyA4NC4zIDExNi41IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSI3NS40IiBjeT0iMTI0LjYiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSI3OSIgY3k9IjEyNS4xIiByPSIxIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc5LjgiIGN5PSIxMTcuNiIgcj0iMS4zIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc4LjYiIGN5PSIxMTcuMiIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc5LjciIGN5PSIxMjQuNyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxMjYiIGN5PSIxMjkuNyIgcng9IjExLjkiIHJ5PSI0LjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEzOC45IDEyMiBRMTM4LjcgMTIzLjIgMTM3LjMgMTI3LjggUTEzMi44IDEzMS4zIDEzMS4yIDEzMSBRMTI3LjMgMTMyLjQgMTI0LjIgMTMyLjIgUTEyMS45IDEzMi43IDExNy41IDEyOS44IFExMTUuNSAxMjguNCAxMTEuNiAxMjUuNCBRMTEwLjMgMTIwLjEgMTEyLjMgMTE4LjggUTExNi44IDExNi4xIDExNy45IDExNC41IFExMTkuNSAxMTMuMiAxMjQuMiAxMTEuOCBRMTI4IDEwOS42IDEzMi4zIDExMC45IFExMzcuMiAxMTIuNiAxMzguMiAxMTUuNyBRMTM5LjEgMTE4LjcgMTM4LjkgMTIyIFoiIGZpbGw9IiNGMEQ0OEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNMTE5LjcgMTE5LjIgUTEyNiAxMTUgMTMyLjMgMTE4LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjEzNC4zIiBjeT0iMTIxLjIiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMjIuOSIgY3k9IjExNy4zIiByPSIwLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTI0LjkiIGN5PSIxMTkuNyIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjExOS40IiBjeT0iMTE4LjkiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTgiIGN5PSIxMjQuNSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yMiA2MiAxMzQpIj48cGF0aCBkPSJNNDYgMTM0IEExNiAxNiAwIDAgMSA3OCAxMzQgWiIgZmlsbD0iI0U5RDY0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MiAxMzQgTDYyIDExOSBNNTMgMTMzIEw2MCAxMjAgTTcxIDEzMyBMNjQgMTIwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik00NiAxMzQgQTE2IDE2IDAgMCAxIDc4IDEzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPjwvZz48ZWxsaXBzZSBjeD0iNjAiIGN5PSI5NiIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjggNjAgOTYpIi8+PGVsbGlwc2UgY3g9IjY4IiBjeT0iOTIiIHJ4PSI1IiByeT0iOSIgZmlsbD0iIzVDOEE0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMiIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgNjggOTIpIi8+PC9nPjwvc3ZnPg=='),
  (p_venue,'food','À partager','Planche charcuterie','Assortiment de charcuteries, cornichons, olives',20,true,false,10,3,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNEOUE0NDEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjMgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjQiIHJ4PSI4MCIgcnk9IjIwIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0yMiA5OCBRMjAgMTM4IDQwIDE0MiBMMTYwIDE0MiBRMTgwIDEzOCAxNzggOTggUTE3OCA2OCAxNjAgNjQgTDQwIDY0IFEyMiA2OCAyMiA5OCBaIiBmaWxsPSIjQzM5NDU3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTMyIDc4IFExMDAgNzAgMTY4IDc4IE0zMCAxMDQgUTEwMCA5NiAxNzAgMTA0IE0zNCAxMjYgUTEwMCAxMTggMTY2IDEyNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjOEE1QTJCIiBzdHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxjaXJjbGUgY3g9IjEwMCIgY3k9IjY0IiByPSI0LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGVsbGlwc2UgY3g9IjYwIiBjeT0iOTciIHJ4PSIxNiIgcnk9IjExLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGVsbGlwc2UgY3g9IjY4LjMiIGN5PSI5My40IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgtNSA2OC4zIDkzLjQpIi8+PGVsbGlwc2UgY3g9IjY1LjgiIGN5PSI5OC44IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSg0NiA2NS44IDk4LjgpIi8+PGVsbGlwc2UgY3g9IjU4LjQiIGN5PSIxMDAuNiIgcng9IjcuNCIgcnk9IjUuNCIgZmlsbD0iI0M5N0E2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAxIDU4LjQgMTAwLjYpIi8+PGVsbGlwc2UgY3g9IjUyLjEiIGN5PSI5Ni4xIiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgxNjEgNTIuMSA5Ni4xKSIvPjxlbGxpcHNlIGN4PSI1Mi4xIiBjeT0iOTEuOCIgcng9IjcuNCIgcnk9IjUuNCIgZmlsbD0iI0M5N0E2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTk5IDUyLjEgOTEuOCkiLz48ZWxsaXBzZSBjeD0iNTcuMyIgY3k9Ijg3LjciIHJ4PSI3LjQiIHJ5PSI1LjQiIGZpbGw9IiNDOTdBNkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDI1MSA1Ny4zIDg3LjcpIi8+PGVsbGlwc2UgY3g9IjY0LjUiIGN5PSI4OC40IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgzMDMgNjQuNSA4OC40KSIvPjxjaXJjbGUgY3g9IjYwIiBjeT0iOTQiIHI9IjQuOCIgZmlsbD0iI0YwQzlBOCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxlbGxpcHNlIGN4PSI5MiIgY3k9IjkxIiByeD0iMTUiIHJ5PSIxMC44IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSI5OS44IiBjeT0iODcuNiIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoLTQgOTkuOCA4Ny42KSIvPjxlbGxpcHNlIGN4PSI5Ni4zIiBjeT0iOTMuMyIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoNTcgOTYuMyA5My4zKSIvPjxlbGxpcHNlIGN4PSI5MC4zIiBjeT0iOTQuMiIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAyIDkwLjMgOTQuMikiLz48ZWxsaXBzZSBjeD0iODQuOCIgY3k9IjkwLjQiIHJ4PSI2LjkiIHJ5PSI1LjEiIGZpbGw9IiNCODVBNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1OCA4NC44IDkwLjQpIi8+PGVsbGlwc2UgY3g9Ijg0LjkiIGN5PSI4NS4zIiByeD0iNi45IiByeT0iNS4xIiBmaWxsPSIjQjg1QTU0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgyMDUgODQuOSA4NS4zKSIvPjxlbGxpcHNlIGN4PSI4OS40IiBjeT0iODIuMSIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMjUwIDg5LjQgODIuMSkiLz48ZWxsaXBzZSBjeD0iOTcuNSIgY3k9IjgzLjUiIHJ4PSI2LjkiIHJ5PSI1LjEiIGZpbGw9IiNCODVBNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDMxNSA5Ny41IDgzLjUpIi8+PGNpcmNsZSBjeD0iOTIiIGN5PSI4OCIgcj0iNC41IiBmaWxsPSIjRjBDOUE4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGVsbGlwc2UgY3g9IjEyNCIgY3k9Ijk5IiByeD0iMTQiIHJ5PSIxMC4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSIxMzEuMyIgY3k9Ijk2LjMiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDMgMTMxLjMgOTYuMykiLz48ZWxsaXBzZSBjeD0iMTI5LjMiIGN5PSIxMDAiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDQ0IDEyOS4zIDEwMCkiLz48ZWxsaXBzZSBjeD0iMTIyLjQiIGN5PSIxMDEuNyIgcng9IjYuNCIgcnk9IjQuOCIgZmlsbD0iI0QwOEE3MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAzIDEyMi40IDEwMS43KSIvPjxlbGxpcHNlIGN4PSIxMTcuNyIgY3k9Ijk4LjkiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1MSAxMTcuNyA5OC45KSIvPjxlbGxpcHNlIGN4PSIxMTcuOSIgY3k9IjkyLjgiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDIxMyAxMTcuOSA5Mi44KSIvPjxlbGxpcHNlIGN4PSIxMjIuMSIgY3k9IjkwLjMiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDI1NSAxMjIuMSA5MC4zKSIvPjxlbGxpcHNlIGN4PSIxMjcuOCIgY3k9IjkxIiByeD0iNi40IiByeT0iNC44IiBmaWxsPSIjRDA4QTcyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgzMDIgMTI3LjggOTEpIi8+PGNpcmNsZSBjeD0iMTI0IiBjeT0iOTYiIHI9IjQuMiIgZmlsbD0iI0YwQzlBOCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxlbGxpcHNlIGN4PSIxNTQiIGN5PSIxMDkiIHJ4PSIxMyIgcnk9IjkuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTYwLjgiIGN5PSIxMDYuMSIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDEgMTYwLjggMTA2LjEpIi8+PGVsbGlwc2UgY3g9IjE1Ny45IiBjeT0iMTEwLjUiIHJ4PSI2IiByeT0iNC40IiBmaWxsPSIjQTg0QTQ4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSg1NSAxNTcuOSAxMTAuNSkiLz48ZWxsaXBzZSBjeD0iMTUyLjgiIGN5PSIxMTEuNCIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDEwMCAxNTIuOCAxMTEuNCkiLz48ZWxsaXBzZSBjeD0iMTQ3LjgiIGN5PSIxMDguMSIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1NyAxNDcuOCAxMDguMSkiLz48ZWxsaXBzZSBjeD0iMTQ4IiBjeT0iMTAzLjUiIHJ4PSI2IiByeT0iNC40IiBmaWxsPSIjQTg0QTQ4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgyMDcgMTQ4IDEwMy41KSIvPjxlbGxpcHNlIGN4PSIxNTIuOSIgY3k9IjEwMC42IiByeD0iNiIgcnk9IjQuNCIgZmlsbD0iI0E4NEE0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMjYxIDE1Mi45IDEwMC42KSIvPjxlbGxpcHNlIGN4PSIxNTguOCIgY3k9IjEwMi4yIiByeD0iNiIgcnk9IjQuNCIgZmlsbD0iI0E4NEE0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMzE2IDE1OC44IDEwMi4yKSIvPjxjaXJjbGUgY3g9IjE1NCIgY3k9IjEwNiIgcj0iMy45IiBmaWxsPSIjRjBDOUE4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGNpcmNsZSBjeD0iNzYiIGN5PSIxMjIiIHI9IjkiIGZpbGw9IiNDNDc0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iNzcuNiIgY3k9IjEyNi44IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSI3OS4zIiBjeT0iMTE3LjkiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9Ijc2LjQiIGN5PSIxMjUiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9Ijc5LjgiIGN5PSIxMTcuNiIgcj0iMS41IiBmaWxsPSIjRjNFMkQyIi8+PGNpcmNsZSBjeD0iNzEuMiIgY3k9IjExNy45IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDgiIGN5PSIxMjYiIHI9IjguNSIgZmlsbD0iI0M0NzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48Y2lyY2xlIGN4PSIxMTAuMyIgY3k9IjEyMS40IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDMuNSIgY3k9IjEyNy41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDcuNSIgY3k9IjEyNi42IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDguNiIgY3k9IjEyNy41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDUuOSIgY3k9IjEyMS41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxNDAiIGN5PSIxMjQiIHI9IjgiIGZpbGw9IiNDNDc0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iMTM5LjgiIGN5PSIxMjIiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjE0MC4zIiBjeT0iMTE5LjkiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjEzOC42IiBjeT0iMTI3LjUiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjEzNyIgY3k9IjEyMC43IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxNDIuMSIgY3k9IjEyMi4yIiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48ZWxsaXBzZSBjeD0iNDIiIGN5PSIxMTgiIHJ4PSI1LjUiIHJ5PSIxMSIgZmlsbD0iIzhGQTM1QiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuOCIgdHJhbnNmb3JtPSJyb3RhdGUoLTIyIDQyIDExOCkiLz48ZWxsaXBzZSBjeD0iNTAiIGN5PSIxMjgiIHJ4PSI1IiByeT0iMTAiIGZpbGw9IiM3RTk0NTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjgiIHRyYW5zZm9ybT0icm90YXRlKDE0IDUwIDEyOCkiLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSIxMTIiIHI9IjUuNSIgZmlsbD0iIzRBM0EyMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIvPjxjaXJjbGUgY3g9IjE3MiIgY3k9IjEyNCIgcj0iNS41IiBmaWxsPSIjNEEzQTIyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42Ii8+PGNpcmNsZSBjeD0iMTYyIiBjeT0iMTI2IiByPSI1LjUiIGZpbGw9IiM0QTNBMjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz48L2c+PC9zdmc+'),
  (p_venue,'food','À partager','Planche fromages','Assortiment de fromages affinés, raisin, noix, miel',20,false,false,10,4,
   'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNEOUE0NDEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjYgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjQiIHJ4PSI4MCIgcnk9IjIwIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0yMiA5OCBRMjAgMTM4IDQwIDE0MiBMMTYwIDE0MiBRMTgwIDEzOCAxNzggOTggUTE3OCA2OCAxNjAgNjQgTDQwIDY0IFEyMiA2OCAyMiA5OCBaIiBmaWxsPSIjQzM5NDU3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTMyIDc4IFExMDAgNzAgMTY4IDc4IE0zMCAxMDQgUTEwMCA5NiAxNzAgMTA0IE0zNCAxMjYgUTEwMCAxMTggMTY2IDEyNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjOEE1QTJCIiBzdHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxjaXJjbGUgY3g9IjEwMCIgY3k9IjY0IiByPSI0LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE0IDY4IDk4KSI+PHBhdGggZD0iTTQ2IDExMiBMNDYgODQgTDkyIDk4IFoiIGZpbGw9IiNGMEQ0OEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNNDYgODQgTDkyIDk4IEw5MiAxMDQgTDQ2IDkwIFoiIGZpbGw9IiNFM0IyNEIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iNjAiIGN5PSI5OCIgcj0iMi4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxjaXJjbGUgY3g9IjcwIiBjeT0iOTQiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoOCAxMTggOTIpIj48cmVjdCB4PSI5OCIgeT0iNzgiIHdpZHRoPSI0MiIgaGVpZ2h0PSIyNiIgcng9IjMiIGZpbGw9IiNFOUM0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz48cmVjdCB4PSI5OCIgeT0iNzgiIHdpZHRoPSI0MiIgaGVpZ2h0PSI3IiByeD0iMyIgZmlsbD0iI0M5OTQyQiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuOCIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNiAxNTAgMTE2KSI+PHBhdGggZD0iTTEzMCAxMzAgTDEzNiAxMDQgTDE3MiAxMDQgTDE2OCAxMzAgWiIgZmlsbD0iI0YzRUJEMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNiIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMzYgMTA0IEwxNzIgMTA0IEwxNzEgMTEwIEwxMzUgMTEwIFoiIGZpbGw9IiNCOEIwQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz48ZWxsaXBzZSBjeD0iMTQ1LjYiIGN5PSIxMTkuMiIgcng9IjMuNSIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDEwNiAxNDUuNiAxMTkuMikiLz48ZWxsaXBzZSBjeD0iMTYwLjYiIGN5PSIxMTQiIHJ4PSIzLjMiIHJ5PSIxLjUiIGZpbGw9IiM0QTVBOEEiIGZpbGwtb3BhY2l0eT0iMC44IiB0cmFuc2Zvcm09InJvdGF0ZSgxMTAgMTYwLjYgMTE0KSIvPjxlbGxpcHNlIGN4PSIxNDUiIGN5PSIxMjEuOSIgcng9IjIuMyIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDYxIDE0NSAxMjEuOSkiLz48ZWxsaXBzZSBjeD0iMTUyLjIiIGN5PSIxMjEuNyIgcng9IjMuNCIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDc3IDE1Mi4yIDEyMS43KSIvPjxlbGxpcHNlIGN4PSIxNjMuOCIgY3k9IjExNi45IiByeD0iMy41IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoNDEgMTYzLjggMTE2LjkpIi8+PGVsbGlwc2UgY3g9IjE2NC44IiBjeT0iMTIwIiByeD0iMy42IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoMjYgMTY0LjggMTIwKSIvPjxlbGxpcHNlIGN4PSIxMzkuNyIgY3k9IjEyNi40IiByeD0iMi42IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoOSAxMzkuNyAxMjYuNCkiLz48ZWxsaXBzZSBjeD0iMTQ1LjEiIGN5PSIxMTgiIHJ4PSIzLjIiIHJ5PSIxLjUiIGZpbGw9IiM0QTVBOEEiIGZpbGwtb3BhY2l0eT0iMC44IiB0cmFuc2Zvcm09InJvdGF0ZSgxNTAgMTQ1LjEgMTE4KSIvPjxlbGxpcHNlIGN4PSIxNDIuNSIgY3k9IjEyNC4yIiByeD0iMy4xIiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoNzMgMTQyLjUgMTI0LjIpIi8+PC9nPjxjaXJjbGUgY3g9IjQ0IiBjeT0iMTEyIiByPSI1LjUiIGZpbGw9IiM3QTVGQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjUiLz48Y2lyY2xlIGN4PSI1MiIgY3k9IjExOCIgcj0iNS41IiBmaWxsPSIjN0E1RkEwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS41Ii8+PGNpcmNsZSBjeD0iNDYiIGN5PSIxMjYiIHI9IjUuNSIgZmlsbD0iIzdBNUZBMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNSIvPjxjaXJjbGUgY3g9IjU4IiBjeT0iMTI2IiByPSI1LjUiIGZpbGw9IiM3QTVGQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjUiLz48cGF0aCBkPSJNNTAgMTA0IFE1NiA5NiA2NCA5NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjNUM4QTRBIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSI4OCIgY3k9IjEyNiIgcng9IjciIHJ5PSI2IiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS44Ii8+PHBhdGggZD0iTTg4IDEyMSBMODggMTMxIE04MyAxMjUgUTg4IDEyOCA5MyAxMjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2Utb3BhY2l0eT0iMC41IiBmaWxsPSJub25lIi8+PGVsbGlwc2UgY3g9IjEwMiIgY3k9IjEzMCIgcng9IjciIHJ5PSI2IiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS44Ii8+PHBhdGggZD0iTTEwMiAxMjUgTDEwMiAxMzUgTTk3IDEyOSBRMTAyIDEzMiAxMDcgMTI5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIgZmlsbD0ibm9uZSIvPjxwYXRoIGQ9Ik0xMTggMTA4IFExMjYgMTE4IDEyMiAxMjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5OTQyQiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvZz48L3N2Zz4=')
  on conflict (venue_id, universe, name) do update
    set subcategory = excluded.subcategory,
        description = excluded.description,
        price       = excluded.price,
        is_popular  = excluded.is_popular,
        is_alcohol  = excluded.is_alcohol,
        vat_rate    = excluded.vat_rate,
        sort_order  = excluded.sort_order,
        image_url   = excluded.image_url;

  -- Repêchage : si le plat avait déjà été saisi à la main sous un libellé
  -- légèrement différent, il reçoit quand même son illustration — mais
  -- seulement s'il n'en a pas déjà une, pour ne rien écraser.
  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjQgMTAwIDEwMCkiPjxsaW5lYXJHcmFkaWVudCBpZD0iZmNfMjk0OTE0NDIiIHgxPSIwIiB5MT0iMCIgeDI9IjAiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAlIiBzdG9wLWNvbG9yPSIjOWIyMzMxIiBzdG9wLW9wYWNpdHk9IjAuOSIvPjxzdG9wIG9mZnNldD0iNTUlIiBzdG9wLWNvbG9yPSIjQjIzQTQ4IiBzdG9wLW9wYWNpdHk9IjAuOSIvPjxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI0IyM0E0OCIgc3RvcC1vcGFjaXR5PSIxIi8+PC9saW5lYXJHcmFkaWVudD48ZWxsaXBzZSBjeD0iOTQiIGN5PSIxODAiIHJ4PSI1MiIgcnk9IjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTcwIDkyIEw1NCAxNzIgUTUzIDE4MiA2NCAxODIgTDEyNCAxODIgUTEzNSAxODIgMTM0IDE3MiBMMTE4IDkyIFoiIGZpbGw9IiNFM0MwOEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNNzAgOTIgTDExOCA5MiBMMTE0IDExMiBMNzQgMTEyIFoiIGZpbGw9IiM4QTVBMkIiIGZpbGwtb3BhY2l0eT0iMC4yIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxwYXRoIGQ9Ik03MiAxMjQgTDExNiAxMjQgTTY4IDE0NiBMMTIwIDE0NiBNNjUgMTY2IEwxMjMgMTY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4xIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTQ2LjMgMTA1LjggOTYpIj48cmVjdCB4PSIxMDEuMyIgeT0iNDcuNiIgd2lkdGg9IjkiIGhlaWdodD0iNDguNCIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSIxMDMuMiIgeT0iNTIuNiIgd2lkdGg9IjIuNCIgaGVpZ2h0PSIzNi40IiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTM1LjkgOTggOTYpIj48cmVjdCB4PSI5My41IiB5PSI0Mi44IiB3aWR0aD0iOSIgaGVpZ2h0PSI1My4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk1LjQiIHk9IjQ3LjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDEuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yNi4zIDEwMC43IDk2KSI+PHJlY3QgeD0iOTYuMiIgeT0iMzUuOSIgd2lkdGg9IjkiIGhlaWdodD0iNjAuMSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5OC4xIiB5PSI0MC45IiB3aWR0aD0iMi40IiBoZWlnaHQ9IjQ4LjEiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMjAuNiA5NC45IDk2KSI+PHJlY3QgeD0iOTAuNCIgeT0iMzYiIHdpZHRoPSI5IiBoZWlnaHQ9IjYwIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9IjkyLjMiIHk9IjQxIiB3aWR0aD0iMi40IiBoZWlnaHQ9IjQ4IiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTkuOCA5OS44IDk2KSI+PHJlY3QgeD0iOTUuMyIgeT0iNDcuMSIgd2lkdGg9IjkiIGhlaWdodD0iNDguOSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5Ny4yIiB5PSI1Mi4xIiB3aWR0aD0iMi40IiBoZWlnaHQ9IjM2LjkiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxIDk2LjcgOTYpIj48cmVjdCB4PSI5Mi4yIiB5PSIzOS44IiB3aWR0aD0iOSIgaGVpZ2h0PSI1Ni4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk0LjEiIHk9IjQ0LjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDQuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDEyLjIgOTkuNCA5NikiPjxyZWN0IHg9Ijk0LjkiIHk9IjM2LjciIHdpZHRoPSI5IiBoZWlnaHQ9IjU5LjMiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iOTYuOCIgeT0iNDEuNyIgd2lkdGg9IjIuNCIgaGVpZ2h0PSI0Ny4zIiByeD0iMS4yIiBmaWxsPSIjRjNEMDhBIiBzdHJva2U9Im5vbmUiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoMTguOCAxMDMuNyA5NikiPjxyZWN0IHg9Ijk5LjIiIHk9IjM0LjQiIHdpZHRoPSI5IiBoZWlnaHQ9IjYxLjYiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iMTAxLjEiIHk9IjM5LjQiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDkuNiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDI1LjUgMTAxLjUgOTYpIj48cmVjdCB4PSI5NyIgeT0iNDcuNSIgd2lkdGg9IjkiIGhlaWdodD0iNDguNSIgcng9IjIuNSIgZmlsbD0iI0U5QjM0NyIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48cmVjdCB4PSI5OC45IiB5PSI1Mi41IiB3aWR0aD0iMi40IiBoZWlnaHQ9IjM2LjUiIHJ4PSIxLjIiIGZpbGw9IiNGM0QwOEEiIHN0cm9rZT0ibm9uZSIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgzNi4xIDEwNS4yIDk2KSI+PHJlY3QgeD0iMTAwLjciIHk9IjM5LjEiIHdpZHRoPSI5IiBoZWlnaHQ9IjU2LjkiIHJ4PSIyLjUiIGZpbGw9IiNFOUIzNDciIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PHJlY3QgeD0iMTAyLjYiIHk9IjQ0LjEiIHdpZHRoPSIyLjQiIGhlaWdodD0iNDQuOSIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxnIHRyYW5zZm9ybT0icm90YXRlKDQzLjEgOTkuNSA5NikiPjxyZWN0IHg9Ijk1IiB5PSI0OC44IiB3aWR0aD0iOSIgaGVpZ2h0PSI0Ny4yIiByeD0iMi41IiBmaWxsPSIjRTlCMzQ3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMiIvPjxyZWN0IHg9Ijk2LjkiIHk9IjUzLjgiIHdpZHRoPSIyLjQiIGhlaWdodD0iMzUuMiIgcng9IjEuMiIgZmlsbD0iI0YzRDA4QSIgc3Ryb2tlPSJub25lIi8+PC9nPjxjaXJjbGUgY3g9IjE0MC41IiBjeT0iNzcuNSIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iOTQuNCIgY3k9Ijg4LjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjcxLjIiIGN5PSI2OS4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMTUuNiIgY3k9Ijc5LjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjcwLjYiIGN5PSI2MC4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSI1OS43IiBjeT0iODcuOSIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iOTQuNCIgY3k9IjYyLjIiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9Ijc1LjUiIGN5PSI2OS4zIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMjkuNiIgY3k9IjcwLjMiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9Ijg0LjgiIGN5PSI1Ni4xIiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxNDEuMyIgY3k9IjY4LjUiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxjaXJjbGUgY3g9IjExMS4yIiBjeT0iODQuOCIgcj0iMS4xIiBmaWxsPSIjRkZGRkZGIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC4zIi8+PGNpcmNsZSBjeD0iMTE4LjkiIGN5PSI2MS42IiByPSIxLjEiIGZpbGw9IiNGRkZGRkYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjMiLz48Y2lyY2xlIGN4PSIxMTguMSIgY3k9Ijg3LjgiIHI9IjEuMSIgZmlsbD0iI0ZGRkZGRiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuMyIvPjxlbGxpcHNlIGN4PSIxNTgiIGN5PSIxNzYiIHJ4PSI5IiByeT0iNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTU4IiBjeT0iMTY2IiByeD0iMTciIHJ5PSIxNSIgZmlsbD0idXJsKCNmY18yOTQ5MTQ0MikiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz48ZWxsaXBzZSBjeD0iMTU4IiBjeT0iMTU3IiByeD0iMTMiIHJ5PSI2IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjwvZz48L3N2Zz4='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%frite%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0NGRTBBNiIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNGM0I2RDgiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxLjIgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjYiIHJ4PSI1NiIgcnk9IjI4IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0zNiAxMDYgUTM0IDE1NCAxMDAgMTYwIFExNjYgMTU0IDE2NCAxMDYgUTEwMCAxMjIgMzYgMTA2IFoiIGZpbGw9IiNGREZCRjYiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjQiIHJ5PSIxNSIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMyIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIvPjxjbGlwUGF0aCBpZD0iZmJfMTAxNzY4MzgiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMDYiIHJ4PSI2MiIgcnk9IjE0Ii8+PC9jbGlwUGF0aD48ZyBjbGlwLXBhdGg9InVybCgjZmJfMTAxNzY4MzgpIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIgZmlsbD0iI0NGRTBBNiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMDMiIHJ4PSI0MSIgcnk9IjciIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHBhdGggZD0iTTQ2IDEwOSBRNzQgMTAwIDEwMCAxMDggUTEyNiAxMTUgMTU0IDEwNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZGNlZGIzIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjEwMS4yIiBjeT0iOTguNSIgcj0iMS45IiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iNzIuMiIgY3k9IjEwMy4yIiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI0Ni4zIiBjeT0iOTcuMyIgcj0iMS40IiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iNDguOSIgY3k9Ijk3LjIiIHI9IjIuMyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9Ijk4LjIiIGN5PSIxMTAuOSIgcj0iMS4zIiBmaWxsPSIjNUM4QTRBIi8+PGNpcmNsZSBjeD0iMTM2LjciIGN5PSI5Ni42IiByPSIxLjQiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSIxMjIuMyIgY3k9IjEwNS40IiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI1MC4yIiBjeT0iMTEyLjUiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEyMi40IiBjeT0iOTgiIHI9IjEuNyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEwMS42IiBjeT0iOTkiIHI9IjEuNiIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjEzMy40IiBjeT0iMTExLjgiIHI9IjEuNyIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjE0NS43IiBjeT0iMTE2IiByPSIxLjgiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSIxMTEuOCIgY3k9Ijk3LjciIHI9IjEuOCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExMi4yIiBjeT0iMTAwLjMiIHI9IjEuNiIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9Ijk2LjkiIGN5PSI5OC41IiByPSIxLjMiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI3OCIgY3k9IjExMC45IiByPSIxLjUiIGZpbGw9IiM1QzhBNEEiLz48Y2lyY2xlIGN4PSI5OS42IiBjeT0iMTA5LjkiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExNS44IiBjeT0iMTA5LjgiIHI9IjIuMSIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjQ0LjgiIGN5PSIxMDMiIHI9IjEuNCIgZmlsbD0iIzVDOEE0QSIvPjxjaXJjbGUgY3g9IjExNS41IiBjeT0iMTAxLjIiIHI9IjEuOSIgZmlsbD0iIzVDOEE0QSIvPjxwYXRoIGQ9Ik01OCAxMDIgUTgwIDExNCAxMDAgMTAzIFExMjAgMTE0IDE0MiAxMDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5OTQyQiIgc3Ryb2tlLXdpZHRoPSIyLjIiIHN0cm9rZS1vcGFjaXR5PSIwLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSIxMjMuMSIgY3k9IjEwMC45IiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0yMSAxMjMuMSAxMDAuOSkiLz48ZWxsaXBzZSBjeD0iNjguMyIgY3k9IjEwMy4yIiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKDI2IDY4LjMgMTAzLjIpIi8+PGVsbGlwc2UgY3g9Ijc1IiBjeT0iMTA2LjciIHJ4PSI0LjIiIHJ5PSIzIiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgdHJhbnNmb3JtPSJyb3RhdGUoNCA3NSAxMDYuNykiLz48ZWxsaXBzZSBjeD0iMTQxIiBjeT0iMTA3LjciIHJ4PSI0LjIiIHJ5PSIzIiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgdHJhbnNmb3JtPSJyb3RhdGUoMjMgMTQxIDEwNy43KSIvPjxlbGxpcHNlIGN4PSIxNDEuNyIgY3k9IjExMS4xIiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0xNyAxNDEuNyAxMTEuMSkiLz48ZWxsaXBzZSBjeD0iNjYuOCIgY3k9IjEwOS44IiByeD0iNC4yIiByeT0iMyIgZmlsbD0iI0I1ODI0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEiIHRyYW5zZm9ybT0icm90YXRlKC0zMCA2Ni44IDEwOS44KSIvPjwvZz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIvPjxlbGxpcHNlIGN4PSI5NiIgY3k9Ijk3IiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKC0yMiA5NiA5NykiLz48ZWxsaXBzZSBjeD0iMTA3IiBjeT0iMTAwIiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKDI0IDEwNyAxMDApIi8+PC9nPjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%houmous%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgxLjcgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjIiIHJ4PSI3MiIgcnk9IjM0IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMTIiIHJ4PSI3OCIgcnk9IjQyIiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjExMiIgcng9IjYzIiByeT0iMzIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHN0cm9rZS1vcGFjaXR5PSIwLjMiLz48ZWxsaXBzZSBjeD0iNzAiIGN5PSIxMDkiIHJ4PSIxNyIgcnk9IjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTg4LjEgOTggUTg4LjggMTA0LjYgODguMyAxMDcuNCBRODEuOCAxMDkuMyA3Ny43IDExMS40IFE3Mi41IDExMi40IDY3IDExNC41IFE2MC43IDExMS44IDU2LjcgMTEwLjMgUTUyLjcgMTA4LjMgNTAuOSAxMDIuNSBRNTAgOTcuOSA1Mi45IDk0IFE1NC4xIDg5LjcgNTcuNSA4Ni40IFE2My4xIDgzLjcgNjcgODEuMyBRNzIuMiA4My40IDc4LjkgODIuNCBRODMuMiA4Ni45IDg0LjkgOTAuMyBRODYuNiA5Mi4zIDg4LjEgOTggWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MSA5NCBRNzAgODggNzkgOTMiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjYzLjIiIGN5PSIxMDQuMyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY3LjgiIGN5PSIxMDUuNCIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY4LjUiIGN5PSI5Mi42IiByPSIxLjMiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNjYuMyIgY3k9IjEwMyIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjY3LjUiIGN5PSI5Ny43IiByPSIxIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxMTIiIGN5PSIxMDEuOSIgcng9IjE1LjMiIHJ5PSI1LjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEyOC42IDkyIFExMjYuMSA5NC42IDEyNi43IDk5LjYgUTEyMC43IDEwMS45IDExOC42IDEwMy41IFExMTIgMTAzLjIgMTA5LjQgMTA2LjYgUTEwNC41IDEwNiA5OS4yIDEwMy44IFE5Ny4yIDk5LjggOTQuNyA5Ni4xIFE5NC4yIDkwLjYgOTMuNyA4Ny43IFE5Ny41IDgyLjkgOTkuOSA4MC44IFExMDMuNSA3OC40IDEwOS43IDc5LjQgUTExMy4zIDc4LjEgMTE4LjYgODAuNSBRMTIxLjMgODMuNiAxMjcuMyA4NC4xIFExMjggODkuMyAxMjguNiA5MiBaIiBmaWxsPSIjRTNCMjRCIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTEwMy45IDg4LjQgUTExMiA4MyAxMjAuMSA4Ny41IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxMDEuMiIgY3k9Ijk3LjYiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTEuOSIgY3k9Ijg3LjgiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMDUuNCIgY3k9Ijk1LjQiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMjAuOSIgY3k9Ijg2LjciIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTUuNyIgY3k9IjkzLjEiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iOTYiIGN5PSIxMzQuNCIgcng9IjE2LjEiIHJ5PSI1LjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTExNS41IDEyNCBRMTE1LjIgMTI5LjQgMTExLjEgMTMxLjggUTEwNS44IDEzNC42IDEwMy4yIDEzNi43IFE5OS45IDEzOC45IDkzLjMgMTM5LjEgUTg4LjkgMTM3LjkgODQuNCAxMzQuNyBRODAuNCAxMzEgNzkuMyAxMjcuOSBRNzcuMSAxMjMuMiA3OC42IDExOS45IFE4MC4yIDExNy42IDgzLjcgMTEyLjYgUTg3LjYgMTExLjYgOTMuNiAxMTAuNyBRMTAwLjIgMTEwLjQgMTAzLjUgMTEwLjkgUTEwNy41IDExNS4xIDExMC44IDExNi40IFExMTQuNSAxMTguNSAxMTUuNSAxMjQgWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik04Ny41IDEyMC4yIFE5NiAxMTQuNSAxMDQuNSAxMTkuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iOTcuNyIgY3k9IjExOS40IiByPSIwLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iOTEuMSIgY3k9IjEzMS4xIiByPSIxLjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTA2LjIiIGN5PSIxMTYuMiIgcj0iMS4zIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijk5LjMiIGN5PSIxMjEuOSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEwNy4yIiBjeT0iMTE3LjEiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iMTM2IiBjeT0iMTI5LjMiIHJ4PSIxNC40IiByeT0iNS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0xNTEuNCAxMjAgUTE1MC44IDEyNS4yIDE0OC41IDEyNi40IFExNDUuNyAxMzAuMyAxNDMgMTMyLjIgUTEzOS44IDEzNC4zIDEzMy41IDEzMy45IFExMzEuMiAxMzMuNiAxMjUuMSAxMzAuMSBRMTI0LjIgMTI3LjkgMTIwLjQgMTIzLjcgUTEyMC45IDExOC4yIDExOC4xIDExNS44IFExMjEuOCAxMTMuNiAxMjYuMSAxMTAuOSBRMTI5LjcgMTA4LjQgMTMzLjYgMTA2LjcgUTEzNy4zIDEwNiAxNDMuOCAxMDYuNCBRMTQ2LjcgMTEwLjUgMTUwLjUgMTEyLjUgUTE1Mi4zIDExNyAxNTEuNCAxMjAgWiIgZmlsbD0iI0RDQTgzQSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMjguMyAxMTYuNiBRMTM2IDExMS41IDE0My43IDExNS44IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxMzMuNiIgY3k9IjEyMS42IiByPSIxLjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTQ1LjEiIGN5PSIxMjAuNyIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzMi4yIiBjeT0iMTE5LjgiIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxNDIuNCIgY3k9IjExMy45IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTM4LjEiIGN5PSIxMjEuMyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxNDgiIGN5PSIxMzAiIHJ4PSIxOSIgcnk9IjE2IiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi42Ii8+PGVsbGlwc2UgY3g9IjE0OCIgY3k9IjEzMCIgcng9IjEzIiByeT0iMTAiIGZpbGw9IiM3QTRBMjIiIGZpbGwtb3BhY2l0eT0iMC44Ii8+PGVsbGlwc2UgY3g9IjE0NCIgY3k9IjEyNiIgcng9IjUiIHJ5PSIzIiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yMiA2MiAxMzQpIj48cGF0aCBkPSJNNDYgMTM0IEExNiAxNiAwIDAgMSA3OCAxMzQgWiIgZmlsbD0iI0U5RDY0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MiAxMzQgTDYyIDExOSBNNTMgMTMzIEw2MCAxMjAgTTcxIDEzMyBMNjQgMTIwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik00NiAxMzQgQTE2IDE2IDAgMCAxIDc4IDEzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPjwvZz48ZWxsaXBzZSBjeD0iNjAiIGN5PSI5NiIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjggNjAgOTYpIi8+PGVsbGlwc2UgY3g9IjY4IiBjeT0iOTIiIHJ4PSI1IiByeT0iOSIgZmlsbD0iIzVDOEE0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMiIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgNjggOTIpIi8+PC9nPjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%tempura%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS42IDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTUyIiByeD0iNjgiIHJ5PSIyMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTQyIiByeD0iNzQiIHJ5PSIzMCIgZmlsbD0iI0ZERkJGNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxNDIiIHJ4PSI1OSIgcnk9IjIwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGVsbGlwc2UgY3g9Ijc2IiBjeT0iMTM5IiByeD0iMzYiIHJ5PSI1IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjbGlwUGF0aCBpZD0iY3ExXzIzMTM4MiI+PHBhdGggZD0iTTM4IDEzNiBMMTE0IDEzNiBMNzYgNzAgWiIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2NxMV8yMzEzODIpIj48cmVjdCB4PSIzNCIgeT0iMTE2LjIiIHdpZHRoPSI4NCIgaGVpZ2h0PSIxOS44IiBmaWxsPSIjRUZDMTcwIi8+PHJlY3QgeD0iMzQiIHk9IjEwOC4zIiB3aWR0aD0iODQiIGhlaWdodD0iNy45IiBmaWxsPSIjRTlDNDZBIi8+PHJlY3QgeD0iMzQiIHk9Ijk5IiB3aWR0aD0iODQiIGhlaWdodD0iOS4yIiBmaWxsPSIjRDk4QThBIi8+PHJlY3QgeD0iMzQiIHk9IjcwIiB3aWR0aD0iODQiIGhlaWdodD0iMjkiIGZpbGw9IiNGN0RCQTQiLz48cmVjdCB4PSIzNCIgeT0iMTE2LjIiIHdpZHRoPSI4NCIgaGVpZ2h0PSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHJlY3QgeD0iMzQiIHk9IjEwOC4zIiB3aWR0aD0iODQiIGhlaWdodD0iMS40IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxyZWN0IHg9IjM0IiB5PSI5OSIgd2lkdGg9Ijg0IiBoZWlnaHQ9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48Y2lyY2xlIGN4PSI1OS44IiBjeT0iMTIyLjkiIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2Ni43IiBjeT0iMTI5LjciIHI9IjEuMiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI5NS40IiBjeT0iMTE5LjgiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2OS4yIiBjeT0iMTI2LjMiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4My44IiBjeT0iMTMwLjUiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI3My42IiBjeT0iMTMzLjEiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4MC4zIiBjeT0iMTMyLjIiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI2MyIgY3k9IjgxLjkiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI3MC43IiBjeT0iODQuMSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjgwLjEiIGN5PSI5MS42IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iNzUuOCIgY3k9IjgwLjkiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSI4MCIgY3k9IjkwLjIiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iNjQuOCIgY3k9IjExNC4xIiByeD0iMi41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMzQgNjQuOCAxMTQuMSkiLz48ZWxsaXBzZSBjeD0iOTcuNiIgY3k9IjExMS40IiByeD0iMy41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMSA5Ny42IDExMS40KSIvPjxlbGxpcHNlIGN4PSI2Ny4xIiBjeT0iMTA2LjUiIHJ4PSIzIiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSg1OCA2Ny4xIDEwNi41KSIvPjxlbGxpcHNlIGN4PSI5OC45IiBjeT0iMTEzLjUiIHJ4PSIzLjUiIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDY2IDk4LjkgMTEzLjUpIi8+PGVsbGlwc2UgY3g9IjY0LjIiIGN5PSIxMTEuNyIgcng9IjMuMiIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoNTUgNjQuMiAxMTEuNykiLz48ZWxsaXBzZSBjeD0iOTcuOSIgY3k9IjEwMi4zIiByeD0iMy4xIiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgxMTkgOTcuOSAxMDIuMykiLz48L2c+PHBhdGggZD0iTTM4IDEzNiBMNzYgNzAgTDExNCAxMzYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M1OEEzNCIgc3Ryb2tlLXdpZHRoPSI1IiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMzggMTM2IEwxMTQgMTM2IEw3NiA3MCBaIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSIxMjgiIGN5PSIxNDUiIHJ4PSIzMyIgcnk9IjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNsaXBQYXRoIGlkPSJjcTJfMjMxMzgyIj48cGF0aCBkPSJNOTQgMTQyIEwxNjIgMTQyIEwxMjggODQgWiIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2NxMl8yMzEzODIpIj48cmVjdCB4PSI5MCIgeT0iMTI0LjYiIHdpZHRoPSI3NiIgaGVpZ2h0PSIxNy40IiBmaWxsPSIjRUZDMTcwIi8+PHJlY3QgeD0iOTAiIHk9IjExNy42IiB3aWR0aD0iNzYiIGhlaWdodD0iNyIgZmlsbD0iI0U5QzQ2QSIvPjxyZWN0IHg9IjkwIiB5PSIxMDkuNSIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjguMSIgZmlsbD0iI0Q5OEE4QSIvPjxyZWN0IHg9IjkwIiB5PSI4NCIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjI1LjUiIGZpbGw9IiNGN0RCQTQiLz48cmVjdCB4PSI5MCIgeT0iMTI0LjYiIHdpZHRoPSI3NiIgaGVpZ2h0PSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4zIi8+PHJlY3QgeD0iOTAiIHk9IjExNy42IiB3aWR0aD0iNzYiIGhlaWdodD0iMS40IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxyZWN0IHg9IjkwIiB5PSIxMDkuNSIgd2lkdGg9Ijc2IiBoZWlnaHQ9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48Y2lyY2xlIGN4PSIxMTcuMyIgY3k9IjEzMi4yIiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iMTQzLjQiIGN5PSIxMzguMSIgcj0iMS45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjE0NS4yIiBjeT0iMTMyLjgiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzEuMyIgY3k9IjEzNy41IiByPSIxLjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGNpcmNsZSBjeD0iMTUwLjUiIGN5PSIxMzMuMSIgcj0iMS45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjEwNy44IiBjeT0iMTI3LjUiIHI9IjEuOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSIxMzkuNiIgcj0iMi4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxjaXJjbGUgY3g9IjEyNi45IiBjeT0iMTA0LjYiIHI9IjEuMyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzQuMiIgY3k9Ijk5LjIiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzUuMiIgY3k9Ijk0LjIiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMjEuNyIgY3k9Ijk0LjciIHI9IjEuOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48Y2lyY2xlIGN4PSIxMzQuNCIgY3k9IjEwMC41IiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGVsbGlwc2UgY3g9IjExNy4xIiBjeT0iMTE2LjMiIHJ4PSIyLjciIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDAgMTE3LjEgMTE2LjMpIi8+PGVsbGlwc2UgY3g9IjEzMy42IiBjeT0iMTE2LjEiIHJ4PSIyLjYiIHJ5PSIxLjMiIGZpbGw9IiMzMzI5MUYiIHRyYW5zZm9ybT0icm90YXRlKDUzIDEzMy42IDExNi4xKSIvPjxlbGxpcHNlIGN4PSIxMjguNSIgY3k9IjExNi43IiByeD0iMy41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSg1MyAxMjguNSAxMTYuNykiLz48ZWxsaXBzZSBjeD0iMTQ0LjEiIGN5PSIxMTQuNCIgcng9IjMuMiIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoMTc2IDE0NC4xIDExNC40KSIvPjxlbGxpcHNlIGN4PSIxMjYuMSIgY3k9IjExMS43IiByeD0iMi41IiByeT0iMS4zIiBmaWxsPSIjMzMyOTFGIiB0cmFuc2Zvcm09InJvdGF0ZSgyMCAxMjYuMSAxMTEuNykiLz48ZWxsaXBzZSBjeD0iMTEyLjUiIGN5PSIxMTkuNyIgcng9IjIuOSIgcnk9IjEuMyIgZmlsbD0iIzMzMjkxRiIgdHJhbnNmb3JtPSJyb3RhdGUoMTM2IDExMi41IDExOS43KSIvPjwvZz48cGF0aCBkPSJNOTQgMTQyIEwxMjggODQgTDE2MiAxNDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M1OEEzNCIgc3Ryb2tlLXdpZHRoPSI1IiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNOTQgMTQyIEwxNjIgMTQyIEwxMjggODQgWiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48ZWxsaXBzZSBjeD0iMTYwIiBjeT0iMTE4IiByeD0iNSIgcnk9IjkiIGZpbGw9IiM1QzhBNEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjIiIHRyYW5zZm9ybT0icm90YXRlKDM0IDE2MCAxMTgpIi8+PHBhdGggZD0iTTQ2IDEyOCBRNDAgMTM2IDQ0IDE0NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzk5NDJCIiBzdHJva2Utd2lkdGg9IjIuMiIgc3Ryb2tlLW9wYWNpdHk9IjAuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PC9nPjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%croque%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0NGRTBBNiIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNGM0I2RDgiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMi4yIDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTI2IiByeD0iNTYiIHJ5PSIyOCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48cGF0aCBkPSJNMzYgMTA2IFEzNCAxNTQgMTAwIDE2MCBRMTY2IDE1NCAxNjQgMTA2IFExMDAgMTIyIDM2IDEwNiBaIiBmaWxsPSIjRkRGQkY2IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjY0IiByeT0iMTUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjMiIHN0cm9rZS1vcGFjaXR5PSIwLjMiLz48Y2xpcFBhdGggaWQ9ImZiXzMzMDQxMjg4Ij48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTA2IiByeD0iNjIiIHJ5PSIxNCIvPjwvY2xpcFBhdGg+PGcgY2xpcC1wYXRoPSJ1cmwoI2ZiXzMzMDQxMjg4KSI+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjYyIiByeT0iMTQiIGZpbGw9IiNGM0VFRTIiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTAzIiByeD0iNDEiIHJ5PSI3IiBmaWxsPSIjRkZGRkZGIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxwYXRoIGQ9Ik00NiAxMDkgUTc0IDEwMCAxMDAgMTA4IFExMjYgMTE1IDE1NCAxMDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2U2ZTFkNSIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSIxNTMuMSIgY3k9Ijk3LjQiIHI9IjEuOSIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjQ1LjEiIGN5PSIxMTIiIHI9IjEuNiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjUzIiBjeT0iOTguNSIgcj0iMS41IiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iNzUuMSIgY3k9IjExMS42IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI5MS44IiBjeT0iOTYuMyIgcj0iMi4xIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iMTUwLjciIGN5PSIxMTUuMSIgcj0iMi4zIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iMTA4LjgiIGN5PSIxMDkuNyIgcj0iMS4zIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iODUuMyIgY3k9Ijk2LjgiIHI9IjEuNCIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjE0MC42IiBjeT0iMTA3LjQiIHI9IjEuNyIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9Ijc5IiBjeT0iMTEyLjQiIHI9IjEuNCIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjEwOC4yIiBjeT0iMTA4LjEiIHI9IjEuNyIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjEyNy45IiBjeT0iMTA4LjEiIHI9IjEuOSIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjExNC41IiBjeT0iMTA2IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSIxNDYuMSIgY3k9IjExMi4xIiByPSIyLjIiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI0Ny4zIiBjeT0iOTUuNyIgcj0iMiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjYyLjQiIGN5PSIxMDYuNSIgcj0iMi4xIiBmaWxsPSIjN0E5NDUwIi8+PGNpcmNsZSBjeD0iOTcuMSIgY3k9IjExMS41IiByPSIxLjkiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSIxMTIuMyIgY3k9IjEwNC42IiByPSIxLjYiIGZpbGw9IiM3QTk0NTAiLz48Y2lyY2xlIGN4PSI5OC4xIiBjeT0iMTE0LjUiIHI9IjEuNiIgZmlsbD0iIzdBOTQ1MCIvPjxjaXJjbGUgY3g9IjE0My4xIiBjeT0iOTguMSIgcj0iMS45IiBmaWxsPSIjN0E5NDUwIi8+PHBhdGggZD0iTTU4IDEwMiBRODAgMTE0IDEwMCAxMDMgUTEyMCAxMTQgMTQyIDEwMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzk5NDJCIiBzdHJva2Utd2lkdGg9IjIuMiIgc3Ryb2tlLW9wYWNpdHk9IjAuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEyNS45IDExMyBxNi4yIDQuNiAxMi40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzLjciIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMjUuOSAxMTMgcTYuMiA0LjYgMTIuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNODguOSAxMDAuMiBxOC45IC0yLjcgMTcuOCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi45IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNODguOSAxMDAuMiBxOC45IC0yLjcgMTcuOCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTcuMyA5OCBxMTAuNiAzLjkgMjEuMiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy44IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTcuMyA5OCBxMTAuNiAzLjkgMjEuMiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTIzLjMgOTkuMyBxNy4xIC0xLjIgMTQuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTIzLjMgOTkuMyBxNy4xIC0xLjIgMTQuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTI0LjQgMTA1LjkgcTcuMyAyLjUgMTQuNiAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEyNC40IDEwNS45IHE3LjMgMi41IDE0LjYgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuOCIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEzOS40IDk3LjEgcTcuMiA0LjIgMTQuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMi42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTM5LjQgOTcuMSBxNy4yIDQuMiAxNC40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMTEuNiAxMDUuOSBxMTAuMiAyLjYgMjAuNCAwIiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMy42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTExLjYgMTA1LjkgcTEwLjIgMi42IDIwLjQgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjAuOCIgc3Ryb2tlLW9wYWNpdHk9IjAuMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTEzNi41IDEwMC40IHE4LjggNC41IDE3LjYgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMzYuNSAxMDAuNCBxOC44IDQuNSAxNy42IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik05OC44IDEwNS4zIHE4LjYgMy43IDE3LjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTk4LjggMTA1LjMgcTguNiAzLjcgMTcuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNNTQuNiAxMDguMSBxMTEuNyAwIDIzLjUgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTU0LjYgMTA4LjEgcTExLjcgMCAyMy41IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMTguMiA5OSBxMTEuMSAtMS4zIDIyLjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjIuOSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTExOC4yIDk5IHExMS4xIC0xLjMgMjIuMyAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48cGF0aCBkPSJNMTQxLjcgMTExLjMgcTguMiAtNC41IDE2LjMgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTE0MS43IDExMS4zIHE4LjIgLTQuNSAxNi4zIDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik01MS4zIDEwNi45IHE2LjcgMCAxMy40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIzLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik01MS4zIDEwNi45IHE2LjcgMCAxMy40IDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIwLjgiIHN0cm9rZS1vcGFjaXR5PSIwLjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xNDEuOCAxMDcuMSBxOCAtMi4yIDE1LjkgMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjMuNyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PHBhdGggZD0iTTE0MS44IDEwNy4xIHE4IC0yLjIgMTUuOSAwIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMC44IiBzdHJva2Utb3BhY2l0eT0iMC4zIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L2c+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjEwNiIgcng9IjYyIiByeT0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiLz48ZWxsaXBzZSBjeD0iOTYiIGN5PSI5NyIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjIgOTYgOTcpIi8+PGVsbGlwc2UgY3g9IjEwNyIgY3k9IjEwMCIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgyNCAxMDcgMTAwKSIvPjwvZz48L3N2Zz4='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%tracia%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0Y0QTU3QSIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNFOUM0NkEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtMS4yIDEwMCAxMDApIj48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTIyIiByeD0iNzIiIHJ5PSIzNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTAwIiBjeT0iMTEyIiByeD0iNzgiIHJ5PSI0MiIgZmlsbD0iI0ZERkJGNiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjMuMiIvPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMTIiIHJ4PSI2MyIgcnk9IjMyIiBmaWxsPSJub25lIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiBzdHJva2Utb3BhY2l0eT0iMC4zIi8+PGVsbGlwc2UgY3g9IjY0IiBjeT0iMTA0LjIiIHJ4PSIxMi44IiByeT0iNC41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik03OC44IDk2IFE3OC43IDEwMC44IDc2LjkgMTAyLjYgUTc1LjIgMTAzLjEgNzAuMSAxMDYuNiBRNjcuMyAxMDUuMyA2Mi4xIDEwNi43IFE1Ny40IDEwNy4zIDUzLjQgMTA1LjggUTUyLjMgMTAzLjcgNDkuMiA5OS41IFE1MC4xIDk1LjYgNTAuNCA5Mi44IFE1MS40IDkwLjYgNTQuMiA4NyBRNTcuNyA4NC45IDYxLjkgODQuMSBRNjYuNyA4Mi44IDcwLjUgODQuNiBRNzQuMSA4Ny40IDc3LjMgODkuMiBRNzYuOCA5My40IDc4LjggOTYgWiIgZmlsbD0iI0U5QzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik01Ny4yIDkzIFE2NCA4OC41IDcwLjggOTIuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iNzAuNCIgY3k9IjEwMCIgcj0iMC45IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjcyLjEiIGN5PSI5MS45IiByPSIxLjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNTciIGN5PSIxMDEuNSIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjU4LjEiIGN5PSI5MC41IiByPSIxLjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iNjMuNiIgY3k9Ijk4LjUiIHI9IjEuMSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48ZWxsaXBzZSBjeD0iOTAiIGN5PSI5Ny4yIiByeD0iMTEiIHJ5PSIzLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEwMi45IDkwIFExMDMuNCA5My4zIDEwMS43IDk2IFE5OS43IDk3LjIgOTQuOSA5OC41IFE5MC44IDk4LjYgODguMSAxMDAuNiBRODUuNSA5OS4zIDgxLjIgOTguMSBRNzguNCA5NSA3Ni43IDkzLjEgUTc1LjkgOTEuMSA3Ny4xIDg3IFE3OS40IDg0LjEgODEuMSA4MS44IFE4NC44IDgxLjMgODguMyA4MC40IFE5MC45IDgxLjIgOTQuOCA4MS42IFE5OC42IDgyLjggMTAxLjMgODQuMiBRMTAzLjkgODUuOSAxMDIuOSA5MCBaIiBmaWxsPSIjRjBENDhBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTg0LjIgODcuNCBROTAgODMuNSA5NS44IDg2LjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjkzLjUiIGN5PSI5MC4xIiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iOTYuOCIgY3k9Ijk0LjgiIHI9IjEuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSI4OC4xIiBjeT0iODUuMiIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjkzLjgiIGN5PSI4NS40IiByPSIxLjYiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iODcuMyIgY3k9IjkwLjMiIHI9IjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9IjExNiIgY3k9IjEwNC4yIiByeD0iMTIuOCIgcnk9IjQuNSIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48cGF0aCBkPSJNMTMyLjEgOTYgUTEzMC40IDk4LjIgMTI5LjUgMTAyLjkgUTEyNS4xIDEwNC42IDEyMi41IDEwNy4zIFExMTcuNyAxMDguMyAxMTQuMSAxMDYuNyBRMTEyLjQgMTAzLjkgMTA3LjUgMTAzLjkgUTEwNC41IDEwMy4zIDEwMy4xIDk5IFExMDQuNyA5NS4zIDEwMy41IDkzLjEgUTEwMy41IDkwLjEgMTA3LjEgODcuNyBRMTA5LjggODQuMSAxMTMuOCA4My43IFExMTkuNSA4NC40IDEyMi4zIDg1IFExMjQuNCA4NS42IDEyOS4xIDg5LjMgUTEyOC44IDkxLjQgMTMyLjEgOTYgWiIgZmlsbD0iI0UzQjI0QiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMDkuMiA5MyBRMTE2IDg4LjUgMTIyLjggOTIuMiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iMTExLjUiIGN5PSI5Mi43IiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTIxLjYiIGN5PSI5OC41IiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTExLjkiIGN5PSI5MS40IiByPSIxLjciIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTE1LjQiIGN5PSI5MC4zIiByPSIxLjMiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTA5LjYiIGN5PSI5NC42IiByPSIxLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9IjE0MCIgY3k9IjExMS4yIiByeD0iMTEiIHJ5PSIzLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTE1MyAxMDQgUTE1My4zIDEwNS4xIDE1MiAxMTAuMiBRMTQ3LjUgMTEyLjkgMTQ1LjQgMTEzLjUgUTE0MS42IDExNC4yIDEzOCAxMTUuMyBRMTM2LjMgMTEzLjkgMTMyLjEgMTExLjMgUTEzMCAxMDkuMyAxMjYuNCAxMDcuMiBRMTI4LjQgMTA2IDEyNi42IDEwMC45IFExMzEuMSA5Ni45IDEzMi4zIDk2LjkgUTEzNC4yIDkzLjYgMTM4LjEgOTMuNCBRMTQxLjQgOTMuMSAxNDQuOSA5NS40IFExNDcuOSA5Ny41IDE1MS44IDk3LjkgUTE1My4zIDk5LjYgMTUzIDEwNCBaIiBmaWxsPSIjRENBODNBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTEzNC4yIDEwMS40IFExNDAgOTcuNSAxNDUuOCAxMDAuOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjRkZGRkZGIiBzdHJva2Utd2lkdGg9IjEuNiIgc3Ryb2tlLW9wYWNpdHk9IjAuNiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+PGNpcmNsZSBjeD0iMTQxLjYiIGN5PSIxMDMuMyIgcj0iMS42IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzNy4xIiBjeT0iMTA1LjQiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxNDMuNyIgY3k9IjEwMi4yIiByPSIxLjQiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTM1LjMiIGN5PSIxMDQuOCIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjEzOS43IiBjeT0iMTA2LjUiIHI9IjEiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGVsbGlwc2UgY3g9Ijc4IiBjeT0iMTI3LjciIHJ4PSIxMS45IiByeT0iNC4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik05MiAxMjAgUTkwLjYgMTIzLjUgOTAuMyAxMjYuMyBRODguNCAxMjkuMSA4NCAxMzAuNiBRODAgMTMwLjQgNzYuMSAxMzAuNCBRNzEuMSAxMzAuOCA3MCAxMjcuNCBRNjUuOCAxMjcgNjQuOSAxMjMuMSBRNjcgMTE5LjcgNjUuMyAxMTcgUTY3LjIgMTEzLjggNjkuNyAxMTIuNCBRNzEuOCAxMDkuNSA3Ni4yIDEwOS44IFE4MC4zIDExMCA4My44IDEwOS44IFE4NS4yIDExMiA5MC40IDExMy42IFE5MS4xIDExNy44IDkyIDEyMCBaIiBmaWxsPSIjRTlDNDZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTcxLjcgMTE3LjIgUTc4IDExMyA4NC4zIDExNi41IiBmaWxsPSJub25lIiBzdHJva2U9IiNGRkZGRkYiIHN0cm9rZS13aWR0aD0iMS42IiBzdHJva2Utb3BhY2l0eT0iMC42IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48Y2lyY2xlIGN4PSI3NS40IiBjeT0iMTI0LjYiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSI3OSIgY3k9IjEyNS4xIiByPSIxIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc5LjgiIGN5PSIxMTcuNiIgcj0iMS4zIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc4LjYiIGN5PSIxMTcuMiIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9Ijc5LjciIGN5PSIxMjQuNyIgcj0iMS4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxlbGxpcHNlIGN4PSIxMjYiIGN5PSIxMjkuNyIgcng9IjExLjkiIHJ5PSI0LjIiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PHBhdGggZD0iTTEzOC45IDEyMiBRMTM4LjcgMTIzLjIgMTM3LjMgMTI3LjggUTEzMi44IDEzMS4zIDEzMS4yIDEzMSBRMTI3LjMgMTMyLjQgMTI0LjIgMTMyLjIgUTEyMS45IDEzMi43IDExNy41IDEyOS44IFExMTUuNSAxMjguNCAxMTEuNiAxMjUuNCBRMTEwLjMgMTIwLjEgMTEyLjMgMTE4LjggUTExNi44IDExNi4xIDExNy45IDExNC41IFExMTkuNSAxMTMuMiAxMjQuMiAxMTEuOCBRMTI4IDEwOS42IDEzMi4zIDExMC45IFExMzcuMiAxMTIuNiAxMzguMiAxMTUuNyBRMTM5LjEgMTE4LjcgMTM4LjkgMTIyIFoiIGZpbGw9IiNGMEQ0OEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNMTE5LjcgMTE5LjIgUTEyNiAxMTUgMTMyLjMgMTE4LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0ZGRkZGRiIgc3Ryb2tlLXdpZHRoPSIxLjYiIHN0cm9rZS1vcGFjaXR5PSIwLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxjaXJjbGUgY3g9IjEzNC4zIiBjeT0iMTIxLjIiIHI9IjEuNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMjIuOSIgY3k9IjExNy4zIiByPSIwLjkiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4yIi8+PGNpcmNsZSBjeD0iMTI0LjkiIGN5PSIxMTkuNyIgcj0iMS41IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxjaXJjbGUgY3g9IjExOS40IiBjeT0iMTE4LjkiIHI9IjEuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48Y2lyY2xlIGN4PSIxMTgiIGN5PSIxMjQuNSIgcj0iMS4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMiIvPjxnIHRyYW5zZm9ybT0icm90YXRlKC0yMiA2MiAxMzQpIj48cGF0aCBkPSJNNDYgMTM0IEExNiAxNiAwIDAgMSA3OCAxMzQgWiIgZmlsbD0iI0U5RDY0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik02MiAxMzQgTDYyIDExOSBNNTMgMTMzIEw2MCAxMjAgTTcxIDEzMyBMNjQgMTIwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxwYXRoIGQ9Ik00NiAxMzQgQTE2IDE2IDAgMCAxIDc4IDEzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjQzlBMjRCIiBzdHJva2Utd2lkdGg9IjEuNiIvPjwvZz48ZWxsaXBzZSBjeD0iNjAiIGN5PSI5NiIgcng9IjUiIHJ5PSI5IiBmaWxsPSIjNUM4QTRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS4yIiB0cmFuc2Zvcm09InJvdGF0ZSgtMjggNjAgOTYpIi8+PGVsbGlwc2UgY3g9IjY4IiBjeT0iOTIiIHJ4PSI1IiByeT0iOSIgZmlsbD0iIzVDOEE0QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuMiIgdHJhbnNmb3JtPSJyb3RhdGUoMjAgNjggOTIpIi8+PC9nPjwvc3ZnPg=='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%fritto%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNEOUE0NDEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjMgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjQiIHJ4PSI4MCIgcnk9IjIwIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0yMiA5OCBRMjAgMTM4IDQwIDE0MiBMMTYwIDE0MiBRMTgwIDEzOCAxNzggOTggUTE3OCA2OCAxNjAgNjQgTDQwIDY0IFEyMiA2OCAyMiA5OCBaIiBmaWxsPSIjQzM5NDU3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTMyIDc4IFExMDAgNzAgMTY4IDc4IE0zMCAxMDQgUTEwMCA5NiAxNzAgMTA0IE0zNCAxMjYgUTEwMCAxMTggMTY2IDEyNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjOEE1QTJCIiBzdHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxjaXJjbGUgY3g9IjEwMCIgY3k9IjY0IiByPSI0LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGVsbGlwc2UgY3g9IjYwIiBjeT0iOTciIHJ4PSIxNiIgcnk9IjExLjUiIGZpbGw9IiMxQzJBNEEiIGZpbGwtb3BhY2l0eT0iMC4xIi8+PGVsbGlwc2UgY3g9IjY4LjMiIGN5PSI5My40IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgtNSA2OC4zIDkzLjQpIi8+PGVsbGlwc2UgY3g9IjY1LjgiIGN5PSI5OC44IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSg0NiA2NS44IDk4LjgpIi8+PGVsbGlwc2UgY3g9IjU4LjQiIGN5PSIxMDAuNiIgcng9IjcuNCIgcnk9IjUuNCIgZmlsbD0iI0M5N0E2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAxIDU4LjQgMTAwLjYpIi8+PGVsbGlwc2UgY3g9IjUyLjEiIGN5PSI5Ni4xIiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgxNjEgNTIuMSA5Ni4xKSIvPjxlbGxpcHNlIGN4PSI1Mi4xIiBjeT0iOTEuOCIgcng9IjcuNCIgcnk9IjUuNCIgZmlsbD0iI0M5N0E2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTk5IDUyLjEgOTEuOCkiLz48ZWxsaXBzZSBjeD0iNTcuMyIgY3k9Ijg3LjciIHJ4PSI3LjQiIHJ5PSI1LjQiIGZpbGw9IiNDOTdBNkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDI1MSA1Ny4zIDg3LjcpIi8+PGVsbGlwc2UgY3g9IjY0LjUiIGN5PSI4OC40IiByeD0iNy40IiByeT0iNS40IiBmaWxsPSIjQzk3QTZBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgzMDMgNjQuNSA4OC40KSIvPjxjaXJjbGUgY3g9IjYwIiBjeT0iOTQiIHI9IjQuOCIgZmlsbD0iI0YwQzlBOCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxlbGxpcHNlIGN4PSI5MiIgY3k9IjkxIiByeD0iMTUiIHJ5PSIxMC44IiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSI5OS44IiBjeT0iODcuNiIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoLTQgOTkuOCA4Ny42KSIvPjxlbGxpcHNlIGN4PSI5Ni4zIiBjeT0iOTMuMyIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoNTcgOTYuMyA5My4zKSIvPjxlbGxpcHNlIGN4PSI5MC4zIiBjeT0iOTQuMiIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAyIDkwLjMgOTQuMikiLz48ZWxsaXBzZSBjeD0iODQuOCIgY3k9IjkwLjQiIHJ4PSI2LjkiIHJ5PSI1LjEiIGZpbGw9IiNCODVBNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1OCA4NC44IDkwLjQpIi8+PGVsbGlwc2UgY3g9Ijg0LjkiIGN5PSI4NS4zIiByeD0iNi45IiByeT0iNS4xIiBmaWxsPSIjQjg1QTU0IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgyMDUgODQuOSA4NS4zKSIvPjxlbGxpcHNlIGN4PSI4OS40IiBjeT0iODIuMSIgcng9IjYuOSIgcnk9IjUuMSIgZmlsbD0iI0I4NUE1NCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMjUwIDg5LjQgODIuMSkiLz48ZWxsaXBzZSBjeD0iOTcuNSIgY3k9IjgzLjUiIHJ4PSI2LjkiIHJ5PSI1LjEiIGZpbGw9IiNCODVBNTQiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDMxNSA5Ny41IDgzLjUpIi8+PGNpcmNsZSBjeD0iOTIiIGN5PSI4OCIgcj0iNC41IiBmaWxsPSIjRjBDOUE4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGVsbGlwc2UgY3g9IjEyNCIgY3k9Ijk5IiByeD0iMTQiIHJ5PSIxMC4xIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxlbGxpcHNlIGN4PSIxMzEuMyIgY3k9Ijk2LjMiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDMgMTMxLjMgOTYuMykiLz48ZWxsaXBzZSBjeD0iMTI5LjMiIGN5PSIxMDAiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDQ0IDEyOS4zIDEwMCkiLz48ZWxsaXBzZSBjeD0iMTIyLjQiIGN5PSIxMDEuNyIgcng9IjYuNCIgcnk9IjQuOCIgZmlsbD0iI0QwOEE3MiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMTAzIDEyMi40IDEwMS43KSIvPjxlbGxpcHNlIGN4PSIxMTcuNyIgY3k9Ijk4LjkiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1MSAxMTcuNyA5OC45KSIvPjxlbGxpcHNlIGN4PSIxMTcuOSIgY3k9IjkyLjgiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDIxMyAxMTcuOSA5Mi44KSIvPjxlbGxpcHNlIGN4PSIxMjIuMSIgY3k9IjkwLjMiIHJ4PSI2LjQiIHJ5PSI0LjgiIGZpbGw9IiNEMDhBNzIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDI1NSAxMjIuMSA5MC4zKSIvPjxlbGxpcHNlIGN4PSIxMjcuOCIgY3k9IjkxIiByeD0iNi40IiByeT0iNC44IiBmaWxsPSIjRDA4QTcyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgzMDIgMTI3LjggOTEpIi8+PGNpcmNsZSBjeD0iMTI0IiBjeT0iOTYiIHI9IjQuMiIgZmlsbD0iI0YwQzlBOCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNCIvPjxlbGxpcHNlIGN4PSIxNTQiIGN5PSIxMDkiIHJ4PSIxMyIgcnk9IjkuNCIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZWxsaXBzZSBjeD0iMTYwLjgiIGN5PSIxMDYuMSIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDEgMTYwLjggMTA2LjEpIi8+PGVsbGlwc2UgY3g9IjE1Ny45IiBjeT0iMTEwLjUiIHJ4PSI2IiByeT0iNC40IiBmaWxsPSIjQTg0QTQ4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSg1NSAxNTcuOSAxMTAuNSkiLz48ZWxsaXBzZSBjeD0iMTUyLjgiIGN5PSIxMTEuNCIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDEwMCAxNTIuOCAxMTEuNCkiLz48ZWxsaXBzZSBjeD0iMTQ3LjgiIGN5PSIxMDguMSIgcng9IjYiIHJ5PSI0LjQiIGZpbGw9IiNBODRBNDgiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiIHRyYW5zZm9ybT0icm90YXRlKDE1NyAxNDcuOCAxMDguMSkiLz48ZWxsaXBzZSBjeD0iMTQ4IiBjeT0iMTAzLjUiIHJ4PSI2IiByeT0iNC40IiBmaWxsPSIjQTg0QTQ4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42IiB0cmFuc2Zvcm09InJvdGF0ZSgyMDcgMTQ4IDEwMy41KSIvPjxlbGxpcHNlIGN4PSIxNTIuOSIgY3k9IjEwMC42IiByeD0iNiIgcnk9IjQuNCIgZmlsbD0iI0E4NEE0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMjYxIDE1Mi45IDEwMC42KSIvPjxlbGxpcHNlIGN4PSIxNTguOCIgY3k9IjEwMi4yIiByeD0iNiIgcnk9IjQuNCIgZmlsbD0iI0E4NEE0OCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIgdHJhbnNmb3JtPSJyb3RhdGUoMzE2IDE1OC44IDEwMi4yKSIvPjxjaXJjbGUgY3g9IjE1NCIgY3k9IjEwNiIgcj0iMy45IiBmaWxsPSIjRjBDOUE4IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS40Ii8+PGNpcmNsZSBjeD0iNzYiIGN5PSIxMjIiIHI9IjkiIGZpbGw9IiNDNDc0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iNzcuNiIgY3k9IjEyNi44IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSI3OS4zIiBjeT0iMTE3LjkiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9Ijc2LjQiIGN5PSIxMjUiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9Ijc5LjgiIGN5PSIxMTcuNiIgcj0iMS41IiBmaWxsPSIjRjNFMkQyIi8+PGNpcmNsZSBjeD0iNzEuMiIgY3k9IjExNy45IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDgiIGN5PSIxMjYiIHI9IjguNSIgZmlsbD0iI0M0NzQ2QSIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIiLz48Y2lyY2xlIGN4PSIxMTAuMyIgY3k9IjEyMS40IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDMuNSIgY3k9IjEyNy41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDcuNSIgY3k9IjEyNi42IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDguNiIgY3k9IjEyNy41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxMDUuOSIgY3k9IjEyMS41IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxNDAiIGN5PSIxMjQiIHI9IjgiIGZpbGw9IiNDNDc0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iMTM5LjgiIGN5PSIxMjIiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjE0MC4zIiBjeT0iMTE5LjkiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjEzOC42IiBjeT0iMTI3LjUiIHI9IjEuNSIgZmlsbD0iI0YzRTJEMiIvPjxjaXJjbGUgY3g9IjEzNyIgY3k9IjEyMC43IiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48Y2lyY2xlIGN4PSIxNDIuMSIgY3k9IjEyMi4yIiByPSIxLjUiIGZpbGw9IiNGM0UyRDIiLz48ZWxsaXBzZSBjeD0iNDIiIGN5PSIxMTgiIHJ4PSI1LjUiIHJ5PSIxMSIgZmlsbD0iIzhGQTM1QiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuOCIgdHJhbnNmb3JtPSJyb3RhdGUoLTIyIDQyIDExOCkiLz48ZWxsaXBzZSBjeD0iNTAiIGN5PSIxMjgiIHJ4PSI1IiByeT0iMTAiIGZpbGw9IiM3RTk0NTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjgiIHRyYW5zZm9ybT0icm90YXRlKDE0IDUwIDEyOCkiLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSIxMTIiIHI9IjUuNSIgZmlsbD0iIzRBM0EyMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNiIvPjxjaXJjbGUgY3g9IjE3MiIgY3k9IjEyNCIgcj0iNS41IiBmaWxsPSIjNEEzQTIyIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS42Ii8+PGNpcmNsZSBjeD0iMTYyIiBjeT0iMTI2IiByPSI1LjUiIGZpbGw9IiM0QTNBMjIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz48L2c+PC9zdmc+'
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%charcuterie%';

  update public.products set image_url = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyMDAgMjAwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Indhc2giIGN4PSIzNiUiIGN5PSIyNiUiIHI9IjgwJSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI0UyQzhCOCIgc3RvcC1vcGFjaXR5PSIwLjUiLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiNEOUE0NDEiIHN0b3Atb3BhY2l0eT0iMC4xIi8+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjIwMCIgaGVpZ2h0PSIyMDAiIGZpbGw9IiNGN0YxRTkiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSIxMDIiIHI9Ijk4IiBmaWxsPSJ1cmwoI3dhc2gpIi8+PGVsbGlwc2UgY3g9IjEwMCIgY3k9IjE3NiIgcng9IjQ2IiByeT0iNyIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjEiLz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgwLjYgMTAwIDEwMCkiPjxlbGxpcHNlIGN4PSIxMDAiIGN5PSIxMjQiIHJ4PSI4MCIgcnk9IjIwIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMSIvPjxwYXRoIGQ9Ik0yMiA5OCBRMjAgMTM4IDQwIDE0MiBMMTYwIDE0MiBRMTgwIDEzOCAxNzggOTggUTE3OCA2OCAxNjAgNjQgTDQwIDY0IFEyMiA2OCAyMiA5OCBaIiBmaWxsPSIjQzM5NDU3IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMy4yIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PHBhdGggZD0iTTMyIDc4IFExMDAgNzAgMTY4IDc4IE0zMCAxMDQgUTEwMCA5NiAxNzAgMTA0IE0zNCAxMjYgUTEwMCAxMTggMTY2IDEyNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjOEE1QTJCIiBzdHJva2Utd2lkdGg9IjEuNCIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIvPjxjaXJjbGUgY3g9IjEwMCIgY3k9IjY0IiByPSI0LjUiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGcgdHJhbnNmb3JtPSJyb3RhdGUoLTE0IDY4IDk4KSI+PHBhdGggZD0iTTQ2IDExMiBMNDYgODQgTDkyIDk4IFoiIGZpbGw9IiNGMEQ0OEEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48cGF0aCBkPSJNNDYgODQgTDkyIDk4IEw5MiAxMDQgTDQ2IDkwIFoiIGZpbGw9IiNFM0IyNEIiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyIi8+PGNpcmNsZSBjeD0iNjAiIGN5PSI5OCIgcj0iMi4yIiBmaWxsPSIjMUMyQTRBIiBmaWxsLW9wYWNpdHk9IjAuMyIvPjxjaXJjbGUgY3g9IjcwIiBjeT0iOTQiIHI9IjEuNiIgZmlsbD0iIzFDMkE0QSIgZmlsbC1vcGFjaXR5PSIwLjMiLz48L2c+PGcgdHJhbnNmb3JtPSJyb3RhdGUoOCAxMTggOTIpIj48cmVjdCB4PSI5OCIgeT0iNzgiIHdpZHRoPSI0MiIgaGVpZ2h0PSIyNiIgcng9IjMiIGZpbGw9IiNFOUM0NkEiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIyLjYiLz48cmVjdCB4PSI5OCIgeT0iNzgiIHdpZHRoPSI0MiIgaGVpZ2h0PSI3IiByeD0iMyIgZmlsbD0iI0M5OTQyQiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuOCIvPjwvZz48ZyB0cmFuc2Zvcm09InJvdGF0ZSgtNiAxNTAgMTE2KSI+PHBhdGggZD0iTTEzMCAxMzAgTDEzNiAxMDQgTDE3MiAxMDQgTDE2OCAxMzAgWiIgZmlsbD0iI0YzRUJEMiIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjIuNiIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPjxwYXRoIGQ9Ik0xMzYgMTA0IEwxNzIgMTA0IEwxNzEgMTEwIEwxMzUgMTEwIFoiIGZpbGw9IiNCOEIwQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjYiLz48ZWxsaXBzZSBjeD0iMTQ1LjYiIGN5PSIxMTkuMiIgcng9IjMuNSIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDEwNiAxNDUuNiAxMTkuMikiLz48ZWxsaXBzZSBjeD0iMTYwLjYiIGN5PSIxMTQiIHJ4PSIzLjMiIHJ5PSIxLjUiIGZpbGw9IiM0QTVBOEEiIGZpbGwtb3BhY2l0eT0iMC44IiB0cmFuc2Zvcm09InJvdGF0ZSgxMTAgMTYwLjYgMTE0KSIvPjxlbGxpcHNlIGN4PSIxNDUiIGN5PSIxMjEuOSIgcng9IjIuMyIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDYxIDE0NSAxMjEuOSkiLz48ZWxsaXBzZSBjeD0iMTUyLjIiIGN5PSIxMjEuNyIgcng9IjMuNCIgcnk9IjEuNSIgZmlsbD0iIzRBNUE4QSIgZmlsbC1vcGFjaXR5PSIwLjgiIHRyYW5zZm9ybT0icm90YXRlKDc3IDE1Mi4yIDEyMS43KSIvPjxlbGxpcHNlIGN4PSIxNjMuOCIgY3k9IjExNi45IiByeD0iMy41IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoNDEgMTYzLjggMTE2LjkpIi8+PGVsbGlwc2UgY3g9IjE2NC44IiBjeT0iMTIwIiByeD0iMy42IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoMjYgMTY0LjggMTIwKSIvPjxlbGxpcHNlIGN4PSIxMzkuNyIgY3k9IjEyNi40IiByeD0iMi42IiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoOSAxMzkuNyAxMjYuNCkiLz48ZWxsaXBzZSBjeD0iMTQ1LjEiIGN5PSIxMTgiIHJ4PSIzLjIiIHJ5PSIxLjUiIGZpbGw9IiM0QTVBOEEiIGZpbGwtb3BhY2l0eT0iMC44IiB0cmFuc2Zvcm09InJvdGF0ZSgxNTAgMTQ1LjEgMTE4KSIvPjxlbGxpcHNlIGN4PSIxNDIuNSIgY3k9IjEyNC4yIiByeD0iMy4xIiByeT0iMS41IiBmaWxsPSIjNEE1QThBIiBmaWxsLW9wYWNpdHk9IjAuOCIgdHJhbnNmb3JtPSJyb3RhdGUoNzMgMTQyLjUgMTI0LjIpIi8+PC9nPjxjaXJjbGUgY3g9IjQ0IiBjeT0iMTEyIiByPSI1LjUiIGZpbGw9IiM3QTVGQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjUiLz48Y2lyY2xlIGN4PSI1MiIgY3k9IjExOCIgcj0iNS41IiBmaWxsPSIjN0E1RkEwIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS41Ii8+PGNpcmNsZSBjeD0iNDYiIGN5PSIxMjYiIHI9IjUuNSIgZmlsbD0iIzdBNUZBMCIgc3Ryb2tlPSIjMUMyQTRBIiBzdHJva2Utd2lkdGg9IjEuNSIvPjxjaXJjbGUgY3g9IjU4IiBjeT0iMTI2IiByPSI1LjUiIGZpbGw9IiM3QTVGQTAiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxLjUiLz48cGF0aCBkPSJNNTAgMTA0IFE1NiA5NiA2NCA5NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjNUM4QTRBIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjxlbGxpcHNlIGN4PSI4OCIgY3k9IjEyNiIgcng9IjciIHJ5PSI2IiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS44Ii8+PHBhdGggZD0iTTg4IDEyMSBMODggMTMxIE04MyAxMjUgUTg4IDEyOCA5MyAxMjUiIHN0cm9rZT0iIzFDMkE0QSIgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2Utb3BhY2l0eT0iMC41IiBmaWxsPSJub25lIi8+PGVsbGlwc2UgY3g9IjEwMiIgY3k9IjEzMCIgcng9IjciIHJ5PSI2IiBmaWxsPSIjQjU4MjRBIiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMS44Ii8+PHBhdGggZD0iTTEwMiAxMjUgTDEwMiAxMzUgTTk3IDEyOSBRMTAyIDEzMiAxMDcgMTI5IiBzdHJva2U9IiMxQzJBNEEiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLW9wYWNpdHk9IjAuNSIgZmlsbD0ibm9uZSIvPjxwYXRoIGQ9Ik0xMTggMTA4IFExMjYgMTE4IDEyMiAxMjgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI0M5OTQyQiIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1vcGFjaXR5PSIwLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvZz48L3N2Zz4='
   where venue_id = p_venue and universe = 'food'
     and coalesce(image_url, '') = '' and lower(trim(name)) like '%fromage%';

end;
$$;

grant execute on function public.seed_noti_food(uuid) to authenticated;

-- Rétroactif, pour les établissements déjà en activité :
do $$
declare v_venue record;
begin
  for v_venue in select id from public.venues loop
    perform public.seed_noti_food(v_venue.id);
  end loop;
end $$;

-- ============================================================================
--  seed_noti_menu() reprend la version de 0017 et sème en plus la carte food :
--  recharger la carte crée/actualise les plats et leurs illustrations.
-- ============================================================================

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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
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

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  -- Étiquetage des articles éligibles aux forfaits à crédits (cf. 0013).
  perform public.tag_credit_menu(p_venue);

  -- Illustration par article (cf. 0017).
  perform public.tag_product_illustrations(p_venue);

  -- Carte food (plats + illustrations, cf. 0019).
  perform public.seed_noti_food(p_venue);

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;


-- ============================================================================
--  NOTI Calling — 0020_equipe_suivi_affluence.sql
--
--  Trois chantiers en un seul patch (à coller d'un bloc) :
--
--   1. ÉQUIPE — invitations par e-mail, rattachement automatique à la première
--      connexion, et trois rôles (owner / manager / staff) dont un accès
--      réduit pour l'équipe de bar.
--
--   2. SUIVI DES COMMANDES — commentaires et signalements horodatés sur chaque
--      commande, à tout stade, qui alimentent la fiche client (incidents).
--
--   3. AFFLUENCE — capacité de la soirée + vue des arrivées par tranche de
--      15 min, pour la jauge de remplissage côté staff.
--
--  Le modèle de crédits des forfaits ne change PAS : 1 alcool éligible vaut
--  toujours 2 crédits, 1 soft 1 crédit, et le jeton food reste convertible.
--  Ce qui change est uniquement la façon dont le staff CONFIGURE un forfait
--  (côté application) : il saisit un nombre de personnes et un nombre de
--  consos par personne, l'app faisant la conversion en crédits à sa place.
--
--  Patch cumulatif : s'exécute aussi bien sur une installation neuve que sur
--  une base déjà en service (tout est `if not exists` / `or replace`).
-- ============================================================================


-- ============================================================================
--  0 bis. RATTRAPAGE DE L'ÉTAPE « EN PRÉPARATION » (ex-0010 / 0011)
--
--  Une base installée avant le patch 0010 n'a pas la valeur 'IN_PREP' dans son
--  type order_status : la colonne « En préparation » du tableau du bar y est
--  alors inutilisable, et ce patch échouait à la création de la vue de
--  pilotage. On l'ajoute donc ici.
--
--  PostgreSQL autorise l'ajout d'une valeur d'enum dans une transaction, mais
--  INTERDIT de s'en servir avant le commit. Partout où ce patch a besoin de
--  comparer un statut à 'IN_PREP', il le fait donc sur `status::text` : c'est
--  une comparaison de texte, qui ne touche pas à l'enum et fonctionne aussi
--  bien avant qu'après. Rien à exécuter séparément.
-- ============================================================================
alter type public.order_status add value if not exists 'IN_PREP' after 'RECEIVED';

-- close_event() doit basculer les commandes restées « En préparation » en
-- impayé à la clôture, sinon elles resteraient bloquées dans cet état.
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
     and status::text in ('RECEIVED', 'IN_PREP', 'READY', 'PICKED_UP');
  get diagnostics n = row_count;

  update public.events set accept_orders = false, is_active = false where id = p_event;
  return n;
end;
$$;

grant execute on function public.close_event(uuid) to authenticated;


-- ============================================================================
--  0. REPRISE D'UNE VERSION ANTÉRIEURE DE CE PATCH
--
--  Une première version de 0020 remplaçait les crédits par une cagnotte en
--  euros. Elle est abandonnée. Ce bloc remet les codes concernés sur le modèle
--  à crédits ; il ne fait rien si cette version n'a jamais été exécutée.
--  Aucune donnée n'est perdue : les colonnes en crédits n'avaient pas été
--  touchées, seules des colonnes en euros avaient été ajoutées à côté.
-- ============================================================================
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'promo_codes'
                and column_name = 'credit_amount') then
    update public.promo_codes
       set kind = 'credits'
     where kind = 'credit'
       and coalesce(credits_per_person, 0) > 0;
  end if;
end $$;


-- ============================================================================
--  1. ÉQUIPE : INVITATIONS PAR E-MAIL ET RÔLES
-- ============================================================================

-- owner   : le créateur du lieu — accès complet + gestion de l'équipe
-- manager : accès complet, sauf la gestion de l'équipe et les mentions légales
-- staff   : accès réduit — bar, caisse, clients
create table if not exists public.staff_invites (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues (id) on delete cascade,
  email       text not null,
  role        text not null default 'staff',
  invited_by  uuid references auth.users (id) on delete set null,
  accepted_at timestamptz,
  accepted_by uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (venue_id, email)
);

create index if not exists staff_invites_email_idx on public.staff_invites (lower(email));

alter table public.staff_invites enable row level security;

-- Seul le propriétaire du lieu gère l'équipe. L'invité, lui, ne lit jamais
-- cette table : il passe par accept_my_staff_invites() (security definer).
drop policy if exists staff_invites_owner on public.staff_invites;
create policy staff_invites_owner on public.staff_invites
  for all to authenticated
  using      (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()));

/** Rôle de l'utilisateur courant sur un lieu — null s'il n'en fait pas partie. */
create or replace function public.my_venue_role(p_venue uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from public.venues v
                  where v.id = p_venue and v.owner_id = auth.uid()) then 'owner'
    else (select s.role from public.staff_members s
           where s.venue_id = p_venue and s.user_id = auth.uid())
  end;
$$;

-- ---------------------------------------------------------------------------
--  Rattachement automatique : appelé à chaque ouverture de l'espace équipe.
--  Toute invitation en attente adressée à l'e-mail du compte connecté devient
--  une adhésion. C'est ce qui permet d'inviter quelqu'un qui n'a pas encore de
--  compte : il crée le sien avec cet e-mail, et il est rattaché à l'entrée.
-- ---------------------------------------------------------------------------
create or replace function public.accept_my_staff_invites()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_inv   record;
  n       int := 0;
begin
  if auth.uid() is null or v_email = '' then return 0; end if;

  for v_inv in
    select * from public.staff_invites
     where lower(email) = v_email and accepted_at is null
  loop
    insert into public.staff_members (venue_id, user_id, role)
    values (v_inv.venue_id, auth.uid(), v_inv.role)
    on conflict (venue_id, user_id) do update set role = excluded.role;

    update public.staff_invites
       set accepted_at = now(), accepted_by = auth.uid()
     where id = v_inv.id;

    n := n + 1;
  end loop;

  return n;
end;
$$;

grant execute on function public.my_venue_role(uuid)       to authenticated;
grant execute on function public.accept_my_staff_invites() to authenticated;


-- ============================================================================
--  2. SUIVI DES COMMANDES : COMMENTAIRES ET SIGNALEMENTS
-- ============================================================================

-- Interne au staff : jamais lisible par le client.
create table if not exists public.order_notes (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders (id)    on delete cascade,
  event_id     uuid not null references public.events (id)    on delete cascade,
  customer_id  uuid references public.customers (id)          on delete set null,
  author_id    uuid references auth.users (id)                on delete set null,
  author_email text,
  flag         text not null default 'info',   -- info | attention | incident | geste
  body         text not null default '',
  created_at   timestamptz not null default now()
);

create index if not exists order_notes_order_idx    on public.order_notes (order_id, created_at desc);
create index if not exists order_notes_customer_idx on public.order_notes (customer_id, created_at desc);

alter table public.order_notes enable row level security;

drop policy if exists order_notes_staff on public.order_notes;
create policy order_notes_staff on public.order_notes
  for all to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- Compteur et drapeau le plus grave, dénormalisés sur la commande : le tableau
-- du bar affiche la pastille sans requête supplémentaire, et la mise à jour de
-- `orders` fait remonter le changement par le temps réel déjà en place.
alter table public.orders
  add column if not exists notes_count int not null default 0,
  add column if not exists flag        text;

create or replace function public.sync_order_notes()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_order uuid := coalesce(new.order_id, old.order_id);
begin
  update public.orders o
     set notes_count = (select count(*) from public.order_notes n where n.order_id = v_order),
         flag = (
           select n.flag from public.order_notes n
            where n.order_id = v_order
            order by case n.flag
                       when 'incident'  then 3
                       when 'attention' then 2
                       when 'geste'     then 1
                       else 0 end desc,
                     n.created_at desc
            limit 1
         )
   where o.id = v_order;
  return null;
end;
$$;

drop trigger if exists trg_order_notes on public.order_notes;
create trigger trg_order_notes
  after insert or delete on public.order_notes
  for each row execute function public.sync_order_notes();

-- ---------------------------------------------------------------------------
--  Un clic sur la commande, à n'importe quel stade. Un signalement « incident »
--  taggue aussi la fiche du client, comme le fait déjà un impayé.
-- ---------------------------------------------------------------------------
create or replace function public.add_order_note(
  p_order uuid,
  p_body  text,
  p_flag  text default 'info'
)
returns public.order_notes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
  v_row   public.order_notes;
begin
  select * into v_order from public.orders where id = p_order;
  if v_order.id is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_order.event_id) then raise exception 'forbidden'; end if;
  if coalesce(p_flag, 'info') not in ('info', 'attention', 'incident', 'geste') then
    raise exception 'invalid_flag';
  end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty_note'; end if;

  insert into public.order_notes
    (order_id, event_id, customer_id, author_id, author_email, flag, body)
  values
    (p_order, v_order.event_id, v_order.customer_id, auth.uid(),
     auth.jwt() ->> 'email', coalesce(p_flag, 'info'), trim(p_body))
  returning * into v_row;

  if p_flag = 'incident' and v_order.customer_id is not null then
    update public.customers
       set tags = case when 'incident' = any (tags) then tags
                       else array_append(tags, 'incident') end
     where id = v_order.customer_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.add_order_note(uuid, text, text) to authenticated;


-- ============================================================================
--  3. AFFLUENCE
-- ============================================================================

-- Dénominateur de la jauge de remplissage (null = pas de jauge, juste le compte).
alter table public.events
  add column if not exists capacity int;

-- Arrivées par tranche de 15 minutes — sert la courbe et le rythme d'arrivée.
create or replace view public.v_event_affluence
with (security_invoker = true) as
select
  a.event_id,
  date_trunc('hour', a.first_scan_at)
    + (floor(extract(minute from a.first_scan_at)::int / 15.0) * interval '15 minutes') as slot,
  count(*)::int                          as arrivals,
  coalesce(sum(a.group_size), 0)::int    as people
from public.attendances a
group by 1, 2;

grant select on public.v_event_affluence to authenticated;

-- ---------------------------------------------------------------------------
--  v_event_live — corrigée : `in_preparation` ne comptait que 'RECEIVED' et
--  ignorait le stade 'IN_PREP' ajouté depuis (0010), donc le compteur du
--  tableau de bord retombait à zéro dès qu'une commande passait « en
--  préparation ».
--
--  La liste de colonnes reste STRICTEMENT celle de 0003 : PostgreSQL refuse
--  qu'un `create or replace view` retire une colonne, et rejouer setup.sql
--  ferait alors repasser 0003 sur cette définition. Les indicateurs
--  d'affluence vivent donc dans leur propre vue, juste en dessous.
-- ---------------------------------------------------------------------------
create or replace view public.v_event_live
with (security_invoker = true) as
select
  e.id as event_id,
  (select count(*) from public.attendances a where a.event_id = e.id)              as present_count,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status::text in ('RECEIVED', 'IN_PREP'))          as in_preparation,
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

grant select on public.v_event_live to authenticated;

-- Indicateurs d'affluence temps réel, consommés par la jauge de remplissage.
create or replace view public.v_event_pulse
with (security_invoker = true) as
select
  e.id                                                                              as event_id,
  e.capacity                                                                        as capacity,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '15 minutes')   as arrivals_15min,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '60 minutes')   as arrivals_60min,
  (select count(*) from public.attendances a
    where a.event_id = e.id and a.last_scan_at >= now() - interval '30 minutes')    as active_30min,
  (select max(a.first_scan_at) from public.attendances a where a.event_id = e.id)   as last_arrival_at
from public.events e;

grant select on public.v_event_pulse to authenticated;


-- ============================================================================
--  4. CORRECTIONS SUR LES FORFAITS À CRÉDITS (modèle inchangé)
-- ============================================================================

-- ---------------------------------------------------------------------------
--  Historique fiable des codes activés par client. Jusqu'ici il fallait le
--  reconstituer depuis event_passes, qui ne garde qu'un seul code par soirée.
--  Sert la fiche client et l'export CSV.
-- ---------------------------------------------------------------------------
create table if not exists public.promo_redemptions (
  id             uuid primary key default gen_random_uuid(),
  promo_code_id  uuid not null references public.promo_codes (id) on delete cascade,
  customer_id    uuid not null references public.customers (id)   on delete cascade,
  event_id       uuid not null references public.events (id)      on delete cascade,
  credits_granted int not null default 0,
  created_at     timestamptz not null default now(),
  unique (promo_code_id, customer_id)
);

-- La première version de ce patch créait la même table avec un montant en
-- euros. `create table if not exists` ne l'aurait alors pas mise à jour :
-- on ajoute la colonne en crédits explicitement.
alter table public.promo_redemptions
  add column if not exists credits_granted int not null default 0;

create index if not exists promo_redemptions_customer_idx
  on public.promo_redemptions (customer_id, created_at desc);

alter table public.promo_redemptions enable row level security;

drop policy if exists promo_redemptions_read on public.promo_redemptions;
create policy promo_redemptions_read on public.promo_redemptions
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- ---------------------------------------------------------------------------
--  redeem_pass() — reprise de 0013, à deux corrections près :
--
--   · un code déjà épuisé renvoyait « invalid_pass_code », impossible à
--     distinguer d'une faute de frappe. Il renvoie maintenant
--     « code_exhausted », et l'incrément de uses_count sert de garde atomique :
--     deux personnes qui activent la dernière place en même temps ne peuvent
--     plus passer toutes les deux.
--   · l'activation est tracée dans promo_redemptions.
--
--  Le modèle de crédits lui-même est inchangé (jeton food inclus).
-- ---------------------------------------------------------------------------
create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust      uuid := public.my_customer_id();
  v_promo     public.promo_codes;
  v_pass      public.event_passes;
  v_now_paris time;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  -- Un pass par personne et par soirée : un second appel — inévitable puisque
  -- le client peut rescanner — renvoie le pass déjà actif, sans recréditer.
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is not null then
    return v_pass;
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind = 'credits'
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now());
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

  update public.promo_codes
     set uses_count = uses_count + 1
   where id = v_promo.id
     and (max_uses is null or uses_count < max_uses);
  if not found then raise exception 'code_exhausted'; end if;

  v_now_paris := (now() at time zone 'Europe/Paris')::time;

  insert into public.event_passes
    (event_id, customer_id, promo_code_id, credits_total, credits_remaining,
     food_token_total, food_token_available)
  values (
    p_event, v_cust, v_promo.id,
    v_promo.credits_per_person, v_promo.credits_per_person,
    v_promo.food_tokens_per_person,
    v_promo.food_tokens_per_person > 0 and v_now_paris < time '22:30:00'
  )
  returning * into v_pass;

  -- Arrivée après 22h30 : le jeton food est automatiquement converti en
  -- crédits (2 crédits par jeton), comme en 0013.
  if v_promo.food_tokens_per_person > 0 and v_now_paris >= time '22:30:00' then
    update public.event_passes
       set credits_total     = credits_total + v_promo.food_tokens_per_person * 2,
           credits_remaining = credits_remaining + v_promo.food_tokens_per_person * 2
     where id = v_pass.id
     returning * into v_pass;
  end if;

  insert into public.promo_redemptions
    (promo_code_id, customer_id, event_id, credits_granted)
  values (v_promo.id, v_cust, p_event, v_pass.credits_total)
  on conflict (promo_code_id, customer_id) do nothing;

  return v_pass;
end;
$$;

grant execute on function public.redeem_pass(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
--  place_order() — reprise EXACTE de la version 0013 (mécanique de crédits
--  inchangée : credit_kind / credit_once / jeton food), avec un seul ajout :
--  `credit_units_used` mémorise le nombre de crédits consommés par la
--  commande, ce qui permet de les rendre si elle est annulée. Sans cela,
--  annuler une commande au bar faisait perdre au client des crédits qu'il
--  n'avait jamais consommés.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists credit_units_used int not null default 0,
  add column if not exists food_token_used   boolean not null default false;

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
  v_pass         public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
  v_credits_used int := 0;
  v_food_used    boolean := false;
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
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;

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

    -- ---- Forfait Noti : consommation du portefeuille (crédits / jeton food) ----
    if v_pass.id is not null then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining >= v_wallet_cost then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_credits_used := v_credits_used + v_wallet_cost;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_qty, v_pass.credits_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
          v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_food_used := true;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable avec le forfait
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := v_discount + least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  if v_pass.id is not null then
    update public.event_passes
       set credits_remaining    = v_pass.credits_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.orders
     set subtotal          = v_subtotal,
         discount          = v_discount,
         total             = greatest(0, v_subtotal - v_discount),
         credit_units_used = v_credits_used,
         food_token_used   = v_food_used,
         promo_code        = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;

-- ---------------------------------------------------------------------------
--  Annulation d'une commande : les crédits (et le jeton food) consommés sont
--  rendus au client.
-- ---------------------------------------------------------------------------
create or replace function public.refund_credits_on_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'CANCELLED'
     and old.status is distinct from 'CANCELLED'
     and (coalesce(old.credit_units_used, 0) > 0 or coalesce(old.food_token_used, false)) then

    update public.event_passes
       set credits_remaining = least(credits_total,
                                     credits_remaining + coalesce(old.credit_units_used, 0)),
           food_token_available = food_token_available or coalesce(old.food_token_used, false)
     where event_id = new.event_id and customer_id = new.customer_id;

    new.credit_units_used := 0;
    new.food_token_used   := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_credit_refund on public.orders;
create trigger trg_orders_credit_refund
  before update on public.orders
  for each row execute function public.refund_credits_on_cancel();

-- ---------------------------------------------------------------------------
--  preview_promo() — reprise de 0008 avec le filtre de type qui manquait.
--  Sans lui, un code de forfait était accepté par l'aperçu et affiché au
--  client comme une remise de 0,00 €, alors qu'il ne s'applique pas ainsi.
-- ---------------------------------------------------------------------------
create or replace function public.preview_promo(p_event uuid, p_code text, p_subtotal numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo    public.promo_codes;
  v_discount numeric(10,2) := 0;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind in ('percent', 'amount')
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses)
      and min_total <= coalesce(p_subtotal, 0);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  v_discount := least(
    case when v_promo.kind = 'amount' then v_promo.value
         else round(coalesce(p_subtotal, 0) * v_promo.value / 100, 2) end,
    coalesce(p_subtotal, 0));

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'discount', v_discount
  );
end;
$$;

grant execute on function public.preview_promo(uuid, text, numeric) to authenticated;


-- ============================================================================
--  NOTI Calling — 0021_codes_cadeaux.sql
--
--  CODES « ARTICLE OFFERT »
--
--  Jusqu'ici un code promo ne savait faire que trois choses : une remise en
--  pourcentage, une remise en montant, ou créditer un forfait de groupe en
--  crédits abstraits. Il manquait le cas le plus courant côté promoteur :
--  « je crée un code SOIREENOTI1, valable pour 6 personnes, qui donne UNE
--  BOISSON ALCOOLISÉE OFFERTE ».
--
--  Ce patch ajoute ce quatrième type. Un code cadeau porte une ou plusieurs
--  lignes, chacune définissant ce qui est offert :
--
--    · par CATÉGORIE — « 1 boisson alcoolisée au choix, jusqu'à 15 € »
--      Le client prend l'article qu'il veut dans la catégorie ; au-delà du
--      plafond il règle la différence au bar.
--    · par ARTICLE PRÉCIS — « 1 Spritz »
--      Le client n'a pas le choix, le promoteur maîtrise exactement le coût.
--
--  Et surtout : chaque cadeau consommé est JOURNALISÉ précisément — quel
--  article exact, à quelle heure, pour quel montant couvert, sur quelle
--  commande. C'est ce qui alimente la fiche client côté administrateur et
--  l'alerte affichée au bar.
--
--  Le modèle de crédits des forfaits (0013) n'est pas touché : les deux
--  coexistent, un client peut avoir un forfait ET un cadeau.
--
--  Patch cumulatif : s'exécute sur une installation neuve comme sur une base
--  déjà en service. Nécessite 0013 et 0020.
-- ============================================================================


-- ============================================================================
--  1. DÉFINITION DU CADEAU, PORTÉE PAR LE CODE PROMO
-- ============================================================================

-- gift_items : tableau JSON décrivant ce que le code offre à CHAQUE personne.
--   [{"mode":"category","category":"alcohol","quantity":1,"max_value":15},
--    {"mode":"product","product_id":"<uuid>","quantity":1}]
--
--   mode      : 'category' (au choix dans la catégorie) | 'product' (article précis)
--   category  : 'alcohol' | 'soft' | 'food' | 'bottle'
--   quantity  : nombre d'articles offerts par personne
--   max_value : plafond en € (mode 'category' uniquement ; null = sans plafond)
alter table public.promo_codes
  add column if not exists gift_items jsonb not null default '[]'::jsonb;

comment on column public.promo_codes.gift_items is
  'Lignes de cadeau d''un code kind=''gift''. Voir 0021_codes_cadeaux.sql.';


-- ============================================================================
--  2. DROITS ACQUIS PAR LE CLIENT (ce qu''il lui reste à consommer)
-- ============================================================================
create table if not exists public.gift_entitlements (
  id                 uuid primary key default gen_random_uuid(),
  event_id           uuid not null references public.events (id)      on delete cascade,
  customer_id        uuid not null references public.customers (id)   on delete cascade,
  promo_code_id      uuid not null references public.promo_codes (id) on delete cascade,
  mode               text not null,                    -- 'category' | 'product'
  category           text,                             -- si mode = 'category'
  product_id         uuid references public.products (id) on delete set null,
  max_value          numeric(10, 2),                   -- plafond € (mode category)
  quantity_total     int not null default 1,
  quantity_remaining int not null default 1,
  created_at         timestamptz not null default now()
);

create index if not exists gift_entitlements_lookup_idx
  on public.gift_entitlements (event_id, customer_id, quantity_remaining);

alter table public.gift_entitlements enable row level security;

drop policy if exists gift_entitlements_read on public.gift_entitlements;
create policy gift_entitlements_read on public.gift_entitlements
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));


-- ============================================================================
--  3. JOURNAL DES CADEAUX CONSOMMÉS
--
--  Le cœur de la demande : « a utilisé son crédit à 23h14 pour un Spritz ».
--  On garde un instantané du nom et du prix, pour que la ligne reste lisible
--  même si l'article est ensuite renommé ou retiré de la carte.
-- ============================================================================
create table if not exists public.gift_redemptions (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events (id)          on delete cascade,
  customer_id    uuid not null references public.customers (id)       on delete cascade,
  promo_code_id  uuid references public.promo_codes (id)              on delete set null,
  entitlement_id uuid references public.gift_entitlements (id)        on delete set null,
  order_id       uuid references public.orders (id)                   on delete cascade,
  product_id     uuid references public.products (id)                 on delete set null,
  product_name   text not null default '',
  unit_price     numeric(10, 2) not null default 0,   -- prix carte de l'article
  covered        numeric(10, 2) not null default 0,   -- part offerte
  paid           numeric(10, 2) not null default 0,   -- reste à charge (dépassement)
  redeemed_at    timestamptz not null default now()
);

create index if not exists gift_redemptions_customer_idx
  on public.gift_redemptions (customer_id, redeemed_at desc);
create index if not exists gift_redemptions_event_idx
  on public.gift_redemptions (event_id, redeemed_at desc);
create index if not exists gift_redemptions_order_idx
  on public.gift_redemptions (order_id);

alter table public.gift_redemptions enable row level security;

drop policy if exists gift_redemptions_read on public.gift_redemptions;
create policy gift_redemptions_read on public.gift_redemptions
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- Marqueur sur la commande : le bar doit voir d'un coup d'œil qu'elle porte
-- un cadeau. Dénormalisé pour que le tableau du bar n'ait pas de requête en
-- plus, et pour que le temps réel déjà en place sur `orders` le propage.
alter table public.orders
  add column if not exists gift_count int not null default 0,
  add column if not exists gift_total numeric(10, 2) not null default 0;


-- ============================================================================
--  4. CATÉGORIE D'UN ARTICLE, AU SENS DES CADEAUX
-- ============================================================================
create or replace function public.gift_category_of(
  p_universe public.universe,
  p_is_alcohol boolean
)
returns text
language sql immutable
as $$
  select case
    when p_universe = 'food'    then 'food'
    when p_universe = 'bottles' then 'bottle'
    when p_is_alcohol           then 'alcohol'
    else 'soft'
  end;
$$;

grant execute on function public.gift_category_of(public.universe, boolean) to authenticated;


-- ============================================================================
--  5. ACTIVATION D'UN CODE CADEAU
--
--  Idempotente par personne : promo_redemptions (unique sur code+client) sert
--  de garde. L'incrément de uses_count sert de garde atomique sur max_uses —
--  deux personnes ne peuvent pas prendre la même dernière place.
-- ============================================================================
create or replace function public.redeem_gift_code(p_event uuid, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_item  jsonb;
  v_qty   int;
  v_lines int := 0;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event
      and upper(code) = upper(trim(p_code))
      and active
      and kind = 'gift'
      and (starts_at is null or starts_at <= now())
      and (ends_at   is null or ends_at   >= now());
  if v_promo.id is null then raise exception 'invalid_gift_code'; end if;

  -- Déjà activé par cette personne : on renvoie l'état, sans rien recréditer
  -- ni consommer d'utilisation.
  if exists (select 1 from public.promo_redemptions
              where promo_code_id = v_promo.id and customer_id = v_cust) then
    return jsonb_build_object(
      'already', true,
      'code', v_promo.code,
      'label', v_promo.label,
      'items', public.my_gift_summary(p_event)
    );
  end if;

  update public.promo_codes
     set uses_count = uses_count + 1
   where id = v_promo.id
     and (max_uses is null or uses_count < max_uses);
  if not found then raise exception 'code_exhausted'; end if;

  for v_item in select * from jsonb_array_elements(coalesce(v_promo.gift_items, '[]'::jsonb)) loop
    v_qty := greatest(1, least(20, coalesce((v_item ->> 'quantity')::int, 1)));

    insert into public.gift_entitlements
      (event_id, customer_id, promo_code_id, mode, category, product_id,
       max_value, quantity_total, quantity_remaining)
    values (
      p_event, v_cust, v_promo.id,
      coalesce(v_item ->> 'mode', 'category'),
      nullif(v_item ->> 'category', ''),
      nullif(v_item ->> 'product_id', '')::uuid,
      nullif(v_item ->> 'max_value', '')::numeric,
      v_qty, v_qty
    );
    v_lines := v_lines + 1;
  end loop;

  insert into public.promo_redemptions (promo_code_id, customer_id, event_id, credits_granted)
  values (v_promo.id, v_cust, p_event, 0)
  on conflict (promo_code_id, customer_id) do nothing;

  return jsonb_build_object(
    'already', false,
    'code', v_promo.code,
    'label', v_promo.label,
    'lines', v_lines,
    'items', public.my_gift_summary(p_event)
  );
end;
$$;

-- ---------------------------------------------------------------------------
--  Résumé lisible des cadeaux qu'il reste au client sur la soirée — affiché
--  sur sa carte (« 1 boisson alcoolisée offerte »).
-- ---------------------------------------------------------------------------
create or replace function public.my_gift_summary(p_event uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'mode', e.mode,
           'category', e.category,
           'product_id', e.product_id,
           'product_name', p.name,
           'max_value', e.max_value,
           'remaining', e.quantity_remaining,
           'total', e.quantity_total
         ) order by e.created_at), '[]'::jsonb)
  from public.gift_entitlements e
  left join public.products p on p.id = e.product_id
  where e.event_id = p_event
    and e.customer_id = public.my_customer_id()
    and e.quantity_remaining > 0;
$$;

grant execute on function public.redeem_gift_code(uuid, text) to authenticated;
grant execute on function public.my_gift_summary(uuid)         to authenticated;


-- ============================================================================
--  6. place_order() — reprise de la version 0020, avec la consommation des
--     cadeaux AVANT les crédits de forfait.
--
--     Pour chaque ligne du panier, on cherche un droit acquis qui couvre
--     l'article — le cadeau sur article précis primant sur le cadeau par
--     catégorie, car c'est le plus spécifique. Chaque unité couverte donne
--     une ligne dans gift_redemptions : article exact, prix carte, part
--     offerte, reste à charge, horodatage.
-- ============================================================================
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
  v_pass         public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
  v_credits_used int := 0;
  v_food_used    boolean := false;
  v_ent          public.gift_entitlements;
  v_gift_cat     text;
  v_gift_left    int;
  v_gift_take    int;
  v_gift_covered numeric(10,2);
  v_gift_count   int := 0;
  v_gift_total   numeric(10,2) := 0;
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
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;

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

    -- ------------------------------------------------------------------
    --  CADEAUX : consommés en premier, et journalisés unité par unité.
    -- ------------------------------------------------------------------
    v_gift_left := v_qty;
    v_gift_cat := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);

    loop
      exit when v_gift_left <= 0;

      select * into v_ent from public.gift_entitlements e
        where e.event_id = p_event
          and e.customer_id = v_cust
          and e.quantity_remaining > 0
          and (
            (e.mode = 'product'  and e.product_id = v_prod.id)
            or (e.mode = 'category' and e.category = v_gift_cat)
          )
        order by (e.mode = 'product') desc, e.created_at
        limit 1;

      exit when v_ent.id is null;

      v_gift_take := least(v_gift_left, v_ent.quantity_remaining);
      v_gift_covered := case
        when v_ent.max_value is null then v_unit
        else least(v_unit, v_ent.max_value)
      end;

      update public.gift_entitlements
         set quantity_remaining = quantity_remaining - v_gift_take
       where id = v_ent.id;

      -- Une ligne de journal par unité offerte : c'est ce qui permet d'écrire
      -- « a utilisé son cadeau à 23h14 pour un Spritz » dans la fiche client.
      insert into public.gift_redemptions
        (event_id, customer_id, promo_code_id, entitlement_id, order_id,
         product_id, product_name, unit_price, covered, paid)
      select p_event, v_cust, v_ent.promo_code_id, v_ent.id, v_order.id,
             v_prod.id,
             v_prod.name || coalesce(' (' || v_vlabel || ')', ''),
             v_unit, v_gift_covered, greatest(0, v_unit - v_gift_covered)
        from generate_series(1, v_gift_take);

      v_discount   := v_discount + v_gift_covered * v_gift_take;
      v_gift_total := v_gift_total + v_gift_covered * v_gift_take;
      v_gift_count := v_gift_count + v_gift_take;
      v_gift_left  := v_gift_left - v_gift_take;
      v_ent := null;
    end loop;

    -- ---- Forfait Noti : le portefeuille ne couvre que ce qui reste -------
    if v_pass.id is not null and v_gift_left > 0 then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining >= v_wallet_cost then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_credits_used := v_credits_used + v_wallet_cost;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_gift_left, v_pass.credits_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
          v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_food_used := true;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := v_discount + least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  if v_pass.id is not null then
    update public.event_passes
       set credits_remaining    = v_pass.credits_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.orders
     set subtotal          = v_subtotal,
         discount          = least(v_discount, v_subtotal),
         total             = greatest(0, v_subtotal - v_discount),
         credit_units_used = v_credits_used,
         food_token_used   = v_food_used,
         gift_count        = v_gift_count,
         gift_total        = v_gift_total,
         promo_code        = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;


-- ============================================================================
--  7. ANNULATION : les cadeaux consommés sont rendus
-- ============================================================================
create or replace function public.refund_credits_on_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_r record;
begin
  if new.status = 'CANCELLED' and old.status is distinct from 'CANCELLED' then

    -- Crédits de forfait et jeton food (comportement de 0020)
    if coalesce(old.credit_units_used, 0) > 0 or coalesce(old.food_token_used, false) then
      update public.event_passes
         set credits_remaining = least(credits_total,
                                       credits_remaining + coalesce(old.credit_units_used, 0)),
             food_token_available = food_token_available or coalesce(old.food_token_used, false)
       where event_id = new.event_id and customer_id = new.customer_id;

      new.credit_units_used := 0;
      new.food_token_used   := false;
    end if;

    -- Cadeaux : on rend chaque unité à son droit d'origine, puis on efface
    -- les lignes de journal — la commande annulée n'a rien consommé.
    if coalesce(old.gift_count, 0) > 0 then
      for v_r in
        select entitlement_id, count(*)::int as n
          from public.gift_redemptions
         where order_id = new.id and entitlement_id is not null
         group by entitlement_id
      loop
        update public.gift_entitlements
           set quantity_remaining = least(quantity_total, quantity_remaining + v_r.n)
         where id = v_r.entitlement_id;
      end loop;

      delete from public.gift_redemptions where order_id = new.id;

      new.gift_count := 0;
      new.gift_total := 0;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_credit_refund on public.orders;
create trigger trg_orders_credit_refund
  before update on public.orders
  for each row execute function public.refund_credits_on_cancel();


-- ============================================================================
--  8. FICHE CLIENT ADMINISTRATEUR — TOUT CE QUI A ÉTÉ COLLECTÉ
--
--  Une seule fonction qui rassemble l'ensemble des informations d'un client :
--  identité, consentements, statistiques, présence sur la soirée en cours,
--  forfait, cadeaux reçus et consommés (horodatés, article par article),
--  codes activés, commandes et signalements de l'équipe.
-- ============================================================================
create or replace function public.customer_dossier(p_customer uuid, p_event uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
begin
  -- Le staff ne voit que les clients passés sur SES événements.
  if not exists (
    select 1 from public.attendances a
    join public.events e on e.id = a.event_id
    where a.customer_id = p_customer and public.is_staff(e.venue_id)
  ) then
    raise exception 'forbidden';
  end if;

  select jsonb_build_object(
    'customer', (select to_jsonb(c) from public.customers c where c.id = p_customer),

    'attendance', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'event_id', a.event_id,
               'event_name', e.name,
               'first_scan_at', a.first_scan_at,
               'last_scan_at', a.last_scan_at,
               'group_size', a.group_size,
               'scan_point', sp.label
             ) order by a.first_scan_at desc), '[]'::jsonb)
      from public.attendances a
      join public.events e on e.id = a.event_id
      left join public.scan_points sp on sp.id = a.scan_point_id
      where a.customer_id = p_customer
    ),

    'gifts_received', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', pc.code,
               'label', pc.label,
               'mode', ge.mode,
               'category', ge.category,
               'product_name', pr.name,
               'max_value', ge.max_value,
               'total', ge.quantity_total,
               'remaining', ge.quantity_remaining
             ) order by ge.created_at desc), '[]'::jsonb)
      from public.gift_entitlements ge
      left join public.promo_codes pc on pc.id = ge.promo_code_id
      left join public.products pr on pr.id = ge.product_id
      where ge.customer_id = p_customer
        and (p_event is null or ge.event_id = p_event)
    ),

    -- Le détail demandé : quel article, à quelle heure, pour quel montant.
    'gifts_used', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'redeemed_at', gr.redeemed_at,
               'product_name', gr.product_name,
               'unit_price', gr.unit_price,
               'covered', gr.covered,
               'paid', gr.paid,
               'code', pc.code,
               'label', pc.label,
               'pickup_code', o.pickup_code
             ) order by gr.redeemed_at desc), '[]'::jsonb)
      from public.gift_redemptions gr
      left join public.promo_codes pc on pc.id = gr.promo_code_id
      left join public.orders o on o.id = gr.order_id
      where gr.customer_id = p_customer
    ),

    'gifts_used_total', (
      select coalesce(sum(covered), 0) from public.gift_redemptions
      where customer_id = p_customer
    ),

    'passes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'event_id', ep.event_id,
               'credits_total', ep.credits_total,
               'credits_remaining', ep.credits_remaining,
               'food_token_total', ep.food_token_total,
               'food_token_available', ep.food_token_available
             )), '[]'::jsonb)
      from public.event_passes ep where ep.customer_id = p_customer
    ),

    'codes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', pc.code,
               'label', pc.label,
               'kind', pc.kind,
               'credits_granted', pr.credits_granted,
               'at', pr.created_at
             ) order by pr.created_at desc), '[]'::jsonb)
      from public.promo_redemptions pr
      join public.promo_codes pc on pc.id = pr.promo_code_id
      where pr.customer_id = p_customer
    ),

    'notes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'flag', n.flag, 'body', n.body,
               'author', n.author_email, 'at', n.created_at
             ) order by n.created_at desc), '[]'::jsonb)
      from public.order_notes n where n.customer_id = p_customer
    )
  ) into v;

  return v;
end;
$$;

grant execute on function public.customer_dossier(uuid, uuid) to authenticated;


-- ============================================================================
--  0022 — Niveau d'urgence sur les messages
--
--  Retour terrain : « Ajouter un état visuel différencié pour les messages
--  urgents. Message standard → bandeau normal. Message urgent → bandeau rouge.
--  Cas d'usage : cela fait plus de 20 minutes que votre commande vous attend. »
--
--  Un simple drapeau sur public.messages suffit : le client le rend en rouge,
--  le staff le coche à la diffusion ou à l'envoi individuel, et les relances de
--  retrait le posent toutes seules.
--
--  Idempotent : rejouable sans dommage (voir setup.sql).
-- ============================================================================

alter table public.messages
  add column if not exists urgent boolean not null default false;

comment on column public.messages.urgent is
  'Affiché en rouge côté client (relance de retrait, incident). Par défaut faux.';

-- Les messages déjà partis restent normaux : on ne repeint pas l'historique.

-- ---------------------------------------------------------------------------
--  Relance de retrait : le staff la déclenche depuis le bar sur une commande
--  qui attend. Le message est marqué urgent d'office — c'est précisément le
--  cas d'usage cité. La fonction est SECURITY DEFINER pour écrire dans
--  messages sans ouvrir la table en écriture aux clients.
-- ---------------------------------------------------------------------------
create or replace function public.nudge_pickup(p_order uuid, p_body text default null)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order   public.orders;
  v_waiting int;
  v_msg     public.messages;
begin
  select * into v_order from public.orders where id = p_order;
  if not found then
    raise exception 'unknown_order';
  end if;

  if not public.is_staff((select venue_id from public.events where id = v_order.event_id)) then
    raise exception 'forbidden';
  end if;

  v_waiting := greatest(
    0,
    floor(extract(epoch from (now() - coalesce(v_order.ready_at, v_order.created_at))) / 60)::int
  );

  insert into public.messages (event_id, kind, body, customer_id, order_id, created_by, urgent)
  values (
    v_order.event_id,
    'status',
    coalesce(
      nullif(btrim(p_body), ''),
      'Votre commande ' || v_order.pickup_code || ' vous attend au bar depuis '
        || v_waiting || ' min. Merci de venir la récupérer.'
    ),
    v_order.customer_id,
    v_order.id,
    auth.uid(),
    true
  )
  returning * into v_msg;

  return v_msg;
end
$$;

revoke all on function public.nudge_pickup(uuid, text) from public;
grant execute on function public.nudge_pickup(uuid, text) to authenticated;


-- ============================================================================
--  0023 — Regroupement des sous-catégories « Boissons »
--
--  Retour terrain : « il y a désormais trop de sous-catégories pour ce type
--  d'établissement, où les commandes restent simples. Une catégorie pour deux
--  produits (ex. Pisco & Cachaça), c'est trop. »
--
--  L'univers Boissons passe de 14 sections à 8 :
--
--    Vodka · Gin · Rhum · Whisky · Mezcal & Tequila · Pisco & Cachaça
--                                                        → Spiritueux  (38 réf.)
--    Softs · Détox Bio                                    → Softs       (12 réf.)
--
--  Conservées telles quelles :
--    · Bar à spritz — c'est une signature de la maison, pas un rangement ;
--    · Digestifs — 12 références, ce n'est pas « peu » ;
--    · Cocktails, Apéritifs, Vins au verre, Bières.
--
--  Food (À grignoter / À partager) et Bouteilles (rosé / rouge / champagne)
--  sont déjà bien dimensionnés : on n'y touche pas.
--
--  PRUDENCE : cette migration réécrit la carte du lieu. Elle ne s'exécute que
--  s'il reste des sections nommées à l'ancienne — si le staff a déjà réorganisé
--  sa carte depuis l'éditeur, elle ne fait rien. Tout reste modifiable ensuite
--  dans l'onglet Carte.
--
--  L'application trie par (universe, sort_order) : ce champ porte donc à la
--  fois l'ordre des sections et l'ordre à l'intérieur d'une section. D'où le
--  calcul en fin de bloc, section × 1000 + rang interne.
-- ============================================================================

do $$
declare
  v_sections text[] := array[
    'Bar à spritz', 'Cocktails', 'Apéritifs', 'Spiritueux',
    'Vins au verre', 'Bières', 'Softs', 'Digestifs'
  ];
  v_nom text;
  v_i   int := 0;
begin
  -- Garde d'idempotence : rien à regrouper = on sort sans rien réécrire. Sans
  -- elle, un second passage recomposerait les sort_order par-dessus les
  -- premiers et mélangerait l'ordre interne des sections.
  if not exists (
    select 1 from public.products
     where universe = 'drinks'
       and subcategory in (
         'Whisky', 'Gin', 'Rhum', 'Vodka', 'Mezcal & Tequila', 'Pisco & Cachaça', 'Détox Bio'
       )
  ) then
    raise notice '0023 : sous-catégories déjà regroupées, rien à faire.';
    return;
  end if;

  -- 1. Les spiritueux dans une seule section. Les familles restent groupées
  --    entre elles (whisky, puis gin, puis rhum…) et le tri d'origine est
  --    conservé à l'intérieur de chaque famille.
  update public.products p
     set subcategory = 'Spiritueux',
         sort_order  = f.rang * 100 + least(f.sort_order, 99)
    from (
      select
        id,
        case subcategory
          when 'Whisky'           then 1
          when 'Gin'              then 2
          when 'Rhum'             then 3
          when 'Vodka'            then 4
          when 'Mezcal & Tequila' then 5
          when 'Pisco & Cachaça'  then 6
        end as rang,
        sort_order
      from public.products
      where universe = 'drinks'
        and subcategory in ('Whisky', 'Gin', 'Rhum', 'Vodka', 'Mezcal & Tequila', 'Pisco & Cachaça')
    ) f
   where p.id = f.id;

  -- 2. Les boissons sans alcool dans une seule section, « Détox Bio » derrière
  --    les softs classiques.
  update public.products
     set subcategory = 'Softs',
         sort_order  = 700 + least(sort_order, 99)
   where universe = 'drinks'
     and subcategory = 'Détox Bio';

  -- 3. Ordre des sections : du plus commandé au plus rare. Les spritz et les
  --    cocktails ouvrent la carte, les digestifs la ferment.
  foreach v_nom in array v_sections loop
    v_i := v_i + 1;
    update public.products
       set sort_order = v_i * 1000 + least(sort_order, 999)
     where universe = 'drinks'
       and subcategory = v_nom;
  end loop;
end $$;


-- ============================================================================
--  0024 — Les codes cadeaux parlent en CRÉDITS, et se limitent deux fois
--
--  Retour terrain, bloc 2 :
--
--  · « Notre modèle est un modèle de crédits / tokens, pas d'euros. Parler en
--    euros crée de la confusion côté client. » → la valeur en euros reste une
--    règle interne, visible du staff, jamais affichée au client.
--
--  · « Si on raisonne en crédits, on n'a plus besoin de distinguer alcoolisé
--    et soft à la création du code — la règle de conversion s'en charge. »
--    → trois cases seulement : Boisson · Food · Bouteille.
--    Barème inchangé : 1 crédit = 1 soft · 2 crédits = 1 conso alcoolisée.
--
--  · « Double limitation : diffusion ET utilisation. » Ce sont deux choses :
--      max_uses        = combien de PERSONNES peuvent activer le code ;
--      uses_per_person = combien de fois CHACUNE peut l'activer.
--    La 16ᵉ personne d'un code prévu pour 15 est refusée, même si le code est
--    par ailleurs valide.
--
--  Idempotent : rejouable sans dommage (voir setup.sql).
-- ============================================================================


-- ============================================================================
--  1. LES DROITS SE COMPTENT EN CRÉDITS
--
--  Les colonnes quantity_* de 0021 comptaient des ARTICLES ; elles comptent
--  maintenant des CRÉDITS. Elles gardent leur nom volontairement : 0021 les
--  référence dans my_gift_summary et place_order, et les renommer ferait
--  échouer tout rejeu de 0021 — y compris celui de setup.sql. Le commentaire
--  ci-dessous porte le sens, à défaut du nom.
-- ============================================================================
comment on column public.gift_entitlements.quantity_remaining is
  'CRÉDITS restants (le nom est historique). Barème : 1 soft = 1 crédit, '
  '1 conso alcoolisée = 2 crédits. En mode article précis, 1 crédit = 1 article.';

comment on column public.gift_entitlements.quantity_total is
  'CRÉDITS accordés au départ (le nom est historique).';


-- ============================================================================
--  2. TROIS CATÉGORIES AU LIEU DE QUATRE
--
--  « alcohol » et « soft » fusionnent en « drink » : à la création du code on
--  ne choisit plus le type de boisson, on donne des crédits et la conversion
--  s'applique au moment de la commande.
--
--  Les droits déjà accordés sont convertis au barème pour ne rien perdre :
--  un droit à 1 article alcoolisé valait 2 crédits, 1 soft en valait 1.
-- ============================================================================
do $$
begin
  -- Un seul passage : une fois la catégorie 'alcohol' disparue, il n'y a plus
  -- rien à convertir et rejouer ne doublerait pas les crédits.
  if exists (select 1 from public.gift_entitlements where category = 'alcohol') then
    update public.gift_entitlements
       set quantity_total     = quantity_total * 2,
           quantity_remaining = quantity_remaining * 2,
           category          = 'drink'
     where category = 'alcohol';
  end if;

  update public.gift_entitlements set category = 'drink' where category = 'soft';
end $$;

-- Les codes non encore activés portent la définition dans promo_codes.gift_items.
update public.promo_codes
   set gift_items = (
     select jsonb_agg(
       case
         when item ->> 'category' in ('alcohol', 'soft') then
           item
             || jsonb_build_object('category', 'drink')
             -- Un article alcoolisé valait 2 crédits, un soft 1.
             || jsonb_build_object(
                  'quantity',
                  coalesce((item ->> 'quantity')::int, 1)
                    * case when item ->> 'category' = 'alcohol' then 2 else 1 end
                )
         else item
       end
     )
     from jsonb_array_elements(gift_items) as item
   )
 where kind = 'gift'
   and (gift_items @> '[{"category": "alcohol"}]'::jsonb
        or gift_items @> '[{"category": "soft"}]'::jsonb);

-- La catégorie d'un article, au sens des cadeaux : trois valeurs désormais.
create or replace function public.gift_category_of(
  p_universe public.universe,
  p_is_alcohol boolean
)
returns text
language sql immutable
as $$
  select case
    when p_universe = 'food'    then 'food'
    when p_universe = 'bottles' then 'bottle'
    else 'drink'
  end;
$$;

-- Ce que coûte UNE unité de cet article, en crédits. C'est ici, et nulle part
-- ailleurs, que vit le barème 2 / 1.
create or replace function public.gift_credit_cost(
  p_universe public.universe,
  p_is_alcohol boolean
)
returns int
language sql immutable
as $$
  select case
    when p_universe = 'drinks' and p_is_alcohol then 2
    else 1
  end;
$$;

grant execute on function public.gift_category_of(public.universe, boolean) to authenticated;
grant execute on function public.gift_credit_cost(public.universe, boolean) to authenticated;


-- ============================================================================
--  3. DOUBLE LIMITATION
-- ============================================================================
alter table public.promo_codes
  add column if not exists uses_per_person int not null default 1;

comment on column public.promo_codes.max_uses is
  'Diffusion : nombre maximum de PERSONNES pouvant activer ce code. null = illimité.';
comment on column public.promo_codes.uses_per_person is
  'Utilisation : nombre d''activations autorisées par personne. 1 par défaut.';

alter table public.promo_redemptions
  add column if not exists uses int not null default 1;

comment on column public.promo_redemptions.uses is
  'Nombre de fois que cette personne a activé ce code (borné par uses_per_person).';


-- ============================================================================
--  4. ACTIVATION D'UN CODE CADEAU
--
--  uses_count compte les PERSONNES, pas les activations : il n'est incrémenté
--  qu'au premier passage d'une personne donnée. Une seconde activation par la
--  même personne consomme son quota individuel, pas une place du groupe.
-- ============================================================================
create or replace function public.redeem_gift_code(p_event uuid, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_red   public.promo_redemptions;
  v_item  jsonb;
  v_qty   int;
  v_lines int := 0;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event
      and upper(code) = upper(trim(p_code))
      and active
      and kind = 'gift'
      and (starts_at is null or starts_at <= now())
      and (ends_at   is null or ends_at   >= now());
  if v_promo.id is null then raise exception 'invalid_gift_code'; end if;

  select * into v_red from public.promo_redemptions
   where promo_code_id = v_promo.id and customer_id = v_cust;

  if v_red.promo_code_id is not null then
    -- Quota individuel épuisé : on renvoie l'état sans rien recréditer. Pas
    -- une erreur — ressaisir son code pour revoir ses crédits est un réflexe.
    if v_red.uses >= greatest(1, coalesce(v_promo.uses_per_person, 1)) then
      return jsonb_build_object(
        'already', true,
        'code', v_promo.code,
        'label', v_promo.label,
        'items', public.my_gift_summary(p_event)
      );
    end if;

    update public.promo_redemptions
       set uses = uses + 1
     where promo_code_id = v_promo.id and customer_id = v_cust;
  else
    -- Première activation de CETTE personne : elle prend une place du groupe.
    -- L'incrément sert de garde atomique — deux personnes ne peuvent pas
    -- prendre la même dernière place.
    update public.promo_codes
       set uses_count = uses_count + 1
     where id = v_promo.id
       and (max_uses is null or uses_count < max_uses);
    if not found then raise exception 'code_exhausted'; end if;

    insert into public.promo_redemptions (promo_code_id, customer_id, event_id, credits_granted, uses)
    values (v_promo.id, v_cust, p_event, 0, 1);
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(v_promo.gift_items, '[]'::jsonb)) loop
    -- « quantity » porte désormais un nombre de CRÉDITS en mode catégorie, et
    -- un nombre d'articles en mode article précis (1 crédit = 1 article).
    v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

    insert into public.gift_entitlements
      (event_id, customer_id, promo_code_id, mode, category, product_id,
       max_value, quantity_total, quantity_remaining)
    values (
      p_event, v_cust, v_promo.id,
      coalesce(v_item ->> 'mode', 'category'),
      nullif(v_item ->> 'category', ''),
      nullif(v_item ->> 'product_id', '')::uuid,
      nullif(v_item ->> 'max_value', '')::numeric,
      v_qty, v_qty
    );
    v_lines := v_lines + 1;
  end loop;

  return jsonb_build_object(
    'already', false,
    'code', v_promo.code,
    'label', v_promo.label,
    'lines', v_lines,
    'items', public.my_gift_summary(p_event)
  );
end
$$;

grant execute on function public.redeem_gift_code(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
--  Résumé côté client. Le plafond en euros n'y figure plus : le client ne
--  raisonne qu'en crédits (le plafond reste une règle interne, appliquée à la
--  commande et visible du staff).
-- ---------------------------------------------------------------------------
create or replace function public.my_gift_summary(p_event uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'mode', e.mode,
           'category', e.category,
           'product_id', e.product_id,
           'product_name', p.name,
           'remaining', e.quantity_remaining,
           'total', e.quantity_total
         ) order by e.created_at), '[]'::jsonb)
  from public.gift_entitlements e
  left join public.products p on p.id = e.product_id
  where e.event_id = p_event
    and e.customer_id = public.my_customer_id()
    and e.quantity_remaining > 0;
$$;

grant execute on function public.my_gift_summary(uuid) to authenticated;


-- ---------------------------------------------------------------------------
--  Récapitulatif d'un code pour l'écran staff : « ce code permet à 15
--  personnes maximum d'obtenir 2 crédits boisson, une fois chacune ».
--  Calculé côté base pour que le staff lise exactement ce que le serveur
--  appliquera, et pas une reformulation de l'interface.
-- ---------------------------------------------------------------------------
create or replace function public.promo_reach(p_promo uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'code', c.code,
    'label', c.label,
    'max_uses', c.max_uses,
    'uses_count', c.uses_count,
    'uses_per_person', greatest(1, coalesce(c.uses_per_person, 1)),
    'people_left', case when c.max_uses is null then null
                        else greatest(0, c.max_uses - c.uses_count) end,
    'credits_per_person', coalesce((
      select jsonb_object_agg(cat, total)
      from (
        select coalesce(item ->> 'category', 'drink') as cat,
               sum(greatest(1, coalesce((item ->> 'quantity')::int, 1)))::int as total
        from jsonb_array_elements(coalesce(c.gift_items, '[]'::jsonb)) as item
        where coalesce(item ->> 'mode', 'category') = 'category'
        group by 1
      ) g
    ), '{}'::jsonb),
    'products_per_person', coalesce((
      select jsonb_agg(jsonb_build_object(
               'product_id', item ->> 'product_id',
               'quantity', greatest(1, coalesce((item ->> 'quantity')::int, 1))))
      from jsonb_array_elements(coalesce(c.gift_items, '[]'::jsonb)) as item
      where item ->> 'mode' = 'product'
    ), '[]'::jsonb)
  )
  from public.promo_codes c
  where c.id = p_promo
    and public.is_event_staff(c.event_id);
$$;

grant execute on function public.promo_reach(uuid) to authenticated;


-- ============================================================================
--  5. place_order() — les cadeaux se consomment au barème
--
--  Version de 0021, à une seule différence près : la boucle « CADEAUX ». Un
--  droit porte des CRÉDITS, et chaque unité commandée en coûte 2 (conso
--  alcoolisée) ou 1 (soft, food, bouteille, article précis). Tout le reste —
--  code de retrait, forfait, jeton food, code promo, horodatage — est
--  identique, volontairement : on ne réécrit pas une logique d'encaissement
--  pour changer un barème.
-- ============================================================================
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
  v_pass         public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
  v_credits_used int := 0;
  v_food_used    boolean := false;
  v_ent          public.gift_entitlements;
  v_gift_cat     text;
  v_gift_cost    int;
  v_gift_left    int;
  v_gift_take    int;
  v_gift_covered numeric(10,2);
  v_gift_count   int := 0;
  v_gift_total   numeric(10,2) := 0;
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
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;

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

    -- ------------------------------------------------------------------
    --  CADEAUX : consommés en premier, et journalisés unité par unité.
    -- ------------------------------------------------------------------
    v_gift_left := v_qty;
    v_gift_cat  := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);
    -- Barème : une conso alcoolisée coûte 2 crédits, tout le reste 1. En mode
    -- article précis, le promoteur a déjà choisi l'article : 1 crédit = 1 unité.
    v_gift_cost := public.gift_credit_cost(v_prod.universe, v_prod.is_alcohol);

    loop
      exit when v_gift_left <= 0;

      select * into v_ent from public.gift_entitlements e
        where e.event_id = p_event
          and e.customer_id = v_cust
          and e.quantity_remaining >= (case when e.mode = 'product' then 1 else v_gift_cost end)
          and (
            (e.mode = 'product'  and e.product_id = v_prod.id)
            or (e.mode = 'category' and e.category = v_gift_cat)
          )
        order by (e.mode = 'product') desc, e.created_at
        limit 1;

      exit when v_ent.id is null;

      v_gift_take := least(
        v_gift_left,
        v_ent.quantity_remaining / (case when v_ent.mode = 'product' then 1 else v_gift_cost end)
      );
      exit when v_gift_take <= 0;
      v_gift_covered := case
        when v_ent.max_value is null then v_unit
        else least(v_unit, v_ent.max_value)
      end;

      update public.gift_entitlements
         set quantity_remaining =
               quantity_remaining
               - v_gift_take * (case when v_ent.mode = 'product' then 1 else v_gift_cost end)
       where id = v_ent.id;

      -- Une ligne de journal par unité offerte : c'est ce qui permet d'écrire
      -- « a utilisé son cadeau à 23h14 pour un Spritz » dans la fiche client.
      insert into public.gift_redemptions
        (event_id, customer_id, promo_code_id, entitlement_id, order_id,
         product_id, product_name, unit_price, covered, paid)
      select p_event, v_cust, v_ent.promo_code_id, v_ent.id, v_order.id,
             v_prod.id,
             v_prod.name || coalesce(' (' || v_vlabel || ')', ''),
             v_unit, v_gift_covered, greatest(0, v_unit - v_gift_covered)
        from generate_series(1, v_gift_take);

      v_discount   := v_discount + v_gift_covered * v_gift_take;
      v_gift_total := v_gift_total + v_gift_covered * v_gift_take;
      v_gift_count := v_gift_count + v_gift_take;
      v_gift_left  := v_gift_left - v_gift_take;
      v_ent := null;
    end loop;

    -- ---- Forfait Noti : le portefeuille ne couvre que ce qui reste -------
    if v_pass.id is not null and v_gift_left > 0 then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.quantity_remaining >= v_wallet_cost then
          v_pass.quantity_remaining := v_pass.quantity_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_credits_used := v_credits_used + v_wallet_cost;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_gift_left, v_pass.quantity_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.quantity_remaining := v_pass.quantity_remaining - v_wallet_units * v_wallet_cost;
          v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_food_used := true;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := v_discount + least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  if v_pass.id is not null then
    update public.event_passes
       set quantity_remaining    = v_pass.quantity_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.orders
     set subtotal          = v_subtotal,
         discount          = least(v_discount, v_subtotal),
         total             = greatest(0, v_subtotal - v_discount),
         credit_units_used = v_credits_used,
         food_token_used   = v_food_used,
         gift_count        = v_gift_count,
         gift_total        = v_gift_total,
         promo_code        = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;


-- ============================================================================
--  6. ANNULATION : les crédits cadeaux reviennent, au même barème
-- ============================================================================
create or replace function public.refund_credits_on_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_r record;
begin
  if new.status = 'CANCELLED' and old.status is distinct from 'CANCELLED' then

    -- Crédits de forfait et jeton food (comportement de 0020)
    if coalesce(old.credit_units_used, 0) > 0 or coalesce(old.food_token_used, false) then
      update public.event_passes
         set quantity_remaining = least(quantity_total,
                                       quantity_remaining + coalesce(old.credit_units_used, 0)),
             food_token_available = food_token_available or coalesce(old.food_token_used, false)
       where event_id = new.event_id and customer_id = new.customer_id;

      new.credit_units_used := 0;
      new.food_token_used   := false;
    end if;

    -- Cadeaux : on rend chaque unité à son droit d'origine, puis on efface
    -- les lignes de journal — la commande annulée n'a rien consommé.
    if coalesce(old.gift_count, 0) > 0 then
      -- On rend exactement ce que chaque unité avait coûté : 2 crédits pour
      -- une conso alcoolisée, 1 sinon. D'où la jointure sur le produit.
      for v_r in
        select gr.entitlement_id, ge.mode, p.universe, p.is_alcohol, count(*)::int as n
          from public.gift_redemptions gr
          join public.gift_entitlements ge on ge.id = gr.entitlement_id
          left join public.products p on p.id = gr.product_id
         where gr.order_id = new.id and gr.entitlement_id is not null
         group by gr.entitlement_id, ge.mode, p.universe, p.is_alcohol
      loop
        update public.gift_entitlements
           set quantity_remaining = least(
                 quantity_total,
                 quantity_remaining + v_r.n * (case
                   when v_r.mode = 'product'  then 1
                   when v_r.universe is null  then 1
                   else public.gift_credit_cost(v_r.universe, v_r.is_alcohol)
                 end))
         where id = v_r.entitlement_id;
      end loop;

      delete from public.gift_redemptions where order_id = new.id;

      new.gift_count := 0;
      new.gift_total := 0;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_orders_credit_refund on public.orders;
create trigger trg_orders_credit_refund
  before update on public.orders
  for each row execute function public.refund_credits_on_cancel();


-- ============================================================================
--  0025 — Deux fusions de plus, et un libellé de bouteilles enfin clair
--
--  Retour terrain, bloc 6 :
--
--  · « Encore deux fusions proposées : Apéritifs → Spiritueux ; Digestifs → à
--    intégrer dans une autre catégorie pertinente. »
--    Les deux vont dans Spiritueux : ce sont des alcools forts servis au verre,
--    la seule différence est le moment de la soirée. Dans la section, les
--    apéritifs ouvrent et les digestifs ferment.
--
--  · « La dernière catégorie nommée simplement Bouteille n'est pas claire — il
--    s'agit du hard. » → « Bouteilles — alcools forts ».
--
--  · « On garde Spritz / Cocktails en premier (retour client direct à
--    l'appui). » → ordre conservé.
--
--  L'ordre est RECALCULÉ de zéro sur tout l'univers Boissons, par rang dense
--  (section × 1000 + rang dans la section). Empiler un nouveau multiplicateur
--  sur celui de 0023 écrasait l'ordre interne : les valeurs dépassaient le
--  plafond et retombaient toutes sur le même nombre. Un rang dense ne peut pas
--  déborder, et rejouer la migration redonne exactement le même résultat.
--
--  À NOTER : Spiritueux regroupe ensuite une soixantaine de références. C'est
--  le prix du regroupement demandé ; si la section devient trop longue à
--  l'usage, la scinder se fait dans l'éditeur de carte, sans migration.
-- ============================================================================

do $$
declare
  -- Ordre d'affichage des sections, du plus commandé au plus rare.
  v_sections text[] := array[
    'Bar à spritz', 'Cocktails', 'Spiritueux', 'Vins au verre', 'Bières', 'Softs'
  ];
begin
  if not exists (
    select 1 from public.products
     where universe = 'drinks' and subcategory in ('Apéritifs', 'Digestifs')
  ) then
    raise notice '0025 : apéritifs et digestifs déjà regroupés, rien à faire.';
    return;
  end if;

  -- 1. Les apéritifs passent devant les spiritueux déjà en place (0023 les a
  --    numérotés à partir de 100), les digestifs passent derrière.
  update public.products
     set subcategory = 'Spiritueux',
         sort_order  = least(sort_order, 99)
   where universe = 'drinks' and subcategory = 'Apéritifs';

  update public.products
     set subcategory = 'Spiritueux',
         sort_order  = 900000 + least(sort_order, 999)
   where universe = 'drinks' and subcategory = 'Digestifs';

  -- 2. Renumérotation dense de tout l'univers, à partir de l'ordre courant.
  --    Les sections inconnues du tableau (une section ajoutée à la main par le
  --    staff) sont rangées après, sans être touchées dans leur ordre interne.
  with ranked as (
    select
      p.id,
      coalesce(array_position(v_sections, p.subcategory), array_length(v_sections, 1) + 1) as sec,
      row_number() over (
        partition by p.subcategory
        order by p.sort_order, p.name
      ) as rn
    from public.products p
    where p.universe = 'drinks'
  )
  update public.products p
     set sort_order = r.sec * 1000 + least(r.rn, 999)
    from ranked r
   where p.id = r.id;
end $$;


-- ---------------------------------------------------------------------------
--  Bouteilles : « Bouteilles » tout court désignait le hard, ce que personne
--  ne devinait. Les vins et champagnes étaient déjà explicites.
-- ---------------------------------------------------------------------------
update public.products
   set subcategory = 'Bouteilles — alcools forts'
 where universe = 'bottles'
   and subcategory = 'Bouteilles';


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



-- ============================================================
-- TAPZ — 0001_schema.sql
-- Schéma de base : groupes, bars, tables, carte, commandes, CRM.
-- Marché FR : montants en EUR, TVA française, SIRET/TVA intra sur la facture.
-- AUCUN paiement en ligne : on ne fait que du suivi d'encaissement.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- GROUPES (mode multi-établissements) ----------
create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  owner_id    uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- ---------- BARS ----------
create table if not exists public.bars (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text unique,
  owner_id      uuid not null references auth.users (id) on delete cascade,
  group_id      uuid references public.groups (id) on delete set null,
  logo_url      text,
  logo_emoji    text default '🍸',
  tables_count  int  not null default 10,
  -- Mentions légales facture (France) — tous optionnels
  siret         text,
  tva_number    text,
  address       text,
  phone         text,
  city          text,
  currency      text not null default 'EUR',
  created_at    timestamptz not null default now()
);

create index if not exists bars_owner_idx on public.bars (owner_id);
create index if not exists bars_group_idx on public.bars (group_id);

-- ---------- TABLES / ZONES ----------
create table if not exists public.tables (
  id          uuid primary key default gen_random_uuid(),
  bar_id      uuid not null references public.bars (id) on delete cascade,
  number      int  not null,
  label       text,                       -- "Carré VIP", "Terrasse", "Comptoir"…
  qr_url      text,
  created_at  timestamptz not null default now(),
  unique (bar_id, number)
);

create index if not exists tables_bar_idx on public.tables (bar_id);

-- ---------- CARTE ----------
create table if not exists public.menu_items (
  id            uuid primary key default gen_random_uuid(),
  bar_id        uuid not null references public.bars (id) on delete cascade,
  name          text not null,
  description   text,
  price         numeric(10, 2) not null default 0,
  category      text not null default 'Cocktails',
  emoji         text default '🍹',
  photo_url     text,
  is_popular    boolean not null default false,
  is_menu       boolean not null default false,  -- formule / menu du soir
  available     boolean not null default true,
  stock         int,                              -- null = illimité
  sort_order    int not null default 0,
  is_alcohol    boolean not null default true,
  vat_rate      numeric(5, 2) not null default 20.00, -- FR : 20 alcool, 10 soft sur place
  translations  jsonb not null default '{}'::jsonb,  -- { "en": {name, description}, ... }
  supplements   jsonb not null default '[]'::jsonb,  -- groupes d'options composables
  extras        jsonb not null default '[]'::jsonb,  -- ajouts simples payants
  created_at    timestamptz not null default now()
);

create index if not exists menu_items_bar_idx on public.menu_items (bar_id);
create index if not exists menu_items_sort_idx on public.menu_items (bar_id, category, sort_order);

comment on column public.menu_items.supplements is
  'JSON: [{ "id":"base", "name":"Base alcool", "required":true, "min":1, "max":1,
            "options":[{"id":"vodka","name":"Vodka","price":0}] }]';
comment on column public.menu_items.extras is
  'JSON: [{ "id":"shot", "name":"Double shot", "price":3 }]';

-- ---------- COMMANDES ----------
do $$ begin
  create type public.order_status as enum ('PENDING', 'PREPARING', 'READY', 'DONE', 'CANCELLED');
exception when duplicate_object then null; end $$;

create table if not exists public.orders (
  id                 uuid primary key default gen_random_uuid(),
  bar_id             uuid not null references public.bars (id) on delete cascade,
  table_id           uuid references public.tables (id) on delete set null,
  status             public.order_status not null default 'PENDING',
  code               text not null default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 4)),
  subtotal           numeric(10, 2) not null default 0,
  discount           numeric(10, 2) not null default 0,
  total              numeric(10, 2) not null default 0,
  promo_code         text,
  note               text,                    -- note pour le comptoir
  customer_name      text,
  customer_email     text,
  order_type         text not null default 'sur_place',  -- sur_place | a_emporter
  estimated_ready_at timestamptz,
  accepted_at        timestamptz,
  ready_at           timestamptz,
  served_at          timestamptz,
  paid               boolean not null default false,
  paid_at            timestamptz,
  paid_method        text,                    -- especes | cb | autre (saisi par le staff)
  created_at         timestamptz not null default now()
);

create index if not exists orders_bar_created_idx on public.orders (bar_id, created_at desc);
create index if not exists orders_bar_status_idx  on public.orders (bar_id, status);
create index if not exists orders_table_idx       on public.orders (table_id);

create table if not exists public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders (id) on delete cascade,
  menu_item_id  uuid references public.menu_items (id) on delete set null,
  name_snapshot text not null default '',
  unit_price    numeric(10, 2) not null default 0,
  vat_rate      numeric(5, 2)  not null default 20.00,
  quantity      int not null default 1,
  detail        jsonb not null default '{}'::jsonb,  -- options choisies + extras
  created_at    timestamptz not null default now()
);

create index if not exists order_items_order_idx on public.order_items (order_id);

-- ---------- CRM ----------
create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  bar_id        uuid not null references public.bars (id) on delete cascade,
  name          text,
  email         text,
  phone         text,
  orders_count  int not null default 0,
  total_spent   numeric(10, 2) not null default 0,
  last_order_at timestamptz,
  created_at    timestamptz not null default now(),
  unique (bar_id, email)
);

create index if not exists customers_bar_idx on public.customers (bar_id);

-- ---------- AVIS ----------
create table if not exists public.reviews (
  id         uuid primary key default gen_random_uuid(),
  bar_id     uuid not null references public.bars (id) on delete cascade,
  order_id   uuid references public.orders (id) on delete set null,
  rating     int not null check (rating between 1 and 5),
  comment    text,
  created_at timestamptz not null default now()
);

create index if not exists reviews_bar_idx on public.reviews (bar_id);

-- ---------- PROMOTIONS / HAPPY HOUR ----------
create table if not exists public.promotions (
  id            uuid primary key default gen_random_uuid(),
  bar_id        uuid not null references public.bars (id) on delete cascade,
  code          text,                         -- null = promo automatique (happy hour)
  label         text not null default 'Promo',
  kind          text not null default 'percent', -- percent | amount | happy_hour
  value         numeric(10, 2) not null default 0,
  min_total     numeric(10, 2) not null default 0,
  days_of_week  int[] not null default '{0,1,2,3,4,5,6}', -- 0 = dimanche
  start_time    time,
  end_time      time,
  starts_at     timestamptz,
  ends_at       timestamptz,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create index if not exists promotions_bar_idx on public.promotions (bar_id);

-- ---------- RÉGLAGES PAR ÉTABLISSEMENT ----------
create table if not exists public.bar_settings (
  bar_id             uuid primary key references public.bars (id) on delete cascade,
  default_eta_min    int  not null default 10,
  accept_orders      boolean not null default true,
  service_message    text,
  alarm_enabled      boolean not null default true,
  languages          text[] not null default '{fr}',
  category_order     jsonb  not null default '[]'::jsonb,
  export_margin_pct  numeric(5, 2) not null default 0,  -- marge appliquée à l'export uniquement
  receipt_footer     text default 'Merci et à très vite. À régler au bar.',
  updated_at         timestamptz not null default now()
);

-- ---------- ABONNEMENTS WEB PUSH ----------
create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  bar_id     uuid references public.bars (id) on delete cascade,
  order_id   uuid references public.orders (id) on delete cascade,
  role       text not null default 'customer', -- customer | staff
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

create index if not exists push_order_idx on public.push_subscriptions (order_id);
create index if not exists push_bar_idx   on public.push_subscriptions (bar_id);

-- ---------- HELPERS ----------
-- Un utilisateur "possède" un bar s'il en est le owner, ou owner du groupe du bar.
create or replace function public.owns_bar(p_bar uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.bars b
    left join public.groups g on g.id = b.group_id
    where b.id = p_bar
      and (b.owner_id = auth.uid() or g.owner_id = auth.uid())
  );
$$;

-- Horodatages de statut + création automatique des réglages.
create or replace function public.tapz_touch_order_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'PREPARING' and new.accepted_at is null then
      new.accepted_at := now();
    elsif new.status = 'READY' and new.ready_at is null then
      new.ready_at := now();
    elsif new.status = 'DONE' and new.served_at is null then
      new.served_at := now();
    end if;
  end if;
  if new.paid and old.paid is distinct from new.paid and new.paid_at is null then
    new.paid_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_status on public.orders;
create trigger trg_orders_status
  before update on public.orders
  for each row execute function public.tapz_touch_order_status();

create or replace function public.tapz_bar_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.bar_settings (bar_id) values (new.id)
  on conflict (bar_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_bar_defaults on public.bars;
create trigger trg_bar_defaults
  after insert on public.bars
  for each row execute function public.tapz_bar_defaults();

-- Table créée à la volée quand un client scanne un QR d'une table inexistante.
create or replace function public.ensure_table(p_bar uuid, p_number int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.tables where bar_id = p_bar and number = p_number;
  if v_id is null then
    insert into public.tables (bar_id, number) values (p_bar, p_number)
    on conflict (bar_id, number) do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.tables where bar_id = p_bar and number = p_number;
    end if;
  end if;
  return v_id;
end;
$$;

grant execute on function public.ensure_table(uuid, int) to anon, authenticated;

-- Mise à jour du CRM quand une commande est servie.
create or replace function public.tapz_sync_customer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'DONE' and old.status is distinct from 'DONE'
     and new.customer_email is not null and length(trim(new.customer_email)) > 0 then
    insert into public.customers (bar_id, email, name, orders_count, total_spent, last_order_at)
    values (new.bar_id, lower(trim(new.customer_email)), new.customer_name, 1, new.total, now())
    on conflict (bar_id, email) do update
      set orders_count  = public.customers.orders_count + 1,
          total_spent   = public.customers.total_spent + excluded.total_spent,
          last_order_at = now(),
          name          = coalesce(excluded.name, public.customers.name);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_customer on public.orders;
create trigger trg_orders_customer
  after update on public.orders
  for each row execute function public.tapz_sync_customer();

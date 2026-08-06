-- ============================================================
-- TAPZ — 0002_rls.sql
-- Row Level Security.
-- Règle générale : gestion = propriétaire uniquement (owner du bar ou du groupe).
--                  lecture publique = carte + tables + bar + promos actives.
--                  insertion publique anonyme = commandes + lignes + table à la volée.
--
-- NOTE DE SÉCURITÉ (assumée) : le client anonyme doit pouvoir LIRE sa commande
-- pour le suivi temps réel (Realtime respecte la RLS). Une policy RLS filtre des
-- lignes, elle ne peut pas dépendre du filtre de la requête : on autorise donc la
-- lecture anonyme des commandes RÉCENTES (< 12 h). L'app n'interroge jamais que
-- par id. Aucune donnée de paiement n'est stockée. Si vous voulez verrouiller
-- davantage, remplacez par une RPC security definer prenant l'id en paramètre —
-- mais vous perdez le Realtime (le polling de secours prendra le relais).
-- ============================================================

alter table public.groups              enable row level security;
alter table public.bars                enable row level security;
alter table public.tables              enable row level security;
alter table public.menu_items          enable row level security;
alter table public.orders              enable row level security;
alter table public.order_items         enable row level security;
alter table public.customers           enable row level security;
alter table public.reviews             enable row level security;
alter table public.promotions          enable row level security;
alter table public.bar_settings        enable row level security;
alter table public.push_subscriptions  enable row level security;

-- ---------------- GROUPS ----------------
drop policy if exists groups_owner_all on public.groups;
create policy groups_owner_all on public.groups
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ---------------- BARS ----------------
drop policy if exists bars_public_read on public.bars;
create policy bars_public_read on public.bars
  for select to anon, authenticated
  using (true);

drop policy if exists bars_owner_insert on public.bars;
create policy bars_owner_insert on public.bars
  for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists bars_owner_update on public.bars;
create policy bars_owner_update on public.bars
  for update to authenticated
  using (public.owns_bar(id))
  with check (public.owns_bar(id));

drop policy if exists bars_owner_delete on public.bars;
create policy bars_owner_delete on public.bars
  for delete to authenticated
  using (owner_id = auth.uid());

-- ---------------- TABLES ----------------
drop policy if exists tables_public_read on public.tables;
create policy tables_public_read on public.tables
  for select to anon, authenticated
  using (true);

-- Création à la volée quand un client scanne un QR d'une table non enregistrée.
drop policy if exists tables_public_insert on public.tables;
create policy tables_public_insert on public.tables
  for insert to anon, authenticated
  with check (true);

drop policy if exists tables_owner_update on public.tables;
create policy tables_owner_update on public.tables
  for update to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

drop policy if exists tables_owner_delete on public.tables;
create policy tables_owner_delete on public.tables
  for delete to authenticated
  using (public.owns_bar(bar_id));

-- ---------------- MENU ----------------
drop policy if exists menu_public_read on public.menu_items;
create policy menu_public_read on public.menu_items
  for select to anon, authenticated
  using (true);

drop policy if exists menu_owner_write on public.menu_items;
create policy menu_owner_write on public.menu_items
  for all to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

-- ---------------- PROMOTIONS ----------------
drop policy if exists promos_public_read on public.promotions;
create policy promos_public_read on public.promotions
  for select to anon, authenticated
  using (active = true);

drop policy if exists promos_owner_write on public.promotions;
create policy promos_owner_write on public.promotions
  for all to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

-- ---------------- BAR SETTINGS ----------------
drop policy if exists settings_public_read on public.bar_settings;
create policy settings_public_read on public.bar_settings
  for select to anon, authenticated
  using (true);

drop policy if exists settings_owner_write on public.bar_settings;
create policy settings_owner_write on public.bar_settings
  for all to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

-- ---------------- ORDERS ----------------
-- Lecture : propriétaire (tout) OU public sur les commandes récentes (suivi client).
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders
  for select to anon, authenticated
  using (
    public.owns_bar(bar_id)
    or created_at > now() - interval '12 hours'
  );

drop policy if exists orders_public_insert on public.orders;
create policy orders_public_insert on public.orders
  for insert to anon, authenticated
  with check (
    status = 'PENDING'
    and paid = false
    and exists (
      select 1 from public.bar_settings s
      where s.bar_id = orders.bar_id and s.accept_orders = true
    )
  );

drop policy if exists orders_owner_update on public.orders;
create policy orders_owner_update on public.orders
  for update to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

drop policy if exists orders_owner_delete on public.orders;
create policy orders_owner_delete on public.orders
  for delete to authenticated
  using (public.owns_bar(bar_id));

-- ---------------- ORDER ITEMS ----------------
drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_items.order_id
        and (public.owns_bar(o.bar_id) or o.created_at > now() - interval '12 hours')
    )
  );

drop policy if exists order_items_public_insert on public.order_items;
create policy order_items_public_insert on public.order_items
  for insert to anon, authenticated
  with check (
    exists (
      select 1 from public.orders o
      where o.id = order_items.order_id
        and o.created_at > now() - interval '10 minutes'
    )
  );

drop policy if exists order_items_owner_write on public.order_items;
create policy order_items_owner_write on public.order_items
  for all to authenticated
  using (
    exists (select 1 from public.orders o
            where o.id = order_items.order_id and public.owns_bar(o.bar_id))
  )
  with check (
    exists (select 1 from public.orders o
            where o.id = order_items.order_id and public.owns_bar(o.bar_id))
  );

-- ---------------- CUSTOMERS (CRM — privé) ----------------
drop policy if exists customers_owner_all on public.customers;
create policy customers_owner_all on public.customers
  for all to authenticated
  using (public.owns_bar(bar_id))
  with check (public.owns_bar(bar_id));

-- ---------------- REVIEWS ----------------
drop policy if exists reviews_public_read on public.reviews;
create policy reviews_public_read on public.reviews
  for select to anon, authenticated
  using (true);

drop policy if exists reviews_public_insert on public.reviews;
create policy reviews_public_insert on public.reviews
  for insert to anon, authenticated
  with check (true);

drop policy if exists reviews_owner_delete on public.reviews;
create policy reviews_owner_delete on public.reviews
  for delete to authenticated
  using (public.owns_bar(bar_id));

-- ---------------- PUSH SUBSCRIPTIONS ----------------
-- Insert public (le client s'abonne pour SA commande). Pas de lecture publique :
-- seules les Edge Functions (service_role) et le propriétaire lisent les endpoints.
drop policy if exists push_public_insert on public.push_subscriptions;
create policy push_public_insert on public.push_subscriptions
  for insert to anon, authenticated
  with check (true);

drop policy if exists push_owner_read on public.push_subscriptions;
create policy push_owner_read on public.push_subscriptions
  for select to authenticated
  using (bar_id is not null and public.owns_bar(bar_id));

drop policy if exists push_owner_delete on public.push_subscriptions;
create policy push_owner_delete on public.push_subscriptions
  for delete to authenticated
  using (bar_id is not null and public.owns_bar(bar_id));

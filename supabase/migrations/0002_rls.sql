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

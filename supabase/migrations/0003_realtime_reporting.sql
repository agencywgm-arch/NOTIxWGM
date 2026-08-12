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

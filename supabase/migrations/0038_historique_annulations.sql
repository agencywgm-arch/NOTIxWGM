-- ============================================================================
--  0038 — Tracer les annulations
--
--  Demande : « un historique des commandes qui comprend même les
--  annulations ».
--
--  Les commandes annulées n'ont jamais été effacées — la RLS staff les
--  laissait déjà lire (orders_read, 0002) — mais rien ne disait QUI avait
--  annulé, ni QUAND. Or les deux cas ne racontent pas la même chose :
--
--    · annulée par le CLIENT  → il s'est ravisé, rien n'a été engagé ;
--    · annulée par le BAR     → rupture, erreur, incident, refus de servir.
--
--  Sans cette distinction, un historique aligne des lignes « Annulée » qui
--  ne veulent rien dire, et le seul chiffre qui compte — combien de fois le
--  bar a dû annuler — reste introuvable.
--
--  `created_at` marque la prise de commande, jamais l'annulation : on ne
--  pouvait donc pas non plus savoir au bout de combien de temps elle est
--  survenue.
-- ============================================================================

alter table public.orders
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by text;

alter table public.orders drop constraint if exists orders_cancelled_by_known;
alter table public.orders
  add constraint orders_cancelled_by_known
  check (cancelled_by is null or cancelled_by in ('client', 'staff'));

comment on column public.orders.cancelled_by is
  'Qui a annulé : « client » (il s''est ravisé) ou « staff » (rupture, '
  'incident…). Deux lectures très différentes pour l''établissement.';

create index if not exists orders_cancelled_idx
  on public.orders (event_id, cancelled_at) where cancelled_at is not null;


-- ---------------------------------------------------------------------------
--  Horodatage automatique.
--
--  Porté par un déclencheur plutôt que par chaque appelant : le staff annule
--  par un simple UPDATE depuis l'application, et il y a plus d'un chemin
--  (bouton du bar, feuille de détail). Un oubli à un seul endroit produirait
--  une ligne « annulée » sans date, donc un trou dans l'historique.
--
--  `coalesce` : si l'appelant a déjà renseigné l'origine — c'est le cas de
--  cancel_my_order, qui sait que c'est le client — on la respecte. Sinon
--  c'est le staff, seul autre acteur autorisé à écrire sur `orders`.
-- ---------------------------------------------------------------------------
create or replace function public.stamp_order_cancellation()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'CANCELLED' and old.status is distinct from 'CANCELLED' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
    new.cancelled_by := coalesce(new.cancelled_by, 'staff');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_stamp_order_cancellation on public.orders;
create trigger trg_stamp_order_cancellation
  before update on public.orders
  for each row execute function public.stamp_order_cancellation();


-- ---------------------------------------------------------------------------
--  cancel_my_order() marque l'origine « client ».
--
--  Repris de 0037 à l'identique, à la seule ligne `cancelled_by` près.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_my_order(p_order uuid)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_order public.orders;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select o.* into v_order from public.orders o
   where o.id = p_order and o.customer_id = v_cust;
  if v_order.id is null then raise exception 'unknown_order'; end if;

  if v_order.status = 'CANCELLED' then
    return v_order;  -- déjà annulée : un second tap ne doit pas échouer
  end if;

  update public.orders
     set status = 'CANCELLED',
         cancelled_by = 'client'
   where id = p_order
     and customer_id = v_cust
     and status in ('RECEIVED', 'AWAITING_PAYMENT')
   returning * into v_order;

  if v_order.id is null then raise exception 'already_in_prep'; end if;

  -- Les crédits et cadeaux consommés sont rendus : la commande n'a jamais été
  -- préparée, il n'y a aucune raison de les retenir.
  update public.event_passes p
     set credits_remaining = least(
           p.credits_total,
           p.credits_remaining + coalesce((select o.credit_units_used from public.orders o where o.id = p_order), 0)
         ),
         food_token_available = p.food_token_available
           or coalesce((select o.food_token_used from public.orders o where o.id = p_order), false)
   where p.event_id = v_order.event_id and p.customer_id = v_cust;

  update public.gift_entitlements e
     set quantity_remaining = least(
           e.quantity_total,
           e.quantity_remaining + sub.rendus
         )
    from (
      select entitlement_id, count(*) as rendus
        from public.gift_redemptions
       where order_id = p_order and entitlement_id is not null
       group by entitlement_id
    ) sub
   where e.id = sub.entitlement_id;

  delete from public.gift_redemptions where order_id = p_order;

  return v_order;
end;
$$;

grant execute on function public.cancel_my_order(uuid) to authenticated;

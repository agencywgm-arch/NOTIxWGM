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

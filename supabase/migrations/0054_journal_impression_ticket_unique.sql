-- ============================================================================
--  NOTI Calling — 0054_journal_impression_ticket_unique.sql
--
--  Deux retours terrain le même soir :
--
--  1. « Des tickets fantômes s'impriment automatiquement, je ne sais pas
--     pourquoi » — la cause : encaisser une commande food au comptoir
--     (start_food_prep, 0037) la fait passer AWAITING_PAYMENT → RECEIVED,
--     et le démon d'impression à l'arrivée (0050) considérait ça comme une
--     commande neuve à imprimer. Un geste à la caisse déclenchait donc un
--     ticket au bar sans que personne n'ait cliqué « imprimer » là-bas —
--     invisible et donc, vu du bar, un « fantôme ».
--
--  2. « Je veux que les seuls tickets sortables soient des tickets de
--     préparation, un seul par commande, jamais un ticket pour une commande
--     déjà réglée, et qu'une réimpression volontaire soit marquée DUPLICATA
--     pour ne pas refaire la commande deux fois. »
--
--  Les deux demandes se répondent par le même changement, entièrement côté
--  application (rien ici ne le impose en base) : supprimer le ticket
--  silencieux à l'arrivée et ne garder QUE celui déclenché par le clic
--  « En prépa » — un geste volontaire, toujours au bar, jamais à la caisse.
--  claim_prep_ticket_print (0052) garantissait déjà l'unicité automatique ;
--  ce qui manquait est une trace de CHAQUE impression, fantôme ou non, pour
--  ne plus jamais avoir à deviner d'où elle vient.
-- ============================================================================

create table if not exists public.print_log (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  order_id    uuid references public.orders (id) on delete set null,
  pickup_code text,
  -- Le DÉCLENCHEUR exact : 'en_prepa' (clic normal), 'reprint_duplicata'
  -- (réimpression volontaire), etc. — c'est la question posée ce soir,
  -- « la cause de chaque ticket envoyé », qui doit rester lisible sans
  -- avoir à relire le code.
  trigger     text not null,
  result      text not null check (result in ('ok', 'fail', 'ambiguous')),
  reason      text,
  created_at  timestamptz not null default now()
);

create index if not exists print_log_event_idx on public.print_log (event_id, created_at desc);

alter table public.print_log enable row level security;

drop policy if exists print_log_staff_read on public.print_log;
create policy print_log_staff_read on public.print_log
  for select to authenticated
  using (public.is_event_staff(event_id));

-- Pas de policy d'insertion directe : ça passe uniquement par la fonction
-- ci-dessous, qui vérifie elle-même que l'appelant fait partie du staff et
-- retrouve event_id/pickup_code depuis la commande — le client applicatif
-- n'a qu'à donner l'id de commande et la cause.
create or replace function public.log_ticket_print(
  p_order   uuid,
  p_trigger text,
  p_result  text,
  p_reason  text default null
)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_event uuid;
  v_code  text;
begin
  select o.event_id, o.pickup_code into v_event, v_code
    from public.orders o where o.id = p_order;
  if v_event is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_event) then raise exception 'forbidden'; end if;

  insert into public.print_log (event_id, order_id, pickup_code, trigger, result, reason)
  values (v_event, p_order, v_code, p_trigger, p_result, p_reason);
end;
$$;

grant execute on function public.log_ticket_print(uuid, text, text, text) to authenticated;

-- ============================================================================
--  NOTI Calling — 0052_ticket_reimprime_en_prepa.sql
--  Un second ticket, indépendant du premier, quand le staff clique
--  « En prépa » sur une commande.
--
--  Demande explicite : garder les deux impressions plutôt que remplacer
--  celle de l'arrivée. Le ticket sort donc deux fois — une fois dès que la
--  commande arrive (0050), une fois quand quelqu'un commence réellement à
--  la traiter — plutôt qu'une seule fois quel que soit le déclencheur.
--
--  Réservation séparée (`prep_printed_at`, pas `printed_at`) : réutiliser la
--  colonne de 0050 aurait empêché ce second ticket de sortir, puisqu'elle
--  est déjà posée par l'impression automatique à l'arrivée. Même mécanisme
--  anti-double-ticket que 0050, sur sa propre colonne — plusieurs tablettes
--  peuvent afficher la même commande et cliquer « En prépa » en même temps,
--  une seule doit imprimer.
-- ============================================================================

alter table public.orders
  add column if not exists prep_printed_at timestamptz;

create or replace function public.claim_prep_ticket_print(p_order uuid)
returns boolean
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_venue uuid;
  v_got   uuid;
begin
  select e.venue_id into v_venue
    from public.orders o join public.events e on e.id = o.event_id
   where o.id = p_order;
  if v_venue is null then raise exception 'unknown_order'; end if;
  if not public.is_staff(v_venue) then raise exception 'forbidden'; end if;

  update public.orders
     set prep_printed_at = now()
   where id = p_order
     and prep_printed_at is null
  returning id into v_got;

  return v_got is not null;
end;
$$;

create or replace function public.release_prep_ticket_print(p_order uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare v_venue uuid;
begin
  select e.venue_id into v_venue
    from public.orders o join public.events e on e.id = o.event_id
   where o.id = p_order;
  if v_venue is null then raise exception 'unknown_order'; end if;
  if not public.is_staff(v_venue) then raise exception 'forbidden'; end if;

  update public.orders set prep_printed_at = null where id = p_order;
end;
$$;

grant execute on function public.claim_prep_ticket_print(uuid)   to authenticated;
grant execute on function public.release_prep_ticket_print(uuid) to authenticated;

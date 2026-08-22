-- ============================================================================
--  NOTI Calling — 0011_in_prep_close_event.sql
--
--  À exécuter APRÈS 0010_in_prep_status.sql (dans un Run séparé).
--
--  close_event() basculait uniquement RECEIVED/READY/PICKED_UP en UNPAID à
--  la clôture de soirée — une commande restée « En préparation » (IN_PREP)
--  doit suivre la même règle, sinon elle resterait indéfiniment bloquée
--  dans cet état après la fermeture de l'événement.
-- ============================================================================

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

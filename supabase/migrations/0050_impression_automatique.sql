-- ============================================================================
--  NOTI Calling — 0050_impression_automatique.sql
--  Réglages d'imprimante et réservation du ticket entre tablettes.
--
--  Le réglage vit sur le lieu, pas sur la tablette : toutes les tablettes du
--  bar doivent viser la même imprimante, et une tablette de remplacement
--  sortie du placard un soir de rush doit marcher sans être reconfigurée.
--
--  claim_ticket_print() est l'anti-double-ticket. Plusieurs tablettes
--  affichent la même commande et voudraient toutes l'imprimer ; une seule
--  doit gagner. La réservation se fait par un UPDATE conditionnel — le
--  premier qui pose sa date l'emporte, les autres ne reçoivent rien. Tester
--  puis écrire aurait laissé passer les deux.
--
--  release_ticket_print() rend la main quand l'impression a échoué (papier
--  fini, imprimante éteinte) : sans ça, une commande réservée puis jamais
--  sortie resterait marquée imprimée et personne ne la reverrait jamais.
-- ============================================================================

alter table public.venues
  add column if not exists printer_url  text,
  add column if not exists printer_auto boolean not null default false;

comment on column public.venues.printer_url is
  'Adresse du point d''entrée d''impression du bar. Voir src/lib/printer.js : '
  'un navigateur ne peut joindre ni une adresse http:// depuis une page '
  'https://, ni un port brut — l''adresse doit donc être joignable en HTTPS.';

/**
 * Réserve l'impression d'une commande. Renvoie true si l'appelant a gagné la
 * réservation et doit imprimer, false si quelqu'un d'autre s'en charge déjà.
 */
create or replace function public.claim_ticket_print(p_order uuid)
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
     set printed_at = now()
   where id = p_order
     and printed_at is null
  returning id into v_got;

  return v_got is not null;
end;
$$;

/** Rend la réservation après un échec d'impression, pour qu'on puisse retenter. */
create or replace function public.release_ticket_print(p_order uuid)
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

  update public.orders set printed_at = null where id = p_order;
end;
$$;

grant execute on function public.claim_ticket_print(uuid)   to authenticated;
grant execute on function public.release_ticket_print(uuid) to authenticated;

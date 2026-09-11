-- ============================================================================
--  NOTI Calling — 0044_correction_redeem_presentation_link.sql
--  Corrige redeem_presentation_link() (0043) : « column reference "venue_id"
--  is ambiguous ». Les paramètres de sortie de la fonction portaient les
--  mêmes noms (venue_id, role) que les colonnes de la requête
--  INSERT ... ON CONFLICT exécutée à l'intérieur — PL/pgSQL confondait les
--  deux. On renomme les paramètres de sortie, la requête interne ne change
--  pas.
-- ============================================================================

create or replace function public.redeem_presentation_link(p_link uuid)
returns table(out_venue_id uuid, out_role text)
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_link record;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_link from public.presentation_links where id = p_link;
  if v_link is null then raise exception 'unknown_order'; end if;
  if v_link.revoked_at is not null then raise exception 'invalid_pass_code'; end if;

  insert into public.staff_members (venue_id, user_id, role, presentation_link_id)
  values (v_link.venue_id, auth.uid(), v_link.role, p_link)
  on conflict (venue_id, user_id) do update
    set role = excluded.role, presentation_link_id = excluded.presentation_link_id
    where public.staff_members.role <> 'owner';

  return query select v_link.venue_id, v_link.role;
end;
$$;

grant execute on function public.redeem_presentation_link(uuid) to authenticated;

-- ============================================================================
--  NOTI Calling — 0045_redeem_presentation_link_scalaire.sql
--  redeem_presentation_link() renvoie désormais un simple uuid.
--
--  Pourquoi : la version « returns table(...) » déclarait des paramètres de
--  sortie qui entraient en collision avec les colonnes manipulées dans la
--  fonction (0043 → « column reference "venue_id" is ambiguous », corrigé en
--  0044 en les renommant out_venue_id / out_role). Mais ce renommage couplait
--  le nom des colonnes de sortie au code client : pendant le laps de temps
--  où la base était à jour et le déploiement Vercel ne l'était pas encore,
--  le client lisait un champ absent et affichait une erreur trompeuse.
--
--  Un scalaire supprime les deux problèmes d'un coup : aucun nom de colonne
--  de sortie à faire entrer en collision, aucun nom à tenir synchronisé.
--  Le rôle accordé n'était de toute façon pas lu par le client — l'espace
--  équipe relit lui-même staff_members à l'ouverture.
--
--  Au passage : messages d'erreur dédiés (unknown_link / link_revoked) au
--  lieu de clés empruntées au vocabulaire des commandes, qui affichaient
--  « Commande introuvable » pour un lien de présentation.
-- ============================================================================

drop function if exists public.redeem_presentation_link(uuid);

create function public.redeem_presentation_link(p_link uuid)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_link record;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_link from public.presentation_links where id = p_link;
  if not found then raise exception 'unknown_link'; end if;
  if v_link.revoked_at is not null then raise exception 'link_revoked'; end if;

  insert into public.staff_members (venue_id, user_id, role, presentation_link_id)
  values (v_link.venue_id, auth.uid(), v_link.role, p_link)
  on conflict (venue_id, user_id) do update
    set role = excluded.role, presentation_link_id = excluded.presentation_link_id
    where public.staff_members.role <> 'owner';

  return v_link.venue_id;
end;
$$;

grant execute on function public.redeem_presentation_link(uuid) to authenticated;

-- ============================================================================
--  NOTI Calling — 0046_liens_presentation_manager.sql
--  Les managers peuvent gérer les liens de présentation, pas seulement le
--  propriétaire.
--
--  Pourquoi : un lien de présentation accorde au mieux le rôle « manager »
--  (0043 : jamais « owner »). Quelqu'un entré par un tel lien se retrouvait
--  donc devant un espace équipe où la section « Liens de présentation »
--  n'existait pas — impossible d'en créer un autre depuis une démo en cours.
--
--  Ce que ça ne change pas : le rôle qu'un lien peut accorder reste plafonné
--  à manager/staff par la contrainte de la table. Un manager ne peut donc
--  toujours pas fabriquer un accès propriétaire, ni gérer l'équipe, ni
--  toucher au lieu. C'est une capacité latérale, pas une élévation.
--
--  L'écriture directe sur la table reste réservée au propriétaire : les
--  managers passent par les deux fonctions ci-dessous, qui seules savent
--  supprimer les adhésions dérivées d'un lien au moment de le révoquer. Un
--  DELETE direct laisserait ces accès ouverts.
-- ============================================================================

drop policy if exists presentation_links_owner on public.presentation_links;

-- Lecture : propriétaire et managers (afficher et copier les liens).
drop policy if exists presentation_links_read on public.presentation_links;
create policy presentation_links_read on public.presentation_links
  for select to authenticated
  using (public.my_venue_role(venue_id) in ('owner', 'manager'));

-- Écriture directe : propriétaire uniquement.
drop policy if exists presentation_links_write on public.presentation_links;
create policy presentation_links_write on public.presentation_links
  for all to authenticated
  using      (public.my_venue_role(venue_id) = 'owner')
  with check (public.my_venue_role(venue_id) = 'owner');

-- coalesce() est indispensable : my_venue_role() renvoie NULL pour qui n'est
-- pas de la maison, et « null not in (...) » vaut NULL — le raise ne serait
-- jamais déclenché et la fonction laisserait passer un inconnu.
create or replace function public.create_presentation_link(p_venue uuid, p_role text, p_label text default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  if coalesce(public.my_venue_role(p_venue), '') not in ('owner', 'manager') then
    raise exception 'forbidden';
  end if;
  if p_role not in ('manager', 'staff') then
    raise exception 'invalid_flag';
  end if;

  insert into public.presentation_links (venue_id, role, label, created_by)
  values (p_venue, p_role, nullif(trim(p_label), ''), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.revoke_presentation_link(p_link uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_venue uuid;
begin
  select venue_id into v_venue from public.presentation_links where id = p_link;
  if not found then raise exception 'unknown_link'; end if;
  if coalesce(public.my_venue_role(v_venue), '') not in ('owner', 'manager') then
    raise exception 'forbidden';
  end if;

  update public.presentation_links set revoked_at = now() where id = p_link;
  delete from public.staff_members where presentation_link_id = p_link;
end;
$$;

grant execute on function public.create_presentation_link(uuid, text, text) to authenticated;
grant execute on function public.revoke_presentation_link(uuid)              to authenticated;

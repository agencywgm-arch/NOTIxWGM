-- ============================================================================
--  NOTI Calling — 0043_liens_presentation_staff.sql
--  Liens d'invitation directe vers l'espace staff, sans connexion.
--
--  Cas d'usage : montrer l'outil (vraies données de l'établissement) à
--  quelqu'un sans lui faire créer de compte. La personne ouvre le lien, une
--  session anonyme Supabase est ouverte pour elle (même mécanisme que les
--  clients qui scannent un QR — signInAnonymously(), déjà utilisé et déjà
--  activé sur ce projet), et cette session anonyme reçoit une ligne
--  staff_members le temps que le lien reste valide.
--
--  Choix de sécurité : le rôle proposé sur un lien de présentation est
--  plafonné à owner-only côté génération (seul le propriétaire peut créer un
--  lien) et à manager/staff côté rôle accordé — jamais « owner » lui-même.
--  Un lien de présentation ne peut donc jamais servir à gérer l'équipe, à
--  supprimer le lieu ni à changer les mentions légales.
--
--  Révocation : marque le lien révoqué ET supprime immédiatement toutes les
--  adhésions staff_members qui en découlent — une simple date de révocation
--  n'aurait pas suffi, elle n'aurait empêché que les nouvelles ouvertures du
--  lien, pas coupé l'accès de qui l'avait déjà ouvert.
-- ============================================================================

create table if not exists public.presentation_links (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues (id) on delete cascade,
  role        text not null default 'manager',   -- manager | staff — jamais owner
  label       text,
  created_by  uuid references auth.users (id) on delete set null,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now(),
  constraint presentation_links_role_check check (role in ('manager', 'staff'))
);

alter table public.staff_members
  add column if not exists presentation_link_id uuid references public.presentation_links (id) on delete set null;

alter table public.presentation_links enable row level security;

-- Seul le propriétaire du lieu voit/gère ses liens de présentation. La
-- personne qui ouvre le lien, elle, ne lit jamais cette table directement :
-- elle passe par redeem_presentation_link() (security definer).
drop policy if exists presentation_links_owner on public.presentation_links;
create policy presentation_links_owner on public.presentation_links
  for all to authenticated
  using      (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()));

/** Crée un lien de présentation. Réservé au propriétaire du lieu. */
create or replace function public.create_presentation_link(p_venue uuid, p_role text, p_label text default null)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  if public.my_venue_role(p_venue) is distinct from 'owner' then
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

/** Révoque un lien de présentation et coupe l'accès de qui l'avait déjà ouvert. */
create or replace function public.revoke_presentation_link(p_link uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_venue uuid;
begin
  select venue_id into v_venue from public.presentation_links where id = p_link;
  if v_venue is null then raise exception 'unknown_order'; end if;
  if public.my_venue_role(v_venue) is distinct from 'owner' then
    raise exception 'forbidden';
  end if;

  update public.presentation_links set revoked_at = now() where id = p_link;
  delete from public.staff_members where presentation_link_id = p_link;
end;
$$;

/**
 * Échange un lien de présentation contre un accès staff pour la session
 * courante (anonyme ou non). Appelable par n'importe quelle session
 * authentifiée (y compris anonyme) : la validité tient au lien lui-même,
 * pas à qui l'appelle.
 */
-- Renvoie un scalaire, jamais « returns table(venue_id, role) » : des
-- paramètres de sortie portant le nom des colonnes manipulées plus bas
-- entrent en collision avec elles côté PL/pgSQL (« column reference
-- "venue_id" is ambiguous »). Voir 0045 pour le détail.
create or replace function public.redeem_presentation_link(p_link uuid)
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

grant execute on function public.create_presentation_link(uuid, text, text) to authenticated;
grant execute on function public.revoke_presentation_link(uuid)              to authenticated;
grant execute on function public.redeem_presentation_link(uuid)              to authenticated;

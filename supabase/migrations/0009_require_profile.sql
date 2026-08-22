-- ============================================================================
--  NOTI Calling — 0009_require_profile.sql
--
--  Prénom, nom et e-mail deviennent obligatoires à l'identification (au lieu
--  du prénom seul) : la commande ne peut plus être passée sans une fiche
--  client complète, exploitable côté CRM (relances, historique, profil).
--
--  À exécuter une seule fois, sur une base qui a déjà 0001-0008. Un nouvel
--  environnement qui repart de zéro n'en a pas besoin : 0001_schema.sql
--  contient déjà directement cette version.
-- ============================================================================

drop function if exists public.upsert_me(text);

create or replace function public.upsert_me(p_first_name text, p_last_name text, p_email text)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row public.customers;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'missing_profile';
  end if;
  if p_email is null or trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  insert into public.customers (auth_user_id, first_name, last_name, email)
  values (auth.uid(), trim(p_first_name), trim(p_last_name), lower(trim(p_email)))
  on conflict (auth_user_id) do update
    set first_name   = excluded.first_name,
        last_name    = excluded.last_name,
        email        = excluded.email,
        last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.upsert_me(text, text, text) to authenticated;

-- ============================================================================
--  NOTI Calling — 0006_simplify_identity.sql
--
--  Retire l'identification par OTP SMS : trop de friction pour ce qui reste un
--  outil de commande, pas un compte client. Le client saisit uniquement son
--  prénom ; une session anonyme Supabase (signInAnonymously, aucun SMS, aucun
--  compte) porte le JWT qui alimente la RLS existante — aucun changement des
--  policies (0002_rls.sql) n'est nécessaire, elles reposent déjà sur auth.uid().
--
--  À exécuter une seule fois, après 0001-0005, sur une base qui les a déjà.
--  Un nouvel environnement qui repart de zéro n'en a pas besoin : le fichier
--  0001_schema.sql à jour contient directement ce schéma simplifié.
-- ============================================================================

-- Le téléphone n'est plus collecté à l'identification (il reste disponible
-- pour une saisie manuelle future par le staff).
alter table public.customers alter column phone drop not null;

drop function if exists public.upsert_me(text, text, jsonb);

create or replace function public.upsert_me(p_first_name text)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row public.customers;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  insert into public.customers (auth_user_id, first_name)
  values (auth.uid(), nullif(trim(p_first_name), ''))
  on conflict (auth_user_id) do update
    set first_name   = coalesce(excluded.first_name, public.customers.first_name),
        last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.upsert_me(text) to authenticated;

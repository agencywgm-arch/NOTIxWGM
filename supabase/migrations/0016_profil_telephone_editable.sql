-- ============================================================================
--  NOTI Calling — 0016_profil_telephone_editable.sql
--
--  L'« espace client » ne permettait de compléter que e-mail / Instagram.
--  Le téléphone (obligatoire à l'identification) devient lui aussi
--  modifiable depuis l'espace client — un numéro peut changer entre deux
--  soirées. Le téléphone restant l'ancre d'identité (unique sur customers),
--  une tentative de reprendre le numéro d'un AUTRE client est bloquée avec
--  un message clair plutôt qu'une erreur Postgres brute.
-- ============================================================================

-- L'ancienne version (2 arguments) doit être supprimée explicitement, sinon
-- les deux coexisteraient (surcharge), avec un risque d'appel ambigu.
drop function if exists public.update_my_optional_profile(text, text);

create or replace function public.update_my_optional_profile(
  p_email     text default null,
  p_instagram text default null,
  p_phone     text default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.customers;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;
  if p_phone is not null and trim(p_phone) = '' then
    raise exception 'missing_phone';
  end if;

  begin
    update public.customers
       set email     = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
           instagram = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end,
           phone     = case when p_phone is null then phone else trim(p_phone) end
     where id = v_cust
     returning * into v_row;
  exception when unique_violation then
    raise exception 'phone_already_used';
  end;

  return v_row;
end;
$$;

grant execute on function public.update_my_optional_profile(text, text, text) to authenticated;

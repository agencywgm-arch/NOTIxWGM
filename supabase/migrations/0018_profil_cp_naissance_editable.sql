-- ============================================================================
--  NOTI Calling — 0018_profil_cp_naissance_editable.sql
--
--  Les fiches créées AVANT l'ajout du code postal / de la date de naissance
--  (patch 0015) ont ces deux champs vides, et rien ne permettait de les
--  compléter depuis l'espace client (affichés en lecture seule uniquement).
--  Ce patch les rend eux aussi modifiables, comme le téléphone (0016).
-- ============================================================================

-- L'ancienne version (3 arguments) doit être supprimée explicitement, sinon
-- les deux coexisteraient (surcharge), avec un risque d'appel ambigu.
drop function if exists public.update_my_optional_profile(text, text, text);

create or replace function public.update_my_optional_profile(
  p_email       text default null,
  p_instagram   text default null,
  p_phone       text default null,
  p_postal_code text default null,
  p_birthdate   date default null
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
  if p_postal_code is not null and trim(p_postal_code) = '' then
    raise exception 'missing_postal_code';
  end if;
  if p_birthdate is not null and p_birthdate > current_date then
    raise exception 'invalid_birthdate';
  end if;

  begin
    update public.customers
       set email       = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
           instagram   = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end,
           phone       = case when p_phone is null then phone else trim(p_phone) end,
           postal_code = case when p_postal_code is null then postal_code else trim(p_postal_code) end,
           birthdate   = coalesce(p_birthdate, birthdate)
     where id = v_cust
     returning * into v_row;
  exception when unique_violation then
    raise exception 'phone_already_used';
  end;

  return v_row;
end;
$$;

grant execute on function public.update_my_optional_profile(text, text, text, text, date) to authenticated;

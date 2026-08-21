-- ============================================================================
--  NOTI Calling — 0015_profil_etendu.sql
--
--  Retour terrain : nom + prénom + e-mail ne suffisent pas pour le fichier
--  client attendu (relances, segmentation géographique/âge). Nouvelle règle :
--
--    OBLIGATOIRE  : prénom, nom, téléphone, code postal, date de naissance
--    OPTIONNEL    : e-mail, Instagram (complétables plus tard, « espace client »)
--
--  Le téléphone devient l'ANCRE D'IDENTITÉ (il était déjà UNIQUE sur
--  customers, jamais exploité jusqu'ici) : si un client se réidentifie avec
--  le même numéro depuis un nouvel appareil (réinstallation, stockage vidé),
--  upsert_me() reprend sa fiche existante au lieu d'en créer une seconde.
--
--  Aussi dans ce patch :
--   · update_my_optional_profile() — l'« espace client » complète email /
--     Instagram après coup, sans re-saisir les champs obligatoires.
--   · validate_promo_code() — vérification immédiate d'un code % / montant
--     saisi AVANT d'avoir un panier (contrairement à preview_promo, qui a
--     besoin d'un sous-total pour le seuil « panier minimum »).
-- ============================================================================

alter table public.customers
  add column if not exists postal_code text,
  add column if not exists birthdate   date,
  add column if not exists instagram   text;

-- ---------------------------------------------------------------------------
--  upsert_me() — nouvelle signature. L'ancienne version (3 arguments) est
--  supprimée explicitement : sinon les deux coexisteraient (surcharge), avec
--  un risque d'appel ambigu.
-- ---------------------------------------------------------------------------
drop function if exists public.upsert_me(text, text, text);

create or replace function public.upsert_me(
  p_first_name  text,
  p_last_name   text,
  p_phone       text,
  p_postal_code text,
  p_birthdate   date,
  p_email       text default null,
  p_instagram   text default null
)
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_row   public.customers;
  v_phone text := nullif(trim(p_phone), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'missing_profile';
  end if;
  if v_phone is null then
    raise exception 'missing_phone';
  end if;
  if nullif(trim(p_postal_code), '') is null then
    raise exception 'missing_postal_code';
  end if;
  if p_birthdate is null or p_birthdate > current_date then
    raise exception 'invalid_birthdate';
  end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  -- Le téléphone est l'ancre d'identité : un même numéro sur un nouvel
  -- appareil reprend la fiche existante plutôt que d'en créer une seconde.
  select * into v_row from public.customers where phone = v_phone;

  if v_row.id is not null then
    -- Libère l'auth_user_id courant s'il était déjà rattaché à une AUTRE
    -- fiche (contrainte unique sur customers.auth_user_id) — évite un
    -- conflit lors de la reprise de fiche par téléphone.
    update public.customers set auth_user_id = null
     where auth_user_id = auth.uid() and id <> v_row.id;

    update public.customers
       set auth_user_id = auth.uid(),
           first_name   = trim(p_first_name),
           last_name    = trim(p_last_name),
           postal_code  = trim(p_postal_code),
           birthdate    = p_birthdate,
           email        = coalesce(nullif(trim(p_email), ''), email),
           instagram    = coalesce(nullif(trim(p_instagram), ''), instagram),
           last_seen_at = now()
     where id = v_row.id
     returning * into v_row;

    return v_row;
  end if;

  insert into public.customers
    (auth_user_id, first_name, last_name, phone, postal_code, birthdate, email, instagram)
  values (
    auth.uid(), trim(p_first_name), trim(p_last_name), v_phone, trim(p_postal_code), p_birthdate,
    nullif(lower(trim(coalesce(p_email, ''))), ''), nullif(trim(coalesce(p_instagram, '')), '')
  )
  on conflict (auth_user_id) do update
    set first_name   = excluded.first_name,
        last_name    = excluded.last_name,
        phone        = excluded.phone,
        postal_code  = excluded.postal_code,
        birthdate    = excluded.birthdate,
        email        = coalesce(excluded.email, public.customers.email),
        instagram    = coalesce(excluded.instagram, public.customers.instagram),
        last_seen_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  « Espace client » : complète e-mail / Instagram après coup, sans re-passer
--  par les champs obligatoires déjà enregistrés.
-- ---------------------------------------------------------------------------
create or replace function public.update_my_optional_profile(
  p_email     text default null,
  p_instagram text default null
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

  update public.customers
     set email     = case when p_email is null then email else nullif(lower(trim(p_email)), '') end,
         instagram = case when p_instagram is null then instagram else nullif(trim(p_instagram), '') end
   where id = v_cust
   returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
--  Vérification immédiate d'un code % / montant, AVANT d'avoir un panier
--  (contrairement à preview_promo, qui a besoin d'un sous-total pour évaluer
--  le seuil « panier minimum »). Utilisé par la saisie de code unifiée.
-- ---------------------------------------------------------------------------
create or replace function public.validate_promo_code(p_event uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo public.promo_codes;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind in ('percent', 'amount')
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'min_total', v_promo.min_total
  );
end;
$$;

grant execute on function public.upsert_me(text, text, text, text, date, text, text) to authenticated;
grant execute on function public.update_my_optional_profile(text, text)             to authenticated;
grant execute on function public.validate_promo_code(uuid, text)                    to authenticated;

-- ============================================================================
--  0035 — Le téléphone au format international, garanti par la base
--
--  Retour terrain : « adapte les numéros pour qu'il y ait toujours le bon
--  format +33… ; n'affiche jamais de coquilles, ou adapte-les en
--  normalisant ».
--
--  ---------------------------------------------------------------------
--  POURQUOI CE N'EST PAS QUE COSMÉTIQUE
--
--  `customers.phone` porte une contrainte UNIQUE et sert d'ANCRE D'IDENTITÉ :
--  upsert_me() cherche la fiche existante par égalité stricte sur ce champ.
--  « 0612345678 », « +33612345678 » et « 612345678 » désignent la même
--  personne mais créent trois fiches distinctes — et cette personne perd ses
--  crédits et son historique selon la variante qu'elle saisit.
--
--  La normalisation existait déjà, mais UNIQUEMENT en JavaScript
--  (normalizePhoneFR). upsert_me() se contentait de :
--
--      v_phone text := nullif(trim(p_phone), '');
--
--  Autrement dit : la garantie d'identité de toute l'application reposait sur
--  une fonction du navigateur. Tout ce qui n'y passe pas — une correction
--  faite à la main dans le Dashboard, un import, un futur appel d'API — écrit
--  une variante et scinde une identité, silencieusement.
--
--  On déplace donc la règle DANS la base : une fonction de référence, son
--  usage dans upsert_me(), et une contrainte qui rend l'erreur impossible.
--
--  ---------------------------------------------------------------------
--  FORMAT RETENU : E.164 (« +33612345678 »)
--
--  C'est le format attendu par tous les opérateurs SMS (Twilio, Vonage,
--  Brevo, OVH — cf. _shared/sms.ts), donc celui à stocker si l'envoi de SMS
--  ou la vérification par code doivent fonctionner un jour sans reprise de
--  données. L'affichage, lui, reste lisible côté application.
--
--  Les numéros étrangers déjà en +XX sont CONSERVÉS tels quels : un client
--  espagnol ou belge ne doit pas voir son numéro maquillé en français.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  1. La fonction de référence.
-- ---------------------------------------------------------------------------
create or replace function public.normalize_phone(p_phone text)
returns text
language plpgsql immutable
as $$
declare
  v_raw   text;
  v_plus  boolean;
  v_d     text;
begin
  if p_phone is null then return null; end if;

  v_raw := trim(p_phone);
  if v_raw = '' then return null; end if;

  -- Un « + » ne compte que s'il ouvre le numéro : « 06 12 (+1) » n'est pas
  -- un indicatif international.
  v_plus := left(v_raw, 1) = '+' or left(v_raw, 4) = '0033';
  v_d    := regexp_replace(v_raw, '\D', '', 'g');

  if v_d = '' then return null; end if;

  -- 00 33 6 12 34 56 78 → +33612345678, et « 0033 (0)6… » de la même façon :
  -- les deux écritures désignent le même numéro, elles doivent donner le
  -- même résultat.
  if left(v_d, 4) = '0033' then
    v_d := substr(v_d, 5);
    if length(v_d) = 10 and left(v_d, 1) = '0' then v_d := substr(v_d, 2); end if;
    if length(v_d) = 9 and left(v_d, 1) <> '0' then return '+33' || v_d; end if;
    return null;
  end if;

  -- Déjà international et NON français : on ne touche à rien. Le format
  -- E.164 tolère 8 à 15 chiffres, indicatif compris.
  if v_plus and left(v_d, 2) <> '33' then
    if length(v_d) between 8 and 15 then return '+' || v_d; end if;
    return null;
  end if;

  -- +33 (0)6 12 34 56 78 — écriture très répandue sur les cartes de visite
  -- et les sites. Le zéro entre parenthèses est une commodité de lecture, il
  -- ne fait pas partie du numéro composé depuis l'étranger.
  if left(v_d, 3) = '330' and length(v_d) = 12 then
    v_d := '33' || substr(v_d, 4);
  end if;

  -- 33 6 12 34 56 78 (avec ou sans +) → +33612345678
  if left(v_d, 2) = '33' and length(v_d) = 11 then
    -- En France, le chiffre qui suit le 0 de service va de 1 à 9 : « +330… »
    -- n'existe pas et trahit une saisie de test ou une coquille.
    if substr(v_d, 3, 1) = '0' then return null; end if;
    return '+33' || substr(v_d, 3);
  end if;

  -- 06 12 34 56 78 → +33612345678
  if length(v_d) = 10 and left(v_d, 1) = '0' then
    if substr(v_d, 2, 1) = '0' then return null; end if;
    return '+33' || substr(v_d, 2);
  end if;

  -- 6 12 34 56 78 — le zéro initial que l'autofill escamote parfois.
  if length(v_d) = 9 and left(v_d, 1) <> '0' then
    return '+33' || v_d;
  end if;

  -- Rien de reconnaissable : null plutôt qu'une valeur inventée. L'appelant
  -- décide quoi en faire — upsert_me() refuse, l'affichage montre le brut.
  return null;
end;
$$;

comment on function public.normalize_phone(text) is
  'Ramène un numéro à E.164 (+33612345678). Gère +33 / 0033 / 33 / 06… / 6…, '
  'conserve les numéros étrangers déjà en +XX, et renvoie null si la saisie '
  'n''est reconnaissable comme aucun de ces formats.';

grant execute on function public.normalize_phone(text) to authenticated, anon, service_role;


-- ---------------------------------------------------------------------------
--  2. Reprise des numéros déjà en base.
--
--  Une conversion peut faire entrer deux fiches en collision (« 0612345678 »
--  et « +33612345678 » deviennent le même numéro), ce que la contrainte
--  UNIQUE refusera. Fusionner deux fiches n'est pas anodin : commandes,
--  forfaits, cadeaux et présences pointent vers l'une ou l'autre, et
--  plusieurs de ces tables ont leurs propres contraintes d'unicité.
--
--  On ne devine donc pas. La migration s'interrompt en listant les numéros
--  concernés, sans avoir rien modifié (tout se joue dans une transaction).
--  C'est volontaire : mieux vaut un message clair qu'une fusion approximative
--  qui ferait disparaître l'historique de quelqu'un.
-- ---------------------------------------------------------------------------
do $$
declare
  v_conflits text;
begin
  select string_agg(distinct norm, ', ')
    into v_conflits
    from (
      select public.normalize_phone(phone) as norm
        from public.customers
       where phone is not null
         and public.normalize_phone(phone) is not null
       group by public.normalize_phone(phone)
      having count(*) > 1
    ) x;

  if v_conflits is not null then
    raise exception
      'Reprise impossible : plusieurs fiches client se ramènent au même numéro (%). '
      'Fusionnez-les avant de rejouer cette migration — aucune donnée n''a été modifiée.',
      v_conflits;
  end if;
end $$;

update public.customers
   set phone = public.normalize_phone(phone)
 where phone is not null
   and public.normalize_phone(phone) is not null
   and phone <> public.normalize_phone(phone);

-- Les numéros que la fonction ne sait pas lire sont conservés tels quels :
-- ils ne bloquent pas la migration (la contrainte ci-dessous les tolère), et
-- la prochaine mise à jour de la fiche les remettra d'aplomb.


-- ---------------------------------------------------------------------------
--  3. La contrainte : plus aucun format bâtard ne peut entrer.
--
--  `not valid` puis `validate` : la vérification des lignes existantes se
--  fait sans verrou long, et les rares numéros illisibles hérités ne bloquent
--  pas la migration — la contrainte ne porte que sur ce qui ressemble à un
--  numéro normalisable.
-- ---------------------------------------------------------------------------
alter table public.customers drop constraint if exists customers_phone_e164;
alter table public.customers
  add constraint customers_phone_e164
  check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$')
  not valid;

comment on constraint customers_phone_e164 on public.customers is
  'Le téléphone est stocké en E.164 (+33612345678). Ancre d''identité : une '
  'variante de format créerait une seconde fiche pour la même personne.';


-- ---------------------------------------------------------------------------
--  4. upsert_me() normalise elle-même.
--
--  Seul changement de fond par rapport à 0015 : `v_phone` passe par
--  normalize_phone(), et une saisie illisible lève `invalid_phone` au lieu
--  d'être enregistrée telle quelle. Le reste est repris à l'identique.
-- ---------------------------------------------------------------------------
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
  v_phone text := public.normalize_phone(p_phone);
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null then
    raise exception 'missing_profile';
  end if;
  if nullif(trim(p_phone), '') is null then
    raise exception 'missing_phone';
  end if;
  -- Saisie présente mais inexploitable : on le dit, plutôt que d'enregistrer
  -- un numéro qui ne joindra jamais personne et scindera l'identité.
  if v_phone is null then
    raise exception 'invalid_phone';
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

grant execute on function public.upsert_me(text, text, text, text, date, text, text) to authenticated;


-- ---------------------------------------------------------------------------
--  5. L'espace client écrit lui aussi le téléphone.
--
--  update_my_optional_profile() (0018) enregistrait `trim(p_phone)` : seconde
--  porte d'entrée, même conséquence. Corriger upsert_me() seule aurait laissé
--  ce chemin réintroduire des variantes à chaque modification de profil.
--
--  Repris à l'identique de 0018, aux deux lignes de normalisation près.
-- ---------------------------------------------------------------------------
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
  v_cust  uuid := public.my_customer_id();
  v_row   public.customers;
  v_phone text;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;
  if p_phone is not null and trim(p_phone) = '' then
    raise exception 'missing_phone';
  end if;
  if p_phone is not null then
    v_phone := public.normalize_phone(p_phone);
    if v_phone is null then raise exception 'invalid_phone'; end if;
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
           phone       = case when p_phone is null then phone else v_phone end,
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


alter table public.customers validate constraint customers_phone_e164;

-- ============================================================================
--  0056 — Code « forfait crédits » rotatif (change toutes les 60 s)
--
--  Le barème ne change pas (1 alcool éligible = 2 crédits, 1 soft = 1 crédit,
--  voir 0013) : c'est toujours un code promo_codes.kind = 'credits'. Seule la
--  VALEUR SAISIE PAR LE CLIENT peut désormais être dynamique plutôt qu'un
--  texte fixe — utile pour un code affiché sur un écran au bar/à l'entrée,
--  qu'on ne veut pas voir circuler par capture d'écran toute la soirée.
--
--  Le code affiché à un instant T est dérivé, par HMAC-SHA256, d'un secret
--  tiré aléatoirement à la création (rotating_secret) et de la minute UNIX en
--  cours (v_step = epoch // 60) — même principe qu'un TOTP, simplifié (pas
--  besoin d'interopérer avec une appli d'authentification tierce, juste
--  d'être imprévisible et vérifiable côté serveur).
--
--  rotating_secret n'est JAMAIS lisible par le client : promo_codes n'a
--  aucune policy de lecture publique (0002_rls.sql, « AUCUNE lecture
--  publique »), et la seule fonction qui expose le code EN COURS
--  (current_rotating_code) est réservée au staff de l'événement.
--
--  redeem_pass() (dernière version : 0034) est repris à l'identique, seule la
--  clause de correspondance du code change — code fixe OU rotatif, l'un ou
--  l'autre selon promo_codes.is_rotating.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

alter table public.promo_codes
  add column if not exists is_rotating     boolean not null default false,
  add column if not exists rotating_secret text;

comment on column public.promo_codes.is_rotating is
  'Code kind=''credits'' dont la valeur saisie par le client change toutes les 60 s au lieu d''être fixe — voir rotating_code_value().';
comment on column public.promo_codes.rotating_secret is
  'Secret aléatoire (généré côté client à la création) servant de clé HMAC. Jamais exposé : ni lu par le client (RLS), ni renvoyé par current_rotating_code().';

-- ---------------------------------------------------------------------------
--  Dérive le code à 6 chiffres valide pour un (secret, pas de 60 s) donné.
--  IMMUTABLE : mêmes entrées, même sortie, toujours — c'est tout l'intérêt
--  d'un TOTP (vérifiable sans état côté serveur, juste l'heure courante).
-- ---------------------------------------------------------------------------
create or replace function public.rotating_code_value(p_secret text, p_step bigint)
returns text
language sql immutable
as $$
  select lpad(
    (
      (
        get_byte(h, 0)::bigint * 16777216 +
        get_byte(h, 1)::bigint * 65536 +
        get_byte(h, 2)::bigint * 256 +
        get_byte(h, 3)::bigint
      ) % 1000000
    )::text,
    6, '0'
  )
  from (select extensions.hmac(p_step::text, p_secret, 'sha256') as h) s;
$$;

-- ---------------------------------------------------------------------------
--  Code actuellement valide, pour affichage en direct côté staff (écran au
--  bar, etc.). Réservé à l'équipe de l'événement — ne renvoie jamais
--  rotating_secret, seulement la valeur du moment et le temps restant avant
--  le prochain changement.
-- ---------------------------------------------------------------------------
create or replace function public.current_rotating_code(p_promo uuid)
returns table (code text, seconds_left int)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo public.promo_codes;
  v_now   double precision;
  v_step  bigint;
begin
  select * into v_promo from public.promo_codes where id = p_promo;
  if v_promo.id is null or not public.is_event_staff(v_promo.event_id) then
    raise exception 'forbidden';
  end if;
  if not v_promo.is_rotating or v_promo.rotating_secret is null then
    raise exception 'not_rotating';
  end if;

  v_now  := extract(epoch from now());
  v_step := floor(v_now / 60)::bigint;

  return query select
    public.rotating_code_value(v_promo.rotating_secret, v_step),
    (60 - (v_now::bigint % 60))::int;
end;
$$;

grant execute on function public.current_rotating_code(uuid) to authenticated;

-- ---------------------------------------------------------------------------
--  redeem_pass() — reprise de 0034, seule la clause de correspondance du
--  code change (fixe OU rotatif). Tolérance d'UN pas (60 s) en arrière sur le
--  rotatif : un client qui tape juste après un changement de code voit
--  encore accepté le code affiché la seconde précédente.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust      uuid := public.my_customer_id();
  v_promo     public.promo_codes;
  v_pass      public.event_passes;
  v_now_paris time;
  v_step      bigint := floor(extract(epoch from now()) / 60)::bigint;
  v_input     text := upper(trim(p_code));
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and active
      and kind = 'credits'
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (
        (not is_rotating and upper(code) = v_input)
        or
        (is_rotating and rotating_secret is not null and v_input in (
           public.rotating_code_value(rotating_secret, v_step),
           public.rotating_code_value(rotating_secret, v_step - 1)
         ))
      );
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is not null then
    return v_pass;
  end if;

  update public.promo_codes
     set uses_count = uses_count + 1
   where id = v_promo.id
     and (max_uses is null or uses_count < max_uses);
  if not found then raise exception 'code_exhausted'; end if;

  v_now_paris := (now() at time zone 'Europe/Paris')::time;

  insert into public.event_passes
    (event_id, customer_id, promo_code_id, credits_total, credits_remaining,
     food_token_total, food_token_available)
  values (
    p_event, v_cust, v_promo.id,
    v_promo.credits_per_person, v_promo.credits_per_person,
    v_promo.food_tokens_per_person,
    v_promo.food_tokens_per_person > 0 and v_now_paris < time '22:30:00'
  )
  returning * into v_pass;

  if v_promo.food_tokens_per_person > 0 and v_now_paris >= time '22:30:00' then
    update public.event_passes
       set credits_total     = credits_total + v_promo.food_tokens_per_person * 2,
           credits_remaining = credits_remaining + v_promo.food_tokens_per_person * 2
     where id = v_pass.id
     returning * into v_pass;
  end if;

  insert into public.promo_redemptions
    (promo_code_id, customer_id, event_id, credits_granted)
  values (v_promo.id, v_cust, p_event, v_pass.credits_total)
  on conflict (promo_code_id, customer_id) do nothing;

  return v_pass;
end;
$$;

grant execute on function public.redeem_pass(uuid, text) to authenticated;

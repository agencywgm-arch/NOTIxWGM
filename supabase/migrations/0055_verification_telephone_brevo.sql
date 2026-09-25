-- ============================================================================
--  0055 — Vérification du numéro, sur Brevo plutôt que Firebase
--
--  0039 faisait reposer l'envoi du SMS entièrement sur Firebase Phone Auth,
--  côté client. Firebase demandait la formule Blaze (carte bancaire) sur un
--  projet séparé, jamais vraiment finalisée — la vérification tournait donc
--  en pause (phone_verify_required, 0053) depuis. Le SMS transactionnel est
--  maintenant en place pour les relances (Brevo, via la fonction Edge
--  `notify`) : on réutilise exactement le même canal pour le code à 6
--  chiffres plutôt que de dépendre d'un second fournisseur.
--
--  Le code lui-même ne transite JAMAIS par le navigateur du client : il est
--  généré et stocké ici, dans une table sans la moindre policy RLS (donc
--  illisible même par son propriétaire), et seule la fonction Edge
--  `send-otp` — via la clé service_role, jamais exposée au client — peut le
--  lire pour l'envoyer par SMS. Le client ne voit que « code envoyé » /
--  « code accepté ou non », jamais le code lui-même.
-- ============================================================================

create table if not exists public.phone_otp_codes (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  code        text not null,
  expires_at  timestamptz not null,
  attempts    int not null default 0,
  sent_at     timestamptz not null default now()
);

alter table public.phone_otp_codes enable row level security;
-- Volontairement AUCUNE policy : ni le client (même sur sa propre ligne), ni
-- le staff ne peuvent lire ou écrire cette table directement. Seules les
-- fonctions SECURITY DEFINER ci-dessous, et la clé service_role côté Edge
--  Function, y ont accès.

-- ---------------------------------------------------------------------------
--  Demande un code : génère, remplace l'éventuel code précédent, repart les
--  tentatives à zéro. Ne renvoie rien — c'est send-otp (Edge Function) qui
--  lit ce code pour l'envoyer, jamais la réponse de ce RPC.
--
--  Anti-abus minimal : un throttle de 30 s entre deux demandes suffit à
--  empêcher qu'un clic répété ne consomme du crédit SMS pour rien, sans
--  gêner un client qui n'a normalement besoin que d'un ou deux essais.
-- ---------------------------------------------------------------------------
create or replace function public.request_phone_otp()
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_last timestamptz;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select sent_at into v_last from public.phone_otp_codes where customer_id = v_cust;
  if v_last is not null and v_last > now() - interval '30 seconds' then
    raise exception 'rate_limited';
  end if;

  insert into public.phone_otp_codes (customer_id, code, expires_at, attempts, sent_at)
  values (
    v_cust,
    lpad(floor(random() * 1000000)::text, 6, '0'),
    now() + interval '10 minutes',
    0,
    now()
  )
  on conflict (customer_id) do update
    set code       = excluded.code,
        expires_at = excluded.expires_at,
        attempts   = 0,
        sent_at    = excluded.sent_at;
end;
$$;

grant execute on function public.request_phone_otp() to authenticated;

-- ---------------------------------------------------------------------------
--  Confirme le code saisi. Plafonne à 5 essais par code envoyé (au-delà, il
--  faut en redemander un neuf via request_phone_otp) — un code à 6 chiffres
--  se devine en ~5 essais avec assez de tentatives libres, ce plafond ferme
--  cette fenêtre sans gêner une simple faute de frappe.
--
--  Renvoie `false` (pas d'exception) sur un mauvais code : une exception
--  PL/pgSQL non rattrapée annule TOUTES les écritures faites plus haut dans
--  le même appel — l'incrément de `attempts` aurait donc été annulé par le
--  `raise` qui suivait juste après, laissant le compteur bloqué à zéro pour
--  toujours (repéré en testant cette migration en local avant de l'envoyer).
--  Les cas bloquants (expiré, trop de tentatives, pas de client) sont
--  vérifiés AVANT toute écriture : eux peuvent lever une exception sans rien
--  perdre.
--
--  Délègue à mark_phone_verified() (0039) une fois le code validé : même
--  sémantique qu'avec Firebase (horodate le numéro ACTUELLEMENT enregistré,
--  pas un numéro arbitraire passé en paramètre).
-- ---------------------------------------------------------------------------
create or replace function public.confirm_phone_otp(p_code text)
returns boolean
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.phone_otp_codes;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_row from public.phone_otp_codes where customer_id = v_cust;
  if v_row.customer_id is null or v_row.expires_at < now() then
    raise exception 'code_expired';
  end if;
  if v_row.attempts >= 5 then
    raise exception 'too_many_attempts';
  end if;

  if p_code is null or btrim(p_code) <> v_row.code then
    update public.phone_otp_codes set attempts = attempts + 1 where customer_id = v_cust;
    return false;
  end if;

  perform public.mark_phone_verified();
  delete from public.phone_otp_codes where customer_id = v_cust;
  return true;
end;
$$;

grant execute on function public.confirm_phone_otp(text) to authenticated;

-- ============================================================================
--  0039 — Vérification du numéro de téléphone
--
--  Demande : « ajouter un moyen d'authentifier le numéro gratuitement ».
--  Objectif confirmé : qualité des données CRM (repérer les faux numéros /
--  doublons), pas une sécurité de connexion — donc une vérification légère
--  et facultative suffit, elle ne doit rien bloquer.
--
--  Le SMS lui-même part de Firebase Phone Auth (gratuit dans le quota
--  Google), côté client uniquement. Supabase n'envoie jamais de SMS et ne
--  connaît rien de Firebase — il se contente d'enregistrer le résultat une
--  fois que le client a confirmé le code à 6 chiffres.
-- ============================================================================

alter table public.customers
  add column if not exists phone_verified_at timestamptz,
  add column if not exists phone_verified_number text;

comment on column public.customers.phone_verified_at is
  'Horodatage de la dernière vérification SMS réussie (Firebase Phone Auth, côté client).';
comment on column public.customers.phone_verified_number is
  'Numéro (E.164) tel qu''il était au moment de la vérification. Si le client '
  'change son numéro ensuite, il ne correspond plus à `phone` : le badge '
  '« vérifié » disparaît de lui-même, sans déclencheur à maintenir.';

-- ---------------------------------------------------------------------------
--  mark_phone_verified() — n'accepte aucun numéro en paramètre : elle
--  horodate le numéro ACTUELLEMENT enregistré sur la fiche, celui que le
--  client vient de prouver détenir côté Firebase. Un paramètre aurait permis
--  d'appeler la fonction avec un numéro arbitraire, jamais vérifié par
--  personne.
-- ---------------------------------------------------------------------------
create or replace function public.mark_phone_verified()
returns public.customers
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_row  public.customers;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  update public.customers
     set phone_verified_at = now(),
         phone_verified_number = phone
   where id = v_cust
   returning * into v_row;

  if v_row.phone is null then raise exception 'no_phone_set'; end if;

  return v_row;
end;
$$;

grant execute on function public.mark_phone_verified() to authenticated;

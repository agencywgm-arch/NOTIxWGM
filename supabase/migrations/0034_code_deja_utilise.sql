-- ============================================================================
--  0034 — Un code déjà utilisé doit le dire
--
--  Retour terrain : « j'ai remis un code promo déjà utilisé, ça m'a pas mis
--  d'erreur ».
--
--  Deux défauts distincts derrière ce symptôme.
--
--  1. redeem_pass() (0020) sortait AVANT de regarder le code :
--
--         select * into v_pass from public.event_passes
--           where event_id = p_event and customer_id = v_cust;
--         if v_pass.id is not null then
--           return v_pass;              -- ← le code n'a jamais été lu
--         end if;
--
--     Conséquence : dès qu'une personne avait un forfait actif, N'IMPORTE
--     QUELLE saisie renvoyait ce forfait — donc un succès. Taper « XXXX »,
--     un code d'une autre soirée, ou un code expiré affichait « Forfait
--     activé ! ». Le raccourci était là pour tolérer une ressaisie après
--     rescan ; il tolérait en réalité tout et n'importe quoi.
--
--     Correction : on valide le code d'abord. Un code invalide lève
--     `invalid_pass_code` (l'application enchaîne alors sur les codes % /
--     montant, comme avant). Un code valide sur une personne qui a déjà son
--     forfait renvoie le forfait existant, sans recréditer — la tolérance
--     voulue, mais seulement pour un vrai code.
--
--  2. redeem_gift_code() (0024) renvoie `already: true` quand le quota
--     individuel est épuisé. Le serveur était honnête, mais l'application
--     affichait quand même « Crédits ajoutés » : côté client, aucune
--     différence entre une activation réelle et une ressaisie. Corrigé côté
--     application (App.jsx), pas ici — le comportement SQL était déjà bon.
-- ============================================================================

create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust      uuid := public.my_customer_id();
  v_promo     public.promo_codes;
  v_pass      public.event_passes;
  v_now_paris time;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  -- Le code d'abord, toujours : c'est ce qui manquait. Sans cette lecture
  -- avant la sortie anticipée, une saisie fantaisiste passait pour un succès
  -- dès qu'un forfait existait.
  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind = 'credits'
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now());
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

  -- Un forfait par personne et par soirée. Le code est valide, la personne en
  -- a déjà un : on renvoie l'existant sans recréditer. L'application compare
  -- avec le forfait qu'elle avait déjà en mémoire pour annoncer « déjà
  -- activé » plutôt que « activé ».
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

  -- Arrivée après 22h30 : le jeton food est automatiquement converti en
  -- crédits (2 crédits par jeton), comme en 0013.
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

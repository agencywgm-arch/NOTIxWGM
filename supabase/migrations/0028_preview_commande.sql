-- ============================================================================
--  0028 — Prévisualisation de commande : le solde de crédits AVANT de valider
--
--  Retour terrain, 2.3 (décision majeure du point équipe) :
--
--  · Le client doit voir, au fil de la carte, quels articles ses crédits
--    peuvent couvrir — un marquage éphémère, qui disparaît dès qu'il n'a
--    plus de crédits.
--  · « Sur le modèle d'Uber Eats ou Bolt : à la validation du panier,
--    afficher le solde de crédits et le reste à payer. »
--  · La règle critique : « le marquage ne doit s'afficher que si le client a
--    effectivement des crédits disponibles. [...] Scénario à éviter
--    absolument : le client a épuisé ses crédits, la mention traîne encore,
--    il commande, et au retrait on lui annonce un règlement au bar. »
--
--  Le badge sur la carte (« ce type d'article se paie avec vos crédits ») est
--  calculé côté client — c'est une indication, pas un prix, et il ne dépend
--  que du solde déjà connu du client (my_gift_summary / event_passes), sans
--  toucher au plafond en euros qui reste une donnée strictement interne.
--
--  Mais le total affiché à la validation, lui, doit être EXACT — c'est très
--  exactement le scénario à éviter qui est en jeu. Le reconstruire dans le
--  navigateur aurait dupliqué toute la logique de place_order(), plafond en
--  euros compris ; c'est précisément ce genre de duplication qui vient de
--  provoquer un bug dans cette même série de migrations. preview_order()
--  tourne donc le MÊME calcul que place_order(), en lecture seule, pour que
--  le nombre annoncé avant validation soit celui qui sera appliqué.
--
--  Duplication assumée, testée : les deux fonctions ne partagent pas de code
--  (place_order() n'est pas retouché, il vient d'être corrigé et re-vérifié),
--  mais le test joint compare leurs résultats sur le même panier et exige
--  l'égalité. Toute divergence future entre les deux échouera ce test.
-- ============================================================================

-- Type de travail : une copie mutable, en mémoire, de chaque droit à crédit du
-- client — pour simuler leur consommation le long du panier sans jamais
-- écrire dans gift_entitlements (contrainte d'une fonction stable/lecture
-- seule, et tout l'intérêt d'une prévisualisation).
do $$ begin
  create type public._gift_ent_sim as (
    id uuid, mode text, category text, product_id uuid,
    max_value numeric, remaining int
  );
exception when duplicate_object then null; end $$;

create or replace function public.preview_order(
  p_event uuid,
  p_items jsonb,
  p_promo text default null
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_cust      uuid := public.my_customer_id();
  v_item      jsonb;
  v_prod      public.products;
  v_qty       int;
  v_unit      numeric(10,2);
  v_variant   jsonb;
  v_opt       jsonb;
  v_subtotal  numeric(10,2) := 0;
  v_discount  numeric(10,2) := 0;
  v_promo     public.promo_codes;
  v_pass      public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
  v_credits_used int := 0;
  v_food_used    boolean := false;
  v_richard_used boolean := false;
  v_ents         public._gift_ent_sim[];
  v_i            int;
  v_gift_cat     text;
  v_gift_cost    int;
  v_gift_left    int;
  v_gift_take    int;
  v_gift_covered numeric(10,2);
  v_gift_total   numeric(10,2) := 0;
  v_gift_count   int := 0;
  v_gift_credits int := 0;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('subtotal', 0, 'discount', 0, 'total', 0, 'gift_total', 0, 'credits_left', 0);
  end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is not null then
    v_richard_used := v_pass.richard_used;
    v_food_used := not v_pass.food_token_available;
  end if;

  select coalesce(array_agg(row(e.id, e.mode, e.category, e.product_id, e.max_value, e.quantity_remaining)::public._gift_ent_sim
                   order by (e.mode = 'product') desc, e.created_at), array[]::public._gift_ent_sim[])
    into v_ents
    from public.gift_entitlements e
   where e.event_id = p_event and e.customer_id = v_cust and e.quantity_remaining > 0;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_prod from public.products
      where id = (v_item ->> 'product_id')::uuid and is_listed and not sold_out;
    if v_prod.id is null then raise exception 'product_unavailable'; end if;

    v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

    v_unit := v_prod.price;
    if jsonb_array_length(coalesce(v_prod.variants, '[]'::jsonb)) > 0 then
      select value into v_variant
        from jsonb_array_elements(v_prod.variants)
        where value ->> 'id' = coalesce(v_item ->> 'variant_id', '')
        limit 1;
      if v_variant is null then raise exception 'variant_required'; end if;
      v_unit := (v_variant ->> 'price')::numeric;
    end if;

    if v_item ? 'options' then
      for v_opt in select * from jsonb_array_elements(v_item -> 'options') loop
        v_unit := v_unit + coalesce((
          select (o ->> 'price')::numeric
          from jsonb_array_elements(v_prod.option_groups) g,
               jsonb_array_elements(g -> 'options') o
          where o ->> 'id' = v_opt ->> 'id'
          limit 1
        ), 0);
      end loop;
    end if;

    v_subtotal := v_subtotal + v_unit * v_qty;

    -- ---- Cadeaux : même ordre de préférence que place_order (article
    -- précis avant catégorie), simulé sur la copie en mémoire. ---------------
    v_gift_left := v_qty;
    v_gift_cat  := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);
    v_gift_cost := public.gift_credit_cost(v_prod.universe, v_prod.is_alcohol);

    loop
      exit when v_gift_left <= 0;

      v_i := null;
      for k in 1 .. coalesce(array_length(v_ents, 1), 0) loop
        if v_ents[k].remaining >= (case when v_ents[k].mode = 'product' then 1 else v_gift_cost end)
           and (
             (v_ents[k].mode = 'product' and v_ents[k].product_id = v_prod.id)
             or (v_ents[k].mode = 'category' and v_ents[k].category = v_gift_cat)
           )
        then
          v_i := k;
          exit;
        end if;
      end loop;
      exit when v_i is null;

      v_gift_take := least(
        v_gift_left,
        v_ents[v_i].remaining / (case when v_ents[v_i].mode = 'product' then 1 else v_gift_cost end)
      );
      exit when v_gift_take <= 0;

      v_gift_covered := case
        when v_ents[v_i].max_value is null then v_unit
        else least(v_unit, v_ents[v_i].max_value)
      end;

      v_ents[v_i].remaining := v_ents[v_i].remaining
        - v_gift_take * (case when v_ents[v_i].mode = 'product' then 1 else v_gift_cost end);
      v_gift_credits := v_gift_credits
        + v_gift_take * (case when v_ents[v_i].mode = 'product' then 1 else v_gift_cost end);

      v_discount   := v_discount + v_gift_covered * v_gift_take;
      v_gift_total := v_gift_total + v_gift_covered * v_gift_take;
      v_gift_count := v_gift_count + v_gift_take;
      v_gift_left  := v_gift_left - v_gift_take;
    end loop;

    -- ---- Forfait Noti : le portefeuille ne couvre que ce qui reste --------
    if v_pass.id is not null and v_gift_left > 0 then
      if v_prod.credit_once and not v_richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining - v_credits_used >= v_wallet_cost then
          v_richard_used := true;
          v_credits_used := v_credits_used + v_wallet_cost;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_gift_left, (v_pass.credits_remaining - v_credits_used) / v_wallet_cost);
        if v_wallet_units > 0 then
          v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and not v_food_used then
        v_food_used := true;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  if nullif(btrim(p_promo), '') is not null then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := v_discount + least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
    end if;
  end if;

  return jsonb_build_object(
    'subtotal', v_subtotal,
    'discount', least(v_discount, v_subtotal),
    'total', greatest(0, v_subtotal - v_discount),
    'gift_total', v_gift_total,
    'gift_count', v_gift_count,
    'promo_applied', v_promo.id is not null,
    -- Crédits qui resteront APRÈS validation — c'est ce nombre, pas un
    -- montant, que le client doit voir : « il vous restera 2 crédits ».
    -- credits_left additionne forfait ET codes cadeaux, exactement comme
    -- creditsTotal côté client (voir isCreditEligible / CreditsIntroSheet) —
    -- une seule notion de « mes crédits », quelle que soit leur origine.
    'credits_left',
      coalesce(case when v_pass.id is not null then v_pass.credits_remaining - v_credits_used else 0 end, 0)
      + coalesce((select sum(e.remaining) from unnest(v_ents) e), 0),
    'pass_credits_left', case when v_pass.id is not null
                               then v_pass.credits_remaining - v_credits_used else null end
  );
end
$$;

revoke all on function public.preview_order(uuid, jsonb, text) from public;
grant execute on function public.preview_order(uuid, jsonb, text) to authenticated;

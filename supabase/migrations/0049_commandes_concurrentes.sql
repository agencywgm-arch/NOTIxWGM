-- ============================================================================
--  NOTI Calling — 0049_commandes_concurrentes.sql
--  Deux verrous manquants sur place_order(), trouvés en rejouant des
--  commandes réellement simultanées sur une base de test.
--
--  1. FORFAIT — le solde de crédits était lu sans verrou, recalculé en
--     mémoire, puis réécrit tel quel en fin de fonction. Deux commandes
--     simultanées du même client partaient donc du même solde et la seconde
--     écrasait la déduction de la première. Mesuré : deux commandes à 2
--     crédits sur un forfait de 10 laissaient 8 crédits au lieu de 6 — deux
--     crédits consommés que personne ne décompte, offerts par la maison.
--     C'est le seul des défauts trouvés qui coûte de l'argent.
--
--  2. CODES CADEAUX — le décrément était déjà relatif, donc juste sur le
--     montant ; mais le nombre d'unités à prendre se décidait sur une
--     lecture non verrouillée, et deux commandes pouvaient se partager une
--     unité unique.
--
--  Ni l'un ni l'autre n'était visible à la relecture : il a fallu les
--  reproduire. Le reste de la fonction est identique à 0037 — en
--  particulier la scission food / boissons et la reprise sur collision de
--  code de retrait, qui étaient déjà correctes.
-- ============================================================================

drop function if exists public.place_order(uuid, uuid, jsonb, text, text);

create function public.place_order(
  p_event      uuid,
  p_scan_point uuid,
  p_items      jsonb,
  p_note       text default null,
  p_promo      text default null
)
returns setof public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust      uuid := public.my_customer_id();
  v_prep      int;
  v_pass      public.event_passes;
  v_promo     public.promo_codes;
  v_promo_hit boolean := false;

  v_food      jsonb := '[]'::jsonb;
  v_other     jsonb := '[]'::jsonb;
  v_basket    jsonb;
  v_is_food   boolean;

  v_order     public.orders;

  v_item      jsonb;
  v_prod      public.products;
  v_qty       int;
  v_unit      numeric(10,2);
  v_variant   jsonb;
  v_vlabel    text;
  v_opt       jsonb;
  v_subtotal  numeric(10,2);
  v_discount  numeric(10,2);

  v_ent          public.gift_entitlements;
  v_gift_left    int;
  v_gift_cat     text;
  v_gift_cost    int;
  v_gift_take    int;
  v_gift_covered numeric(10,2);
  v_gift_total   numeric(10,2);
  v_gift_count   int;
  v_credits_used int;
  v_food_used    boolean;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  if not exists (select 1 from public.events e
                 where e.id = p_event and e.is_active and e.accept_orders) then
    raise exception 'orders_closed';
  end if;

  if not public.can_order(p_event) then
    raise exception 'pickup_pending';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_cart';
  end if;

  select default_prep_min into v_prep from public.events where id = p_event;
  -- FOR UPDATE : ce solde est recalculé en mémoire tout au long de la
  -- fonction, puis réécrit tel quel à la fin. Sans verrou, deux commandes
  -- simultanées du même client partent du même solde et la seconde écrase la
  -- déduction de la première — des crédits consommés que personne ne
  -- décompte. Reproduit en test : deux commandes à 2 crédits sur un forfait
  -- de 10 laissaient 8 au lieu de 6.
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust
    for update;

  -- ---- Répartition food / reste -------------------------------------------
  for v_item in select * from jsonb_array_elements(p_items) loop
    select (universe = 'food') into v_is_food from public.products
      where id = (v_item ->> 'product_id')::uuid;
    if v_is_food is null then raise exception 'product_unavailable'; end if;
    if v_is_food then
      v_food := v_food || jsonb_build_array(v_item);
    else
      v_other := v_other || jsonb_build_array(v_item);
    end if;
  end loop;

  -- ---- Une commande par panier non vide -----------------------------------
  foreach v_basket in array array[v_other, v_food] loop
    continue when jsonb_array_length(v_basket) = 0;

    v_is_food  := v_basket = v_food;
    v_subtotal := 0;
    v_discount := 0;
    v_gift_total := 0;
    v_gift_count := 0;
    v_credits_used := 0;
    v_food_used := false;

    -- Le code de retrait est réservé par l'écriture elle-même, avec reprise
    -- en cas de collision (voir insert_order_with_code). Le chrono de la food
    -- ne démarre pas ici : `estimated_ready_at` reste null tant que la caisse
    -- n'a pas encaissé (voir start_food_prep).
    v_order := public.insert_order_with_code(
      p_event, v_cust, p_scan_point,
      case when v_is_food then 'AWAITING_PAYMENT'::public.order_status
           else 'RECEIVED'::public.order_status end,
      nullif(trim(p_note), ''),
      case when v_is_food then null
           else now() + make_interval(mins => coalesce(v_prep, 1)) end
    );

    for v_item in select * from jsonb_array_elements(v_basket) loop
      select * into v_prod from public.products
        where id = (v_item ->> 'product_id')::uuid and is_listed and not sold_out;
      if v_prod.id is null then raise exception 'product_unavailable'; end if;

      v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

      v_unit := v_prod.price;
      v_vlabel := null;
      if jsonb_array_length(coalesce(v_prod.variants, '[]'::jsonb)) > 0 then
        select value into v_variant
          from jsonb_array_elements(v_prod.variants)
          where value ->> 'id' = coalesce(v_item ->> 'variant_id', '')
          limit 1;
        if v_variant is null then raise exception 'variant_required'; end if;
        v_unit := (v_variant ->> 'price')::numeric;
        v_vlabel := v_variant ->> 'label';
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

      insert into public.order_items (order_id, product_id, name_snapshot, variant_label,
                                      unit_price, vat_rate, quantity, detail)
      values (v_order.id, v_prod.id, v_prod.name, v_vlabel, v_unit, v_prod.vat_rate, v_qty,
              jsonb_build_object('options', coalesce(v_item -> 'options', '[]'::jsonb)));

      v_subtotal := v_subtotal + v_unit * v_qty;

      -- ---- Cadeaux : consommés en premier, journalisés unité par unité ----
      v_gift_left := v_qty;
      v_gift_cat  := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);
      v_gift_cost := public.gift_credit_cost(v_prod.universe, v_prod.is_alcohol);

      loop
        exit when v_gift_left <= 0;

        select * into v_ent from public.gift_entitlements e
          where e.event_id = p_event
            and e.customer_id = v_cust
            and e.quantity_remaining >= (case when e.mode = 'product' then 1 else v_gift_cost end)
            and (
              (e.mode = 'product'  and e.product_id = v_prod.id)
              or (e.mode = 'category' and e.category = v_gift_cat)
            )
          order by (e.mode = 'product') desc, e.created_at
          limit 1
          -- Le décrément plus bas est relatif, donc juste sur le montant ;
          -- mais le NOMBRE d'unités à prendre se décide ici, sur ce qu'on
          -- vient de lire. Sans verrou, deux commandes peuvent se partager
          -- une unité qui n'existe qu'en un exemplaire.
          for update;

        exit when v_ent.id is null;

        v_gift_take := least(
          v_gift_left,
          v_ent.quantity_remaining / (case when v_ent.mode = 'product' then 1 else v_gift_cost end)
        );
        exit when v_gift_take <= 0;
        v_gift_covered := case
          when v_ent.max_value is null then v_unit
          else least(v_unit, v_ent.max_value)
        end;

        update public.gift_entitlements
           set quantity_remaining =
                 quantity_remaining
                 - v_gift_take * (case when v_ent.mode = 'product' then 1 else v_gift_cost end)
         where id = v_ent.id;

        insert into public.gift_redemptions
          (event_id, customer_id, promo_code_id, entitlement_id, order_id,
           product_id, product_name, unit_price, covered, paid)
        select p_event, v_cust, v_ent.promo_code_id, v_ent.id, v_order.id,
               v_prod.id,
               v_prod.name || coalesce(' (' || v_vlabel || ')', ''),
               v_unit, v_gift_covered, greatest(0, v_unit - v_gift_covered)
          from generate_series(1, v_gift_take);

        v_discount   := v_discount + v_gift_covered * v_gift_take;
        v_gift_total := v_gift_total + v_gift_covered * v_gift_take;
        v_gift_count := v_gift_count + v_gift_take;
        v_gift_left  := v_gift_left - v_gift_take;
        v_ent := null;
      end loop;

      -- ---- Forfait Noti : le portefeuille couvre ce qui reste -------------
      if v_pass.id is not null and v_gift_left > 0 then
        if v_prod.credit_once and not v_pass.richard_used then
          if v_pass.credits_remaining >= (case when v_prod.credit_kind = 'alcohol' then 2 else 1 end) then
            v_pass.credits_remaining := v_pass.credits_remaining
              - (case when v_prod.credit_kind = 'alcohol' then 2 else 1 end);
            v_pass.richard_used := true;
            v_credits_used := v_credits_used
              + (case when v_prod.credit_kind = 'alcohol' then 2 else 1 end);
            v_discount := v_discount + v_unit;
          end if;
        elsif v_prod.credit_kind in ('alcohol', 'soft') then
          declare
            v_wallet_cost  int := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
            v_wallet_units int;
          begin
            v_wallet_units := least(v_gift_left, v_pass.credits_remaining / v_wallet_cost);
            if v_wallet_units > 0 then
              v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
              v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
              v_discount := v_discount + v_wallet_units * v_unit;
            end if;
          end;
        elsif v_prod.universe = 'food' and v_pass.food_token_available then
          v_pass.food_token_available := false;
          v_food_used := true;
          v_discount := v_discount + v_unit;
        end if;
      end if;
    end loop;

    -- ---- Code promo classique, sur le premier panier seulement -----------
    -- Sans cette réserve, un panier mixte appliquerait la remise DEUX fois
    -- (une par commande) : le client paierait moins que son panier réel.
    if not v_promo_hit and p_promo is not null and length(trim(p_promo)) > 0 then
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
        update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
        v_promo_hit := true;
      end if;
    end if;

    update public.orders
       set subtotal          = v_subtotal,
           discount          = least(v_discount, v_subtotal),
           total             = greatest(0, v_subtotal - v_discount),
           credit_units_used = v_credits_used,
           food_token_used   = v_food_used,
           gift_count        = v_gift_count,
           gift_total        = v_gift_total,
           promo_code        = case when v_promo_hit and v_promo.id is not null
                                    then upper(trim(p_promo)) else null end
     where id = v_order.id
     returning * into v_order;

    return next v_order;
  end loop;

  -- Le forfait n'est écrit qu'une fois, après les deux paniers : les
  -- décomptes intermédiaires vivent dans v_pass en mémoire.
  if v_pass.id is not null then
    update public.event_passes
       set credits_remaining    = v_pass.credits_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.customers set last_seen_at = now() where id = v_cust;
end;
$$;

grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;

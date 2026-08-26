-- ============================================================================
--  0037 — Flux food, annulation client, prise en charge
--
--  Note technique du 23/08. Trois besoins distincts, une seule migration parce
--  qu'ils touchent tous au cycle de vie de la commande.
--
--  ⚠️  À exécuter APRÈS 0036, dans un Run séparé (nouvelle valeur d'enum).
--
--  ---------------------------------------------------------------------
--  §2 — FOOD : LE CHRONO NE DÉMARRE QU'APRÈS ENCAISSEMENT
--
--  Arbitrage retenu (§7, option A) : les boissons partent en préparation
--  immédiatement, seule la food attend le règlement.
--
--  Conséquence de structure : un panier mixte est SCINDÉ EN DEUX commandes.
--  Le statut vit sur la commande, pas sur la ligne — une commande unique ne
--  peut pas être à la fois « en préparation » pour le verre et « en attente
--  de règlement » pour l'assiette. Deux commandes, deux codes de retrait,
--  deux retraits : c'est exactement ce que décrit l'option A.
--
--  place_order() renvoie donc PLUSIEURS lignes (`setof`). Changement de type
--  de retour, d'où le drop explicite : `create or replace` refuse.
--
--  ---------------------------------------------------------------------
--  §2bis.2 — ANNULATION CLIENT, ET LA COURSE À ARBITRER
--
--  « Le client annule au moment exact où le staff passe la commande en
--  préparation. Il faut un arbitrage serveur strict : le premier des deux
--  événements l'emporte. »
--
--  C'est le point délicat. Un `select` du statut suivi d'un `update` laisse
--  une fenêtre entre les deux : deux sessions peuvent lire « RECEIVED » puis
--  écrire chacune leur statut. L'arbitrage est donc porté par l'UPDATE
--  lui-même — `where status = 'RECEIVED'` — qui verrouille la ligne et ne
--  touche rien si le statut a déjà bougé. Le perdant l'apprend par
--  `not found`, jamais par une lecture périmée.
--
--  ---------------------------------------------------------------------
--  §1.5 — PRISE EN CHARGE (ANTI-COLLISION)
--
--  « Risque que deux personnes préparent la même commande sans le savoir. »
--  Même logique : la prise en charge est un UPDATE conditionnel, pas un
--  drapeau posé après lecture.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  1. Prise en charge : qui s'occupe de quoi.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists claimed_by uuid references auth.users (id) on delete set null,
  add column if not exists claimed_at timestamptz;

comment on column public.orders.claimed_by is
  'Opérateur qui s''est attribué la commande au bar. Évite que deux personnes '
  'préparent le même ticket.';

create index if not exists orders_claimed_idx on public.orders (event_id, claimed_by);


-- ---------------------------------------------------------------------------
--  2. Création d'une commande : un code de retrait garanti, même en rafale.
--
--  RÉVÉLÉ PAR LE TEST DE CHARGE (§5 de la note, « perte de commande : zéro
--  tolérance »). L'ancien code faisait :
--
--      loop
--        v_code := gen_pickup_code();
--        exit when not exists (select 1 from orders where pickup_code = v_code);
--      end loop;
--      insert into orders ... values (..., v_code, ...);
--
--  Entre le contrôle et l'écriture, rien ne réserve le code. Deux commandes
--  simultanées peuvent tirer le même : aucune des deux ne voit la ligne de
--  l'autre, non encore validée. La première passe, la seconde heurte l'index
--  unique — et comme rien ne rattrape l'erreur, LA COMMANDE EST PERDUE, avec
--  un message incompréhensible pour le client.
--
--  Ce n'est pas théorique. Le code fait 2 lettres + 2 chiffres, soit 57 600
--  combinaisons : sur une soirée à 300 commandes, le paradoxe des
--  anniversaires donne ~54 % de risque qu'au moins deux se télescopent. La
--  collision a été reproduite en forçant deux transactions sur le même code :
--  une commande créée, une perdue.
--
--  Correction : c'est l'INSERT qui arbitre. En cas de collision on retire un
--  code et on retente, et au-delà de quelques essais on allonge le code d'un
--  chiffre — l'espace grandit alors plus vite que la salle ne se remplit.
-- ---------------------------------------------------------------------------
create or replace function public.insert_order_with_code(
  p_event      uuid,
  p_customer   uuid,
  p_scan_point uuid,
  p_status     public.order_status,
  p_note       text,
  p_eta        timestamptz
)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
  v_code  text;
  i       int;
begin
  for i in 1 .. 25 loop
    v_code := public.gen_pickup_code();
    -- Passé une douzaine d'échecs, la soirée est manifestement dense : on
    -- ajoute un chiffre plutôt que de s'acharner sur un espace saturé.
    if i > 12 then v_code := v_code || floor(random() * 10)::text; end if;

    begin
      insert into public.orders (event_id, customer_id, scan_point_id, pickup_code,
                                 status, note, estimated_ready_at)
      values (p_event, p_customer, p_scan_point, v_code, p_status, p_note, p_eta)
      returning * into v_order;
      return v_order;
    exception when unique_violation then
      -- Quelqu'un a pris ce code entre-temps : on en tire un autre.
      null;
    end;
  end loop;

  raise exception 'pickup_code_exhausted';
end;
$$;

comment on function public.insert_order_with_code(uuid, uuid, uuid, public.order_status, text, timestamptz) is
  'Crée la commande en réservant son code de retrait par l''écriture '
  'elle-même. Un contrôle préalable ne protège de rien : deux commandes '
  'simultanées ne voient pas la ligne l''une de l''autre.';


-- ---------------------------------------------------------------------------
--  3. place_order() : scinde le panier mixte, et ne démarre pas le chrono
--     d'une commande food.
--
--  Repris de 0024, avec deux changements de fond :
--    · les articles sont répartis en deux paniers (food / non-food) ;
--    · chaque panier donne une commande, la food naissant en
--      'AWAITING_PAYMENT' sans `estimated_ready_at`.
--
--  Le reste — cadeaux, forfait, code promo — est inchangé et s'applique
--  panier par panier, dans l'ordre : boissons d'abord, food ensuite. Les
--  crédits se consomment donc en priorité sur les boissons, ce qui est le
--  comportement attendu (le jeton food a sa propre mécanique).
-- ---------------------------------------------------------------------------
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
  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;

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
          limit 1;

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

revoke all on function public.place_order(uuid, uuid, jsonb, text, text) from public;
grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;


-- ---------------------------------------------------------------------------
--  3. Encaissement d'une commande food : le chrono démarre ICI.
-- ---------------------------------------------------------------------------
create or replace function public.start_food_prep(p_order uuid)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
  v_prep  int;
begin
  select o.* into v_order from public.orders o where o.id = p_order;
  if v_order.id is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_order.event_id) then raise exception 'forbidden'; end if;

  select default_prep_min into v_prep from public.events where id = v_order.event_id;

  -- Conditionné au statut : deux encaissements simultanés ne redémarrent pas
  -- le chrono deux fois.
  update public.orders
     set status = 'RECEIVED',
         estimated_ready_at = now() + make_interval(mins => coalesce(v_prep, 1))
   where id = p_order and status = 'AWAITING_PAYMENT'
   returning * into v_order;

  if v_order.id is null then raise exception 'not_awaiting_payment'; end if;
  return v_order;
end;
$$;

grant execute on function public.start_food_prep(uuid) to authenticated;


-- ---------------------------------------------------------------------------
--  4. Annulation par le client, avec arbitrage de la course.
--
--  L'UPDATE conditionnel EST l'arbitrage : il verrouille la ligne et ne
--  modifie rien si le staff a déjà lancé la préparation. Le client reçoit
--  alors `already_in_prep`, jamais un succès trompeur.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_my_order(p_order uuid)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_order public.orders;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select o.* into v_order from public.orders o
   where o.id = p_order and o.customer_id = v_cust;
  if v_order.id is null then raise exception 'unknown_order'; end if;

  if v_order.status = 'CANCELLED' then
    return v_order;  -- déjà annulée : un second tap ne doit pas échouer
  end if;

  update public.orders
     set status = 'CANCELLED'
   where id = p_order
     and customer_id = v_cust
     and status in ('RECEIVED', 'AWAITING_PAYMENT')
   returning * into v_order;

  if v_order.id is null then raise exception 'already_in_prep'; end if;

  -- Les crédits et cadeaux consommés sont rendus : la commande n'a jamais été
  -- préparée, il n'y a aucune raison de les retenir.
  update public.event_passes p
     set credits_remaining = least(
           p.credits_total,
           p.credits_remaining + coalesce((select o.credit_units_used from public.orders o where o.id = p_order), 0)
         ),
         food_token_available = p.food_token_available
           or coalesce((select o.food_token_used from public.orders o where o.id = p_order), false)
   where p.event_id = v_order.event_id and p.customer_id = v_cust;

  update public.gift_entitlements e
     set quantity_remaining = least(
           e.quantity_total,
           e.quantity_remaining + sub.rendus
         )
    from (
      select entitlement_id, count(*) as rendus
        from public.gift_redemptions
       where order_id = p_order and entitlement_id is not null
       group by entitlement_id
    ) sub
   where e.id = sub.entitlement_id;

  delete from public.gift_redemptions where order_id = p_order;

  return v_order;
end;
$$;

grant execute on function public.cancel_my_order(uuid) to authenticated;

comment on function public.cancel_my_order(uuid) is
  'Annulation par le client, possible tant que la commande n''est pas en '
  'préparation. L''UPDATE conditionnel arbitre la course avec le staff : le '
  'premier des deux événements l''emporte, le second reçoit already_in_prep.';


-- ---------------------------------------------------------------------------
--  5. Prise en charge / libération, par le même arbitrage conditionnel.
-- ---------------------------------------------------------------------------
create or replace function public.claim_order(p_order uuid)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
begin
  select o.* into v_order from public.orders o where o.id = p_order;
  if v_order.id is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_order.event_id) then raise exception 'forbidden'; end if;

  -- `claimed_by is null or claimed_by = auth.uid()` : reprendre sa propre
  -- commande est sans effet, prendre celle d'un collègue est refusé.
  update public.orders
     set claimed_by = auth.uid(), claimed_at = now()
   where id = p_order
     and (claimed_by is null or claimed_by = auth.uid())
   returning * into v_order;

  if v_order.id is null then raise exception 'already_claimed'; end if;
  return v_order;
end;
$$;

create or replace function public.release_order(p_order uuid)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
begin
  select o.* into v_order from public.orders o where o.id = p_order;
  if v_order.id is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_order.event_id) then raise exception 'forbidden'; end if;

  -- Tout membre de l'équipe peut libérer : si quelqu'un pose sa tablette ou
  -- quitte son poste, sa prise en charge ne doit pas bloquer le ticket.
  update public.orders
     set claimed_by = null, claimed_at = null
   where id = p_order
   returning * into v_order;

  return v_order;
end;
$$;

grant execute on function public.claim_order(uuid)   to authenticated;
grant execute on function public.release_order(uuid) to authenticated;

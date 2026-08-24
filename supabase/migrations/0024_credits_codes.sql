-- ============================================================================
--  0024 — Les codes cadeaux parlent en CRÉDITS, et se limitent deux fois
--
--  Retour terrain, bloc 2 :
--
--  · « Notre modèle est un modèle de crédits / tokens, pas d'euros. Parler en
--    euros crée de la confusion côté client. » → la valeur en euros reste une
--    règle interne, visible du staff, jamais affichée au client.
--
--  · « Si on raisonne en crédits, on n'a plus besoin de distinguer alcoolisé
--    et soft à la création du code — la règle de conversion s'en charge. »
--    → trois cases seulement : Boisson · Food · Bouteille.
--    Barème inchangé : 1 crédit = 1 soft · 2 crédits = 1 conso alcoolisée.
--
--  · « Double limitation : diffusion ET utilisation. » Ce sont deux choses :
--      max_uses        = combien de PERSONNES peuvent activer le code ;
--      uses_per_person = combien de fois CHACUNE peut l'activer.
--    La 16ᵉ personne d'un code prévu pour 15 est refusée, même si le code est
--    par ailleurs valide.
--
--  Idempotent : rejouable sans dommage (voir setup.sql).
-- ============================================================================


-- ============================================================================
--  1. LES DROITS SE COMPTENT EN CRÉDITS
--
--  Les colonnes quantity_* de 0021 comptaient des ARTICLES ; elles comptent
--  maintenant des CRÉDITS. Elles gardent leur nom volontairement : 0021 les
--  référence dans my_gift_summary et place_order, et les renommer ferait
--  échouer tout rejeu de 0021 — y compris celui de setup.sql. Le commentaire
--  ci-dessous porte le sens, à défaut du nom.
-- ============================================================================
comment on column public.gift_entitlements.quantity_remaining is
  'CRÉDITS restants (le nom est historique). Barème : 1 soft = 1 crédit, '
  '1 conso alcoolisée = 2 crédits. En mode article précis, 1 crédit = 1 article.';

comment on column public.gift_entitlements.quantity_total is
  'CRÉDITS accordés au départ (le nom est historique).';


-- ============================================================================
--  2. TROIS CATÉGORIES AU LIEU DE QUATRE
--
--  « alcohol » et « soft » fusionnent en « drink » : à la création du code on
--  ne choisit plus le type de boisson, on donne des crédits et la conversion
--  s'applique au moment de la commande.
--
--  Les droits déjà accordés sont convertis au barème pour ne rien perdre :
--  un droit à 1 article alcoolisé valait 2 crédits, 1 soft en valait 1.
-- ============================================================================
do $$
begin
  -- Un seul passage : une fois la catégorie 'alcohol' disparue, il n'y a plus
  -- rien à convertir et rejouer ne doublerait pas les crédits.
  if exists (select 1 from public.gift_entitlements where category = 'alcohol') then
    update public.gift_entitlements
       set quantity_total     = quantity_total * 2,
           quantity_remaining = quantity_remaining * 2,
           category          = 'drink'
     where category = 'alcohol';
  end if;

  update public.gift_entitlements set category = 'drink' where category = 'soft';
end $$;

-- Les codes non encore activés portent la définition dans promo_codes.gift_items.
update public.promo_codes
   set gift_items = (
     select jsonb_agg(
       case
         when item ->> 'category' in ('alcohol', 'soft') then
           item
             || jsonb_build_object('category', 'drink')
             -- Un article alcoolisé valait 2 crédits, un soft 1.
             || jsonb_build_object(
                  'quantity',
                  coalesce((item ->> 'quantity')::int, 1)
                    * case when item ->> 'category' = 'alcohol' then 2 else 1 end
                )
         else item
       end
     )
     from jsonb_array_elements(gift_items) as item
   )
 where kind = 'gift'
   and (gift_items @> '[{"category": "alcohol"}]'::jsonb
        or gift_items @> '[{"category": "soft"}]'::jsonb);

-- La catégorie d'un article, au sens des cadeaux : trois valeurs désormais.
create or replace function public.gift_category_of(
  p_universe public.universe,
  p_is_alcohol boolean
)
returns text
language sql immutable
as $$
  select case
    when p_universe = 'food'    then 'food'
    when p_universe = 'bottles' then 'bottle'
    else 'drink'
  end;
$$;

-- Ce que coûte UNE unité de cet article, en crédits. C'est ici, et nulle part
-- ailleurs, que vit le barème 2 / 1.
create or replace function public.gift_credit_cost(
  p_universe public.universe,
  p_is_alcohol boolean
)
returns int
language sql immutable
as $$
  select case
    when p_universe = 'drinks' and p_is_alcohol then 2
    else 1
  end;
$$;

grant execute on function public.gift_category_of(public.universe, boolean) to authenticated;
grant execute on function public.gift_credit_cost(public.universe, boolean) to authenticated;


-- ============================================================================
--  3. DOUBLE LIMITATION
-- ============================================================================
alter table public.promo_codes
  add column if not exists uses_per_person int not null default 1;

comment on column public.promo_codes.max_uses is
  'Diffusion : nombre maximum de PERSONNES pouvant activer ce code. null = illimité.';
comment on column public.promo_codes.uses_per_person is
  'Utilisation : nombre d''activations autorisées par personne. 1 par défaut.';

alter table public.promo_redemptions
  add column if not exists uses int not null default 1;

comment on column public.promo_redemptions.uses is
  'Nombre de fois que cette personne a activé ce code (borné par uses_per_person).';


-- ============================================================================
--  4. ACTIVATION D'UN CODE CADEAU
--
--  uses_count compte les PERSONNES, pas les activations : il n'est incrémenté
--  qu'au premier passage d'une personne donnée. Une seconde activation par la
--  même personne consomme son quota individuel, pas une place du groupe.
-- ============================================================================
create or replace function public.redeem_gift_code(p_event uuid, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_red   public.promo_redemptions;
  v_item  jsonb;
  v_qty   int;
  v_lines int := 0;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event
      and upper(code) = upper(trim(p_code))
      and active
      and kind = 'gift'
      and (starts_at is null or starts_at <= now())
      and (ends_at   is null or ends_at   >= now());
  if v_promo.id is null then raise exception 'invalid_gift_code'; end if;

  select * into v_red from public.promo_redemptions
   where promo_code_id = v_promo.id and customer_id = v_cust;

  if v_red.promo_code_id is not null then
    -- Quota individuel épuisé : on renvoie l'état sans rien recréditer. Pas
    -- une erreur — ressaisir son code pour revoir ses crédits est un réflexe.
    if v_red.uses >= greatest(1, coalesce(v_promo.uses_per_person, 1)) then
      return jsonb_build_object(
        'already', true,
        'code', v_promo.code,
        'label', v_promo.label,
        'items', public.my_gift_summary(p_event)
      );
    end if;

    update public.promo_redemptions
       set uses = uses + 1
     where promo_code_id = v_promo.id and customer_id = v_cust;
  else
    -- Première activation de CETTE personne : elle prend une place du groupe.
    -- L'incrément sert de garde atomique — deux personnes ne peuvent pas
    -- prendre la même dernière place.
    update public.promo_codes
       set uses_count = uses_count + 1
     where id = v_promo.id
       and (max_uses is null or uses_count < max_uses);
    if not found then raise exception 'code_exhausted'; end if;

    insert into public.promo_redemptions (promo_code_id, customer_id, event_id, credits_granted, uses)
    values (v_promo.id, v_cust, p_event, 0, 1);
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(v_promo.gift_items, '[]'::jsonb)) loop
    -- « quantity » porte désormais un nombre de CRÉDITS en mode catégorie, et
    -- un nombre d'articles en mode article précis (1 crédit = 1 article).
    v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

    insert into public.gift_entitlements
      (event_id, customer_id, promo_code_id, mode, category, product_id,
       max_value, quantity_total, quantity_remaining)
    values (
      p_event, v_cust, v_promo.id,
      coalesce(v_item ->> 'mode', 'category'),
      nullif(v_item ->> 'category', ''),
      nullif(v_item ->> 'product_id', '')::uuid,
      nullif(v_item ->> 'max_value', '')::numeric,
      v_qty, v_qty
    );
    v_lines := v_lines + 1;
  end loop;

  return jsonb_build_object(
    'already', false,
    'code', v_promo.code,
    'label', v_promo.label,
    'lines', v_lines,
    'items', public.my_gift_summary(p_event)
  );
end
$$;

grant execute on function public.redeem_gift_code(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
--  Résumé côté client. Le plafond en euros n'y figure plus : le client ne
--  raisonne qu'en crédits (le plafond reste une règle interne, appliquée à la
--  commande et visible du staff).
-- ---------------------------------------------------------------------------
create or replace function public.my_gift_summary(p_event uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'mode', e.mode,
           'category', e.category,
           'product_id', e.product_id,
           'product_name', p.name,
           'remaining', e.quantity_remaining,
           'total', e.quantity_total
         ) order by e.created_at), '[]'::jsonb)
  from public.gift_entitlements e
  left join public.products p on p.id = e.product_id
  where e.event_id = p_event
    and e.customer_id = public.my_customer_id()
    and e.quantity_remaining > 0;
$$;

grant execute on function public.my_gift_summary(uuid) to authenticated;


-- ---------------------------------------------------------------------------
--  Récapitulatif d'un code pour l'écran staff : « ce code permet à 15
--  personnes maximum d'obtenir 2 crédits boisson, une fois chacune ».
--  Calculé côté base pour que le staff lise exactement ce que le serveur
--  appliquera, et pas une reformulation de l'interface.
-- ---------------------------------------------------------------------------
create or replace function public.promo_reach(p_promo uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'code', c.code,
    'label', c.label,
    'max_uses', c.max_uses,
    'uses_count', c.uses_count,
    'uses_per_person', greatest(1, coalesce(c.uses_per_person, 1)),
    'people_left', case when c.max_uses is null then null
                        else greatest(0, c.max_uses - c.uses_count) end,
    'credits_per_person', coalesce((
      select jsonb_object_agg(cat, total)
      from (
        select coalesce(item ->> 'category', 'drink') as cat,
               sum(greatest(1, coalesce((item ->> 'quantity')::int, 1)))::int as total
        from jsonb_array_elements(coalesce(c.gift_items, '[]'::jsonb)) as item
        where coalesce(item ->> 'mode', 'category') = 'category'
        group by 1
      ) g
    ), '{}'::jsonb),
    'products_per_person', coalesce((
      select jsonb_agg(jsonb_build_object(
               'product_id', item ->> 'product_id',
               'quantity', greatest(1, coalesce((item ->> 'quantity')::int, 1))))
      from jsonb_array_elements(coalesce(c.gift_items, '[]'::jsonb)) as item
      where item ->> 'mode' = 'product'
    ), '[]'::jsonb)
  )
  from public.promo_codes c
  where c.id = p_promo
    and public.is_event_staff(c.event_id);
$$;

grant execute on function public.promo_reach(uuid) to authenticated;


-- ============================================================================
--  5. place_order() — les cadeaux se consomment au barème
--
--  Version de 0021, à une seule différence près : la boucle « CADEAUX ». Un
--  droit porte des CRÉDITS, et chaque unité commandée en coûte 2 (conso
--  alcoolisée) ou 1 (soft, food, bouteille, article précis). Tout le reste —
--  code de retrait, forfait, jeton food, code promo, horodatage — est
--  identique, volontairement : on ne réécrit pas une logique d'encaissement
--  pour changer un barème.
-- ============================================================================
create or replace function public.place_order(
  p_event      uuid,
  p_scan_point uuid,
  p_items      jsonb,
  p_note       text default null,
  p_promo      text default null
)
returns public.orders
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust     uuid := public.my_customer_id();
  v_order    public.orders;
  v_item     jsonb;
  v_prod     public.products;
  v_qty      int;
  v_unit     numeric(10,2);
  v_variant  jsonb;
  v_vlabel   text;
  v_opt      jsonb;
  v_subtotal numeric(10,2) := 0;
  v_discount numeric(10,2) := 0;
  v_promo    public.promo_codes;
  v_prep     int;
  v_code     text;
  v_tries    int := 0;
  v_pass         public.event_passes;
  v_wallet_cost  int;
  v_wallet_units int;
  v_credits_used int := 0;
  v_food_used    boolean := false;
  v_ent          public.gift_entitlements;
  v_gift_cat     text;
  v_gift_cost    int;
  v_gift_left    int;
  v_gift_take    int;
  v_gift_covered numeric(10,2);
  v_gift_count   int := 0;
  v_gift_total   numeric(10,2) := 0;
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

  -- Code de retrait unique sur l'événement
  loop
    v_code := public.gen_pickup_code();
    exit when not exists (
      select 1 from public.orders where event_id = p_event and pickup_code = v_code
    );
    v_tries := v_tries + 1;
    if v_tries > 40 then
      v_code := v_code || floor(random() * 10)::text;
      exit;
    end if;
  end loop;

  insert into public.orders (event_id, customer_id, scan_point_id, pickup_code, status,
                             note, estimated_ready_at)
  values (p_event, v_cust, p_scan_point, v_code, 'RECEIVED',
          nullif(trim(p_note), ''), now() + make_interval(mins => coalesce(v_prep, 1)))
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_prod from public.products
      where id = (v_item ->> 'product_id')::uuid and is_listed and not sold_out;
    if v_prod.id is null then raise exception 'product_unavailable'; end if;

    v_qty := greatest(1, least(50, coalesce((v_item ->> 'quantity')::int, 1)));

    -- Format (12cl / 75cl / 150cl…) : prix pris dans le variant si fourni
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

    -- Options : le prix est relu dans option_groups, jamais pris du client
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

    -- ------------------------------------------------------------------
    --  CADEAUX : consommés en premier, et journalisés unité par unité.
    -- ------------------------------------------------------------------
    v_gift_left := v_qty;
    v_gift_cat  := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);
    -- Barème : une conso alcoolisée coûte 2 crédits, tout le reste 1. En mode
    -- article précis, le promoteur a déjà choisi l'article : 1 crédit = 1 unité.
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

      -- Une ligne de journal par unité offerte : c'est ce qui permet d'écrire
      -- « a utilisé son cadeau à 23h14 pour un Spritz » dans la fiche client.
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

    -- ---- Forfait Noti : le portefeuille ne couvre que ce qui reste -------
    if v_pass.id is not null and v_gift_left > 0 then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining >= v_wallet_cost then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_credits_used := v_credits_used + v_wallet_cost;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_gift_left, v_pass.credits_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
          v_credits_used := v_credits_used + v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_food_used := true;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable
  if p_promo is not null and length(trim(p_promo)) > 0 then
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
    end if;
  end if;

  if v_pass.id is not null then
    update public.event_passes
       set credits_remaining   = v_pass.credits_remaining,
           food_token_available = v_pass.food_token_available,
           richard_used         = v_pass.richard_used
     where id = v_pass.id;
  end if;

  update public.orders
     set subtotal          = v_subtotal,
         discount          = least(v_discount, v_subtotal),
         total             = greatest(0, v_subtotal - v_discount),
         credit_units_used = v_credits_used,
         food_token_used   = v_food_used,
         gift_count        = v_gift_count,
         gift_total        = v_gift_total,
         promo_code        = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;


-- ============================================================================
--  6. ANNULATION : les crédits cadeaux reviennent, au même barème
-- ============================================================================
create or replace function public.refund_credits_on_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_r record;
begin
  if new.status = 'CANCELLED' and old.status is distinct from 'CANCELLED' then

    -- Crédits de forfait et jeton food (comportement de 0020)
    if coalesce(old.credit_units_used, 0) > 0 or coalesce(old.food_token_used, false) then
      update public.event_passes
         set credits_remaining = least(credits_total,
                                       credits_remaining + coalesce(old.credit_units_used, 0)),
             food_token_available = food_token_available or coalesce(old.food_token_used, false)
       where event_id = new.event_id and customer_id = new.customer_id;

      new.credit_units_used := 0;
      new.food_token_used   := false;
    end if;

    -- Cadeaux : on rend chaque unité à son droit d'origine, puis on efface
    -- les lignes de journal — la commande annulée n'a rien consommé.
    if coalesce(old.gift_count, 0) > 0 then
      -- On rend exactement ce que chaque unité avait coûté : 2 crédits pour
      -- une conso alcoolisée, 1 sinon. D'où la jointure sur le produit.
      for v_r in
        select gr.entitlement_id, ge.mode, p.universe, p.is_alcohol, count(*)::int as n
          from public.gift_redemptions gr
          join public.gift_entitlements ge on ge.id = gr.entitlement_id
          left join public.products p on p.id = gr.product_id
         where gr.order_id = new.id and gr.entitlement_id is not null
         group by gr.entitlement_id, ge.mode, p.universe, p.is_alcohol
      loop
        update public.gift_entitlements
           set quantity_remaining = least(
                 quantity_total,
                 quantity_remaining + v_r.n * (case
                   when v_r.mode = 'product'  then 1
                   when v_r.universe is null  then 1
                   else public.gift_credit_cost(v_r.universe, v_r.is_alcohol)
                 end))
         where id = v_r.entitlement_id;
      end loop;

      delete from public.gift_redemptions where order_id = new.id;

      new.gift_count := 0;
      new.gift_total := 0;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_orders_credit_refund on public.orders;
create trigger trg_orders_credit_refund
  before update on public.orders
  for each row execute function public.refund_credits_on_cancel();

-- ============================================================================
--  NOTI Calling — 0021_codes_cadeaux.sql
--
--  CODES « ARTICLE OFFERT »
--
--  Jusqu'ici un code promo ne savait faire que trois choses : une remise en
--  pourcentage, une remise en montant, ou créditer un forfait de groupe en
--  crédits abstraits. Il manquait le cas le plus courant côté promoteur :
--  « je crée un code SOIREENOTI1, valable pour 6 personnes, qui donne UNE
--  BOISSON ALCOOLISÉE OFFERTE ».
--
--  Ce patch ajoute ce quatrième type. Un code cadeau porte une ou plusieurs
--  lignes, chacune définissant ce qui est offert :
--
--    · par CATÉGORIE — « 1 boisson alcoolisée au choix, jusqu'à 15 € »
--      Le client prend l'article qu'il veut dans la catégorie ; au-delà du
--      plafond il règle la différence au bar.
--    · par ARTICLE PRÉCIS — « 1 Spritz »
--      Le client n'a pas le choix, le promoteur maîtrise exactement le coût.
--
--  Et surtout : chaque cadeau consommé est JOURNALISÉ précisément — quel
--  article exact, à quelle heure, pour quel montant couvert, sur quelle
--  commande. C'est ce qui alimente la fiche client côté administrateur et
--  l'alerte affichée au bar.
--
--  Le modèle de crédits des forfaits (0013) n'est pas touché : les deux
--  coexistent, un client peut avoir un forfait ET un cadeau.
--
--  Patch cumulatif : s'exécute sur une installation neuve comme sur une base
--  déjà en service. Nécessite 0013 et 0020.
-- ============================================================================


-- ============================================================================
--  1. DÉFINITION DU CADEAU, PORTÉE PAR LE CODE PROMO
-- ============================================================================

-- gift_items : tableau JSON décrivant ce que le code offre à CHAQUE personne.
--   [{"mode":"category","category":"alcohol","quantity":1,"max_value":15},
--    {"mode":"product","product_id":"<uuid>","quantity":1}]
--
--   mode      : 'category' (au choix dans la catégorie) | 'product' (article précis)
--   category  : 'alcohol' | 'soft' | 'food' | 'bottle'
--   quantity  : nombre d'articles offerts par personne
--   max_value : plafond en € (mode 'category' uniquement ; null = sans plafond)
alter table public.promo_codes
  add column if not exists gift_items jsonb not null default '[]'::jsonb;

comment on column public.promo_codes.gift_items is
  'Lignes de cadeau d''un code kind=''gift''. Voir 0021_codes_cadeaux.sql.';


-- ============================================================================
--  2. DROITS ACQUIS PAR LE CLIENT (ce qu''il lui reste à consommer)
-- ============================================================================
create table if not exists public.gift_entitlements (
  id                 uuid primary key default gen_random_uuid(),
  event_id           uuid not null references public.events (id)      on delete cascade,
  customer_id        uuid not null references public.customers (id)   on delete cascade,
  promo_code_id      uuid not null references public.promo_codes (id) on delete cascade,
  mode               text not null,                    -- 'category' | 'product'
  category           text,                             -- si mode = 'category'
  product_id         uuid references public.products (id) on delete set null,
  max_value          numeric(10, 2),                   -- plafond € (mode category)
  quantity_total     int not null default 1,
  quantity_remaining int not null default 1,
  created_at         timestamptz not null default now()
);

create index if not exists gift_entitlements_lookup_idx
  on public.gift_entitlements (event_id, customer_id, quantity_remaining);

alter table public.gift_entitlements enable row level security;

drop policy if exists gift_entitlements_read on public.gift_entitlements;
create policy gift_entitlements_read on public.gift_entitlements
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));


-- ============================================================================
--  3. JOURNAL DES CADEAUX CONSOMMÉS
--
--  Le cœur de la demande : « a utilisé son crédit à 23h14 pour un Spritz ».
--  On garde un instantané du nom et du prix, pour que la ligne reste lisible
--  même si l'article est ensuite renommé ou retiré de la carte.
-- ============================================================================
create table if not exists public.gift_redemptions (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events (id)          on delete cascade,
  customer_id    uuid not null references public.customers (id)       on delete cascade,
  promo_code_id  uuid references public.promo_codes (id)              on delete set null,
  entitlement_id uuid references public.gift_entitlements (id)        on delete set null,
  order_id       uuid references public.orders (id)                   on delete cascade,
  product_id     uuid references public.products (id)                 on delete set null,
  product_name   text not null default '',
  unit_price     numeric(10, 2) not null default 0,   -- prix carte de l'article
  covered        numeric(10, 2) not null default 0,   -- part offerte
  paid           numeric(10, 2) not null default 0,   -- reste à charge (dépassement)
  redeemed_at    timestamptz not null default now()
);

create index if not exists gift_redemptions_customer_idx
  on public.gift_redemptions (customer_id, redeemed_at desc);
create index if not exists gift_redemptions_event_idx
  on public.gift_redemptions (event_id, redeemed_at desc);
create index if not exists gift_redemptions_order_idx
  on public.gift_redemptions (order_id);

alter table public.gift_redemptions enable row level security;

drop policy if exists gift_redemptions_read on public.gift_redemptions;
create policy gift_redemptions_read on public.gift_redemptions
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- Marqueur sur la commande : le bar doit voir d'un coup d'œil qu'elle porte
-- un cadeau. Dénormalisé pour que le tableau du bar n'ait pas de requête en
-- plus, et pour que le temps réel déjà en place sur `orders` le propage.
alter table public.orders
  add column if not exists gift_count int not null default 0,
  add column if not exists gift_total numeric(10, 2) not null default 0;


-- ============================================================================
--  4. CATÉGORIE D'UN ARTICLE, AU SENS DES CADEAUX
-- ============================================================================
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
    when p_is_alcohol           then 'alcohol'
    else 'soft'
  end;
$$;

grant execute on function public.gift_category_of(public.universe, boolean) to authenticated;


-- ============================================================================
--  5. ACTIVATION D'UN CODE CADEAU
--
--  Idempotente par personne : promo_redemptions (unique sur code+client) sert
--  de garde. L'incrément de uses_count sert de garde atomique sur max_uses —
--  deux personnes ne peuvent pas prendre la même dernière place.
-- ============================================================================
create or replace function public.redeem_gift_code(p_event uuid, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
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

  -- Déjà activé par cette personne : on renvoie l'état, sans rien recréditer
  -- ni consommer d'utilisation.
  if exists (select 1 from public.promo_redemptions
              where promo_code_id = v_promo.id and customer_id = v_cust) then
    return jsonb_build_object(
      'already', true,
      'code', v_promo.code,
      'label', v_promo.label,
      'items', public.my_gift_summary(p_event)
    );
  end if;

  update public.promo_codes
     set uses_count = uses_count + 1
   where id = v_promo.id
     and (max_uses is null or uses_count < max_uses);
  if not found then raise exception 'code_exhausted'; end if;

  for v_item in select * from jsonb_array_elements(coalesce(v_promo.gift_items, '[]'::jsonb)) loop
    v_qty := greatest(1, least(20, coalesce((v_item ->> 'quantity')::int, 1)));

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

  insert into public.promo_redemptions (promo_code_id, customer_id, event_id, credits_granted)
  values (v_promo.id, v_cust, p_event, 0)
  on conflict (promo_code_id, customer_id) do nothing;

  return jsonb_build_object(
    'already', false,
    'code', v_promo.code,
    'label', v_promo.label,
    'lines', v_lines,
    'items', public.my_gift_summary(p_event)
  );
end;
$$;

-- ---------------------------------------------------------------------------
--  Résumé lisible des cadeaux qu'il reste au client sur la soirée — affiché
--  sur sa carte (« 1 boisson alcoolisée offerte »).
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
           'max_value', e.max_value,
           'remaining', e.quantity_remaining,
           'total', e.quantity_total
         ) order by e.created_at), '[]'::jsonb)
  from public.gift_entitlements e
  left join public.products p on p.id = e.product_id
  where e.event_id = p_event
    and e.customer_id = public.my_customer_id()
    and e.quantity_remaining > 0;
$$;

grant execute on function public.redeem_gift_code(uuid, text) to authenticated;
grant execute on function public.my_gift_summary(uuid)         to authenticated;


-- ============================================================================
--  6. place_order() — reprise de la version 0020, avec la consommation des
--     cadeaux AVANT les crédits de forfait.
--
--     Pour chaque ligne du panier, on cherche un droit acquis qui couvre
--     l'article — le cadeau sur article précis primant sur le cadeau par
--     catégorie, car c'est le plus spécifique. Chaque unité couverte donne
--     une ligne dans gift_redemptions : article exact, prix carte, part
--     offerte, reste à charge, horodatage.
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
    v_gift_cat := public.gift_category_of(v_prod.universe, v_prod.is_alcohol);

    loop
      exit when v_gift_left <= 0;

      select * into v_ent from public.gift_entitlements e
        where e.event_id = p_event
          and e.customer_id = v_cust
          and e.quantity_remaining > 0
          and (
            (e.mode = 'product'  and e.product_id = v_prod.id)
            or (e.mode = 'category' and e.category = v_gift_cat)
          )
        order by (e.mode = 'product') desc, e.created_at
        limit 1;

      exit when v_ent.id is null;

      v_gift_take := least(v_gift_left, v_ent.quantity_remaining);
      v_gift_covered := case
        when v_ent.max_value is null then v_unit
        else least(v_unit, v_ent.max_value)
      end;

      update public.gift_entitlements
         set quantity_remaining = quantity_remaining - v_gift_take
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
       set credits_remaining    = v_pass.credits_remaining,
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
--  7. ANNULATION : les cadeaux consommés sont rendus
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
      for v_r in
        select entitlement_id, count(*)::int as n
          from public.gift_redemptions
         where order_id = new.id and entitlement_id is not null
         group by entitlement_id
      loop
        update public.gift_entitlements
           set quantity_remaining = least(quantity_total, quantity_remaining + v_r.n)
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


-- ============================================================================
--  8. FICHE CLIENT ADMINISTRATEUR — TOUT CE QUI A ÉTÉ COLLECTÉ
--
--  Une seule fonction qui rassemble l'ensemble des informations d'un client :
--  identité, consentements, statistiques, présence sur la soirée en cours,
--  forfait, cadeaux reçus et consommés (horodatés, article par article),
--  codes activés, commandes et signalements de l'équipe.
-- ============================================================================
create or replace function public.customer_dossier(p_customer uuid, p_event uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
begin
  -- Le staff ne voit que les clients passés sur SES événements.
  if not exists (
    select 1 from public.attendances a
    join public.events e on e.id = a.event_id
    where a.customer_id = p_customer and public.is_staff(e.venue_id)
  ) then
    raise exception 'forbidden';
  end if;

  select jsonb_build_object(
    'customer', (select to_jsonb(c) from public.customers c where c.id = p_customer),

    'attendance', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'event_id', a.event_id,
               'event_name', e.name,
               'first_scan_at', a.first_scan_at,
               'last_scan_at', a.last_scan_at,
               'group_size', a.group_size,
               'scan_point', sp.label
             ) order by a.first_scan_at desc), '[]'::jsonb)
      from public.attendances a
      join public.events e on e.id = a.event_id
      left join public.scan_points sp on sp.id = a.scan_point_id
      where a.customer_id = p_customer
    ),

    'gifts_received', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', pc.code,
               'label', pc.label,
               'mode', ge.mode,
               'category', ge.category,
               'product_name', pr.name,
               'max_value', ge.max_value,
               'total', ge.quantity_total,
               'remaining', ge.quantity_remaining
             ) order by ge.created_at desc), '[]'::jsonb)
      from public.gift_entitlements ge
      left join public.promo_codes pc on pc.id = ge.promo_code_id
      left join public.products pr on pr.id = ge.product_id
      where ge.customer_id = p_customer
        and (p_event is null or ge.event_id = p_event)
    ),

    -- Le détail demandé : quel article, à quelle heure, pour quel montant.
    'gifts_used', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'redeemed_at', gr.redeemed_at,
               'product_name', gr.product_name,
               'unit_price', gr.unit_price,
               'covered', gr.covered,
               'paid', gr.paid,
               'code', pc.code,
               'label', pc.label,
               'pickup_code', o.pickup_code
             ) order by gr.redeemed_at desc), '[]'::jsonb)
      from public.gift_redemptions gr
      left join public.promo_codes pc on pc.id = gr.promo_code_id
      left join public.orders o on o.id = gr.order_id
      where gr.customer_id = p_customer
    ),

    'gifts_used_total', (
      select coalesce(sum(covered), 0) from public.gift_redemptions
      where customer_id = p_customer
    ),

    'passes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'event_id', ep.event_id,
               'credits_total', ep.credits_total,
               'credits_remaining', ep.credits_remaining,
               'food_token_total', ep.food_token_total,
               'food_token_available', ep.food_token_available
             )), '[]'::jsonb)
      from public.event_passes ep where ep.customer_id = p_customer
    ),

    'codes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', pc.code,
               'label', pc.label,
               'kind', pc.kind,
               'credits_granted', pr.credits_granted,
               'at', pr.created_at
             ) order by pr.created_at desc), '[]'::jsonb)
      from public.promo_redemptions pr
      join public.promo_codes pc on pc.id = pr.promo_code_id
      where pr.customer_id = p_customer
    ),

    'notes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'flag', n.flag, 'body', n.body,
               'author', n.author_email, 'at', n.created_at
             ) order by n.created_at desc), '[]'::jsonb)
      from public.order_notes n where n.customer_id = p_customer
    )
  ) into v;

  return v;
end;
$$;

grant execute on function public.customer_dossier(uuid, uuid) to authenticated;

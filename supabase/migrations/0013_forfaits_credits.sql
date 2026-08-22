-- ============================================================================
--  NOTI Calling — 0013_forfaits_credits.sql
--  Forfaits Groupes Noti : pass à crédits (entrée + conso) vendu hors app
--  (lien de paiement en amont), activé par le client via un code dédié.
--
--  Modèle retenu : 1 alcool éligible = 2 crédits, 1 soft = 1 crédit (donc
--  1 alcool = 2 softs). Le jeton food vaut, s'il est converti, 2 crédits
--  fongibles (1 alcool OU 2 softs au choix du client) — pas besoin de suivre
--  « en quoi » il a été converti, juste d'ajouter 2 crédits au portefeuille.
--
--  · promo_codes.kind = 'credits' : nouveau type de code, en plus de
--    percent/amount. credits_per_person / food_tokens_per_person sont
--    crédités à CHAQUE personne qui active le code (max_uses = nombre de
--    personnes du groupe, chacune consommant 1 utilisation).
--  · event_passes : le portefeuille d'un client pour une soirée donnée —
--    un seul par (event, customer), jamais recrédité si déjà activé (donc
--    sans risque même si le client se réidentifie à chaque scan).
--  · products.credit_kind ('alcohol' | 'soft' | null) + credit_once (le
--    verre de Champagne Richard Brut, plafonné à 1 par forfait) déterminent
--    l'éligibilité, étiquetée automatiquement par seed_noti_menu().
--  · place_order() consomme le portefeuille en plus du code promo classique
--    (les deux sont cumulables, mais un forfait n'a normalement pas de code
--    promo à côté).
--
--  Fenêtres horaires (Europe/Paris) :
--   · conversion manuelle du jeton food → crédits : jusqu'à 22h00.
--   · arrivée après 22h30 (activation du pass) : jeton food auto-converti.
-- ============================================================================

alter table public.products
  add column if not exists credit_kind text,   -- 'alcohol' | 'soft' | null (non éligible)
  add column if not exists credit_once boolean not null default false; -- ex. 1 verre Richard

alter table public.promo_codes
  add column if not exists credits_per_person int not null default 0,
  add column if not exists food_tokens_per_person int not null default 0;

-- ----------------------------------------------------------- PORTEFEUILLE
create table if not exists public.event_passes (
  id                    uuid primary key default gen_random_uuid(),
  event_id              uuid not null references public.events (id) on delete cascade,
  customer_id           uuid not null references public.customers (id) on delete cascade,
  promo_code_id         uuid references public.promo_codes (id) on delete set null,
  credits_total         int not null default 0,
  credits_remaining     int not null default 0,
  food_token_total      int not null default 0,
  food_token_available  boolean not null default false,
  richard_used          boolean not null default false,
  created_at            timestamptz not null default now(),
  unique (event_id, customer_id)
);

alter table public.event_passes enable row level security;

drop policy if exists event_passes_select on public.event_passes;
create policy event_passes_select on public.event_passes for select
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- ---------------------------------------------------------------------------
--  Activation du forfait : idempotente (un seul pass par personne et par
--  soirée). Un second appel — inévitable puisque le client se réidentifie à
--  chaque scan — renvoie simplement le pass déjà actif, sans recréditer.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_pass  public.event_passes;
  v_now_paris time;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is not null then
    return v_pass;
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind = 'credits'
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses);
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

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
  -- crédits (2 crédits/jeton — cf. note de modèle en tête de fichier).
  if v_promo.food_tokens_per_person > 0 and v_now_paris >= time '22:30:00' then
    update public.event_passes
       set credits_total     = credits_total + v_promo.food_tokens_per_person * 2,
           credits_remaining = credits_remaining + v_promo.food_tokens_per_person * 2
     where id = v_pass.id
     returning * into v_pass;
  end if;

  update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;

  return v_pass;
end;
$$;

-- ---------------------------------------------------------------------------
--  Conversion manuelle du jeton food (avant 22h00) : +2 crédits fongibles,
--  dépensables ensuite en 1 alcool éligible ou 2 softs au choix du client.
-- ---------------------------------------------------------------------------
create or replace function public.convert_food_token(p_event uuid)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust uuid := public.my_customer_id();
  v_pass public.event_passes;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;
  if (now() at time zone 'Europe/Paris')::time >= time '22:00:00' then
    raise exception 'conversion_closed';
  end if;

  select * into v_pass from public.event_passes
    where event_id = p_event and customer_id = v_cust;
  if v_pass.id is null then raise exception 'no_pass'; end if;
  if not v_pass.food_token_available then raise exception 'no_food_token'; end if;

  update public.event_passes
     set food_token_available = false,
         credits_total     = credits_total + 2,
         credits_remaining = credits_remaining + 2
   where id = v_pass.id
   returning * into v_pass;

  return v_pass;
end;
$$;

-- ---------------------------------------------------------------------------
--  place_order() — même signature qu'en 0001, remplacée pour consommer le
--  portefeuille forfait en plus du code promo classique (les deux sont
--  cumulables). Le prix catalogue reste affiché sur le ticket (unit_price
--  inchangé) : seule la remise finale absorbe la part couverte par le pass.
-- ---------------------------------------------------------------------------
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

    -- ---- Forfait Noti : consommation du portefeuille (crédits / jeton food) ----
    if v_pass.id is not null then
      if v_prod.credit_once and not v_pass.richard_used then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        if v_pass.credits_remaining >= v_wallet_cost then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_cost;
          v_pass.richard_used := true;
          v_discount := v_discount + v_unit;
        end if;
      elsif v_prod.credit_kind in ('alcohol', 'soft') then
        v_wallet_cost := case when v_prod.credit_kind = 'alcohol' then 2 else 1 end;
        v_wallet_units := least(v_qty, v_pass.credits_remaining / v_wallet_cost);
        if v_wallet_units > 0 then
          v_pass.credits_remaining := v_pass.credits_remaining - v_wallet_units * v_wallet_cost;
          v_discount := v_discount + v_wallet_units * v_unit;
        end if;
      elsif v_prod.universe = 'food' and v_pass.food_token_available then
        v_pass.food_token_available := false;
        v_discount := v_discount + v_unit;
      end if;
    end if;
  end loop;

  -- Code promo classique (pourcentage / montant), cumulable avec le forfait
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
     set subtotal = v_subtotal,
         discount = v_discount,
         total = greatest(0, v_subtotal - v_discount),
         promo_code = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

-- ---------------------------------------------------------------------------
--  Étiquetage crédits sur la carte Noti Club — rejoué à chaque appel de
--  seed_noti_menu(), donc appliqué aussi bien à un venue neuf qu'à un venue
--  existant qui clique sur « Recharger la carte Noti Club ».
--  Helper interne uniquement : jamais exposée aux clients (pas de grant à
--  authenticated) — seed_noti_menu() a déjà vérifié is_staff() avant de
--  l'appeler, et la ligne de rattrapage en bas de fichier tourne dans le
--  SQL Editor (rôle postgres, sans auth.uid()) donc sans contexte staff.
-- ---------------------------------------------------------------------------
create or replace function public.tag_credit_menu(p_venue uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  update public.products set credit_kind = 'soft', credit_once = false
   where venue_id = p_venue and universe = 'drinks' and is_alcohol = false;

  update public.products set credit_kind = 'alcohol', credit_once = false
   where venue_id = p_venue and universe = 'drinks' and (
     subcategory = 'Bar à spritz'
     or (subcategory = 'Cocktails' and name in ('Moscow Mule', 'Rive Gauche'))
     or (subcategory = 'Vins au verre' and name in (
           'Côtes de Provence AOP — Minuty Prestige 2024',
           'Pouilly-Fumé AOP — Domaine Minet',
           'Bordeaux AOP — James Deschartrons 2021/22',
           'Saint-Amour AOP — Domaine des Pierres 2023/24'))
     or subcategory = 'Bières'
     or (subcategory = 'Vodka' and name = 'Absolut')
     or (subcategory = 'Gin' and name = 'Tanqueray')
     or (subcategory = 'Rhum' and name = 'Havana 3 ans')
     or (subcategory = 'Whisky' and name = 'Monkey Shoulder')
   );

  -- 1 verre de Champagne Richard Brut offert, une fois par forfait (2 crédits)
  update public.products set credit_kind = 'alcohol', credit_once = true
   where venue_id = p_venue and universe = 'drinks'
     and subcategory = 'Vins au verre' and name = 'Champagne AOP Richard — Brut';
end;
$$;

-- ---------------------------------------------------------------------------
--  seed_noti_menu() — redéfinie ici pour appeler tag_credit_menu() en fin de
--  rechargement (bouton « Recharger la carte Noti Club » côté app), afin que
--  l'étiquetage crédits reste à jour sans intervention SQL manuelle.
--  Copie exacte de 0005/0012, seule la dernière ligne avant `return n;`
--  change. Installation neuve : 0005_seed_noti_menu.sql contient déjà cette
--  version, cette redéfinition est alors un simple no-op identique.
-- ---------------------------------------------------------------------------
create unique index if not exists products_venue_universe_name_uniq
  on public.products (venue_id, universe, name);

create or replace function public.seed_noti_menu(p_venue uuid)
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  n int;
begin
  if not public.is_staff(p_venue) then
    raise exception 'forbidden';
  end if;

  insert into public.products
    (venue_id, universe, subcategory, name, description, price, is_popular,
     is_alcohol, vat_rate, sort_order, variants)
  values
  -- ------------------------------------------------------------ BAR À SPRITZ (4 cl)
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',13,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',14,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',14,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',15,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',11,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',14,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',14,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',7,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',10,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',13,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',19,true,true,20,6,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',10,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',10,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',10,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',10,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',7,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',7,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',7,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',7,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',7,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',7,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',7,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',10,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,15,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,21,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,23,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,17,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,21,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,22,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,23,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,15,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,26,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,28,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,14,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,17,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,19,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,23,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,29,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,32,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,41,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,15,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,21,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,23,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,14,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,14,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,14,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,14,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,14,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,14,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,15,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,18,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,18,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,21,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,10,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,10,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,10,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',75,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":75}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',190,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',190,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',190,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',190,false,true,20,5,'[]')
  on conflict (venue_id, universe, name) do update
    set subcategory = excluded.subcategory,
        description = excluded.description,
        price       = excluded.price,
        is_popular  = excluded.is_popular,
        is_alcohol  = excluded.is_alcohol,
        vat_rate    = excluded.vat_rate,
        sort_order  = excluded.sort_order,
        variants    = excluded.variants;

  get diagnostics n = row_count;

  -- Retirés de la carte des vins au verre à la rentrée 2026 : on deliste plutôt
  -- que supprimer (historique des commandes déjà passées préservé).
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and name in (
       'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
       'IGP Méditerranée — Ponton 7 2024'
     );

  -- Étiquetage des articles éligibles aux forfaits à crédits (cf. 0013).
  perform public.tag_credit_menu(p_venue);

  return n;
end;
$$;

grant execute on function public.redeem_pass(uuid, text)     to authenticated;
grant execute on function public.convert_food_token(uuid)    to authenticated;
grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;
grant execute on function public.seed_noti_menu(uuid)         to authenticated;

-- Rétroactif, pour les venues déjà en activité (le prochain rechargement de
-- carte l'aurait fait de toute façon) :
do $$
declare v_venue record;
begin
  for v_venue in select id from public.venues loop
    perform public.tag_credit_menu(v_venue.id);
  end loop;
end $$;

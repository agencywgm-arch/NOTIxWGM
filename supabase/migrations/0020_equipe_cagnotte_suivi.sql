-- ============================================================================
--  NOTI Calling — 0020_equipe_cagnotte_suivi.sql
--
--  Quatre chantiers en un seul patch (à coller d'un bloc) :
--
--   1. CAGNOTTE EN EUROS — remplace le système de crédits (1 alcool = 2
--      crédits, 1 soft = 1 crédit, jeton food convertible avant 22h…) par une
--      cagnotte en euros, dépensée euro pour euro sur n'importe quel article.
--      Un code promo de type « crédit » verse un montant à chaque personne qui
--      l'active, dans la limite du nombre d'utilisations défini.
--
--   2. ÉQUIPE — invitations par e-mail, rattachement automatique à la première
--      connexion, et trois rôles (owner / manager / staff) dont un accès
--      réduit pour l'équipe de bar.
--
--   3. SUIVI DES COMMANDES — commentaires et signalements horodatés sur chaque
--      commande, à tout stade, qui alimentent la fiche client (incidents).
--
--   4. AFFLUENCE — capacité de la soirée + vue des arrivées par tranche de
--      15 min, pour la jauge de remplissage côté staff.
--
--  Patch cumulatif : s'exécute aussi bien sur une installation neuve que sur
--  une base déjà en service (tout est `if not exists` / `or replace`).
-- ============================================================================


-- ============================================================================
--  1. CAGNOTTE EN EUROS
-- ============================================================================

-- Le code promo « crédit » verse ce montant à chaque activation.
alter table public.promo_codes
  add column if not exists credit_amount numeric(10, 2) not null default 0;

-- La cagnotte du client pour une soirée, en euros.
alter table public.event_passes
  add column if not exists credit_total     numeric(10, 2) not null default 0,
  add column if not exists credit_remaining numeric(10, 2) not null default 0;

-- Part du panier réglée par la cagnotte (transparence sur le ticket/la fiche).
alter table public.orders
  add column if not exists credit_used numeric(10, 2) not null default 0;

-- ---------------------------------------------------------------------------
--  Une activation par personne et par code : c'est ce qui empêche de recharger
--  sa cagnotte en ressaisissant le même code, tout en autorisant deux codes
--  différents à se cumuler. Sert aussi d'historique propre « codes utilisés »
--  par client, à la place de l'ancienne reconstitution approximative.
-- ---------------------------------------------------------------------------
create table if not exists public.promo_redemptions (
  id             uuid primary key default gen_random_uuid(),
  promo_code_id  uuid not null references public.promo_codes (id) on delete cascade,
  customer_id    uuid not null references public.customers (id)   on delete cascade,
  event_id       uuid not null references public.events (id)      on delete cascade,
  credit_granted numeric(10, 2) not null default 0,
  created_at     timestamptz not null default now(),
  unique (promo_code_id, customer_id)
);

create index if not exists promo_redemptions_customer_idx
  on public.promo_redemptions (customer_id, created_at desc);

alter table public.promo_redemptions enable row level security;

drop policy if exists promo_redemptions_read on public.promo_redemptions;
create policy promo_redemptions_read on public.promo_redemptions
  for select to authenticated
  using (customer_id = public.my_customer_id() or public.is_event_staff(event_id));

-- ---------------------------------------------------------------------------
--  Reprise des données existantes.
--
--  VALEUR_CREDIT ci-dessous est la conversion appliquée UNE FOIS aux anciens
--  soldes en crédits. 5,00 € correspond au ticket moyen d'un soft de la carte ;
--  ajustez-la AVANT d'exécuter ce patch si votre forfait valait autre chose.
--  Le jeton food valait 2 crédits, il est converti au même taux.
-- ---------------------------------------------------------------------------
do $$
declare
  v_credit_eur constant numeric(10, 2) := 5.00;
begin
  -- Portefeuilles déjà distribués → cagnotte en euros.
  update public.event_passes
     set credit_total = (credits_total + case when food_token_available then 2 else 0 end) * v_credit_eur,
         credit_remaining = (credits_remaining + case when food_token_available then 2 else 0 end) * v_credit_eur
   where credit_total = 0
     and credit_remaining = 0
     and (credits_total > 0 or credits_remaining > 0 or food_token_available);

  -- Codes « forfait » existants → codes « crédit » en euros.
  update public.promo_codes
     set credit_amount = (credits_per_person + food_tokens_per_person * 2) * v_credit_eur,
         kind = 'credit'
   where kind = 'credits'
     and credit_amount = 0;
end $$;

-- ---------------------------------------------------------------------------
--  Activation d'un code à crédit. Idempotente par personne : réutiliser le
--  même code renvoie la cagnotte inchangée, sans consommer d'utilisation.
--  L'incrément de `uses_count` sert de garde atomique sur `max_uses` : deux
--  clients qui activent la dernière place en même temps ne peuvent pas passer
--  tous les deux.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_credit_code(p_event uuid, p_code text)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_cust  uuid := public.my_customer_id();
  v_promo public.promo_codes;
  v_pass  public.event_passes;
begin
  if v_cust is null then raise exception 'not_a_customer'; end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event
      and upper(code) = upper(trim(p_code))
      and active
      and kind = 'credit'
      and (starts_at is null or starts_at <= now())
      and (ends_at   is null or ends_at   >= now());
  if v_promo.id is null then raise exception 'invalid_pass_code'; end if;

  -- Déjà activé par cette personne : on renvoie la cagnotte telle quelle.
  if exists (select 1 from public.promo_redemptions
              where promo_code_id = v_promo.id and customer_id = v_cust) then
    select * into v_pass from public.event_passes
      where event_id = p_event and customer_id = v_cust;
    return v_pass;
  end if;

  update public.promo_codes
     set uses_count = uses_count + 1
   where id = v_promo.id
     and (max_uses is null or uses_count < max_uses);
  if not found then raise exception 'code_exhausted'; end if;

  insert into public.event_passes
    (event_id, customer_id, promo_code_id, credit_total, credit_remaining)
  values (p_event, v_cust, v_promo.id, v_promo.credit_amount, v_promo.credit_amount)
  on conflict (event_id, customer_id) do update
    set credit_total     = public.event_passes.credit_total     + v_promo.credit_amount,
        credit_remaining = public.event_passes.credit_remaining + v_promo.credit_amount,
        promo_code_id    = coalesce(public.event_passes.promo_code_id, v_promo.id)
  returning * into v_pass;

  insert into public.promo_redemptions (promo_code_id, customer_id, event_id, credit_granted)
  values (v_promo.id, v_cust, p_event, v_promo.credit_amount);

  return v_pass;
end;
$$;

-- Ancien nom conservé : une intégration qui l'appelle encore continue de
-- fonctionner, sur le nouveau modèle.
create or replace function public.redeem_pass(p_event uuid, p_code text)
returns public.event_passes
language sql volatile security definer set search_path = public
as $$
  select public.redeem_credit_code(p_event, p_code);
$$;

-- Le jeton food n'existe plus : la fonction reste déclarée pour ne rien casser,
-- mais refuse explicitement.
create or replace function public.convert_food_token(p_event uuid)
returns public.event_passes
language plpgsql volatile security definer set search_path = public
as $$
begin
  raise exception 'no_food_token';
end;
$$;

-- ---------------------------------------------------------------------------
--  place_order() — reprise de la version 0013, dont toute la mécanique
--  d'éligibilité aux crédits (credit_kind / credit_once / jeton food) est
--  remplacée par une simple absorption de la cagnotte : la remise promo
--  s'applique d'abord, la cagnotte couvre ensuite ce qu'il reste à payer.
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
  v_wallet   numeric(10,2) := 0;
  v_promo    public.promo_codes;
  v_prep     int;
  v_code     text;
  v_tries    int := 0;
  v_pass     public.event_passes;
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
  end loop;

  -- Code promo classique (pourcentage / montant)
  if p_promo is not null and length(trim(p_promo)) > 0 then
    select * into v_promo from public.promo_codes
      where event_id = p_event and upper(code) = upper(trim(p_promo)) and active
        and kind in ('percent', 'amount')
        and (starts_at is null or starts_at <= now())
        and (ends_at is null or ends_at >= now())
        and (max_uses is null or uses_count < max_uses)
        and min_total <= v_subtotal;
    if v_promo.id is not null then
      v_discount := least(
        case when v_promo.kind = 'amount' then v_promo.value
             else round(v_subtotal * v_promo.value / 100, 2) end,
        v_subtotal);
      update public.promo_codes set uses_count = uses_count + 1 where id = v_promo.id;
    end if;
  end if;

  -- Cagnotte : couvre ce qu'il reste à payer, euro pour euro.
  if v_pass.id is not null and v_pass.credit_remaining > 0 then
    v_wallet := least(v_pass.credit_remaining, v_subtotal - v_discount);
    if v_wallet > 0 then
      update public.event_passes
         set credit_remaining = credit_remaining - v_wallet
       where id = v_pass.id;
    end if;
  end if;

  update public.orders
     set subtotal    = v_subtotal,
         discount    = v_discount + v_wallet,
         credit_used = v_wallet,
         total       = greatest(0, v_subtotal - v_discount - v_wallet),
         promo_code  = case when v_promo.id is not null then upper(trim(p_promo)) else null end
   where id = v_order.id
   returning * into v_order;

  update public.customers set last_seen_at = now() where id = v_cust;

  return v_order;
end;
$$;

-- ---------------------------------------------------------------------------
--  preview_promo() — reprise de 0008 avec le filtre de type qui manquait.
--  Sans lui, un code de type « cagnotte » était accepté par l'aperçu et
--  affiché au client comme une remise de 0,00 €, alors qu'il ne s'applique
--  pas de cette façon. Seuls les codes % / montant ont un aperçu de remise.
-- ---------------------------------------------------------------------------
create or replace function public.preview_promo(p_event uuid, p_code text, p_subtotal numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_promo    public.promo_codes;
  v_discount numeric(10,2) := 0;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('valid', false);
  end if;

  select * into v_promo from public.promo_codes
    where event_id = p_event and upper(code) = upper(trim(p_code)) and active
      and kind in ('percent', 'amount')
      and (starts_at is null or starts_at <= now())
      and (ends_at is null or ends_at >= now())
      and (max_uses is null or uses_count < max_uses)
      and min_total <= coalesce(p_subtotal, 0);

  if v_promo.id is null then
    return jsonb_build_object('valid', false);
  end if;

  v_discount := least(
    case when v_promo.kind = 'amount' then v_promo.value
         else round(coalesce(p_subtotal, 0) * v_promo.value / 100, 2) end,
    coalesce(p_subtotal, 0));

  return jsonb_build_object(
    'valid', true,
    'kind', v_promo.kind,
    'value', v_promo.value,
    'label', v_promo.label,
    'discount', v_discount
  );
end;
$$;

grant execute on function public.preview_promo(uuid, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
--  Annulation d'une commande : la part réglée par la cagnotte est rendue.
--  Sans cela, annuler une commande au bar faisait perdre au client des euros
--  qu'il n'a jamais consommés.
-- ---------------------------------------------------------------------------
create or replace function public.refund_credit_on_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'CANCELLED'
     and old.status is distinct from 'CANCELLED'
     and coalesce(old.credit_used, 0) > 0 then

    update public.event_passes
       set credit_remaining = least(credit_total, credit_remaining + old.credit_used)
     where event_id = new.event_id and customer_id = new.customer_id;

    new.discount    := greatest(0, coalesce(new.discount, 0) - old.credit_used);
    new.credit_used := 0;
    new.total       := greatest(0, coalesce(new.subtotal, 0) - new.discount);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_credit_refund on public.orders;
create trigger trg_orders_credit_refund
  before update on public.orders
  for each row execute function public.refund_credit_on_cancel();

grant execute on function public.redeem_credit_code(uuid, text) to authenticated;
grant execute on function public.redeem_pass(uuid, text)        to authenticated;
grant execute on function public.convert_food_token(uuid)       to authenticated;
grant execute on function public.place_order(uuid, uuid, jsonb, text, text) to authenticated;


-- ============================================================================
--  2. ÉQUIPE : INVITATIONS PAR E-MAIL ET RÔLES
-- ============================================================================

-- owner   : le créateur du lieu — accès complet + gestion de l'équipe
-- manager : accès complet, sauf la gestion de l'équipe et les mentions légales
-- staff   : accès réduit — bar, caisse, clients
create table if not exists public.staff_invites (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues (id) on delete cascade,
  email       text not null,
  role        text not null default 'staff',
  invited_by  uuid references auth.users (id) on delete set null,
  accepted_at timestamptz,
  accepted_by uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (venue_id, email)
);

create index if not exists staff_invites_email_idx on public.staff_invites (lower(email));

alter table public.staff_invites enable row level security;

-- Seul le propriétaire du lieu gère l'équipe. L'invité, lui, ne lit jamais
-- cette table : il passe par accept_my_staff_invites() (security definer).
drop policy if exists staff_invites_owner on public.staff_invites;
create policy staff_invites_owner on public.staff_invites
  for all to authenticated
  using      (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()))
  with check (exists (select 1 from public.venues v where v.id = venue_id and v.owner_id = auth.uid()));

/** Rôle de l'utilisateur courant sur un lieu — null s'il n'en fait pas partie. */
create or replace function public.my_venue_role(p_venue uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from public.venues v
                  where v.id = p_venue and v.owner_id = auth.uid()) then 'owner'
    else (select s.role from public.staff_members s
           where s.venue_id = p_venue and s.user_id = auth.uid())
  end;
$$;

-- ---------------------------------------------------------------------------
--  Rattachement automatique : appelé à chaque ouverture de l'espace équipe.
--  Toute invitation en attente adressée à l'e-mail du compte connecté devient
--  une adhésion. C'est ce qui permet d'inviter quelqu'un qui n'a pas encore de
--  compte : il crée le sien avec cet e-mail, et il est rattaché à l'entrée.
-- ---------------------------------------------------------------------------
create or replace function public.accept_my_staff_invites()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_inv   record;
  n       int := 0;
begin
  if auth.uid() is null or v_email = '' then return 0; end if;

  for v_inv in
    select * from public.staff_invites
     where lower(email) = v_email and accepted_at is null
  loop
    insert into public.staff_members (venue_id, user_id, role)
    values (v_inv.venue_id, auth.uid(), v_inv.role)
    on conflict (venue_id, user_id) do update set role = excluded.role;

    update public.staff_invites
       set accepted_at = now(), accepted_by = auth.uid()
     where id = v_inv.id;

    n := n + 1;
  end loop;

  return n;
end;
$$;

grant execute on function public.my_venue_role(uuid)         to authenticated;
grant execute on function public.accept_my_staff_invites()   to authenticated;

-- Le staff doit pouvoir lire les comptes de son équipe (nom affiché dans les
-- réglages) : la policy 0002 le permet déjà via is_staff(venue_id).


-- ============================================================================
--  3. SUIVI DES COMMANDES : COMMENTAIRES ET SIGNALEMENTS
-- ============================================================================

-- Interne au staff : jamais lisible par le client.
create table if not exists public.order_notes (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders (id)    on delete cascade,
  event_id     uuid not null references public.events (id)    on delete cascade,
  customer_id  uuid references public.customers (id)          on delete set null,
  author_id    uuid references auth.users (id)                on delete set null,
  author_email text,
  flag         text not null default 'info',   -- info | attention | incident | geste
  body         text not null default '',
  created_at   timestamptz not null default now()
);

create index if not exists order_notes_order_idx    on public.order_notes (order_id, created_at desc);
create index if not exists order_notes_customer_idx on public.order_notes (customer_id, created_at desc);

alter table public.order_notes enable row level security;

drop policy if exists order_notes_staff on public.order_notes;
create policy order_notes_staff on public.order_notes
  for all to authenticated
  using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

-- Compteur et drapeau le plus grave, dénormalisés sur la commande : le tableau
-- du bar affiche la pastille sans requête supplémentaire, et la mise à jour de
-- `orders` fait remonter le changement par le temps réel déjà en place.
alter table public.orders
  add column if not exists notes_count int not null default 0,
  add column if not exists flag        text;

create or replace function public.sync_order_notes()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_order uuid := coalesce(new.order_id, old.order_id);
begin
  update public.orders o
     set notes_count = (select count(*) from public.order_notes n where n.order_id = v_order),
         flag = (
           select n.flag from public.order_notes n
            where n.order_id = v_order
            order by case n.flag
                       when 'incident'  then 3
                       when 'attention' then 2
                       when 'geste'     then 1
                       else 0 end desc,
                     n.created_at desc
            limit 1
         )
   where o.id = v_order;
  return null;
end;
$$;

drop trigger if exists trg_order_notes on public.order_notes;
create trigger trg_order_notes
  after insert or delete on public.order_notes
  for each row execute function public.sync_order_notes();

-- ---------------------------------------------------------------------------
--  Un clic sur la commande, à n'importe quel stade. Un signalement « incident »
--  taggue aussi la fiche du client, comme le fait déjà un impayé.
-- ---------------------------------------------------------------------------
create or replace function public.add_order_note(
  p_order uuid,
  p_body  text,
  p_flag  text default 'info'
)
returns public.order_notes
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_order public.orders;
  v_row   public.order_notes;
begin
  select * into v_order from public.orders where id = p_order;
  if v_order.id is null then raise exception 'unknown_order'; end if;
  if not public.is_event_staff(v_order.event_id) then raise exception 'forbidden'; end if;
  if coalesce(p_flag, 'info') not in ('info', 'attention', 'incident', 'geste') then
    raise exception 'invalid_flag';
  end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty_note'; end if;

  insert into public.order_notes
    (order_id, event_id, customer_id, author_id, author_email, flag, body)
  values
    (p_order, v_order.event_id, v_order.customer_id, auth.uid(),
     auth.jwt() ->> 'email', coalesce(p_flag, 'info'), trim(p_body))
  returning * into v_row;

  if p_flag = 'incident' and v_order.customer_id is not null then
    update public.customers
       set tags = case when 'incident' = any (tags) then tags
                       else array_append(tags, 'incident') end
     where id = v_order.customer_id;
  end if;

  return v_row;
end;
$$;

grant execute on function public.add_order_note(uuid, text, text) to authenticated;


-- ============================================================================
--  4. AFFLUENCE
-- ============================================================================

-- Dénominateur de la jauge de remplissage (null = pas de jauge, juste le compte).
alter table public.events
  add column if not exists capacity int;

-- Arrivées par tranche de 15 minutes — sert la courbe et le rythme d'arrivée.
create or replace view public.v_event_affluence
with (security_invoker = true) as
select
  a.event_id,
  date_trunc('hour', a.first_scan_at)
    + (floor(extract(minute from a.first_scan_at)::int / 15.0) * interval '15 minutes') as slot,
  count(*)::int                          as arrivals,
  coalesce(sum(a.group_size), 0)::int    as people
from public.attendances a
group by 1, 2;

grant select on public.v_event_affluence to authenticated;

-- ---------------------------------------------------------------------------
--  v_event_live — corrigée : `in_preparation` ne comptait que 'RECEIVED' et
--  ignorait le stade 'IN_PREP' ajouté depuis (0010), donc le compteur du
--  tableau de bord retombait à zéro dès qu'une commande passait « en
--  préparation ».
--
--  La liste de colonnes reste STRICTEMENT celle de 0003 : PostgreSQL refuse
--  qu'un `create or replace view` retire une colonne, et rejouer setup.sql
--  ferait alors repasser 0003 sur cette définition. Les indicateurs
--  d'affluence vivent donc dans leur propre vue, juste en dessous.
-- ---------------------------------------------------------------------------
create or replace view public.v_event_live
with (security_invoker = true) as
select
  e.id as event_id,
  (select count(*) from public.attendances a where a.event_id = e.id)              as present_count,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status in ('RECEIVED', 'IN_PREP'))                as in_preparation,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status = 'READY')                                 as awaiting_pickup,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status in ('PICKED_UP', 'UNPAID'))                as awaiting_payment,
  (select coalesce(sum(o.total), 0) from public.orders o
    where o.event_id = e.id and o.status = 'PAID')                                  as revenue_paid,
  (select coalesce(sum(o.total), 0) from public.orders o
    where o.event_id = e.id and o.status in ('PICKED_UP', 'UNPAID'))                as revenue_pending,
  (select count(*) from public.orders o
    where o.event_id = e.id and o.status = 'UNPAID')                                as unpaid_count
from public.events e;

grant select on public.v_event_live to authenticated;

-- Indicateurs d'affluence temps réel, consommés par la jauge de remplissage.
create or replace view public.v_event_pulse
with (security_invoker = true) as
select
  e.id                                                                              as event_id,
  e.capacity                                                                        as capacity,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id)                                                        as headcount,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '15 minutes')   as arrivals_15min,
  (select coalesce(sum(a.group_size), 0) from public.attendances a
    where a.event_id = e.id and a.first_scan_at >= now() - interval '60 minutes')   as arrivals_60min,
  (select count(*) from public.attendances a
    where a.event_id = e.id and a.last_scan_at >= now() - interval '30 minutes')    as active_30min,
  (select max(a.first_scan_at) from public.attendances a where a.event_id = e.id)   as last_arrival_at
from public.events e;

grant select on public.v_event_pulse to authenticated;

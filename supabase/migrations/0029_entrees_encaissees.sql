-- ============================================================================
--  0029 — Les entrées payantes dans « Encaissé »
--
--  Retour terrain, 6.4 (nouveau, validé) :
--
--  « Le montant encaissé doit inclure l'argent entré grâce à l'outil, donc
--  les entrées. Une personne qui paie son entrée à 25 € reçoit immédiatement
--  le code promo Noti daté du jour, qui lui donne accès à ses consos
--  prépayées. Donc : détenir ce code = avoir payé son entrée → on peut
--  comptabiliser automatiquement 25 € encaissés dès l'activation du code.
--  Une personne qui scanne simplement le QR sans ce code est entrée
--  autrement (invitation, connaissance) → seules ses commandes sont
--  comptabilisées. Bénéfice secondaire : le delta entre scans QR et entrées
--  payantes. »
--
--  Le « code Noti daté du jour » est le code de forfait groupe (kind =
--  'credits', celui que redeem_pass() active) — c'est lui qui donne les
--  consos prépayées décrites. Le staff marque LEQUEL des codes credits du
--  jour est le code d'entrée, avec son prix ; l'activation du code
--  enregistre l'entrée automatiquement, une fois par personne.
--
--  IMPORTANT : on n'a PAS touché à redeem_pass() (0020), déjà testé et tout
--  juste sorti d'un vrai bug de régression sur ce même chemin — cf. 0024. Un
--  DÉCLENCHEUR sur l'insertion dans event_passes fait le travail à côté, sans
--  toucher une seule ligne de la fonction existante.
-- ============================================================================

alter table public.promo_codes
  add column if not exists is_entry_code boolean not null default false,
  add column if not exists entry_price numeric(10,2);

comment on column public.promo_codes.is_entry_code is
  'Coche ce code comme LE code d''entrée de la soirée (kind=credits) : son '
  'activation vaut paiement d''entrée et alimente « Encaissé ».';
comment on column public.promo_codes.entry_price is
  'Prix de l''entrée associé à ce code, en euros (ex. 25.00).';

-- Un seul code d'entrée actif par soirée — sinon deux entrées à des prix
-- différents s'additionneraient de façon incohérente dans le total encaissé.
create unique index if not exists promo_codes_one_entry_per_event
  on public.promo_codes (event_id)
  where is_entry_code;


-- ---------------------------------------------------------------------------
--  Journal des entrées payées : une ligne par personne et par soirée.
-- ---------------------------------------------------------------------------
create table if not exists public.event_entries (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events (id) on delete cascade,
  customer_id   uuid not null references public.customers (id) on delete cascade,
  promo_code_id uuid references public.promo_codes (id) on delete set null,
  amount        numeric(10,2) not null,
  created_at    timestamptz not null default now(),
  unique (event_id, customer_id)
);

create index if not exists event_entries_event_idx on public.event_entries (event_id, created_at);

alter table public.event_entries enable row level security;

drop policy if exists event_entries_staff_read on public.event_entries;
create policy event_entries_staff_read on public.event_entries
  for select to authenticated
  using (public.is_event_staff(event_id));


-- ---------------------------------------------------------------------------
--  Déclencheur : l'activation du code d'entrée du jour enregistre le
--  paiement, une fois par personne (la contrainte unique de event_passes sur
--  (event_id, customer_id) garantit déjà qu'il n'y a qu'une seule ligne par
--  personne — voir redeem_pass, qui renvoie le pass existant sans en
--  recréer un second à un rescan).
-- ---------------------------------------------------------------------------
create or replace function public.log_entry_on_pass()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_promo public.promo_codes;
begin
  select * into v_promo from public.promo_codes where id = new.promo_code_id;
  if v_promo.is_entry_code then
    insert into public.event_entries (event_id, customer_id, promo_code_id, amount)
    values (new.event_id, new.customer_id, new.promo_code_id, coalesce(v_promo.entry_price, 0))
    on conflict (event_id, customer_id) do nothing;
  end if;
  return new;
end
$$;

drop trigger if exists trg_log_entry_on_pass on public.event_passes;
create trigger trg_log_entry_on_pass
  after insert on public.event_passes
  for each row execute function public.log_entry_on_pass();


-- ---------------------------------------------------------------------------
--  Résumé pour l'écran staff : entrées payées, total, et le delta demandé
--  (scans QR uniques moins entrées payées = qui est entré autrement).
-- ---------------------------------------------------------------------------
create or replace function public.event_entries_summary(p_event uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'entries_count', coalesce((select count(*) from public.event_entries where event_id = p_event), 0),
    'entries_total', coalesce((select sum(amount) from public.event_entries where event_id = p_event), 0),
    'scan_count', coalesce((select count(*) from public.attendances where event_id = p_event), 0)
  )
  where public.is_event_staff(p_event);
$$;

grant execute on function public.event_entries_summary(uuid) to authenticated;

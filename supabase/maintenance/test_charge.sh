#!/usr/bin/env bash
# ============================================================================
#  NOTI Calling — banc d'essai de tenue en charge
#
#  Monte une base Postgres jetable, y applique toutes les migrations, puis
#  lance N commandes RÉELLEMENT simultanées (une connexion par commande) et
#  vérifie que rien n'a dérivé. Ne touche jamais à la base de production : il
#  n'y a aucun moyen de lui donner une URL distante, c'est volontaire.
#
#  Usage :   ./supabase/maintenance/test_charge.sh [nombre_de_commandes]
#  Défaut :  40 commandes, la cible annoncée pour une soirée.
#
#  Sort en échec (code 1) dès qu'un invariant est violé : utilisable tel quel
#  pour vérifier qu'une modification du SQL n'a rien cassé.
#
#  Ce banc a servi à trouver la perte de crédits corrigée en 0049 : deux
#  commandes simultanées du même client partaient du même solde. Le scénario
#  est rejoué ici à chaque exécution, en garde-fou.
# ============================================================================
set -uo pipefail

N=${1:-40}
PORT=${PORT:-5439}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W=$(mktemp -d /var/tmp/notitest.XXXXXX)
PGBIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | tail -1)
FAILURES=0

EV=22222222-2222-2222-2222-222222222222
SP=33333333-3333-3333-3333-333333333333

if [ -z "$PGBIN" ]; then echo "✗ PostgreSQL introuvable (apt install postgresql)"; exit 1; fi

q()  { psql -h "$W" -p "$PORT" -U postgres -tAc "$1" 2>/dev/null; }
say() { printf '%s\n' "$1"; }
check() { # libellé, obtenu, attendu
  if [ "$2" = "$3" ]; then say "  ✓ $1 : $2"
  else say "  ✗ $1 : $2 (attendu $3)"; FAILURES=$((FAILURES+1)); fi
}

cleanup() {
  su postgres -c "$PGBIN/pg_ctl -D $W/data stop" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

say "── Base jetable ──────────────────────────────────────────"
chown postgres:postgres "$W"
su postgres -c "$PGBIN/initdb -D $W/data -A trust -U postgres" >"$W/initdb.log" 2>&1 || { cat "$W/initdb.log"; exit 1; }
su postgres -c "$PGBIN/pg_ctl -D $W/data -o '-p $PORT -k $W -c max_connections=200' -l $W/pg.log start" >/dev/null 2>&1
sleep 2
q "select 1" >/dev/null || { say "✗ démarrage impossible"; cat "$W/pg.log"; exit 1; }

# Ce que Supabase fournit et qu'un Postgres nu n'a pas.
psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<'SQL'
create role anon; create role authenticated; create role service_role;
create schema if not exists auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb default '{}');
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid; $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb); $$;
create schema if not exists storage;
create table storage.buckets (id text primary key, name text, public boolean,
  file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
SQL

APPLIED=0
for f in "$ROOT"/supabase/migrations/*.sql; do
  psql -h "$W" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -f "$f" >"$W/mig.log" 2>&1 \
    && APPLIED=$((APPLIED+1)) \
    || { say "  ✗ $(basename "$f")"; tail -3 "$W/mig.log" | sed 's/^/      /'; FAILURES=$((FAILURES+1)); }
done
say "  ✓ migrations appliquées : $APPLIED"

say ""
say "── Soirée de test ────────────────────────────────────────"
psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<SQL
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000ff','owner@noti.test');
insert into public.venues (id, owner_id, name)
  values ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000ff','Noti Club');
insert into public.events (id, venue_id, name, is_active, accept_orders, default_prep_min)
  values ('$EV','11111111-1111-1111-1111-111111111111','Soirée test',true,true,1);
insert into public.scan_points (id, event_id, kind, label) values ('$SP','$EV','bar','Bar');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000ff',false);
select public.seed_noti_menu('11111111-1111-1111-1111-111111111111');
select set_config('request.jwt.claim.sub','',false);
-- Sans credit_kind le forfait ne s'engage jamais : on le renseigne pour que
-- le chemin des crédits soit réellement éprouvé.
update public.products set credit_kind = case when is_alcohol then 'alcohol' else 'soft' end
  where is_listed and universe = 'drinks';
do \$\$ declare i int; u uuid; begin
  for i in 1..$N loop
    u := ('40000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid;
    insert into auth.users (id,email) values (u,'client'||i||'@noti.test');
    insert into public.customers (auth_user_id, first_name, last_name, phone, postal_code, birthdate)
      values (u,'Client','Numéro '||i,'+3360000'||lpad(i::text,4,'0'),'75007','1995-01-01');
  end loop;
end \$\$;
SQL
say "  ✓ carte : $(q "select count(*) from public.products where is_listed") articles"
say "  ✓ clients : $(q "select count(*) from public.customers")"

# --------------------------------------------------------------------------
commande() { # $1 = numéro de client, $2 = fichier de sortie
  local u items start end rc out
  u=$(printf "40000000-0000-0000-0000-%012d" "$1")
  items=$(q "select jsonb_agg(jsonb_build_object('product_id',id,'quantity',1,'options','[]'::jsonb))
             from (select id from public.products where is_listed and universe='drinks'
                   order by md5(id::text || '$1') limit 2) s;")
  start=$(date +%s%N)
  out=$(psql -h "$W" -p "$PORT" -U postgres -q -t -A -v ON_ERROR_STOP=1 2>&1 <<SQL
select set_config('request.jwt.claim.sub','$u',false);
select (public.place_order('$EV'::uuid,'$SP'::uuid,'$items'::jsonb,null,null)).pickup_code;
SQL
)
  rc=$?
  end=$(date +%s%N)
  if [ $rc -eq 0 ]; then echo "OK $(( (end-start)/1000000 ))" > "$2"
  else echo "ERR $(( (end-start)/1000000 )) $(echo "$out" | tr '\n' ' ' | cut -c1-140)" > "$2"; fi
}

say ""
say "── $N commandes simultanées ──────────────────────────────"
rm -f "$W"/res_*
T0=$(date +%s%N)
for i in $(seq 1 "$N"); do commande "$i" "$W/res_$i" & done
wait
T1=$(date +%s%N)

OK=$(grep -lc OK "$W"/res_* 2>/dev/null | wc -l)
say "  durée totale : $(( (T1-T0)/1000000 )) ms"
say "  latences (ms, lancement de psql inclus) : $(cat "$W"/res_* | awk '$1=="OK"{print $2}' | sort -n | awk '{a[NR]=$1} END{printf "médiane %d · p95 %d · max %d", a[int((NR+1)/2)], a[int(NR*0.95)], a[NR]}')"
grep -h ERR "$W"/res_* 2>/dev/null | head -3 | sed 's/^/  ✗ /'

say ""
say "── Invariants ────────────────────────────────────────────"
check "commandes abouties"        "$OK" "$N"
check "commandes en base"         "$(q "select count(*) from public.orders")" "$N"
check "codes de retrait distincts" "$(q "select count(distinct pickup_code) from public.orders")" "$N"
check "commandes sans article"    "$(q "select count(*) from public.orders o where not exists (select 1 from public.order_items i where i.order_id=o.id)")" "0"
check "sous-totaux incohérents"   "$(q "select count(*) from public.orders o join (select order_id, sum(unit_price*quantity) s from public.order_items group by order_id) i on i.order_id=o.id where abs(o.subtotal-i.s) > 0.001")" "0"
check "cadeaux en négatif"        "$(q "select count(*) from public.gift_entitlements where quantity_remaining < 0")" "0"

# --------------------------------------------------------------------------
# Régression 0049 : deux commandes du même client, à la même milliseconde, sur
# un forfait. Avant le verrou, la seconde écrasait la déduction de la
# première et l'établissement offrait les crédits.
say ""
say "── Régression : double commande simultanée sur un forfait ─"
BAD=0
for essai in 1 2 3 4 5; do
  psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<SQL
delete from public.gift_redemptions; delete from public.order_items; delete from public.orders;
delete from public.event_passes;
insert into public.event_passes (event_id, customer_id, credits_total, credits_remaining)
select '$EV', c.id, 10, 10 from public.customers c
 where c.auth_user_id = '40000000-0000-0000-0000-000000000001';
SQL
  U=40000000-0000-0000-0000-000000000001
  ITEMS=$(q "select jsonb_agg(jsonb_build_object('product_id',id,'quantity',1,'options','[]'::jsonb))
             from (select id from public.products where is_listed and credit_kind='alcohol' limit 1) s;")
  for n in 1 2; do
    psql -h "$W" -p "$PORT" -U postgres -q -t -A >/dev/null 2>&1 <<SQL &
select set_config('request.jwt.claim.sub','$U',false);
select (public.place_order('$EV'::uuid,'$SP'::uuid,'$ITEMS'::jsonb,null,null)).pickup_code;
SQL
  done
  wait
  FACT=$(q "select coalesce(sum(credit_units_used),0) from public.orders")
  REST=$(q "select credits_remaining from public.event_passes")
  [ "$REST" = "$((10 - FACT))" ] || { BAD=$((BAD+1)); say "  ✗ essai $essai : facturé $FACT, restant $REST"; }
done
check "essais incohérents sur 5" "$BAD" "0"

# --------------------------------------------------------------------------
# Anti-double-ticket : toutes les tablettes du bar voient la même commande et
# voudraient l'imprimer. Une seule doit gagner, sinon le poste reçoit autant
# de tickets que de tablettes allumées.
say ""
say "── Anti-double-ticket entre tablettes ────────────────────"
psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<SQL
delete from public.gift_redemptions; delete from public.order_items; delete from public.orders;
insert into public.orders (event_id, customer_id, scan_point_id, pickup_code, status)
select '$EV', c.id, '$SP', 'TK' || lpad(g::text,2,'0'), 'RECEIVED'
from generate_series(1,10) g
cross join lateral (select id from public.customers limit 1) c;
SQL
MULTI=0
for o in $(q "select id from public.orders order by pickup_code"); do
  rm -f "$W"/claim_*
  for n in 1 2 3 4 5; do
    psql -h "$W" -p "$PORT" -U postgres -q -t -A >"$W/claim_$n" 2>&1 <<SQL &
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000ff',false);
select public.claim_ticket_print('$o');
SQL
  done
  wait
  G=$(cat "$W"/claim_* 2>/dev/null | grep -c '^t$')
  [ "$G" = "1" ] || { MULTI=$((MULTI+1)); say "  ✗ $G tablette(s) ont gagné sur une même commande"; }
done
check "commandes imprimées plus d'une fois" "$MULTI" "0"

# Une impression qui échoue doit rendre la main, sinon la commande reste
# marquée imprimée sans qu'aucun papier ne soit sorti.
OID=$(q "select id from public.orders limit 1")
psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<SQL
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000ff',false);
select public.release_ticket_print('$OID');
SQL
check "réimprimable après un échec" "$(q "select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000ff',false); select public.claim_ticket_print('$OID')" | tail -1)" "t"

# --------------------------------------------------------------------------
# L'écran du bar ne charge plus toute la soirée mais une fenêtre glissante.
# La garantie à ne jamais perdre : une commande en cours reste visible quel
# que soit son âge. Une commande prête oubliée six heures plus tôt doit
# encore apparaître, sinon un client attend un verre que personne ne voit.
say ""
say "── Fenêtre du bar : rien d'en cours ne disparaît ─────────"
psql -h "$W" -p "$PORT" -U postgres -q >/dev/null 2>&1 <<SQL
insert into public.orders (event_id, customer_id, scan_point_id, pickup_code, status, created_at)
select '$EV', (select id from public.customers limit 1), '$SP', 'OLD1', 'READY', now() - interval '6 hours';
insert into public.orders (event_id, customer_id, scan_point_id, pickup_code, status, created_at)
select '$EV', (select id from public.customers limit 1), '$SP', 'OLD2', 'PAID', now() - interval '6 hours';
SQL
FENETRE="status <> 'PAID' and (status in ('AWAITING_PAYMENT','RECEIVED','IN_PREP','READY')
         or created_at >= now() - interval '2 hours')"
check "commande prête vieille de 6 h, encore chargée" \
  "$(q "select count(*) from public.orders where pickup_code='OLD1' and $FENETRE")" "1"
check "commande réglée vieille de 6 h, écartée"       \
  "$(q "select count(*) from public.orders where pickup_code='OLD2' and $FENETRE")" "0"

say ""
if [ "$FAILURES" -eq 0 ]; then
  say "✅ $N commandes simultanées absorbées, tous les invariants tiennent."
  exit 0
else
  say "❌ $FAILURES invariant(s) en échec."
  exit 1
fi

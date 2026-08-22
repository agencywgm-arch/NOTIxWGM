-- ============================================================================
--  NOTI Calling — 0012_menu_rentree_2026.sql
--  Mise à jour de la carte Noti Club — RENTRÉE 2026 (patch, installs existantes).
--
--  Remplace seed_noti_menu() par la version « Rentrée 2026 » :
--   · Au bar (au verre + bouteilles au bar) : +15 % arrondi à l'euro supérieur.
--   · Tous les anciens items à 7 € → 10 € (Red Bull, détox, apéritifs).
--   · Commandes de bouteilles : prix fixes, vins alignés à 50 €.
--   · Food : inchangé (non géré par cette fonction).
--   · Rosé Chardonnay/Ecoterra et rosé Ponton 7 retirés de la carte (delistés,
--     pas supprimés — l'historique des commandes déjà passées est préservé).
--
--  Un nouvel environnement qui repart de zéro n'en a pas besoin : le fichier
--  0005_seed_noti_menu.sql à jour contient directement cette version.
--
--  Après avoir collé ce bloc : rouvrez l'onglet Carte côté app et cliquez sur
--  « 🍸 Carte Noti Club » pour appliquer les nouveaux prix aux articles déjà
--  en base (le rechargement met à jour, il ne duplique pas).
-- ============================================================================

-- Rejouable à volonté (bouton « Recharger la carte Noti Club » côté app) : les
-- articles déjà présents sont mis à jour (prix, description, variantes...) au
-- lieu d'être dupliqués. Le statut « épuisé » / « retiré », lui, appartient au
-- staff et n'est jamais écrasé par un rechargement — sauf action explicite de
-- delistage ci-dessous, pour les deux vins qui sortent de la carte 2026.
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

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;

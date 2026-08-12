-- ============================================================================
--  NOTI Calling — 0005_seed_noti_menu.sql
--  Carte du NOTI CLUB, saisie depuis les cartes fournies (Drinks & Cocktails,
--  Spirits, Commandes de bouteilles).
--
--  Répartition dans les 3 univers de la feuille de route (§04) :
--   · drinks  = tout ce qui se sert au verre (spritz, cocktails, vins au verre,
--               bières, softs, spiritueux à la dose, digestifs, apéritifs)
--   · bottles = service bouteille de la soirée Noti Calling (vins 75/150 cl,
--               champagnes, bouteilles de spiritueux)
--   · food    = à compléter (tapas / planches) — aucune donnée fournie à ce jour
--
--  NOTE PRIX : les deux cartes fournies divergent sur les vins (Minuty 12 cl à
--  8 € sur la carte bar, 10 € sur la carte Noti Calling ; 75 cl à 39 € vs 50 €).
--  Retenu ici : prix « carte bar » au verre, prix « Noti Calling » à la
--  bouteille. À arbitrer avec l'établissement avant la première soirée.
--
--  Usage : select public.seed_noti_menu('<venue_id>');
-- ============================================================================

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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',11,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',12,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',12,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',13,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',9,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Moscow Mule','Vodka, citron, ginger beer, angustura',12,true,true,20,2,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',12,true,true,20,3,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','IGP Méditerranée — Ponton 7 2024','Rosé · 12 cl',6,false,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',8,true,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24','Blanc · 12 cl',6,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',8,false,true,20,4,'[]'),
  (p_venue,'drinks','Vins au verre','Bordeaux AOP — James Deschartrons 2021/22','Rouge · 12 cl',6,false,true,20,5,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',8,false,true,20,6,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Richard — Brut','Bulles · 12 cl',11,false,true,20,7,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',16,true,true,20,8,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',6,true,true,20,1,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — IPA','33 cl',8,false,true,20,2,'[]'),
  (p_venue,'drinks','Bières','La Parisienne — Blanche','33 cl',8,false,true,20,3,'[]'),

  -- ----------------------------------------------------------- BOISSONS DÉTOX BIO
  (p_venue,'drinks','Détox Bio','Limonaid bio fruits de la passion','33 cl',7,false,false,10,1,'[]'),
  (p_venue,'drinks','Détox Bio','Limonaid bio orange sanguine','33 cl',7,false,false,10,2,'[]'),
  (p_venue,'drinks','Détox Bio','Teansai Tea — thé blanc myrtille','33 cl',7,false,false,10,3,'[]'),

  -- ------------------------------------------------------------------------ SOFTS
  (p_venue,'drinks','Softs','Coca-Cola','33 cl',6,true,false,10,1,'[]'),
  (p_venue,'drinks','Softs','Coca-Cola Zéro','33 cl',6,false,false,10,2,'[]'),
  (p_venue,'drinks','Softs','Lipton Ice Tea Pêche','33 cl',6,false,false,10,3,'[]'),
  (p_venue,'drinks','Softs','Jus d''orange','20 cl',6,false,false,10,4,'[]'),
  (p_venue,'drinks','Softs','Jus de pomme','20 cl',6,false,false,10,5,'[]'),
  (p_venue,'drinks','Softs','Jus d''ananas','20 cl',6,false,false,10,6,'[]'),
  (p_venue,'drinks','Softs','Evian','50 cl',6,false,false,10,7,'[]'),
  (p_venue,'drinks','Softs','Badoit','50 cl',6,false,false,10,8,'[]'),
  (p_venue,'drinks','Softs','Red Bull','25 cl',7,false,false,10,9,'[]'),

  -- ------------------------------------------------------------------------ VODKA
  (p_venue,'drinks','Vodka','Absolut',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Vodka','Ketel One',null,13,false,true,20,2,'[]'),
  (p_venue,'drinks','Vodka','Grey Goose',null,18,false,true,20,3,'[]'),
  (p_venue,'drinks','Vodka','Belvedere Pure',null,20,false,true,20,4,'[]'),

  -- -------------------------------------------------------------------------- GIN
  (p_venue,'drinks','Gin','Tanqueray',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Gin','G''Vine June Pêche',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Gin','G''Vine Floraison',null,13,false,true,20,3,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s',null,14,false,true,20,4,'[]'),
  (p_venue,'drinks','Gin','Hendrick''s Orbium',null,15,false,true,20,5,'[]'),
  (p_venue,'drinks','Gin','The Botanist',null,17,false,true,20,6,'[]'),
  (p_venue,'drinks','Gin','Lord Of Barbès',null,18,false,true,20,7,'[]'),
  (p_venue,'drinks','Gin','Monkey 47',null,19,false,true,20,8,'[]'),
  (p_venue,'drinks','Gin','Belle Rives',null,20,false,true,20,9,'[]'),

  -- ------------------------------------------------------------------------- RHUM
  (p_venue,'drinks','Rhum','Havana 3 ans',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Rhum','Havana Club Especial',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Rhum','Bumbu — The Original',null,13,false,true,20,3,'[]'),
  (p_venue,'drinks','Rhum','Diplomatico — Reserva Exclusiva',null,16,false,true,20,4,'[]'),
  (p_venue,'drinks','Rhum','Millionario 15 — Reserva Especial',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Rhum','Santa Teresa 1796',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Rhum','Centenario Fundacion 20',null,22,false,true,20,7,'[]'),
  (p_venue,'drinks','Rhum','Zacapa 23',null,24,false,true,20,8,'[]'),

  -- ----------------------------------------------------------------------- WHISKY
  (p_venue,'drinks','Whisky','Monkey Shoulder',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Whisky','Maker''s Mark',null,12,false,true,20,2,'[]'),
  (p_venue,'drinks','Whisky','Bulleit Rye',null,14,false,true,20,3,'[]'),
  (p_venue,'drinks','Whisky','Glenfiddich — Triple Oak 12 ans',null,16,false,true,20,4,'[]'),
  (p_venue,'drinks','Whisky','Nikka from Barrel',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Whisky','Lagavulin 8 ans',null,20,false,true,20,6,'[]'),
  (p_venue,'drinks','Whisky','Glann Ar Mor — Bourbon Barrel',null,25,false,true,20,7,'[]'),
  (p_venue,'drinks','Whisky','Chivas Regal 18 ans',null,27,false,true,20,8,'[]'),
  (p_venue,'drinks','Whisky','Johnnie Walker — Blue Label',null,35,false,true,20,9,'[]'),

  -- -------------------------------------------------------------- MEZCAL & TEQUILA
  (p_venue,'drinks','Mezcal & Tequila','Vecindad',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Union — Uno Joven',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Blanco',null,12,false,true,20,3,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Calle 23 — Reposado',null,13,false,true,20,4,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Mezcal Mahani',null,18,false,true,20,5,'[]'),
  (p_venue,'drinks','Mezcal & Tequila','Patron — Silver',null,20,false,true,20,6,'[]'),

  -- ------------------------------------------------------------- PISCO ET CACHAÇA
  (p_venue,'drinks','Pisco & Cachaça','Cachaça Leblon',null,12,false,true,20,1,'[]'),
  (p_venue,'drinks','Pisco & Cachaça','Pisco La Caravedo',null,12,false,true,20,2,'[]'),

  -- -------------------------------------------------------------------- DIGESTIFS
  (p_venue,'drinks','Digestifs','Limoncello Walcher',null,10,false,true,20,1,'[]'),
  (p_venue,'drinks','Digestifs','La Menteuse — Crème de Menthe',null,10,false,true,20,2,'[]'),
  (p_venue,'drinks','Digestifs','La Pulpeuse — Crème de citron',null,10,false,true,20,3,'[]'),
  (p_venue,'drinks','Digestifs','Bas Armagnac',null,12,false,true,20,4,'[]'),
  (p_venue,'drinks','Digestifs','Vieille Prune',null,12,false,true,20,5,'[]'),
  (p_venue,'drinks','Digestifs','Poire Williams',null,12,false,true,20,6,'[]'),
  (p_venue,'drinks','Digestifs','Amaretto Walcher',null,12,false,true,20,7,'[]'),
  (p_venue,'drinks','Digestifs','Nardini Grappa',null,12,false,true,20,8,'[]'),
  (p_venue,'drinks','Digestifs','Cognac Camus — VS',null,13,false,true,20,9,'[]'),
  (p_venue,'drinks','Digestifs','Calvados Coquerel — XO',null,15,false,true,20,10,'[]'),
  (p_venue,'drinks','Digestifs','Chartreuse Verte',null,15,false,true,20,11,'[]'),
  (p_venue,'drinks','Digestifs','Hennessy VS',null,18,false,true,20,12,'[]'),

  -- -------------------------------------------------------------------- APÉRITIFS
  (p_venue,'drinks','Apéritifs','Lillet blanc',null,7,false,true,20,1,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin blanc',null,7,false,true,20,2,'[]'),
  (p_venue,'drinks','Apéritifs','Dolin Rouge',null,7,false,true,20,3,'[]'),
  (p_venue,'drinks','Apéritifs','Ricard',null,7,false,true,20,4,'[]'),
  (p_venue,'drinks','Apéritifs','Cynar',null,7,false,true,20,5,'[]'),
  (p_venue,'drinks','Apéritifs','Campari',null,7,false,true,20,6,'[]'),

  -- ===================== UNIVERS BOUTEILLES (service Noti Calling) =============
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50},{"id":"150cl","label":"Magnum 150 cl","price":90}]'),
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire',42,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":42}]'),
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais',42,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":42}]'),
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',60,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":60}]'),
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',90,true,true,20,2,
   '[{"id":"75cl","label":"75 cl","price":90},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),

  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',160,false,true,20,1,'[]'),
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',180,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',180,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',180,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',180,false,true,20,5,'[]');

  get diagnostics n = row_count;
  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;

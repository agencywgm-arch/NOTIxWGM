-- ============================================================================
--  NOTI Calling — 0051_correction_prix_bouteilles.sql
--  Nouvelle carte physique reçue (photo) : corrections de prix sur les
--  bouteilles, et retour du Champagne Richard — Brut en bouteille.
--
--  Comparé ligne à ligne avec ce qui était en base avant d'écrire quoi que ce
--  soit :
--   · Pouilly-Fumé AOP — Domaine Minet         42 € → 50 €
--   · Saint-Amour AOP — Domaine des Pierres    42 € → 50 €
--   · Moët & Chandon — Brut Impérial (75 cl)   90 € → 100 €  (magnum 170 € inchangé)
--   · Vodka Absolut (bouteille)                160 € → 170 €
--   · Vodka Grey Goose (bouteille)              180 € → 200 €
--   · Jack Daniel's, Tanqueray, Rhum Havana 7 ans : inchangés, déjà exacts
--
--  Champagne Richard — Brut (bouteille) avait été retiré en 0041, absent du
--  PDF de référence de l'époque à 75 €. Il réapparaît sur cette nouvelle
--  carte à 70 € : remis dans le seed ET relisté explicitement — un simple
--  ON CONFLICT DO UPDATE ne touche jamais `is_listed`, une venue déjà seedée
--  serait donc restée avec l'article masqué malgré le nouveau prix écrit en
--  base.
--
--  Volontairement laissé de côté : la carte des cocktails/spiritueux au verre
--  (mention vocale d'un « Vodka Red Bull » à 15 €) n'apparaît pas sur cette
--  photo — aucune modification n'est faite sur les univers `drinks` tant que
--  cette partie de la carte n'est pas fournie. Le Champagne Richard AU VERRE
--  (univers drinks) reste retiré : seule la version bouteille est confirmée.
--
--  Food (Bar à tapas / Bar à planches) : déjà identique à la nouvelle carte,
--  aucun changement.
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
  (p_venue,'drinks','Bar à spritz','Spritz','Aperol, prosecco, eau gazeuse',12,true,true,20,1,'[]'),
  (p_venue,'drinks','Bar à spritz','Limoncello Spritz','Limoncello, prosecco, eau gazeuse',13,false,true,20,2,'[]'),
  (p_venue,'drinks','Bar à spritz','Sarti Spritz','Sarti (fruit de la passion, orange sanguine, mangue), prosecco, eau gazeuse',13,false,true,20,3,'[]'),
  (p_venue,'drinks','Bar à spritz','Hugo Spritz','Fleur de sureau, prosecco, eau gazeuse',14,false,true,20,4,'[]'),

  -- --------------------------------------------------------------- COCKTAILS (4 cl)
  (p_venue,'drinks','Cocktails','Mocktail Exotique','Maracuja, banane, mangue, grenadine — sans alcool',10,false,false,10,1,'[]'),
  (p_venue,'drinks','Cocktails','Rive Gauche','Rhum, maracuja, banane, mangue, grenadine',13,true,true,20,2,'[]'),

  -- ------------------------------------------------------------ VINS AU VERRE (12 cl)
  (p_venue,'drinks','Vins au verre','Côtes de Provence AOP — Minuty Prestige 2024','Rosé · 12 cl',10,true,true,20,1,'[]'),
  (p_venue,'drinks','Vins au verre','Pouilly-Fumé AOP — Domaine Minet','Blanc · 12 cl',9,false,true,20,2,'[]'),
  (p_venue,'drinks','Vins au verre','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge · 12 cl',9,false,true,20,3,'[]'),
  (p_venue,'drinks','Vins au verre','Champagne AOP Moët & Chandon — Brut Impérial','Bulles · 12 cl',16,true,true,20,4,'[]'),

  -- ------------------------------------------------------- BIÈRES ARTISANALES (33 cl)
  (p_venue,'drinks','Bières','La Parisienne — Blonde','33 cl',7,true,true,20,1,'[]'),

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

  -- ===================== UNIVERS BOUTEILLES (Commandes de bouteilles) ==========
  (p_venue,'bottles','Vins — Rosés','Côtes de Provence AOP — Minuty Prestige 2024','Rosé de Provence · 75 cl',50,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50},{"id":"150cl","label":"Magnum 150 cl","price":90}]'),
  -- 42 € → 50 € (0051)
  (p_venue,'bottles','Vins — Blancs','Pouilly-Fumé AOP — Domaine Minet','Blanc sec, Loire · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  -- 42 € → 50 € (0051)
  (p_venue,'bottles','Vins — Rouges','Saint-Amour AOP — Domaine des Pierres 2023/24','Rouge, Beaujolais · 75 cl',50,false,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":50}]'),
  -- 75 cl : 90 € → 100 € (0051) — magnum 170 € inchangé
  (p_venue,'bottles','Champagnes','Moët & Chandon — Brut Impérial','Champagne AOP',100,true,true,20,1,
   '[{"id":"75cl","label":"75 cl","price":100},{"id":"150cl","label":"Magnum 150 cl","price":170}]'),
  -- Retour sur la carte à 70 € (0051) — retiré en 0041, absent du PDF de
  -- l'époque à 75 €. Relisté explicitement plus bas : l'upsert ne touche
  -- jamais is_listed.
  (p_venue,'bottles','Champagnes','Champagne Richard — Brut','Champagne AOP',70,false,true,20,2,'[]'),

  -- 160 € → 170 € (0051)
  (p_venue,'bottles','Bouteilles','Vodka Absolut','Bouteille servie à table',170,false,true,20,1,'[]'),
  -- 180 € → 200 € (0051)
  (p_venue,'bottles','Bouteilles','Vodka Grey Goose','Bouteille servie à table',200,true,true,20,2,'[]'),
  (p_venue,'bottles','Bouteilles','Jack Daniel''s','Bouteille servie à table',180,false,true,20,3,'[]'),
  (p_venue,'bottles','Bouteilles','Tanqueray','Bouteille servie à table',180,false,true,20,4,'[]'),
  (p_venue,'bottles','Bouteilles','Rhum Havana 7 ans','Bouteille servie à table',180,false,true,20,5,'[]')
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

  -- Delistage : catégories entières et articles isolés absents du PDF de
  -- référence, sur les venues déjà seedées. Historique des commandes déjà
  -- passées préservé (delist, jamais delete).
  --
  -- Champagne AOP Richard — Brut AU VERRE (univers drinks) reste dans cette
  -- liste : seule la version bouteille est confirmée de retour, la carte des
  -- cocktails/verre n'a pas été revue.
  update public.products
     set is_listed = false
   where venue_id = p_venue
     and universe = 'drinks'
     and (
       subcategory in ('Détox Bio', 'Digestifs', 'Apéritifs')
       or name in (
         'IGP Pays d''Oc — Ecoterra Chardonnay BIO 2023/24',
         'IGP Méditerranée — Ponton 7 2024',
         'Moscow Mule',
         'Bordeaux AOP — James Deschartrons 2021/22',
         'Champagne AOP Richard — Brut',
         'La Parisienne — IPA',
         'La Parisienne — Blanche',
         'Johnnie Walker — Blue Label'
       )
     );

  -- Champagne Richard — Brut EN BOUTEILLE : relisté (0051), voir plus haut.
  update public.products
     set is_listed = true
   where venue_id = p_venue
     and universe = 'bottles'
     and name = 'Champagne Richard — Brut';

  return n;
end;
$$;

grant execute on function public.seed_noti_menu(uuid) to authenticated;

-- ============================================================================
--  0023 — Regroupement des sous-catégories « Boissons »
--
--  Retour terrain : « il y a désormais trop de sous-catégories pour ce type
--  d'établissement, où les commandes restent simples. Une catégorie pour deux
--  produits (ex. Pisco & Cachaça), c'est trop. »
--
--  L'univers Boissons passe de 14 sections à 8 :
--
--    Vodka · Gin · Rhum · Whisky · Mezcal & Tequila · Pisco & Cachaça
--                                                        → Spiritueux  (38 réf.)
--    Softs · Détox Bio                                    → Softs       (12 réf.)
--
--  Conservées telles quelles :
--    · Bar à spritz — c'est une signature de la maison, pas un rangement ;
--    · Digestifs — 12 références, ce n'est pas « peu » ;
--    · Cocktails, Apéritifs, Vins au verre, Bières.
--
--  Food (À grignoter / À partager) et Bouteilles (rosé / rouge / champagne)
--  sont déjà bien dimensionnés : on n'y touche pas.
--
--  PRUDENCE : cette migration réécrit la carte du lieu. Elle ne s'exécute que
--  s'il reste des sections nommées à l'ancienne — si le staff a déjà réorganisé
--  sa carte depuis l'éditeur, elle ne fait rien. Tout reste modifiable ensuite
--  dans l'onglet Carte.
--
--  L'application trie par (universe, sort_order) : ce champ porte donc à la
--  fois l'ordre des sections et l'ordre à l'intérieur d'une section. D'où le
--  calcul en fin de bloc, section × 1000 + rang interne.
-- ============================================================================

do $$
declare
  v_sections text[] := array[
    'Bar à spritz', 'Cocktails', 'Apéritifs', 'Spiritueux',
    'Vins au verre', 'Bières', 'Softs', 'Digestifs'
  ];
  v_nom text;
  v_i   int := 0;
begin
  -- Garde d'idempotence : rien à regrouper = on sort sans rien réécrire. Sans
  -- elle, un second passage recomposerait les sort_order par-dessus les
  -- premiers et mélangerait l'ordre interne des sections.
  if not exists (
    select 1 from public.products
     where universe = 'drinks'
       and subcategory in (
         'Whisky', 'Gin', 'Rhum', 'Vodka', 'Mezcal & Tequila', 'Pisco & Cachaça', 'Détox Bio'
       )
  ) then
    raise notice '0023 : sous-catégories déjà regroupées, rien à faire.';
    return;
  end if;

  -- 1. Les spiritueux dans une seule section. Les familles restent groupées
  --    entre elles (whisky, puis gin, puis rhum…) et le tri d'origine est
  --    conservé à l'intérieur de chaque famille.
  update public.products p
     set subcategory = 'Spiritueux',
         sort_order  = f.rang * 100 + least(f.sort_order, 99)
    from (
      select
        id,
        case subcategory
          when 'Whisky'           then 1
          when 'Gin'              then 2
          when 'Rhum'             then 3
          when 'Vodka'            then 4
          when 'Mezcal & Tequila' then 5
          when 'Pisco & Cachaça'  then 6
        end as rang,
        sort_order
      from public.products
      where universe = 'drinks'
        and subcategory in ('Whisky', 'Gin', 'Rhum', 'Vodka', 'Mezcal & Tequila', 'Pisco & Cachaça')
    ) f
   where p.id = f.id;

  -- 2. Les boissons sans alcool dans une seule section, « Détox Bio » derrière
  --    les softs classiques.
  update public.products
     set subcategory = 'Softs',
         sort_order  = 700 + least(sort_order, 99)
   where universe = 'drinks'
     and subcategory = 'Détox Bio';

  -- 3. Ordre des sections : du plus commandé au plus rare. Les spritz et les
  --    cocktails ouvrent la carte, les digestifs la ferment.
  foreach v_nom in array v_sections loop
    v_i := v_i + 1;
    update public.products
       set sort_order = v_i * 1000 + least(sort_order, 999)
     where universe = 'drinks'
       and subcategory = v_nom;
  end loop;
end $$;

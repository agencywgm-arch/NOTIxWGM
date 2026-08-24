-- ============================================================================
--  0025 — Deux fusions de plus, et un libellé de bouteilles enfin clair
--
--  Retour terrain, bloc 6 :
--
--  · « Encore deux fusions proposées : Apéritifs → Spiritueux ; Digestifs → à
--    intégrer dans une autre catégorie pertinente. »
--    Les deux vont dans Spiritueux : ce sont des alcools forts servis au verre,
--    la seule différence est le moment de la soirée. Dans la section, les
--    apéritifs ouvrent et les digestifs ferment.
--
--  · « La dernière catégorie nommée simplement Bouteille n'est pas claire — il
--    s'agit du hard. » → « Bouteilles — alcools forts ».
--
--  · « On garde Spritz / Cocktails en premier (retour client direct à
--    l'appui). » → ordre conservé.
--
--  L'ordre est RECALCULÉ de zéro sur tout l'univers Boissons, par rang dense
--  (section × 1000 + rang dans la section). Empiler un nouveau multiplicateur
--  sur celui de 0023 écrasait l'ordre interne : les valeurs dépassaient le
--  plafond et retombaient toutes sur le même nombre. Un rang dense ne peut pas
--  déborder, et rejouer la migration redonne exactement le même résultat.
--
--  À NOTER : Spiritueux regroupe ensuite une soixantaine de références. C'est
--  le prix du regroupement demandé ; si la section devient trop longue à
--  l'usage, la scinder se fait dans l'éditeur de carte, sans migration.
-- ============================================================================

do $$
declare
  -- Ordre d'affichage des sections, du plus commandé au plus rare.
  v_sections text[] := array[
    'Bar à spritz', 'Cocktails', 'Spiritueux', 'Vins au verre', 'Bières', 'Softs'
  ];
begin
  if not exists (
    select 1 from public.products
     where universe = 'drinks' and subcategory in ('Apéritifs', 'Digestifs')
  ) then
    raise notice '0025 : apéritifs et digestifs déjà regroupés, rien à faire.';
    return;
  end if;

  -- 1. Les apéritifs passent devant les spiritueux déjà en place (0023 les a
  --    numérotés à partir de 100), les digestifs passent derrière.
  update public.products
     set subcategory = 'Spiritueux',
         sort_order  = least(sort_order, 99)
   where universe = 'drinks' and subcategory = 'Apéritifs';

  update public.products
     set subcategory = 'Spiritueux',
         sort_order  = 900000 + least(sort_order, 999)
   where universe = 'drinks' and subcategory = 'Digestifs';

  -- 2. Renumérotation dense de tout l'univers, à partir de l'ordre courant.
  --    Les sections inconnues du tableau (une section ajoutée à la main par le
  --    staff) sont rangées après, sans être touchées dans leur ordre interne.
  with ranked as (
    select
      p.id,
      coalesce(array_position(v_sections, p.subcategory), array_length(v_sections, 1) + 1) as sec,
      row_number() over (
        partition by p.subcategory
        order by p.sort_order, p.name
      ) as rn
    from public.products p
    where p.universe = 'drinks'
  )
  update public.products p
     set sort_order = r.sec * 1000 + least(r.rn, 999)
    from ranked r
   where p.id = r.id;
end $$;


-- ---------------------------------------------------------------------------
--  Bouteilles : « Bouteilles » tout court désignait le hard, ce que personne
--  ne devinait. Les vins et champagnes étaient déjà explicites.
-- ---------------------------------------------------------------------------
update public.products
   set subcategory = 'Bouteilles — alcools forts'
 where universe = 'bottles'
   and subcategory = 'Bouteilles';

-- ============================================================================
--  0027 — Le mocktail rejoint les softs
--
--  Retour terrain, 7.3 : « les mocktails sont actuellement dans Cocktails. Ils
--  doivent aller dans Softs. » Une seule référence concernée : Mocktail
--  Exotique, sans alcool, historiquement rangé avec les cocktails alcoolisés.
--
--  Le nouveau rang est calculé (max + 1 dans Softs), pas codé en dur : il
--  reste juste quelle que soit la taille de la section au moment où cette
--  migration s'exécute. Idempotent — si le produit est déjà dans Softs, ou
--  n'existe pas (carte reconstruite autrement), la clause where ne trouve
--  rien et la mise à jour ne fait rien.
-- ============================================================================

update public.products p
   set subcategory = 'Softs',
       sort_order  = coalesce(
         (select max(sort_order) + 1 from public.products
           where venue_id = p.venue_id and universe = 'drinks' and subcategory = 'Softs'),
         1
       )
 where p.universe = 'drinks'
   and p.subcategory = 'Cocktails'
   and p.is_alcohol = false
   and p.name = 'Mocktail Exotique';

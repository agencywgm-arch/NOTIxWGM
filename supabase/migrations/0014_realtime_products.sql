-- ============================================================================
--  NOTI Calling — 0014_realtime_products.sql
--
--  Rupture de stock en temps réel (retour terrain, point 3.1).
--
--  Le staff pouvait déjà marquer un article « épuisé » depuis la tablette,
--  mais la table products n'était pas publiée en Realtime : côté client, la
--  carte ne se mettait à jour qu'au rechargement de la page. Un client
--  pouvait donc commander un article épuisé plusieurs minutes durant, et se
--  faire refuser la commande au moment de l'envoi (product_unavailable).
--
--  Avec ce patch, le basculement « épuisé » se propage instantanément à tous
--  les téléphones connectés : l'article reste visible mais devient
--  non commandable, sans que personne n'ait à recharger quoi que ce soit.
-- ============================================================================

alter table public.products replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.products;
  exception when duplicate_object then null;
  end;
end $$;

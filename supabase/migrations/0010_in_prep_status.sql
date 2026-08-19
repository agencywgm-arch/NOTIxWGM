-- ============================================================================
--  NOTI Calling — 0010_in_prep_status.sql
--
--  Ajoute une étape « En préparation » entre "Reçue" et "Prête" côté Bar,
--  pour que le staff puisse distinguer une commande pas encore prise en
--  charge d'une commande en cours de préparation au bar/cuisine.
--
--  IMPORTANT : ce fichier doit être exécuté SEUL (Run), puis 0011 ensuite
--  dans un second Run séparé. PostgreSQL interdit d'utiliser une nouvelle
--  valeur d'enum dans la même transaction que celle qui l'a créée.
-- ============================================================================

alter type public.order_status add value if not exists 'IN_PREP' after 'RECEIVED';

-- ============================================================================
--  0036 — Nouveau statut « En attente de règlement »
--
--  Note technique du 23/08, §2 : « pour toute commande contenant de la food,
--  le chronomètre de préparation ne démarre qu'après encaissement en caisse ».
--
--  ⚠️  CE FICHIER DOIT ÊTRE EXÉCUTÉ SEUL (un « Run »), puis 0037 dans un
--      SECOND Run séparé. PostgreSQL interdit d'utiliser une nouvelle valeur
--      d'enum dans la transaction qui vient de la créer — même contrainte
--      qu'en 0010 / 0011 pour « IN_PREP ».
--
--  Position dans l'énumération : AVANT 'RECEIVED'. L'ordre des valeurs d'un
--  enum sert au tri, et cette étape précède bien la prise en charge au bar.
-- ============================================================================

alter type public.order_status add value if not exists 'AWAITING_PAYMENT' before 'RECEIVED';

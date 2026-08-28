-- ============================================================================
--  NOTI Calling — 0042_regrouper_food_bar_a_tapas.sql
--  Alignement des sous-catégories food sur la carte imprimée.
--
--  seed_noti_food() (0019) rangeait les 8 plats sous « À grignoter » /
--  « À partager », un découpage inventé pour l'app. La carte imprimée en a
--  un autre : « BAR A TAPAS » (6 plats, y compris Straciatella et Fritto
--  misto) et « BAR A PLANCHES » (les 2 planches, séparément — pas mélangées
--  avec Straciatella/Fritto misto comme c'était le cas dans « À partager »).
--
--  UPDATE ciblée plutôt que redéfinition de seed_noti_food() : cette
--  dernière embarque une illustration par plat encodée en base64 (plusieurs
--  dizaines de Ko chacune) — les reproduire à la main dans une nouvelle
--  migration risquerait de corrompre une image sur une seule faute de frappe
--  invisible à la relecture. Ici on ne touche qu'au nom de sous-catégorie et
--  au rang d'affichage, jamais à `image_url`.
--
--  Limite acceptée : un tout nouveau lieu qui exécute seed_noti_food() pour
--  la première fois après cette migration recevra encore l'ancien découpage
--  (À grignoter / À partager) — il faudra relancer ce correctif pour lui
--  aussi. Sans conséquence pratique pour Noti Club, seul établissement actif
--  à ce jour.
-- ============================================================================

do $$
declare v record;
begin
  for v in select id from public.venues loop
    update public.products
       set subcategory = 'Bar à tapas',
           sort_order = case name
             when 'Cornet de frites'     then 1
             when 'Houmous pistache'     then 2
             when 'Tempura poulet'       then 3
             when 'Noti croque truffé'   then 4
             when 'Straciatella'         then 5
             when 'Fritto misto'         then 6
             else sort_order
           end
     where venue_id = v.id
       and universe = 'food'
       and name in (
         'Cornet de frites', 'Houmous pistache', 'Tempura poulet',
         'Noti croque truffé', 'Straciatella', 'Fritto misto'
       );

    update public.products
       set subcategory = 'Bar à planches',
           sort_order = case name
             when 'Planche charcuterie' then 1
             when 'Planche fromages'    then 2
             else sort_order
           end
     where venue_id = v.id
       and universe = 'food'
       and name in ('Planche charcuterie', 'Planche fromages');
  end loop;
end $$;

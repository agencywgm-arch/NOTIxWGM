-- ============================================================================
--  NOTI Calling — 0048_traduction_carte.sql
--  Traduction de la carte en anglais, espagnol, russe et mandarin.
--
--  Retour du test terrain : changer la langue ne traduisait que l'interface,
--  la carte restait en français. Le mécanisme existait pourtant déjà —
--  products.translations et trProduct() — mais aucune traduction n'avait
--  jamais été saisie.
--
--  Traduction écrite en dur plutôt que produite par la fonction de traduction
--  automatique du dépôt (translate-menu) : celle-ci demande un déploiement
--  Supabase et une clé API Anthropic facturée à l'usage, alors que la carte
--  est désormais stabilisée sur le PDF de référence. À refaire à la main si
--  la carte change — c'est le prix de l'absence d'infrastructure.
--
--  Ce qu'on ne traduit PAS, volontairement :
--   · les marques et noms propres (Absolut, Hendrick's, Moët & Chandon,
--     Zacapa…) — un client cherche l'étiquette qu'il connaît ;
--   · les noms de cocktails établis (Spritz, Hugo, Mocktail) ;
--   · les appellations viticoles (Côtes de Provence AOP, Pouilly-Fumé) —
--     ce sont des mentions légales protégées ;
--   · les contenances (33 cl, 75 cl), lisibles partout.
--  Un article sans entrée ici affiche son libellé d'origine : c'est le repli
--  prévu par trProduct(), et c'est le bon comportement pour une marque.
--
--  Fusion plutôt qu'écrasement (`translations || ...`) : une traduction déjà
--  saisie à la main dans l'éditeur de carte n'est pas perdue.
-- ============================================================================

do $$
declare
  v record;
  v_tr jsonb;
  v_name text;
begin
  for v in select id from public.venues loop

    -- ------------------------------------------------------------- BOISSONS
    for v_name, v_tr in
      select * from (values
        ('Spritz', '{"en":{"description":"Aperol, prosecco, sparkling water"},"es":{"description":"Aperol, prosecco, agua con gas"},"ru":{"description":"Апероль, просекко, газированная вода"},"zh":{"description":"Aperol、普罗塞克、气泡水"}}'::jsonb),
        ('Limoncello Spritz', '{"en":{"description":"Limoncello, prosecco, sparkling water"},"es":{"description":"Limoncello, prosecco, agua con gas"},"ru":{"description":"Лимончелло, просекко, газированная вода"},"zh":{"description":"柠檬酒、普罗塞克、气泡水"}}'::jsonb),
        ('Sarti Spritz', '{"en":{"description":"Sarti (passion fruit, blood orange, mango), prosecco, sparkling water"},"es":{"description":"Sarti (maracuyá, naranja sanguina, mango), prosecco, agua con gas"},"ru":{"description":"Sarti (маракуйя, красный апельсин, манго), просекко, газированная вода"},"zh":{"description":"Sarti（百香果、血橙、芒果）、普罗塞克、气泡水"}}'::jsonb),
        ('Hugo Spritz', '{"en":{"description":"Elderflower, prosecco, sparkling water"},"es":{"description":"Flor de saúco, prosecco, agua con gas"},"ru":{"description":"Цветы бузины, просекко, газированная вода"},"zh":{"description":"接骨木花、普罗塞克、气泡水"}}'::jsonb),
        ('Mocktail Exotique', '{"en":{"name":"Exotic Mocktail","description":"Passion fruit, banana, mango, grenadine — alcohol-free"},"es":{"name":"Mocktail Exótico","description":"Maracuyá, plátano, mango, granadina — sin alcohol"},"ru":{"name":"Экзотический моктейль","description":"Маракуйя, банан, манго, гренадин — без алкоголя"},"zh":{"name":"热带无酒精调饮","description":"百香果、香蕉、芒果、红石榴糖浆——不含酒精"}}'::jsonb),
        ('Rive Gauche', '{"en":{"description":"Rum, passion fruit, banana, mango, grenadine"},"es":{"description":"Ron, maracuyá, plátano, mango, granadina"},"ru":{"description":"Ром, маракуйя, банан, манго, гренадин"},"zh":{"description":"朗姆酒、百香果、香蕉、芒果、红石榴糖浆"}}'::jsonb),

        ('Côtes de Provence AOP — Minuty Prestige 2024', '{"en":{"description":"Rosé · 12 cl"},"es":{"description":"Rosado · 12 cl"},"ru":{"description":"Розовое · 12 cl"},"zh":{"description":"桃红 · 12 cl"}}'::jsonb),
        ('Pouilly-Fumé AOP — Domaine Minet', '{"en":{"description":"White · 12 cl"},"es":{"description":"Blanco · 12 cl"},"ru":{"description":"Белое · 12 cl"},"zh":{"description":"白葡萄酒 · 12 cl"}}'::jsonb),
        ('Saint-Amour AOP — Domaine des Pierres 2023/24', '{"en":{"description":"Red · 12 cl"},"es":{"description":"Tinto · 12 cl"},"ru":{"description":"Красное · 12 cl"},"zh":{"description":"红葡萄酒 · 12 cl"}}'::jsonb),
        ('Champagne AOP Moët & Chandon — Brut Impérial', '{"en":{"description":"Sparkling · 12 cl"},"es":{"description":"Burbujas · 12 cl"},"ru":{"description":"Игристое · 12 cl"},"zh":{"description":"气泡 · 12 cl"}}'::jsonb),

        ('La Parisienne — Blonde', '{"en":{"name":"La Parisienne — Lager"},"es":{"name":"La Parisienne — Rubia"},"ru":{"name":"La Parisienne — светлое"},"zh":{"name":"La Parisienne — 金色艾尔"}}'::jsonb),

        ('Jus d''orange', '{"en":{"name":"Orange juice"},"es":{"name":"Zumo de naranja"},"ru":{"name":"Апельсиновый сок"},"zh":{"name":"鲜橙汁"}}'::jsonb),
        ('Jus de pomme', '{"en":{"name":"Apple juice"},"es":{"name":"Zumo de manzana"},"ru":{"name":"Яблочный сок"},"zh":{"name":"苹果汁"}}'::jsonb),
        ('Jus d''ananas', '{"en":{"name":"Pineapple juice"},"es":{"name":"Zumo de piña"},"ru":{"name":"Ананасовый сок"},"zh":{"name":"菠萝汁"}}'::jsonb),
        ('Lipton Ice Tea Pêche', '{"en":{"name":"Lipton Ice Tea Peach"},"es":{"name":"Lipton Ice Tea Melocotón"},"ru":{"name":"Lipton Ice Tea персик"},"zh":{"name":"Lipton 蜜桃冰红茶"}}'::jsonb),

        ('Havana 3 ans', '{"en":{"name":"Havana 3 years"},"es":{"name":"Havana 3 años"},"ru":{"name":"Havana 3 года"},"zh":{"name":"Havana 3 年"}}'::jsonb),
        ('Glenfiddich — Triple Oak 12 ans', '{"en":{"name":"Glenfiddich — Triple Oak 12 years"},"es":{"name":"Glenfiddich — Triple Oak 12 años"},"ru":{"name":"Glenfiddich — Triple Oak 12 лет"},"zh":{"name":"Glenfiddich — Triple Oak 12 年"}}'::jsonb),
        ('Lagavulin 8 ans', '{"en":{"name":"Lagavulin 8 years"},"es":{"name":"Lagavulin 8 años"},"ru":{"name":"Lagavulin 8 лет"},"zh":{"name":"Lagavulin 8 年"}}'::jsonb),
        ('Chivas Regal 18 ans', '{"en":{"name":"Chivas Regal 18 years"},"es":{"name":"Chivas Regal 18 años"},"ru":{"name":"Chivas Regal 18 лет"},"zh":{"name":"Chivas Regal 18 年"}}'::jsonb),
        ('G''Vine June Pêche', '{"en":{"name":"G''Vine June Peach"},"es":{"name":"G''Vine June Melocotón"},"ru":{"name":"G''Vine June персик"},"zh":{"name":"G''Vine June 蜜桃"}}'::jsonb)
      ) as x(n, t)
    loop
      update public.products
         set translations = coalesce(translations, '{}'::jsonb) || v_tr
       where venue_id = v.id and universe = 'drinks' and name = v_name;
    end loop;

    -- ---------------------------------------------------------- BOUTEILLES
    for v_name, v_tr in
      select * from (values
        ('Côtes de Provence AOP — Minuty Prestige 2024', '{"en":{"description":"Provence rosé · 75 cl"},"es":{"description":"Rosado de Provenza · 75 cl"},"ru":{"description":"Розовое из Прованса · 75 cl"},"zh":{"description":"普罗旺斯桃红 · 75 cl"}}'::jsonb),
        ('Pouilly-Fumé AOP — Domaine Minet', '{"en":{"description":"Dry white, Loire · 75 cl"},"es":{"description":"Blanco seco, Loira · 75 cl"},"ru":{"description":"Белое сухое, Луара · 75 cl"},"zh":{"description":"干白，卢瓦尔 · 75 cl"}}'::jsonb),
        ('Saint-Amour AOP — Domaine des Pierres 2023/24', '{"en":{"description":"Red, Beaujolais · 75 cl"},"es":{"description":"Tinto, Beaujolais · 75 cl"},"ru":{"description":"Красное, Божоле · 75 cl"},"zh":{"description":"红葡萄酒，博若莱 · 75 cl"}}'::jsonb),
        ('Moët & Chandon — Brut Impérial', '{"en":{"description":"Champagne AOP"},"es":{"description":"Champán AOP"},"ru":{"description":"Шампанское AOP"},"zh":{"description":"香槟 AOP"}}'::jsonb),
        ('Vodka Absolut', '{"en":{"name":"Absolut Vodka","description":"Bottle served at your table"},"es":{"name":"Vodka Absolut","description":"Botella servida en la mesa"},"ru":{"name":"Водка Absolut","description":"Бутылка с подачей за стол"},"zh":{"name":"Absolut 伏特加","description":"整瓶送至您的桌"}}'::jsonb),
        ('Vodka Grey Goose', '{"en":{"name":"Grey Goose Vodka","description":"Bottle served at your table"},"es":{"name":"Vodka Grey Goose","description":"Botella servida en la mesa"},"ru":{"name":"Водка Grey Goose","description":"Бутылка с подачей за стол"},"zh":{"name":"Grey Goose 伏特加","description":"整瓶送至您的桌"}}'::jsonb),
        ('Jack Daniel''s', '{"en":{"description":"Bottle served at your table"},"es":{"description":"Botella servida en la mesa"},"ru":{"description":"Бутылка с подачей за стол"},"zh":{"description":"整瓶送至您的桌"}}'::jsonb),
        ('Tanqueray', '{"en":{"description":"Bottle served at your table"},"es":{"description":"Botella servida en la mesa"},"ru":{"description":"Бутылка с подачей за стол"},"zh":{"description":"整瓶送至您的桌"}}'::jsonb),
        ('Rhum Havana 7 ans', '{"en":{"name":"Havana 7 years Rum","description":"Bottle served at your table"},"es":{"name":"Ron Havana 7 años","description":"Botella servida en la mesa"},"ru":{"name":"Ром Havana 7 лет","description":"Бутылка с подачей за стол"},"zh":{"name":"Havana 7 年朗姆酒","description":"整瓶送至您的桌"}}'::jsonb)
      ) as x(n, t)
    loop
      update public.products
         set translations = coalesce(translations, '{}'::jsonb) || v_tr
       where venue_id = v.id and universe = 'bottles' and name = v_name;
    end loop;

    -- ----------------------------------------------------------------- FOOD
    for v_name, v_tr in
      select * from (values
        ('Cornet de frites', '{"en":{"name":"Cone of fries","description":"Fresh-cut fries, sea salt"},"es":{"name":"Cono de patatas fritas","description":"Patatas frescas, flor de sal"},"ru":{"name":"Картофель фри","description":"Свежий картофель фри, морская соль"},"zh":{"name":"薯条杯","description":"现切薯条、海盐"}}'::jsonb),
        ('Houmous pistache', '{"en":{"name":"Pistachio hummus","description":"Chickpeas, pistachio, olive oil, toasted bread"},"es":{"name":"Hummus de pistacho","description":"Garbanzos, pistacho, aceite de oliva, pan tostado"},"ru":{"name":"Хумус с фисташкой","description":"Нут, фисташка, оливковое масло, тосты"},"zh":{"name":"开心果鹰嘴豆泥","description":"鹰嘴豆、开心果、橄榄油、烤面包"}}'::jsonb),
        ('Tempura poulet', '{"en":{"name":"Chicken tempura","description":"Tempura chicken, house sauce"},"es":{"name":"Tempura de pollo","description":"Pollo en tempura, salsa de la casa"},"ru":{"name":"Курица в темпуре","description":"Курица в темпуре, фирменный соус"},"zh":{"name":"天妇罗炸鸡","description":"天妇罗炸鸡、招牌酱汁"}}'::jsonb),
        ('Noti croque truffé', '{"en":{"name":"Noti truffle croque","description":"Toasted cheese sandwich with melted cheese and truffle shavings"},"es":{"name":"Croque trufado Noti","description":"Sándwich caliente con queso fundido y virutas de trufa"},"ru":{"name":"Noti крок с трюфелем","description":"Горячий сэндвич с расплавленным сыром и стружкой трюфеля"},"zh":{"name":"Noti 松露热三明治","description":"融化芝士热三明治，配松露碎"}}'::jsonb),
        ('Straciatella', '{"en":{"description":"Creamy stracciatella, olive oil, basil"},"es":{"description":"Stracciatella cremosa, aceite de oliva, albahaca"},"ru":{"description":"Кремовая страчателла, оливковое масло, базилик"},"zh":{"description":"绵密 stracciatella 奶酪、橄榄油、罗勒"}}'::jsonb),
        ('Fritto misto', '{"en":{"description":"Fried vegetables and seafood, lemon"},"es":{"description":"Fritura de verduras y marisco, limón"},"ru":{"description":"Жареные овощи и морепродукты, лимон"},"zh":{"description":"炸蔬菜与海鲜、柠檬"}}'::jsonb),
        ('Planche charcuterie', '{"en":{"name":"Charcuterie board","description":"Selection of cured meats, gherkins, olives"},"es":{"name":"Tabla de embutidos","description":"Surtido de embutidos, pepinillos, aceitunas"},"ru":{"name":"Мясная доска","description":"Ассорти мясных деликатесов, корнишоны, оливки"},"zh":{"name":"风干肉拼盘","description":"风干肉拼盘、酸黄瓜、橄榄"}}'::jsonb),
        ('Planche fromages', '{"en":{"name":"Cheese board","description":"Selection of matured cheeses, grapes, walnuts, honey"},"es":{"name":"Tabla de quesos","description":"Surtido de quesos curados, uvas, nueces, miel"},"ru":{"name":"Сырная доска","description":"Ассорти выдержанных сыров, виноград, грецкий орех, мёд"},"zh":{"name":"芝士拼盘","description":"熟成芝士拼盘、葡萄、核桃、蜂蜜"}}'::jsonb)
      ) as x(n, t)
    loop
      update public.products
         set translations = coalesce(translations, '{}'::jsonb) || v_tr
       where venue_id = v.id and universe = 'food' and name = v_name;
    end loop;

  end loop;
end $$;

-- Les langues proposées au client sont portées par la soirée. Sans cet ajout,
-- le sélecteur ne montrerait toujours que FR/EN/ES et les traductions
-- ci-dessus resteraient invisibles.
alter table public.events alter column languages set default '{fr,en,es,ru,zh}';

-- Ajout en fin de liste, sans retrier : le premier élément sert de langue par
-- défaut quand le client arrive dans une langue non proposée (voir ClientApp).
-- Un tri, même stable, pourrait faire basculer une soirée en chinois.
update public.events
   set languages = languages || array(
     select l from unnest('{ru,zh}'::text[]) as l where not (languages @> array[l])
   )
 where not (languages @> '{ru,zh}');

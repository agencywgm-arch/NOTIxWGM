-- ============================================================================
--  NOTI Calling — 0047_rang_file_attente.sql
--  Combien de personnes ont commandé avant moi et attendent encore.
--
--  Remplace l'heure de disponibilité estimée affichée au client. Un temps
--  annoncé est une promesse que le bar ne tient pas toujours un soir de
--  rush : elle produit des réclamations. Un rang dans la file, non — il ne
--  promet rien, il situe, et il descend tout seul sous les yeux du client.
--
--  Ne comptent que les commandes réellement dans la file : reçues et en
--  préparation. Une commande en attente de règlement (food non encaissée)
--  n'occupe pas encore le bar, elle ne compte donc pas.
--
--  Le résultat ne dit rien qu'un inconnu puisse exploiter — un simple
--  décompte — mais la fonction n'accepte quand même que les commandes de
--  l'appelant : un identifiant de commande qui n'est pas le sien ne
--  joint rien et renvoie 0.
-- ============================================================================

create or replace function public.orders_ahead(p_order uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.orders me
    join public.customers c
      on c.id = me.customer_id
     and c.auth_user_id = auth.uid()
    join public.orders o
      on o.event_id = me.event_id
     and o.status in ('RECEIVED', 'IN_PREP')
     and o.created_at < me.created_at
   where me.id = p_order;
$$;

grant execute on function public.orders_ahead(uuid) to authenticated;

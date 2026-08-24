-- ============================================================================
--  0033 — assistant_rate_ok : ne plus accepter d'identifiant client en entrée
--
--  Revue de code. La version de 0031 prenait le client en paramètre :
--
--      assistant_rate_ok(p_event uuid, p_customer uuid)
--
--  Fonction `security definer`, donc sans RLS : n'importe quel compte
--  authentifié pouvait l'appeler avec l'identifiant d'un AUTRE client et
--  apprendre s'il avait écrit à l'assistant dans les cinq dernières minutes.
--  Fuite mineure — un booléen — mais gratuite à supprimer : la fonction n'a
--  jamais eu besoin qu'on lui dise qui appelle, elle peut le déduire.
--
--  L'ancienne signature est retirée : la laisser en place laisserait le
--  chemin ouvert, une surcharge ne la remplaçant pas.
-- ============================================================================

drop function if exists public.assistant_rate_ok(uuid, uuid);

create or replace function public.assistant_rate_ok(p_event uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select count(*) < 12
  from public.client_assistant_messages
  where event_id = p_event
    and customer_id = public.my_customer_id()
    and role = 'user'
    and created_at >= now() - interval '5 minutes';
$$;

grant execute on function public.assistant_rate_ok(uuid) to authenticated, service_role;

comment on function public.assistant_rate_ok(uuid) is
  'Débit de l''assistant client : au plus 12 questions par tranche de 5 min. '
  'Le client est déduit de la session (my_customer_id), jamais fourni par '
  'l''appelant.';

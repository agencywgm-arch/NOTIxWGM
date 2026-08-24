-- ============================================================================
--  0031 — Assistant IA côté client
--
--  Retour terrain : « un agent copilote pour les clients qui ont des
--  questions pour commande ou besoin d'aide ». Choix acté : une vraie IA
--  (pas une simple FAQ), qui répond en langage naturel sur la carte, le
--  statut d'une commande, les crédits — via l'Edge Function client-assistant
--  (secret ANTHROPIC_API_KEY déjà configuré, utilisé par translate-menu).
--
--  Cette migration ne fait QUE stocker l'historique de la conversation :
--  · pour que le client retrouve son fil en rouvrant l'app,
--  · pour que le staff puisse relire ce qui a été demandé (lecture seule),
--  · et pour limiter le débit côté serveur (compter les messages récents
--    d'un même client, sans dépendre d'un état en mémoire de l'Edge
--    Function, qui redémarre à froid entre les appels).
-- ============================================================================

create table if not exists public.client_assistant_messages (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  role        text not null check (role in ('user', 'assistant')),
  content     text not null,
  created_at  timestamptz not null default now()
);

create index if not exists client_assistant_messages_thread_idx
  on public.client_assistant_messages (event_id, customer_id, created_at);

alter table public.client_assistant_messages enable row level security;

-- Le client ne voit et n'écrit que son propre fil.
drop policy if exists client_assistant_messages_own on public.client_assistant_messages;
create policy client_assistant_messages_own on public.client_assistant_messages
  for select to authenticated
  using (customer_id = public.my_customer_id());

-- L'écriture passe uniquement par l'Edge Function (service_role) : c'est elle
-- qui compose la question ET la réponse dans le même échange, pour ne jamais
-- persister une question sans réponse (ou l'inverse) si l'appel IA échoue en
-- cours de route.
drop policy if exists client_assistant_messages_staff_read on public.client_assistant_messages;
create policy client_assistant_messages_staff_read on public.client_assistant_messages
  for select to authenticated
  using (public.is_event_staff(event_id));

comment on table public.client_assistant_messages is
  'Historique de conversation avec l''assistant IA côté client. Écrit '
  'uniquement par l''Edge Function client-assistant (service_role) ; lu par '
  'le client (son propre fil) et par le staff de la soirée (lecture seule).';

-- ---------------------------------------------------------------------------
--  Débit : au plus 12 messages client sur les 5 dernières minutes, par
--  personne — large pour un usage normal, assez bas pour borner le coût si
--  un téléphone reste ouvert sur la conversation.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_rate_ok(p_event uuid, p_customer uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select count(*) < 12
  from public.client_assistant_messages
  where event_id = p_event and customer_id = p_customer
    and role = 'user'
    and created_at >= now() - interval '5 minutes';
$$;

grant execute on function public.assistant_rate_ok(uuid, uuid) to authenticated, service_role;

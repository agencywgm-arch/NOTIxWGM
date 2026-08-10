// ============================================================================
//  NOTI Calling — Edge Function : notify
//  Couche relationnelle (§09) : notification de statut, diffusion à toute la
//  soirée, ou message individuel de l'organisateur vers un client.
//
//  Body :
//   { eventId, kind: "status"|"broadcast"|"individual",
//     body, title?, customerId?, orderId?, channels?: ["push","sms"] }
//
//  Secrets : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT,
//            SMS_PROVIDER (+ secrets du fournisseur choisi)
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import { json, preflight } from '../_shared/cors.ts'
import { dispatch, type NotifyInput } from '../_shared/dispatch.ts'

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  let input: NotifyInput
  try {
    input = await req.json()
  } catch {
    return json({ error: 'JSON invalide' }, 400)
  }
  if (!input?.eventId || !input?.body) return json({ error: 'eventId et body requis' }, 400)

  // Diffusion et message individuel : réservés au staff de l'événement.
  // On rejoue la vérification avec le JWT de l'appelant, pas avec service_role.
  const authHeader = req.headers.get('Authorization') ?? ''
  const caller = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  )
  const { data: allowed, error } = await caller.rpc('is_event_staff', { p_event: input.eventId })
  if (error || !allowed) return json({ error: 'forbidden' }, 403)

  try {
    return json(await dispatch(input))
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})

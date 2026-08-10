// ============================================================================
//  NOTI Calling — Edge Function : reminders (déclenchée par cron, ~1 ×/min)
//
//  Deux relances automatiques prévues par la feuille de route (§09) :
//   1. Commande prête non retirée depuis 5 min → relance simple.
//   2. Une heure avant la fermeture → relance renforcée, volontairement
//      impactante, avec la conséquence explicite en cas de non-retrait.
//
//  Sécurité : la fonction n'agit que si l'appelant présente CRON_SECRET
//  (en-tête x-cron-secret) ou la clé service_role.
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import { json, preflight } from '../_shared/cors.ts'
import { dispatch } from '../_shared/dispatch.ts'

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

const CRON_SECRET = Deno.env.get('CRON_SECRET') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

const CLOSING_MESSAGE =
  'Venez récupérer votre commande immédiatement : le bar ferme très bientôt et votre commande est prête. ' +
  'Passé la fermeture, toute commande non retirée reste due et vous sera facturée, même si elle ne peut plus être servie.'

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  const auth = req.headers.get('Authorization') ?? ''
  const secret = req.headers.get('x-cron-secret') ?? ''
  const authorized =
    (CRON_SECRET && secret === CRON_SECRET) || (SERVICE_KEY && auth.includes(SERVICE_KEY))
  if (!authorized) return json({ error: 'forbidden' }, 403)

  const now = Date.now()
  let reminded5 = 0
  let remindedClosing = 0

  // ---------------------------------------------------------- 1. Relance 5 min
  const fiveMinAgo = new Date(now - 5 * 60_000).toISOString()
  const { data: stale } = await admin
    .from('orders')
    .select('id, event_id, customer_id, pickup_code')
    .eq('status', 'READY')
    .is('reminder_5min_at', null)
    .lt('ready_at', fiveMinAgo)
    .limit(200)

  for (const o of stale ?? []) {
    await dispatch({
      eventId: o.event_id,
      kind: 'status',
      customerId: o.customer_id,
      orderId: o.id,
      title: 'Votre commande vous attend',
      body: `Votre commande ${o.pickup_code} est prête depuis 5 minutes. Présentez votre code de retrait au bar — le règlement se fait sur place.`,
      requireInteraction: true,
    })
    await admin
      .from('orders')
      .update({ reminder_5min_at: new Date().toISOString() })
      .eq('id', o.id)
    reminded5++
  }

  // --------------------------------------------- 2. Relance 1 h avant fermeture
  const { data: closingEvents } = await admin
    .from('events')
    .select('id, closes_at')
    .eq('is_active', true)
    .not('closes_at', 'is', null)
    .lte('closes_at', new Date(now + 60 * 60_000).toISOString())
    .gt('closes_at', new Date(now).toISOString())

  for (const e of closingEvents ?? []) {
    const { data: pending } = await admin
      .from('orders')
      .select('id, customer_id, pickup_code')
      .eq('event_id', e.id)
      .in('status', ['RECEIVED', 'READY'])
      .is('reminder_closing_at', null)
      .limit(500)

    for (const o of pending ?? []) {
      await dispatch({
        eventId: e.id,
        kind: 'status',
        customerId: o.customer_id,
        orderId: o.id,
        title: '⚠️ Dernier appel — commande à retirer',
        body: `Commande ${o.pickup_code}. ${CLOSING_MESSAGE}`,
        requireInteraction: true,
      })
      await admin
        .from('orders')
        .update({ reminder_closing_at: new Date().toISOString() })
        .eq('id', o.id)
      remindedClosing++
    }
  }

  return json({ reminded_5min: reminded5, reminded_closing: remindedClosing })
})

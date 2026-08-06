// ============================================================
// TAPZ — Edge Function : send-push
// Envoie une notification Web Push aux abonnés d'une commande (client)
// ou d'un bar (staff). Aucune fonction de paiement ici — jamais.
//
// Body attendu :
//   { orderId: "uuid", title, body, url?, tag?, requireInteraction? }
//   ou
//   { barId: "uuid", role: "staff", title, body, ... }
//
// Secrets requis : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
//                  (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY sont injectés)
// ============================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'
import { corsHeaders, json, preflight } from '../_shared/cors.ts'

const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY') ?? ''
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY') ?? ''
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:contact@tapz.app'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    return json({ error: 'VAPID non configuré (VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY)' }, 500)
  }
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE)

  let payload: Record<string, unknown>
  try {
    payload = await req.json()
  } catch {
    return json({ error: 'JSON invalide' }, 400)
  }

  const { orderId, barId, role, title, body, url, tag, requireInteraction } = payload as {
    orderId?: string
    barId?: string
    role?: string
    title?: string
    body?: string
    url?: string
    tag?: string
    requireInteraction?: boolean
  }

  if (!orderId && !barId) return json({ error: 'orderId ou barId requis' }, 400)

  let query = supabase.from('push_subscriptions').select('id, endpoint, p256dh, auth')
  if (orderId) query = query.eq('order_id', orderId)
  else query = query.eq('bar_id', barId!).eq('role', role ?? 'staff')

  const { data: subs, error } = await query
  if (error) return json({ error: error.message }, 500)
  if (!subs?.length) return json({ sent: 0, note: 'aucun abonné' })

  const notification = JSON.stringify({
    title: title ?? 'TAPZ',
    body: body ?? 'Mise à jour de votre commande.',
    url: url ?? '/',
    tag: tag ?? (orderId ? `tapz-${orderId}` : 'tapz'),
    requireInteraction: requireInteraction ?? false,
    orderId: orderId ?? null,
    vibrate: [180, 80, 180, 80, 320],
  })

  let sent = 0
  const dead: string[] = []

  await Promise.all(
    subs.map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          notification
        )
        sent++
      } catch (e) {
        // 404/410 = abonnement expiré côté navigateur, on nettoie.
        const code = (e as { statusCode?: number }).statusCode
        if (code === 404 || code === 410) dead.push(s.id)
      }
    })
  )

  if (dead.length) {
    await supabase.from('push_subscriptions').delete().in('id', dead)
  }

  return json({ sent, cleaned: dead.length }, 200)
})

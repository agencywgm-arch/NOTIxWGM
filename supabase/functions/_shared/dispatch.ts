// ============================================================================
//  NOTI Calling — cœur d'envoi des notifications, partagé par `notify` et
//  `reminders`. Écrit dans `messages` (source de vérité), puis pousse en Web
//  Push et en SMS — best-effort : un canal en échec ne fait jamais échouer
//  l'appel, conformément au « canal dégradé non bloquant » (§09).
// ============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'
import { sendSms } from './sms.ts'

const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY') ?? ''
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY') ?? ''
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:contact@noticalling.fr'

const admin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

if (VAPID_PUBLIC && VAPID_PRIVATE) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE)
}

export type NotifyInput = {
  eventId: string
  kind?: 'status' | 'broadcast' | 'individual'
  body: string
  title?: string
  customerId?: string | null
  orderId?: string | null
  channels?: Array<'push' | 'sms'>
  url?: string
  requireInteraction?: boolean
  /** Rendu en rouge côté client (relance de retrait, incident). */
  urgent?: boolean
}

export async function dispatch(input: NotifyInput) {
  const {
    eventId,
    kind = 'broadcast',
    body,
    title = 'Noti Calling',
    customerId = null,
    orderId = null,
    channels = ['push', 'sms'],
    url = '/',
    requireInteraction = false,
    urgent = false,
  } = input

  await admin.from('messages').insert({
    event_id: eventId,
    kind,
    body,
    customer_id: customerId,
    order_id: orderId,
    urgent,
  })

  let customerIds: string[] = []
  if (customerId) {
    customerIds = [customerId]
  } else {
    const { data } = await admin.from('attendances').select('customer_id').eq('event_id', eventId)
    customerIds = (data ?? []).map((a) => a.customer_id)
  }
  if (!customerIds.length) return { recipients: 0, push: 0, sms: 0 }

  // ------------------------------------------------------------------ Web Push
  let pushSent = 0
  if (channels.includes('push') && VAPID_PUBLIC && VAPID_PRIVATE) {
    const { data: subs } = await admin
      .from('push_subscriptions')
      .select('id, endpoint, p256dh, auth')
      .in('customer_id', customerIds)

    const payload = JSON.stringify({
      title,
      body,
      url,
      tag: orderId ? `noti-${orderId}` : `noti-${eventId}`,
      requireInteraction,
      orderId,
      vibrate: [180, 80, 180, 80, 320],
    })

    const dead: string[] = []
    await Promise.all(
      (subs ?? []).map(async (s) => {
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            payload
          )
          pushSent++
        } catch (e) {
          const code = (e as { statusCode?: number }).statusCode
          if (code === 404 || code === 410) dead.push(s.id)
        }
      })
    )
    if (dead.length) await admin.from('push_subscriptions').delete().in('id', dead)
  }

  // ----------------------------------------------------------------------- SMS
  let smsSent = 0
  if (channels.includes('sms')) {
    const { data: people } = await admin
      .from('customers')
      .select('id, phone')
      .in('id', customerIds)
    const results = await Promise.all((people ?? []).map((p) => sendSms(p.phone, body)))
    smsSent = results.filter((r) => r.ok).length
  }

  return { recipients: customerIds.length, push: pushSent, sms: smsSent }
}

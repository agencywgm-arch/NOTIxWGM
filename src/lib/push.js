// Noti Calling — Web Push (Service Worker + VAPID) et retours haptiques.
import { supabase, BASE_PATH } from './supabase.js'

const VAPID_PUBLIC = import.meta.env.VITE_VAPID_PUBLIC_KEY || ''

export const pushSupported = () =>
  typeof window !== 'undefined' &&
  'serviceWorker' in navigator &&
  'PushManager' in window &&
  'Notification' in window

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(base64)
  const out = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
  return out
}

export async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return null
  try {
    return await navigator.serviceWorker.register(`${BASE_PATH}sw.js`, { scope: BASE_PATH })
  } catch (e) {
    console.warn('[Noti] SW non enregistré', e)
    return null
  }
}

/**
 * Abonne l'appareil : côté client (rattaché au customer + événement) ou côté
 * staff (rattaché au lieu). Renvoie true si l'abonnement est enregistré.
 */
export async function subscribePush({ customerId = null, eventId = null, venueId = null, role = 'customer' }) {
  if (!pushSupported() || !VAPID_PUBLIC) return false
  try {
    const permission = await Notification.requestPermission()
    if (permission !== 'granted') return false

    const reg =
      (await navigator.serviceWorker.getRegistration(BASE_PATH)) || (await registerServiceWorker())
    if (!reg) return false
    await navigator.serviceWorker.ready

    let sub = await reg.pushManager.getSubscription()
    if (!sub) {
      sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC),
      })
    }

    const json = sub.toJSON()
    const { error } = await supabase.from('push_subscriptions').insert({
      customer_id: customerId,
      event_id: eventId,
      venue_id: venueId,
      role,
      endpoint: json.endpoint,
      p256dh: json.keys?.p256dh,
      auth: json.keys?.auth,
    })
    // 23505 = endpoint déjà enregistré : ce n'est pas une erreur fonctionnelle.
    if (error && error.code !== '23505') throw error
    return true
  } catch (e) {
    console.warn('[Noti] push', e)
    return false
  }
}

/**
 * Notification métier (statut / diffusion / message individuel).
 * Best-effort : ne bloque jamais l'action en cours (canal dégradé, §09).
 */
export async function notify(payload) {
  try {
    const { data, error } = await supabase.functions.invoke('notify', { body: payload })
    if (error) throw error
    return data
  } catch (e) {
    console.warn('[Noti] notify', e)
    return null
  }
}

export function vibrate(pattern = [180, 80, 180]) {
  try {
    navigator.vibrate?.(pattern)
  } catch (_) {}
}

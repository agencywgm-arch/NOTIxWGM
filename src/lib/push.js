// TAPZ — Web Push (Service Worker + VAPID) et retours haptiques.
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
    console.warn('[TAPZ] SW non enregistré', e)
    return null
  }
}

/**
 * Abonne l'appareil aux notifications pour une commande (client) ou un bar (staff).
 * Renvoie true si l'abonnement est enregistré côté Supabase.
 */
export async function subscribePush({ orderId = null, barId = null, role = 'customer' }) {
  if (!pushSupported() || !VAPID_PUBLIC) return false
  try {
    const permission = await Notification.requestPermission()
    if (permission !== 'granted') return false

    const reg = (await navigator.serviceWorker.getRegistration(BASE_PATH)) || (await registerServiceWorker())
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
      order_id: orderId,
      bar_id: barId,
      role,
      endpoint: json.endpoint,
      p256dh: json.keys?.p256dh,
      auth: json.keys?.auth,
    })
    // 23505 = endpoint déjà enregistré : ce n'est pas une erreur fonctionnelle.
    if (error && error.code !== '23505') throw error
    return true
  } catch (e) {
    console.warn('[TAPZ] push', e)
    return false
  }
}

/** Déclenche l'envoi via l'Edge Function send-push. */
export async function sendPush(payload) {
  try {
    await supabase.functions.invoke('send-push', { body: payload })
  } catch (e) {
    console.warn('[TAPZ] send-push', e)
  }
}

export function vibrate(pattern = [180, 80, 180]) {
  try {
    navigator.vibrate?.(pattern)
  } catch (_) {}
}

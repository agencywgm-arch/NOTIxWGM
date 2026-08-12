/* Noti Calling — Service Worker (Web Push + réveil de l'onglet de suivi) */

self.addEventListener('install', (e) => {
  self.skipWaiting()
})

self.addEventListener('activate', (e) => {
  e.waitUntil(self.clients.claim())
})

self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_) {
    data = { title: 'Noti Calling', body: event.data ? event.data.text() : '' }
  }

  const title = data.title || 'Noti Calling'
  const options = {
    body: data.body || 'Votre commande avance.',
    icon: data.icon || undefined,
    badge: data.badge || undefined,
    tag: data.tag || 'noti-order',
    renotify: true,
    requireInteraction: !!data.requireInteraction,
    vibrate: data.vibrate || [180, 80, 180, 80, 320],
    data: { url: data.url || '/', orderId: data.orderId || null },
  }

  event.waitUntil(
    (async () => {
      await self.registration.showNotification(title, options)
      const clientsList = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      })
      for (const c of clientsList) {
        c.postMessage({ type: 'NOTI_PUSH', payload: data })
      }
    })()
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || '/'
  event.waitUntil(
    (async () => {
      const all = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      })
      for (const c of all) {
        if ('focus' in c) {
          c.navigate?.(url)
          return c.focus()
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url)
    })()
  )
})

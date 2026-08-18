import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY

export const isConfigured = Boolean(url && anon)

if (!isConfigured) {
  console.warn('[Noti] VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY manquants.')
}

export const supabase = createClient(url || 'http://localhost', anon || 'public-anon-key', {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'noti-auth',
  },
  realtime: { params: { eventsPerSecond: 20 } },
})

/** Chemin de base du déploiement (GitHub Pages projet = "/mon-repo/"). */
export const BASE_PATH = (import.meta.env.VITE_BASE_PATH || '/').replace(/\/+$/, '') + '/'

/**
 * URL d'un point de scan — FORMAT STABLE, ne jamais casser : /s/{scan_point_id}
 * Phase 1 : un QR à l'entrée, un QR au bar. Phase 2 : un QR par table, même URL.
 */
export function scanUrl(scanPointId) {
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  return `${origin}${BASE_PATH}s/${scanPointId}`.replace(/([^:]\/)\/+/g, '$1')
}

/** Messages d'erreur Supabase traduits. */
export function frError(err) {
  const raw = err?.message || String(err || '')
  const m = raw.toLowerCase()

  // Erreurs métier remontées par les fonctions PostgreSQL
  if (m.includes('pickup_pending'))
    return 'Vous avez une commande prête à retirer. Récupérez-la d’abord au bar avant de pouvoir passer une nouvelle commande.'
  if (m.includes('orders_closed')) return 'Les commandes sont fermées pour le moment.'
  if (m.includes('empty_cart')) return 'Votre panier est vide.'
  if (m.includes('product_unavailable')) return 'Un article de votre panier n’est plus disponible.'
  if (m.includes('variant_required')) return 'Choisissez un format pour chaque article.'
  if (m.includes('not_a_customer') || m.includes('not_authenticated')) return 'Identifiez-vous pour commander.'
  if (m.includes('forbidden')) return 'Action non autorisée.'
  if (m.includes('scan_point_orphan'))
    return 'Ce QR code ne pointe plus vers une soirée valide. Demandez au staff un QR à jour.'

  // Auth
  if (m.includes('anonymous sign-ins are disabled'))
    return "L'identification client n'est pas activée sur le projet Supabase (Authentication → Providers → Anonymous)."
  if (m.includes('invalid login credentials')) return 'E-mail ou mot de passe incorrect.'
  if (m.includes('user already registered') || m.includes('already been registered'))
    return 'Cet e-mail est déjà utilisé. Connectez-vous.'
  if (m.includes('password should be at least'))
    return 'Le mot de passe doit faire au moins 6 caractères.'
  if (m.includes('failed to fetch') || m.includes('network'))
    return 'Connexion instable. Réessayez dans un instant.'

  return raw || 'Une erreur est survenue.'
}

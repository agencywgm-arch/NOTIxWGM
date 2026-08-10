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

/** Messages d'erreur Supabase traduits, y compris ceux de l'auth par SMS. */
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
  if (m.includes('not_a_customer')) return 'Identifiez-vous pour commander.'
  if (m.includes('phone_not_verified')) return 'Numéro non vérifié. Recommencez la vérification par SMS.'
  if (m.includes('forbidden')) return 'Action non autorisée.'

  // Auth
  if (m.includes('invalid login credentials')) return 'E-mail ou mot de passe incorrect.'
  if (m.includes('user already registered') || m.includes('already been registered'))
    return 'Cet e-mail est déjà utilisé. Connectez-vous.'
  if (m.includes('token has expired') || m.includes('otp_expired'))
    return 'Le code a expiré. Demandez-en un nouveau.'
  if (m.includes('invalid otp') || m.includes('token is invalid') || m.includes('otp'))
    return 'Code incorrect. Vérifiez les 6 chiffres reçus par SMS.'
  if (m.includes('sms') && m.includes('not') && m.includes('enabl'))
    return "L'authentification par SMS n'est pas activée sur le projet Supabase."
  if (m.includes('rate limit') || m.includes('too many') || m.includes('over_sms_send_rate_limit'))
    return 'Trop de tentatives. Patientez une minute avant de réessayer.'
  if (m.includes('invalid phone') || m.includes('phone'))
    return 'Numéro de mobile invalide. Format attendu : 06 12 34 56 78.'
  if (m.includes('password should be at least'))
    return 'Le mot de passe doit faire au moins 6 caractères.'
  if (m.includes('failed to fetch') || m.includes('network'))
    return 'Connexion instable. Réessayez dans un instant.'

  return raw || 'Une erreur est survenue.'
}

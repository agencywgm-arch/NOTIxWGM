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

/**
 * Un QR imprimé depuis un déploiement d'aperçu Vercel (un lien différent à
 * chaque déploiement de branche/PR) casse dès que cet aperçu expire — c'est
 * arrivé une fois en soirée. `scanUrl()` fige `window.location.origin` au
 * moment de la génération : générer depuis le mauvais lien y grave l'erreur
 * pour de bon, sur le papier.
 *
 * Détection sans connaître à l'avance le vrai domaine de prod : chaque
 * déploiement Vercel reçoit un identifiant aléatoire (9-10 caractères,
 * lettres ET chiffres mélangés, ex. « 4wp5dmqbv ») inséré dans le nom
 * d'hôte — le domaine de production stable n'en a pas.
 */
export function isPreviewDeployment() {
  if (typeof window === 'undefined') return false
  const host = window.location.hostname
  if (!host.endsWith('.vercel.app')) return false
  return host
    .split('.')[0]
    .split('-')
    .some((seg) => /^[a-z0-9]{8,12}$/.test(seg) && /[0-9]/.test(seg) && /[a-z]/.test(seg))
}

/**
 * Clé stable d'une erreur métier, indépendante de la langue : le parcours
 * client la traduit via son dictionnaire (voir lib/i18n.js), l'espace staff
 * garde frError() ci-dessous.
 */
const ERROR_KEYS = [
  'pickup_pending',
  'orders_closed',
  'empty_cart',
  'product_unavailable',
  'variant_required',
  'not_a_customer',
  'not_authenticated',
  'scan_point_orphan',
  'missing_profile',
  'missing_phone',
  'invalid_phone',
  'phone_already_used',
  'missing_postal_code',
  'invalid_birthdate',
  'invalid_email',
  'code_exhausted',
  'invalid_pass_code',
  'conversion_closed',
  'no_food_token',
  'no_pass',
  'unknown_order',
  'forbidden',
]

export function errorKey(err) {
  const m = (err?.message || String(err || '')).toLowerCase()
  // « forbidden » est testé en dernier : plusieurs messages plus précis le
  // contiennent, et on préfère toujours le plus parlant pour le client.
  const hit = ERROR_KEYS.find((k) => m.includes(k))
  if (hit === 'not_authenticated') return 'not_a_customer'
  if (hit) return hit
  if (m.includes('failed to fetch') || m.includes('network')) return 'network'
  return null
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
  if (m.includes('missing_profile')) return 'Prénom et nom sont obligatoires.'
  if (m.includes('missing_phone')) return 'Numéro de téléphone obligatoire.'
  if (m.includes('phone_already_used'))
    return 'Ce numéro est déjà utilisé par une autre fiche client.'
  if (m.includes('missing_postal_code')) return 'Code postal obligatoire.'
  if (m.includes('invalid_birthdate')) return 'Date de naissance invalide.'
  if (m.includes('invalid_email')) return 'Adresse e-mail invalide.'
  if (m.includes('code_exhausted'))
    return 'Ce code est épuisé : toutes ses utilisations ont déjà été activées.'
  if (m.includes('invalid_pass_code'))
    return 'Code invalide, expiré ou déjà entièrement utilisé.'
  if (m.includes('conversion_closed'))
    return 'La conversion du jeton food est fermée (disponible jusqu’à 22h).'
  if (m.includes('no_food_token')) return 'Aucun jeton food disponible à convertir.'
  if (m.includes('no_pass')) return 'Aucun forfait actif pour cette soirée.'
  if (m.includes('unknown_order')) return 'Commande introuvable.'
  if (m.includes('invalid_flag')) return 'Type de signalement inconnu.'
  if (m.includes('empty_note')) return 'Le commentaire ne peut pas être vide.'

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

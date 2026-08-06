import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY

export const isConfigured = Boolean(url && anon)

if (!isConfigured) {
  // Pas de crash : l'app affiche un écran de configuration.
  console.warn('[TAPZ] VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY manquants.')
}

export const supabase = createClient(url || 'http://localhost', anon || 'public-anon-key', {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: 'tapz-auth',
  },
  realtime: { params: { eventsPerSecond: 10 } },
})

/** Traduit les messages d'erreur Supabase Auth en français lisible. */
export function frAuthError(err) {
  const m = (err?.message || String(err || '')).toLowerCase()
  if (m.includes('invalid login credentials')) return 'E-mail ou mot de passe incorrect.'
  if (m.includes('user already registered') || m.includes('already been registered'))
    return 'Cet e-mail est déjà utilisé. Connectez-vous.'
  if (m.includes('email not confirmed'))
    return "E-mail non confirmé. Vérifiez votre boîte de réception."
  if (m.includes('password should be at least'))
    return 'Le mot de passe doit faire au moins 6 caractères.'
  if (m.includes('unable to validate email') || m.includes('invalid email'))
    return "Adresse e-mail invalide."
  if (m.includes('rate limit') || m.includes('too many'))
    return 'Trop de tentatives. Réessayez dans quelques minutes.'
  if (m.includes('signups not allowed')) return "Les inscriptions sont désactivées sur ce projet."
  if (m.includes('failed to fetch') || m.includes('network'))
    return 'Connexion impossible. Vérifiez votre réseau.'
  return err?.message || 'Une erreur est survenue.'
}

/** Chemin de base du déploiement (GitHub Pages projet = "/mon-repo/"). */
export const BASE_PATH = (import.meta.env.VITE_BASE_PATH || '/').replace(/\/+$/, '') + '/'

/** URL absolue d'une table — FORMAT STABLE, ne jamais casser : /r/{bar_id}/t/{table_number} */
export function tableUrl(barId, tableNumber) {
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  return `${origin}${BASE_PATH}r/${barId}/t/${tableNumber}`.replace(/([^:]\/)\/+/g, '$1')
}

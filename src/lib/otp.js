// ============================================================================
//  Vérification SMS du numéro — sur Brevo, via le canal transactionnel déjà
//  en place pour les relances (voir supabase/functions/notify).
//  ----------------------------------------------------------------------
//  Remplace lib/firebase.js (0039) : Firebase demandait la formule payante
//  Blaze sur un projet séparé, jamais finalisée, la vérification tournait
//  donc en pause depuis. Même garantie qu'avant — « qualité des données,
//  pas une sécurité de connexion » — mais un seul fournisseur SMS pour tout
//  (relances ET vérification), déjà opérationnel côté serveur.
//
//  Le code à 6 chiffres est généré et gardé côté base (0055, table sans la
//  moindre policy RLS) : il ne transite jamais par ce fichier ni par le
//  navigateur. sendOtpCode() se contente de déclencher sa génération puis
//  son envoi ; confirmOtpCode() en fait vérifier la correspondance côté
//  base, sans jamais la connaître elle-même.
// ============================================================================
import { supabase } from './supabase.js'

/** Toujours disponible : contrairement à Firebase, rien à configurer côté
 * client — tout vit dans les secrets du projet Supabase. */
export const phoneVerificationAvailable = true

/** Demande un nouveau code et déclenche son envoi par SMS. Lève sur échec —
 * y compris un échec d'envoi Brevo (`sms_failed`), pas seulement une erreur
 * de la base. */
export async function sendOtpCode() {
  const { error } = await supabase.rpc('request_phone_otp')
  if (error) throw error

  const { data, error: sendErr } = await supabase.functions.invoke('send-otp', { body: {} })
  if (sendErr) throw sendErr
  if (!data?.ok) {
    const e = new Error(data?.reason || data?.error || 'sms_failed')
    e.message = 'sms_failed'
    throw e
  }
  return true
}

/** Vérifie le code saisi. Retourne `true`/`false` (jamais d'exception pour
 * un simple mauvais code — voir 0055) ; lève seulement sur un blocage réel
 * (code expiré, trop de tentatives, session invalide). */
export async function confirmOtpCode(code) {
  const { data, error } = await supabase.rpc('confirm_phone_otp', { p_code: code })
  if (error) throw error
  return Boolean(data)
}

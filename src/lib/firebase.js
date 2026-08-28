// ============================================================================
//  Vérification SMS du numéro (Firebase Phone Auth)
//  ----------------------------------------------------------------------
//  Sert UNIQUEMENT à prouver qu'un client détient bien le numéro qu'il a
//  saisi — qualité des données, pas une sécurité de connexion. L'identité
//  du client reste entièrement portée par Supabase (session anonyme +
//  `customers`) ; Firebase n'intervient qu'ici, comme un simple oracle de
//  vérification, et son résultat est ensuite enregistré côté Supabase via
//  `mark_phone_verified()`.
//
//  Gratuit dans le quota Google, mais nécessite la formule Blaze (carte
//  bancaire enregistrée) sur le projet Firebase — voir README.
// ============================================================================

const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
}

/** Absent du .env → la fonctionnalité se désactive proprement (pas d'erreur). */
export const phoneVerificationAvailable = Boolean(firebaseConfig.apiKey && firebaseConfig.projectId)

let authPromise = null

/** Chargement paresseux : le SDK Firebase (~15 ko gzip) ne pèse que sur les
 * sessions qui ouvrent réellement l'écran de vérification. */
async function getFirebaseAuth() {
  if (!phoneVerificationAvailable) throw new Error('firebase_not_configured')
  if (!authPromise) {
    authPromise = (async () => {
      const { initializeApp, getApps } = await import('firebase/app')
      const { getAuth } = await import('firebase/auth')
      const app = getApps()[0] ?? initializeApp(firebaseConfig)
      return getAuth(app)
    })()
  }
  return authPromise
}

/**
 * Envoie le code SMS. `containerId` doit être l'id d'un élément DOM déjà
 * monté (peut être invisible) — reCAPTCHA s'y accroche pour écarter les
 * abus. Retourne un `confirmationResult` à repasser à `confirmPhoneCode`.
 *
 * Un nouveau vérificateur à chaque appel plutôt qu'un singleton mis en
 * cache : le conteneur DOM disparaît quand la feuille se ferme (le
 * composant est démonté), un vérificateur mis en cache pointerait alors
 * vers un nœud détaché à la prochaine ouverture.
 */
export async function sendPhoneCode(e164Phone, containerId) {
  const auth = await getFirebaseAuth()
  const { RecaptchaVerifier, signInWithPhoneNumber } = await import('firebase/auth')
  const verifier = new RecaptchaVerifier(auth, containerId, { size: 'invisible' })
  try {
    return await signInWithPhoneNumber(auth, e164Phone, verifier)
  } finally {
    // Inutile après l'envoi : la confirmation du code (confirmPhoneCode) ne
    // s'appuie plus dessus.
    verifier.clear()
  }
}

/** Confirme le code saisi par le client. Lève si le code est invalide. */
export async function confirmPhoneCode(confirmationResult, code) {
  const result = await confirmationResult.confirm(code.trim())
  // On n'a besoin que de la preuve, pas d'une session Firebase durable —
  // l'identité reste Supabase. On se déconnecte donc immédiatement.
  const auth = await getFirebaseAuth()
  await auth.signOut()
  return result
}

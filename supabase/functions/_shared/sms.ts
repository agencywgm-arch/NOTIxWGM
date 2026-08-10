// ============================================================================
//  NOTI Calling — envoi SMS, fournisseur interchangeable.
//
//  La feuille de route (§13) laisse le choix à arbitrer entre Twilio, Vonage,
//  Brevo et OVHcloud. Les quatre sont implémentés derrière la même interface :
//  basculez avec le secret SMS_PROVIDER, sans toucher au reste du code.
//
//  ⚠️ L'OTP d'identification n'utilise PAS ce module : il est géré nativement
//     par Supabase Phone Auth (qui pilote lui-même Twilio / Vonage / MessageBird).
//     Ce module ne sert qu'aux notifications métier (statut, relances, diffusion).
//
//  Canal dégradé (§09) : un échec SMS ne doit JAMAIS bloquer une commande.
//  Toutes les fonctions renvoient un booléen et n'émettent jamais d'exception.
// ============================================================================

const PROVIDER = (Deno.env.get('SMS_PROVIDER') ?? 'none').toLowerCase()
const SENDER = Deno.env.get('SMS_SENDER') ?? 'NotiCalling'

export type SmsResult = { ok: boolean; provider: string; error?: string }

async function twilio(to: string, body: string): Promise<SmsResult> {
  const sid = Deno.env.get('TWILIO_ACCOUNT_SID')
  const token = Deno.env.get('TWILIO_AUTH_TOKEN')
  const from = Deno.env.get('TWILIO_FROM') ?? SENDER
  if (!sid || !token) return { ok: false, provider: 'twilio', error: 'secrets manquants' }

  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: 'POST',
    headers: {
      Authorization: 'Basic ' + btoa(`${sid}:${token}`),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ To: to, From: from, Body: body }),
  })
  return { ok: res.ok, provider: 'twilio', error: res.ok ? undefined : await res.text() }
}

async function vonage(to: string, body: string): Promise<SmsResult> {
  const key = Deno.env.get('VONAGE_API_KEY')
  const secret = Deno.env.get('VONAGE_API_SECRET')
  if (!key || !secret) return { ok: false, provider: 'vonage', error: 'secrets manquants' }

  const res = await fetch('https://rest.nexmo.com/sms/json', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      api_key: key,
      api_secret: secret,
      to: to.replace(/^\+/, ''),
      from: SENDER,
      text: body,
      type: 'unicode',
    }),
  })
  const j = await res.json().catch(() => ({}))
  const ok = j?.messages?.[0]?.status === '0'
  return { ok, provider: 'vonage', error: ok ? undefined : JSON.stringify(j) }
}

async function brevo(to: string, body: string): Promise<SmsResult> {
  const key = Deno.env.get('BREVO_API_KEY')
  if (!key) return { ok: false, provider: 'brevo', error: 'secret manquant' }

  const res = await fetch('https://api.brevo.com/v3/transactionalSMS/sms', {
    method: 'POST',
    headers: { 'api-key': key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sender: SENDER, recipient: to.replace(/^\+/, ''), content: body }),
  })
  return { ok: res.ok, provider: 'brevo', error: res.ok ? undefined : await res.text() }
}

async function ovh(to: string, body: string): Promise<SmsResult> {
  // OVHcloud SMS — API HTTP simple (compte SMS + login applicatif).
  const account = Deno.env.get('OVH_SMS_ACCOUNT')
  const login = Deno.env.get('OVH_SMS_LOGIN')
  const password = Deno.env.get('OVH_SMS_PASSWORD')
  if (!account || !login || !password) return { ok: false, provider: 'ovh', error: 'secrets manquants' }

  const url = new URL('https://www.ovh.com/cgi-bin/sms/http2sms.cgi')
  url.searchParams.set('account', account)
  url.searchParams.set('login', login)
  url.searchParams.set('password', password)
  url.searchParams.set('from', SENDER)
  url.searchParams.set('to', to)
  url.searchParams.set('message', body)
  url.searchParams.set('contentType', 'text/json')
  url.searchParams.set('noStop', '0')

  const res = await fetch(url.toString())
  const txt = await res.text()
  return { ok: res.ok && !/"status":\s*[1-9]/.test(txt), provider: 'ovh', error: res.ok ? undefined : txt }
}

/** Envoie un SMS. Ne lève jamais : le SMS est un confort, pas la source de vérité. */
export async function sendSms(to: string, body: string): Promise<SmsResult> {
  if (!to) return { ok: false, provider: PROVIDER, error: 'destinataire vide' }
  try {
    switch (PROVIDER) {
      case 'twilio': return await twilio(to, body)
      case 'vonage': return await vonage(to, body)
      case 'brevo':  return await brevo(to, body)
      case 'ovh':    return await ovh(to, body)
      default:
        // Aucun fournisseur configuré : on trace et on continue.
        console.log(`[SMS désactivé] → ${to} : ${body}`)
        return { ok: false, provider: 'none', error: 'SMS_PROVIDER non configuré' }
    }
  } catch (e) {
    return { ok: false, provider: PROVIDER, error: (e as Error).message }
  }
}

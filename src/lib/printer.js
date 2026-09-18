// ============================================================================
//  NOTI Calling — envoi d'un ticket à l'imprimante du bar
//
//  CE QU'IL FAUT SAVOIR AVANT D'ACHETER UNE IMPRIMANTE
//
//  L'application est servie en HTTPS (Vercel). Un navigateur refuse qu'une
//  page HTTPS parle à une adresse http:// — c'est la règle du « contenu
//  mixte », et elle n'a pas de contournement côté page. Il refuse également
//  d'ouvrir une connexion réseau brute (le port 9100 des imprimantes de
//  caisse) : aucune page web ne peut le faire, quel que soit le navigateur.
//
//  Trois façons d'imprimer automatiquement, par ordre de solidité :
//
//   1. IMPRIMANTE QUI VA CHERCHER SES TICKETS (recommandé)
//      Epson « Server Direct Print », Star CloudPRNT. L'imprimante interroge
//      elle-même une adresse publique et récupère ce qu'elle doit sortir.
//      Rien à ouvrir sur la box du lieu, rien à installer, et ça traverse
//      n'importe quel réseau. Demande un point d'entrée côté serveur.
//
//   2. RELAIS SUR PLACE
//      Un petit appareil sur le réseau du lieu reçoit les tickets et les
//      pousse vers l'imprimante en ESC/POS. Marche avec n'importe quelle
//      imprimante, y compris les moins chères — mais c'est une machine de
//      plus qui peut tomber en panne un soir de rush.
//
//   3. APPEL DIRECT DEPUIS LA TABLETTE (ce que fait ce fichier)
//      Ne fonctionne que si l'imprimante répond en HTTPS avec un certificat
//      que le navigateur accepte, ce qui est rare sur un réseau local. Prévu
//      ici parce que c'est le seul chemin qui ne demande aucune
//      infrastructure quand il marche — et parce que le contenu du ticket,
//      lui, ne change pas d'un transport à l'autre.
//
//  Le ticket (src/lib/ticket.js) est volontairement indépendant de tout
//  ceci : changer de transport ne change pas une ligne de ce qui s'imprime.
// ============================================================================

/** Message court et parlant, à afficher au staff. Jamais une trace technique. */
export function printerError(e) {
  const m = String(e?.message || e || '').toLowerCase()
  if (m.includes('mixed') || m.includes('insecure'))
    return 'Le navigateur refuse de joindre une imprimante en http depuis un site sécurisé.'
  if (m.includes('failed to fetch') || m.includes('networkerror') || m.includes('load failed'))
    return 'Imprimante injoignable — vérifiez qu’elle est allumée et sur le même réseau.'
  if (m.includes('timeout') || m.includes('abort')) return 'L’imprimante n’a pas répondu à temps.'
  return 'Impression impossible pour le moment.'
}

const xmlEscape = (s) =>
  String(s).replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' })[c])

/**
 * Enveloppe ePOS-Print (Epson) : du XML sur HTTP, seul dialecte d'imprimante
 * qu'une page web sait parler. Les octets ESC/POS y voyagent en base64.
 */
function eposEnvelope(bytes) {
  let bin = ''
  for (const b of bytes) bin += String.fromCharCode(b)
  return (
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>' +
    '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print">' +
    `<command>${xmlEscape(btoa(bin))}</command>` +
    '</epos-print></s:Body></s:Envelope>'
  )
}

/**
 * Pousse un ticket vers l'imprimante. Ne lève jamais tout seul : le service
 * ne doit pas s'arrêter parce qu'un rouleau de papier est vide.
 *
 * @returns {Promise<{ok: boolean, reason?: string}>}
 */
export async function sendToPrinter(bytes, { url, timeoutMs = 6000 } = {}) {
  if (!url) return { ok: false, reason: 'Aucune imprimante configurée.' }

  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        SOAPAction: '""',
      },
      body: eposEnvelope(bytes),
      signal: ctrl.signal,
    })
    if (!res.ok) return { ok: false, reason: `L’imprimante a répondu ${res.status}.` }
    const body = await res.text()
    // ePOS-Print répond 200 même quand il refuse : le verdict est dans le XML.
    if (/success="false"/i.test(body)) {
      const code = body.match(/code="([^"]*)"/i)?.[1] || ''
      return { ok: false, reason: `L’imprimante a refusé le ticket${code ? ` (${code})` : ''}.` }
    }
    return { ok: true }
  } catch (e) {
    return { ok: false, reason: printerError(e) }
  } finally {
    clearTimeout(timer)
  }
}

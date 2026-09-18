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

import { WIDTH } from './ticket.js'

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
 * Traduit les lignes du ticket (src/lib/ticket.js) en XML ePOS-Print — le
 * langage structuré que l'imprimante attend réellement derrière
 * /cgi-bin/epos/service.cgi. Une première version envoyait des octets
 * ESC/POS bruts encapsulés dans une balise <command> inventée pour
 * l'occasion : l'imprimante les a refusés avec « SchemaError », relevé sur
 * une TM-m30III réelle le soir du branchement — ePOS-Print XML ne transporte
 * pas de flux binaire arbitraire, seulement des balises connues (<text>,
 * <feed>, <cut>…) validées contre son propre schéma.
 *
 * Bénéfice au passage : le texte voyage en UTF-8 normal, directement — plus
 * besoin de translittérer les accents pour une page de codes imprimante.
 */
function buildEposPrintXml(lines) {
  const text = (v, attrs = '') => `<text${attrs}>${xmlEscape(v)}\n</text>`
  const parts = lines.map((l) => {
    switch (l.t) {
      case 'sep':
        // Largeur reprise de ticket.js, jamais recopiée en dur ici — c'est
        // le fait d'avoir deux « 42 » séparés qui a cassé l'alignement au
        // passage à un rouleau 58 mm plus étroit.
        return text('-'.repeat(WIDTH))
      case 'title':
        // Taille normale : seul le code de retrait (ci-dessous) doit
        // dominer le ticket, le nom du lieu n'a pas besoin de rivaliser.
        return text(l.v, ' align="center" em="true"')
      case 'big':
        // Double largeur/hauteur (avant : triple) — retours du terrain : les
        // tickets étaient trop grands une fois le nom du lieu déjà réduit.
        // Reste le plus gros élément du ticket, ce qui suffit à se lire
        // sans le brandir à bout de bras.
        return text(l.v, ' align="center" width="2" height="2" em="true"')
      case 'center':
        return text(l.v, ' align="center"')
      case 'bold':
        return text(l.v, ' em="true"')
      default:
        return text(l.v)
    }
  })
  parts.push('<feed line="2"/>', '<cut type="feed"/>')
  return parts.join('')
}

function eposEnvelope(xmlBody) {
  return (
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>' +
    '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print">' +
    xmlBody +
    '</epos-print></s:Body></s:Envelope>'
  )
}

/**
 * Pousse un ticket vers l'imprimante. Ne lève jamais tout seul : le service
 * ne doit pas s'arrêter parce qu'un rouleau de papier est vide.
 *
 * @param {ReturnType<typeof import('./ticket.js').buildTicket>} lines
 * @returns {Promise<{ok: boolean, reason?: string}>}
 */
export async function sendToPrinter(lines, { url, timeoutMs = 6000 } = {}) {
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
      body: eposEnvelope(buildEposPrintXml(lines)),
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

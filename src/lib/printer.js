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
// Rattrapage matériel : sur ce rouleau, le texte aligné à gauche perdait
// systématiquement ses 2 premiers caractères, engloutis avant le bord réel
// du papier (« 18:54 » sortait « 54 », « TOTAL » sortait « TAL » — constaté
// sur un ticket imprimé). Uniquement sur le texte aligné à gauche : les
// éléments centrés (title/big/center) sont positionnés par l'imprimante
// elle-même selon la longueur du texte — leur ajouter cette marge décalerait
// leur centrage au lieu de le corriger.
const LEFT_MARGIN = '  '

function buildEposPrintXml(lines) {
  const text = (v, attrs = '') => `<text${attrs}>${xmlEscape(v)}\n</text>`
  const left = (v, attrs = '') => text(LEFT_MARGIN + v, attrs)
  const parts = lines.map((l) => {
    switch (l.t) {
      case 'sep':
        // Largeur reprise de ticket.js, jamais recopiée en dur ici — c'est
        // le fait d'avoir deux « 42 » séparés qui a cassé l'alignement au
        // passage à un rouleau 58 mm plus étroit.
        return left('-'.repeat(WIDTH))
      case 'title':
        // Taille normale : seul le code de retrait (ci-dessous) doit
        // dominer le ticket, le nom du lieu n'a pas besoin de rivaliser.
        return text(l.v, ' align="center" em="true"')
      case 'big':
        // Double hauteur seulement (avant : double largeur ET hauteur) —
        // doubler la largeur double aussi le nombre de colonnes que prend
        // chaque caractère, ce qui serrait le texte contre les bords sur un
        // rouleau étroit. Rester grand en hauteur suffit à se lire sans le
        // brandir à bout de bras, sans jamais risquer de déborder en largeur.
        return text(l.v, ' align="center" height="2" em="true"')
      case 'center':
        return text(l.v, ' align="center"')
      case 'bold':
        return left(l.v, ' em="true"')
      default:
        return left(l.v)
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
 * `ambiguous: true` distingue « on sait que ça a échoué » de « on ne sait
 * pas » — la nuance qui a provoqué une impression en boucle un soir de
 * rush : un simple dépassement de délai (l'imprimante encaisse la requête
 * mais répond lentement) était traité comme un échec certain, la
 * réservation était relâchée, et ce relâchement relançait aussitôt une
 * nouvelle tentative — qui imprimait à nouveau, retimeoutait, relâchait de
 * nouveau, sans fin. Un abandon par délai ne prouve pas que l'impression a
 * raté : l'appelant ne doit PAS relâcher la réservation dans ce cas,
 * seulement sur un refus net (code HTTP d'erreur, ou l'imprimante qui
 * répond explicitement qu'elle refuse).
 *
 * @param {ReturnType<typeof import('./ticket.js').buildTicket>} lines
 * @returns {Promise<{ok: boolean, reason?: string, ambiguous?: boolean}>}
 */
// 25 s plutôt que 15 : même symptôme revécu un soir encore plus chargé — le
// Wi-Fi partagé du lieu peut rester engorgé plusieurs dizaines de secondes
// d'affilée, et l'imprimante encaissait bel et bien le ticket après que
// l'appli ait déjà abandonné. Le mécanisme « ambigu, ne pas relâcher la
// réservation » au-dessus protège déjà contre un vrai doublon ; un délai
// encore plus large réduit combien de fois ce faux négatif se déclenche.
export async function sendToPrinter(lines, { url, timeoutMs = 25000 } = {}) {
  if (!url) return { ok: false, ambiguous: false, reason: 'Aucune imprimante configurée.' }

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
    if (!res.ok) return { ok: false, ambiguous: false, reason: `L’imprimante a répondu ${res.status}.` }
    const body = await res.text()
    // ePOS-Print répond 200 même quand il refuse : le verdict est dans le XML.
    if (/success="false"/i.test(body)) {
      const code = body.match(/code="([^"]*)"/i)?.[1] || ''
      return { ok: false, ambiguous: false, reason: `L’imprimante a refusé le ticket${code ? ` (${code})` : ''}.` }
    }
    return { ok: true }
  } catch (e) {
    // AbortError : c'est NOUS qui avons abandonné après timeoutMs, pas
    // l'imprimante qui a refusé — elle a très bien pu recevoir et imprimer
    // quand même, juste plus lentement que prévu.
    const ambiguous = e?.name === 'AbortError'
    return { ok: false, ambiguous, reason: printerError(e) }
  } finally {
    clearTimeout(timer)
  }
}

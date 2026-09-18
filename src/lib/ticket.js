// ============================================================================
//  NOTI Calling — ticket de commande pour imprimante thermique 80 mm
//
//  Deux étages volontairement séparés :
//    · buildTicket()  décide CE QUI est imprimé — indépendant de toute
//      imprimante, donc testable seul et réutilisable quel que soit le
//      matériel choisi ;
//    · encodeEscPos()  traduit ça en octets ESC/POS, le langage que parlent
//      toutes les imprimantes de caisse.
//
//  Le transport (comment les octets atteignent l'imprimante) vit ailleurs :
//  c'est la seule partie qui dépend du modèle acheté.
// ============================================================================

/** 42 caractères : la largeur d'un rouleau 80 mm en police par défaut. */
export const WIDTH = 42

const pad = (left, right, w = WIDTH) => {
  const l = String(left ?? '')
  const r = String(right ?? '')
  const gap = Math.max(1, w - l.length - r.length)
  return l + ' '.repeat(gap) + r
}

const wrap = (text, w = WIDTH, indent = '') => {
  const out = []
  let line = ''
  for (const word of String(text ?? '').split(/\s+/).filter(Boolean)) {
    const prefix = out.length === 0 ? indent : indent
    if (!line.length) line = prefix + word
    else if (line.length + 1 + word.length <= w) line += ' ' + word
    else {
      out.push(line)
      line = prefix + word
    }
  }
  if (line.length) out.push(line)
  return out
}

const hhmm = (iso) => {
  const d = new Date(iso)
  return Number.isNaN(d.getTime())
    ? ''
    : `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

const money = (n) => `${Number(n ?? 0).toFixed(2).replace('.', ',')} EUR`

/**
 * Le contenu du ticket, sous forme de lignes typées. Chaque ligne porte son
 * intention (`big`, `title`, `sep`…) plutôt qu'une mise en forme : c'est
 * l'encodeur qui décide comment la rendre, et un test peut lire le contenu
 * sans rien connaître d'ESC/POS.
 *
 * Ce que le bar doit trouver sur le papier, et pourquoi :
 *   · le code de retrait, en très gros — c'est lui qu'on crie ;
 *   · l'heure de la commande, pour servir dans l'ordre d'arrivée ;
 *   · le NOM du client, pour l'appeler plutôt que de brandir un code ;
 *   · son téléphone, pour le joindre s'il ne vient pas ;
 *   · l'état du règlement : une commande food non encaissée ne se prépare
 *     pas, et c'est l'erreur la plus coûteuse à faire en plein rush.
 */
export function buildTicket({ order, event, venue }) {
  const L = []
  const c = order.customers || {}
  const nom = [c.first_name, c.last_name].filter(Boolean).join(' ').trim()
  const items = order.order_items || []
  // place_order scinde la commande : une moitié boissons, une moitié food.
  // Tous les articles d'une commande sont donc du même univers. On lit celui
  // du produit quand il a été chargé ; sinon on retombe sur la signature
  // d'une commande food à sa création — elle attend d'être encaissée.
  const food =
    items.some((i) => i.products?.universe === 'food') || order.status === 'AWAITING_PAYMENT'

  L.push({ t: 'title', v: (venue?.name || 'NOTI CALLING').toUpperCase() })
  if (event?.name) L.push({ t: 'center', v: event.name })
  L.push({ t: 'sep' })

  L.push({ t: 'center', v: 'CODE DE RETRAIT' })
  L.push({ t: 'big', v: order.pickup_code || '----' })
  L.push({ t: 'sep' })

  L.push({ t: 'line', v: pad(hhmm(order.created_at), food ? 'FOOD' : 'BOISSONS') })
  if (nom) L.push({ t: 'bold', v: nom })
  if (c.phone) L.push({ t: 'line', v: c.phone })
  if ((c.tags || []).includes('vip')) L.push({ t: 'bold', v: '*** CLIENT VIP ***' })
  L.push({ t: 'sep' })

  for (const it of items) {
    L.push({ t: 'bold', v: pad(`${it.quantity}x ${it.name_snapshot}`, money(Number(it.unit_price) * Number(it.quantity))) })
    const extra = [it.variant_label, ...(it.detail?.options || []).map((o) => o.name)]
      .filter(Boolean)
      .join(' + ')
    if (extra) for (const l of wrap(extra, WIDTH, '   ')) L.push({ t: 'line', v: l })
  }

  if (order.note) {
    L.push({ t: 'sep' })
    for (const l of wrap('NOTE : ' + order.note)) L.push({ t: 'bold', v: l })
  }

  L.push({ t: 'sep' })
  if (Number(order.discount) > 0) {
    L.push({ t: 'line', v: pad('Sous-total', money(order.subtotal)) })
    L.push({ t: 'line', v: pad('Remise', '-' + money(order.discount)) })
  }
  L.push({ t: 'bold', v: pad('TOTAL', money(order.total)) })

  L.push({ t: 'sep' })
  L.push({
    t: 'center',
    v:
      order.status === 'AWAITING_PAYMENT'
        ? '!! NON REGLEE - PASSAGE EN CAISSE !!'
        : order.status === 'PAID'
          ? 'REGLEE'
          : 'A REGLER AU BAR',
  })

  return L
}

/** Rendu texte, pour l'aperçu à l'écran et pour les tests. */
export function ticketToText(lines) {
  return lines
    .map((l) => {
      if (l.t === 'sep') return '-'.repeat(WIDTH)
      if (l.t === 'center' || l.t === 'title' || l.t === 'big') {
        const v = l.t === 'big' ? l.v.split('').join(' ') : l.v
        const left = Math.max(0, Math.floor((WIDTH - v.length) / 2))
        return ' '.repeat(left) + v
      }
      return l.v
    })
    .join('\n')
}

// ---------------------------------------------------------------- ESC/POS
const ESC = 0x1b
const GS = 0x1d

// Une imprimante de caisse ne connaît pas l'Unicode : elle travaille par page
// de codes. CP858 (page 19) couvre le français ; tout ce qui en sort est
// translittéré plutôt que rendu en caractère parasite — un prénom mal
// accentué se lit encore, un « ▯ » non.
const CP858 = {
  é: 0x82, è: 0x8a, ê: 0x88, ë: 0x89, à: 0x85, â: 0x83, ä: 0x84,
  î: 0x8c, ï: 0x8b, ô: 0x93, ö: 0x94, ù: 0x97, û: 0x96, ü: 0x81,
  ç: 0x87, É: 0x90, È: 0xd4, Ê: 0xd2, À: 0xb7, Ç: 0x80, Î: 0xd7,
  Ô: 0xe2, Û: 0xea, Ù: 0xeb, '€': 0xd5, '°': 0xf8, '·': 0xfa,
}
const TRANSLIT = {
  '’': "'", '‘': "'", '“': '"', '”': '"', '—': '-', '–': '-', '…': '...',
  œ: 'oe', Œ: 'OE', æ: 'ae', Æ: 'AE',
}

function encodeLine(text) {
  const out = []
  for (const ch of String(text)) {
    if (TRANSLIT[ch]) {
      for (const c of TRANSLIT[ch]) out.push(c.charCodeAt(0) & 0x7f)
      continue
    }
    if (CP858[ch] !== undefined) {
      out.push(CP858[ch])
      continue
    }
    const code = ch.charCodeAt(0)
    if (code < 0x80) {
      out.push(code)
      continue
    }
    // Dernier recours : on retire l'accent plutôt que d'imprimer un pavé.
    const plain = ch.normalize('NFD').replace(/[̀-ͯ]/g, '')
    out.push(plain.length === 1 && plain.charCodeAt(0) < 0x80 ? plain.charCodeAt(0) : 0x3f)
  }
  return out
}

/**
 * Traduit les lignes en octets ESC/POS, prêts à être poussés vers
 * l'imprimante par le transport de votre choix.
 */
export function encodeEscPos(lines, { cut = true } = {}) {
  const b = []
  const push = (...bytes) => b.push(...bytes)
  const text = (s) => push(...encodeLine(s), 0x0a)
  const align = (n) => push(ESC, 0x61, n) // 0 gauche · 1 centre · 2 droite
  const bold = (on) => push(ESC, 0x45, on ? 1 : 0)
  const size = (n) => push(GS, 0x21, n) // quartet haut = largeur, bas = hauteur

  push(ESC, 0x40) // initialisation
  push(ESC, 0x74, 19) // page de codes CP858

  for (const l of lines) {
    switch (l.t) {
      case 'sep':
        align(0)
        bold(false)
        size(0)
        text('-'.repeat(WIDTH))
        break
      case 'title':
        align(1)
        bold(true)
        size(0x11) // double largeur et hauteur
        text(l.v)
        size(0)
        bold(false)
        break
      case 'big':
        align(1)
        bold(true)
        size(0x22) // triple : le code doit se lire à bout de bras
        text(l.v)
        size(0)
        bold(false)
        break
      case 'center':
        align(1)
        text(l.v)
        break
      case 'bold':
        align(0)
        bold(true)
        text(l.v)
        bold(false)
        break
      default:
        align(0)
        text(l.v)
    }
  }

  push(0x0a, 0x0a, 0x0a) // marge avant la coupe
  if (cut) push(GS, 0x56, 0x42, 0x00) // coupe partielle
  return Uint8Array.from(b)
}

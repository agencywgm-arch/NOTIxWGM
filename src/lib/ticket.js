// ============================================================================
//  NOTI Calling — ticket de commande pour imprimante thermique 80 mm
//
//  buildTicket() décide CE QUI est imprimé — indépendant de toute imprimante,
//  donc testable seul. La traduction vers le langage de l'imprimante (XML
//  ePOS-Print pour une Epson en réseau) vit dans src/lib/printer.js, avec le
//  transport : c'est la seule partie qui dépend du modèle acheté.
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


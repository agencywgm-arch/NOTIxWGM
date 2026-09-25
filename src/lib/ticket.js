// ============================================================================
//  NOTI Calling — ticket de commande pour imprimante thermique
//
//  buildTicket() décide CE QUI est imprimé — indépendant de toute imprimante,
//  donc testable seul. La traduction vers le langage de l'imprimante (XML
//  ePOS-Print pour une Epson en réseau) vit dans src/lib/printer.js, avec le
//  transport : c'est la seule partie qui dépend du modèle acheté.
// ============================================================================

// 26 caractères utiles, sur un rouleau 58 mm. Deux essais réels avant
// celui-ci ont encore coupé du texte à 42 puis à 30 — la marge de sécurité
// est volontairement large plutôt que de retenter un chiffre précis :
// mieux vaut un ticket un peu plus étroit qu'un caractère perdu dans un
// prix. Les lignes qui approchaient la largeur totale (prix alignés à
// droite sur la même ligne que l'article) ont aussi été retirées plus bas
// — chaque prix est maintenant sur sa propre ligne, courte, jamais près du
// bord quelle que soit la largeur réelle de l'imprimante.
export const WIDTH = 26

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
 *
 * `duplicate` : réimpression volontaire d'un ticket déjà sorti une fois
 * (voir printer.js / App.jsx). Un bandeau DUPLICATA en tête, avant même le
 * nom du lieu, pour qu'on ne prépare jamais deux fois la même commande en
 * la confondant avec une nouvelle arrivée.
 *
 * Hors duplicata, un bandeau NOUVELLE COMMANDE en tête à la place : ce
 * ticket sort automatiquement dès que la commande arrive (AutoPrintDaemon,
 * App.jsx), sans qu'un barman ait à cliquer quoi que ce soit — ce bandeau
 * le dit explicitement, pour qu'un ticket sans lui saute aux yeux comme
 * anormal.
 */
export function buildTicket({ order, event, venue, duplicate = false }) {
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

  if (duplicate) {
    L.push({ t: 'big', v: 'DUPLICATA' })
    L.push({ t: 'bold', v: '*** NE PAS REFAIRE ***' })
  } else {
    // Volontairement court : les lignes pleine largeur en gras/em ont déjà
    // débordé une fois (voir plus haut) — mieux vaut une marge large que de
    // retenter au plus près des 26 caractères.
    L.push({ t: 'title', v: 'NOUVELLE COMMANDE' })
  }
  L.push({ t: 'sep' })

  L.push({ t: 'title', v: (venue?.name || 'NOTI CALLING').toUpperCase() })
  if (event?.name) L.push({ t: 'center', v: event.name })
  L.push({ t: 'sep' })

  L.push({ t: 'center', v: 'CODE DE RETRAIT' })
  L.push({ t: 'big', v: order.pickup_code || '----' })
  L.push({ t: 'sep' })

  L.push({ t: 'line', v: `${hhmm(order.created_at)} - ${food ? 'FOOD' : 'BOISSONS'}` })
  if (nom) L.push({ t: 'bold', v: nom })
  if ((c.tags || []).includes('vip')) L.push({ t: 'bold', v: '*** CLIENT VIP ***' })
  L.push({ t: 'sep' })

  // Prix sur sa propre ligne, jamais aligné à droite sur la même ligne que
  // l'article : c'est cette ligne pleine largeur qui perdait un chiffre du
  // prix (« 24,00 EUR » imprimé « 4,00 EUR ») sur un ticket réel — une
  // ligne courte ne peut pas déborder, quelle que soit la largeur exacte.
  for (const it of items) {
    L.push({ t: 'bold', v: `${it.quantity}x ${it.name_snapshot}` })
    L.push({ t: 'line', v: '   ' + money(Number(it.unit_price) * Number(it.quantity)) })
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
    L.push({ t: 'line', v: `Sous-total : ${money(order.subtotal)}` })
    L.push({ t: 'line', v: `Remise : -${money(order.discount)}` })
  }
  L.push({ t: 'bold', v: `TOTAL : ${money(order.total)}` })

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
        // 'big' n'est plus qu'une question de hauteur (voir printer.js) —
        // rien à simuler en largeur ici, l'aperçu texte reste un centrage
        // ordinaire, fidèle à ce qui sort réellement.
        const left = Math.max(0, Math.floor((WIDTH - l.v.length) / 2))
        return ' '.repeat(left) + l.v
      }
      return l.v
    })
    .join('\n')
}


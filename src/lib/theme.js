// ============================================================================
//  NOTI Calling — charte graphique (non négociable, cf. feuille de route §11)
//  Crème #F7F1E9 · Terracotta #B96A4C · Bleu marine #1C2A4A · Indigo #6A5FD6
//  Dégradé signature : rose lavande #F3B6D8 → pêche #F4A57A
//  Typos : Playfair Display (titres) · Great Vibes (script) · Oswald (labels)
//          · Jost (corps)
// ============================================================================

/**
 * Chaque teinte passe par une variable CSS, avec sa valeur de charte en
 * repli. Le parcours CLIENT ne bouge pas d'un pixel : personne ne redéfinit
 * ces variables, donc c'est toujours le repli qui s'applique.
 *
 * Ce détour sert l'espace STAFF, qui adopte un rendu épuré noir et blanc
 * (voir `.noti-staff` dans index.html). Redéfinir les variables sur un
 * conteneur suffit à retourner tout ce qu'il contient — y compris les
 * composants PARTAGÉS avec le client (Sheet, Banner, Field, Empty…), qui
 * auraient sinon fallu dupliquer, avec deux versions à maintenir en
 * parallèle et l'assurance qu'elles divergent un jour.
 */
const v = (name, fallback) => `var(--n-${name}, ${fallback})`

export const C = {
  // Fonds
  cream: v('cream', '#F7F1E9'),
  creamSoft: v('creamSoft', '#FBF7F2'),
  paper: v('paper', '#FFFFFF'),

  // Couleurs de marque
  terracotta: v('terracotta', '#B96A4C'),
  terracottaSoft: v('terracottaSoft', '#E2C8B8'),
  navy: v('navy', '#1C2A4A'),
  indigo: v('indigo', '#6A5FD6'),

  // Dégradé signature
  rose: v('rose', '#F3B6D8'),
  peach: v('peach', '#F4A57A'),

  // Fonctionnel
  ok: v('ok', '#2E7D5B'),
  warn: v('warn', '#C9821F'),
  danger: v('danger', '#C0392B'),

  // Or — réservé aux cadeaux (articles offerts). Même teinte que l'accent des
  // illustrations produits, pour que « offert » se lise d'un coup d'œil au bar.
  gold: v('gold', '#C9A24B'),
  goldDark: v('goldDark', '#8A6A20'),

  // Texte
  text: v('text', '#1C2A4A'),
  dim: v('dim', '#5A6480'),
  faint: v('faint', '#98A0B4'),

  // Traits
  line: v('line', 'rgba(28,42,74,0.10)'),
  lineHi: v('lineHi', 'rgba(28,42,74,0.22)'),
}

/**
 * Teinte translucide. Remplace la concaténation `${C.gold}66`, qui ne peut
 * plus fonctionner : une variable CSS ne se laisse pas suffixer de deux
 * caractères hexadécimaux. `color-mix` a l'avantage d'accepter aussi bien un
 * hexadécimal qu'une variable, donc de marcher pour les couleurs calculées
 * (celles d'un statut de commande, par exemple).
 */
export const alpha = (color, percent) =>
  `color-mix(in srgb, ${color} ${percent}%, transparent)`

export const GRADIENT = v('gradient', `linear-gradient(120deg, ${C.rose}, ${C.peach})`)

export const FONT = {
  display: v('fontDisplay', "'Playfair Display', Georgia, serif"),
  script: v('fontScript', "'Great Vibes', cursive"),
  label: v('fontLabel', "'Oswald', 'Jost', sans-serif"),
  body: v('fontBody', "'Jost', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"),
}

/**
 * Rayon des angles. L'espace staff les resserre : l'esthétique iOS est faite
 * d'angles francs et réguliers, pas des arrondis généreux du parcours client.
 */
export const RADIUS = {
  card: v('radiusCard', '18px'),
  control: v('radiusControl', '14px'),
}

export const S = {
  page: {
    minHeight: '100vh',
    background: C.cream,
    color: C.text,
    fontFamily: FONT.body,
    paddingBottom: 'calc(env(safe-area-inset-bottom) + 24px)',
  },
  card: {
    background: C.paper,
    border: `1px solid ${C.line}`,
    borderRadius: RADIUS.card,
    padding: 18,
  },
  h1: {
    fontFamily: FONT.display,
    fontSize: 30,
    fontWeight: 700,
    lineHeight: 1.15,
    margin: 0,
  },
  h2: {
    fontFamily: FONT.label,
    fontSize: 15,
    fontWeight: 600,
    letterSpacing: 1.6,
    textTransform: 'uppercase',
    color: C.terracotta,
    margin: 0,
  },
  btn: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    width: '100%',
    minHeight: 54,
    borderRadius: RADIUS.control,
    border: 'none',
    background: C.terracotta,
    color: '#fff',
    fontFamily: FONT.label,
    fontSize: 15,
    fontWeight: 600,
    letterSpacing: 0.8,
    textTransform: 'uppercase',
    cursor: 'pointer',
  },
  btnIndigo: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    width: '100%',
    minHeight: 54,
    borderRadius: RADIUS.control,
    border: 'none',
    background: C.indigo,
    color: '#fff',
    fontFamily: FONT.label,
    fontSize: 15,
    fontWeight: 600,
    letterSpacing: 0.8,
    textTransform: 'uppercase',
    cursor: 'pointer',
  },
  btnGhost: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    width: '100%',
    minHeight: 50,
    borderRadius: RADIUS.control,
    border: `1.5px solid ${C.terracotta}`,
    background: 'transparent',
    color: C.terracotta,
    fontFamily: FONT.label,
    fontSize: 14,
    fontWeight: 600,
    letterSpacing: 0.6,
    textTransform: 'uppercase',
    cursor: 'pointer',
  },
  input: {
    width: '100%',
    minHeight: 50,
    borderRadius: RADIUS.control,
    border: `1.5px solid ${C.lineHi}`,
    background: C.paper,
    color: C.text,
    fontFamily: FONT.body,
    padding: '12px 14px',
    outline: 'none',
  },
  label: {
    display: 'block',
    fontFamily: FONT.label,
    fontSize: 11,
    fontWeight: 600,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    color: C.dim,
    marginBottom: 6,
  },
  money: { fontVariantNumeric: 'tabular-nums' },
  chip: {
    padding: '9px 15px',
    borderRadius: 999,
    border: `1.5px solid ${C.lineHi}`,
    background: 'transparent',
    color: C.dim,
    fontFamily: FONT.label,
    fontSize: 12.5,
    fontWeight: 500,
    letterSpacing: 0.6,
    whiteSpace: 'nowrap',
    cursor: 'pointer',
  },
}

// ---------------------------------------------------------------------------
//  Formats (marché français)
// ---------------------------------------------------------------------------

export const eur = (n) =>
  new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' }).format(Number(n) || 0)

export const timeFR = (d) =>
  new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit' }).format(new Date(d))

export const dateFR = (d) =>
  new Intl.DateTimeFormat('fr-FR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(d))

/**
 * Téléphone lisible. Les numéros sont stockés en E.164 (+33612345678, voir
 * 0035) ; on les rend respirables sans jamais les réécrire :
 *   +33612345678 → +33 6 12 34 56 78
 *   +34600123456 → +34 600 123 456   (étranger : groupes de 3)
 *
 * Une valeur illisible est renvoyée telle quelle plutôt que découpée
 * n'importe comment — une coquille visible se corrige, une coquille
 * maquillée en joli numéro ne se voit plus.
 */
export const phoneFR = (p) => {
  const raw = String(p || '').trim()
  if (!raw) return ''

  const e164 = normalizePhone(raw)
  if (!e164) return raw

  if (e164.startsWith('+33') && e164.length === 12) {
    const n = e164.slice(3) // 9 chiffres : 612345678
    return `+33 ${n[0]} ${n.slice(1, 3)} ${n.slice(3, 5)} ${n.slice(5, 7)} ${n.slice(7, 9)}`
  }
  // Étranger : indicatif à part, puis groupes de trois.
  const cc = e164.slice(1, 3)
  const rest = e164.slice(3)
  return `+${cc} ${rest.replace(/(\d{3})(?=\d)/g, '$1 ')}`.trim()
}

/**
 * Ramène un numéro à E.164 : « +33612345678 ».
 *
 * MÊMES RÈGLES que public.normalize_phone() (migration 0035). La base fait
 * désormais autorité — c'est elle qui garantit le format, y compris pour ce
 * qui ne passe pas par ce navigateur. Cette version sert à l'affichage
 * immédiat et à la validation avant envoi ; les deux doivent rester
 * d'accord, sinon un numéro accepté à l'écran serait refusé au serveur.
 *
 * Retour terrain : « l'autofill est inconstant — parfois +33, parfois 06,
 * parfois il supprime le zéro. » Ce n'est pas cosmétique : le téléphone est
 * l'ANCRE D'IDENTITÉ de la fiche client (voir upsert_me), comparée en
 * égalité stricte. +33612345678, 0612345678 et 612345678 désignent la même
 * personne mais créeraient trois fiches distinctes.
 *
 * E.164 plutôt que « 06… » parce que c'est le format qu'attendent tous les
 * opérateurs SMS : stocker autre chose obligerait à convertir au moment
 * d'envoyer, donc à re-normaliser dans un troisième endroit.
 *
 * Renvoie null si la saisie n'est reconnaissable comme aucun format connu.
 */
export const normalizePhone = (p) => {
  const raw = String(p ?? '').trim()
  if (!raw) return null

  // Un « + » ne compte que s'il ouvre le numéro.
  const hasPlus = raw.startsWith('+') || raw.startsWith('0033')
  const d = raw.replace(/\D/g, '')
  if (!d) return null

  // « 0033 6… » et « 0033 (0)6… » désignent le même numéro : même résultat.
  if (d.startsWith('0033')) {
    let n = d.slice(4)
    if (n.length === 10 && n.startsWith('0')) n = n.slice(1)
    return n.length === 9 && !n.startsWith('0') ? `+33${n}` : null
  }
  // Déjà international et non français : on n'y touche pas.
  if (hasPlus && !d.startsWith('33')) {
    return d.length >= 8 && d.length <= 15 ? `+${d}` : null
  }
  // +33 (0)6 12 34 56 78 — écriture très répandue. Le zéro entre parenthèses
  // est une commodité de lecture, il ne fait pas partie du numéro composé.
  let fr = d
  if (fr.startsWith('330') && fr.length === 12) fr = '33' + fr.slice(3)

  // En France, le chiffre qui suit le 0 de service va de 1 à 9 : « +330… »
  // n'existe pas et trahit une saisie de test ou une coquille.
  if (fr.startsWith('33') && fr.length === 11) {
    return fr[2] === '0' ? null : `+33${fr.slice(2)}`
  }
  if (fr.length === 10 && fr.startsWith('0')) {
    return fr[1] === '0' ? null : `+33${fr.slice(1)}`
  }
  // Le zéro initial que l'autofill escamote parfois.
  if (fr.length === 9 && !fr.startsWith('0')) return `+33${fr}`

  return null
}

/** Ancien nom, conservé le temps que les appels existants soient repris. */
export const normalizePhoneFR = normalizePhone

/** La saisie est-elle exploitable ? Sert à guider avant l'envoi. */
export const isValidPhone = (p) => normalizePhone(p) !== null

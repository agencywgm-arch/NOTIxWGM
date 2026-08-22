// ============================================================================
//  NOTI Calling — charte graphique (non négociable, cf. feuille de route §11)
//  Crème #F7F1E9 · Terracotta #B96A4C · Bleu marine #1C2A4A · Indigo #6A5FD6
//  Dégradé signature : rose lavande #F3B6D8 → pêche #F4A57A
//  Typos : Playfair Display (titres) · Great Vibes (script) · Oswald (labels)
//          · Jost (corps)
// ============================================================================

export const C = {
  // Fonds
  cream: '#F7F1E9',
  creamSoft: '#FBF7F2',
  paper: '#FFFFFF',

  // Couleurs de marque
  terracotta: '#B96A4C',
  terracottaSoft: '#E2C8B8',
  navy: '#1C2A4A',
  indigo: '#6A5FD6',

  // Dégradé signature
  rose: '#F3B6D8',
  peach: '#F4A57A',

  // Fonctionnel
  ok: '#2E7D5B',
  warn: '#C9821F',
  danger: '#C0392B',

  // Or — réservé aux cadeaux (articles offerts). Même teinte que l'accent des
  // illustrations produits, pour que « offert » se lise d'un coup d'œil au bar.
  gold: '#C9A24B',
  goldDark: '#8A6A20',

  // Texte
  text: '#1C2A4A',
  dim: '#5A6480',
  faint: '#98A0B4',

  // Traits
  line: 'rgba(28,42,74,0.10)',
  lineHi: 'rgba(28,42,74,0.22)',
}

export const GRADIENT = `linear-gradient(120deg, ${C.rose}, ${C.peach})`

export const FONT = {
  display: "'Playfair Display', Georgia, serif",
  script: "'Great Vibes', cursive",
  label: "'Oswald', 'Jost', sans-serif",
  body: "'Jost', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
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
    borderRadius: 18,
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
    borderRadius: 14,
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
    borderRadius: 14,
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
    borderRadius: 14,
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
    borderRadius: 12,
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

/** Téléphone FR lisible : 06 12 34 56 78 */
export const phoneFR = (p) => {
  const d = String(p || '').replace(/\D/g, '')
  const local = d.startsWith('33') ? '0' + d.slice(2) : d
  return local.replace(/(\d{2})(?=\d)/g, '$1 ').trim()
}

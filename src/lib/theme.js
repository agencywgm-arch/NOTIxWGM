// TAPZ — palette "Electric Violet" (dark-first, lisible de nuit)
export const C = {
  bg: '#0A0713',
  surface: '#141024',
  surfaceHi: '#1E1833',
  line: 'rgba(255,255,255,0.08)',
  lineHi: 'rgba(255,255,255,0.16)',

  primary: '#B14EFF', // violet néon
  cyan: '#00E5FF',
  hot: '#FF3D8B', // magenta — alertes, "Populaire"
  ok: '#3DFFA8', // vert menthe — "prête"
  warn: '#FFB020',

  text: '#F4F1FF',
  dim: '#9C93B8',
  faint: '#6F668C',
}

export const glow = (color = C.primary, a = 0.45, r = 24) =>
  `0 0 ${r}px ${color}${Math.round(a * 255)
    .toString(16)
    .padStart(2, '0')}`

export const S = {
  page: {
    minHeight: '100vh',
    background: C.bg,
    color: C.text,
    paddingBottom: 'calc(env(safe-area-inset-bottom) + 24px)',
  },
  card: {
    background: C.surface,
    border: `1px solid ${C.line}`,
    borderRadius: 16,
    padding: 16,
  },
  btn: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    width: '100%',
    minHeight: 52,
    borderRadius: 14,
    border: 'none',
    background: C.primary,
    color: '#fff',
    fontSize: 16,
    fontWeight: 800,
    cursor: 'pointer',
    boxShadow: '0 0 24px rgba(177,78,255,.45)',
  },
  btnGhost: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    width: '100%',
    minHeight: 48,
    borderRadius: 14,
    border: `1px solid ${C.lineHi}`,
    background: 'transparent',
    color: C.text,
    fontSize: 15,
    fontWeight: 700,
    cursor: 'pointer',
  },
  input: {
    width: '100%',
    minHeight: 48,
    borderRadius: 12,
    border: `1px solid ${C.lineHi}`,
    background: C.surfaceHi,
    color: C.text,
    padding: '12px 14px',
    outline: 'none',
  },
  label: {
    display: 'block',
    fontSize: 12,
    fontWeight: 700,
    color: C.dim,
    marginBottom: 6,
    letterSpacing: 0.4,
  },
  money: { fontVariantNumeric: 'tabular-nums' },
  chip: {
    padding: '6px 12px',
    borderRadius: 999,
    border: `1px solid ${C.lineHi}`,
    background: 'transparent',
    color: C.dim,
    fontSize: 13,
    fontWeight: 700,
    whiteSpace: 'nowrap',
    cursor: 'pointer',
  },
}

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

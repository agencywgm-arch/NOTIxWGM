// ============================================================================
//  TAPZ — Scanne. Commande. Trinque.
//  SaaS de commande par QR code pour bars & monde de la nuit.
//  AUCUN PAIEMENT EN LIGNE : le règlement se fait au comptoir. On génère une
//  facture / récapitulatif et on suit l'encaissement, c'est tout.
//
//  URL QR stable — NE JAMAIS CASSER :  /r/{bar_id}/t/{table_number}
// ============================================================================

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { supabase, isConfigured, frAuthError, BASE_PATH, tableUrl } from './lib/supabase.js'
import { C, S, eur, timeFR, dateFR } from './lib/theme.js'
import {
  canvasesToPdfBlob,
  shareOrDownload,
  makeCanvas,
  roundRect,
  wrapText,
  loadImage,
  canvasToPng,
} from './lib/pdf.js'
import { Alarm, chime, tick, unlockAudio } from './lib/sound.js'
import { pushSupported, registerServiceWorker, subscribePush, sendPush, vibrate } from './lib/push.js'

// ----------------------------------------------------------------------------
//  Routeur minimal (history API, compatible GitHub Pages via 404.html)
// ----------------------------------------------------------------------------

function currentRoute() {
  if (typeof window === 'undefined') return '/'
  const p = window.location.pathname
  const base = BASE_PATH.replace(/\/$/, '')
  const rel = base && p.startsWith(base) ? p.slice(base.length) : p
  return rel || '/'
}

function navigate(to) {
  const base = BASE_PATH.replace(/\/$/, '')
  window.history.pushState({}, '', `${base}${to.startsWith('/') ? to : `/${to}`}`)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

function useRoute() {
  const [route, setRoute] = useState(currentRoute())
  useEffect(() => {
    const on = () => setRoute(currentRoute())
    window.addEventListener('popstate', on)
    return () => window.removeEventListener('popstate', on)
  }, [])
  return route
}

/** /r/{bar_id}/t/{table_number} */
function parseClientRoute(route) {
  const m = route.match(/^\/r\/([0-9a-fA-F-]{36})\/t\/(\d+)\/?$/)
  if (!m) return null
  return { barId: m[1], tableNumber: parseInt(m[2], 10) }
}

// ----------------------------------------------------------------------------
//  Petits utilitaires
// ----------------------------------------------------------------------------

const LS = {
  get(k, fallback = null) {
    try {
      const v = localStorage.getItem(k)
      return v ? JSON.parse(v) : fallback
    } catch (_) {
      return fallback
    }
  },
  set(k, v) {
    try {
      localStorage.setItem(k, JSON.stringify(v))
    } catch (_) {}
  },
  del(k) {
    try {
      localStorage.removeItem(k)
    } catch (_) {}
  },
}

const uid = () => Math.random().toString(36).slice(2, 10)

const STATUS = {
  PENDING: { label: 'Reçue', color: C.hot, step: 1 },
  PREPARING: { label: 'En préparation', color: C.warn, step: 2 },
  READY: { label: 'Prête à récupérer', color: C.ok, step: 3 },
  DONE: { label: 'Servie', color: C.dim, step: 4 },
  CANCELLED: { label: 'Annulée', color: C.faint, step: 0 },
}

/** Applique la marge d'export (n'affecte jamais la carte réelle ni les commandes). */
const withMargin = (price, pct) => Number(price || 0) * (1 + (Number(pct) || 0) / 100)

/** Prix unitaire d'une ligne panier = base + options + extras. */
function lineUnitPrice(line) {
  const opts = (line.options || []).reduce((s, o) => s + Number(o.price || 0), 0)
  const extras = (line.extras || []).reduce((s, e) => s + Number(e.price || 0), 0)
  return Number(line.item.price || 0) + opts + extras
}

const lineTotal = (line) => lineUnitPrice(line) * line.quantity

/** Vrai si une promo "happy hour" s'applique maintenant. */
function promoActiveNow(p, now = new Date()) {
  if (!p.active) return false
  if (p.starts_at && new Date(p.starts_at) > now) return false
  if (p.ends_at && new Date(p.ends_at) < now) return false
  if (Array.isArray(p.days_of_week) && p.days_of_week.length && !p.days_of_week.includes(now.getDay()))
    return false
  if (p.start_time && p.end_time) {
    const hhmm = now.toTimeString().slice(0, 8)
    const a = p.start_time.slice(0, 8)
    const b = p.end_time.slice(0, 8)
    // Créneau à cheval sur minuit (typique en boîte de nuit) : 22:00 → 02:00
    if (a <= b ? !(hhmm >= a && hhmm <= b) : !(hhmm >= a || hhmm <= b)) return false
  }
  return true
}

function computeDiscount(promo, subtotal) {
  if (!promo) return 0
  if (subtotal < Number(promo.min_total || 0)) return 0
  const v = Number(promo.value || 0)
  const raw = promo.kind === 'amount' ? v : (subtotal * v) / 100
  return Math.min(Math.round(raw * 100) / 100, subtotal)
}

// ----------------------------------------------------------------------------
//  Composants UI partagés
// ----------------------------------------------------------------------------

function Spinner({ label = 'Chargement…' }) {
  return (
    <div
      style={{
        minHeight: '60vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 14,
        color: C.dim,
      }}
    >
      <div
        style={{
          width: 34,
          height: 34,
          borderRadius: '50%',
          border: `3px solid ${C.line}`,
          borderTopColor: C.primary,
          animation: 'tapzspin 0.8s linear infinite',
        }}
      />
      <style>{`@keyframes tapzspin{to{transform:rotate(360deg)}}
        @keyframes tapzpulse{0%,100%{opacity:1}50%{opacity:.45}}
        @keyframes tapzin{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}`}</style>
      <div style={{ fontSize: 13 }}>{label}</div>
    </div>
  )
}

function Logo({ size = 13 }) {
  return (
    <div
      style={{
        fontSize: size,
        letterSpacing: 5,
        fontWeight: 900,
        color: C.primary,
        textShadow: '0 0 18px rgba(177,78,255,.7)',
      }}
    >
      TAPZ
    </div>
  )
}

function Toast({ toast }) {
  if (!toast) return null
  const bg = toast.kind === 'error' ? C.hot : toast.kind === 'ok' ? C.ok : C.primary
  return (
    <div
      style={{
        position: 'fixed',
        left: 16,
        right: 16,
        bottom: 'calc(env(safe-area-inset-bottom) + 90px)',
        zIndex: 9000,
        background: C.surfaceHi,
        border: `1px solid ${bg}`,
        color: C.text,
        borderRadius: 14,
        padding: '14px 16px',
        fontSize: 14,
        fontWeight: 600,
        boxShadow: `0 0 30px ${bg}55`,
        animation: 'tapzin .18s ease',
      }}
    >
      {toast.msg}
    </div>
  )
}

function useToast() {
  const [toast, setToast] = useState(null)
  const show = useCallback((msg, kind = 'info') => {
    setToast({ msg, kind })
    setTimeout(() => setToast(null), 3200)
  }, [])
  return [toast, show]
}

function Sheet({ open, onClose, title, children, maxHeight = '86vh' }) {
  if (!open) return null
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 8000,
        background: 'rgba(3,2,8,.72)',
        backdropFilter: 'blur(6px)',
        display: 'flex',
        alignItems: 'flex-end',
        justifyContent: 'center',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: '100%',
          maxWidth: 560,
          maxHeight,
          overflowY: 'auto',
          background: C.surface,
          border: `1px solid ${C.lineHi}`,
          borderBottom: 'none',
          borderRadius: '22px 22px 0 0',
          padding: 20,
          paddingBottom: 'calc(env(safe-area-inset-bottom) + 20px)',
          animation: 'tapzin .2s ease',
        }}
      >
        <div
          style={{
            width: 42,
            height: 4,
            borderRadius: 2,
            background: C.lineHi,
            margin: '0 auto 16px',
          }}
        />
        {title && (
          <div style={{ fontSize: 19, fontWeight: 900, marginBottom: 14 }}>{title}</div>
        )}
        {children}
      </div>
    </div>
  )
}

function Field({ label, children }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <label style={S.label}>{label}</label>
      {children}
    </div>
  )
}

function Empty({ emoji = '🌙', title, sub }) {
  return (
    <div style={{ textAlign: 'center', padding: '46px 20px', color: C.dim }}>
      <div style={{ fontSize: 44, marginBottom: 10 }}>{emoji}</div>
      <div style={{ fontWeight: 800, color: C.text, marginBottom: 6 }}>{title}</div>
      {sub && <div style={{ fontSize: 13, lineHeight: 1.5 }}>{sub}</div>}
    </div>
  )
}

// ============================================================================
//  RACINE
// ============================================================================

export default function App() {
  const route = useRoute()
  const client = parseClientRoute(route)
  const [session, setSession] = useState(undefined)

  useEffect(() => {
    if (!isConfigured) return
    supabase.auth.getSession().then(({ data }) => setSession(data.session ?? null))
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s ?? null))
    return () => data.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    registerServiceWorker()
  }, [])

  if (!isConfigured) return <ConfigScreen />
  if (client) return <ClientApp barId={client.barId} tableNumber={client.tableNumber} />
  if (session === undefined) return <div style={S.page}><Spinner /></div>
  if (!session) return <AuthScreen />
  return <AdminApp session={session} />
}

function ConfigScreen() {
  return (
    <div style={{ ...S.page, padding: 24 }}>
      <Logo />
      <div style={{ ...S.card, marginTop: 24 }}>
        <div style={{ fontSize: 20, fontWeight: 900, marginBottom: 10 }}>Configuration requise</div>
        <p style={{ color: C.dim, fontSize: 14, lineHeight: 1.7 }}>
          Renseignez <code style={{ color: C.cyan }}>VITE_SUPABASE_URL</code> et{' '}
          <code style={{ color: C.cyan }}>VITE_SUPABASE_ANON_KEY</code> dans un fichier{' '}
          <code style={{ color: C.cyan }}>.env</code> à la racine (voir{' '}
          <code style={{ color: C.cyan }}>.env.example</code>), puis relancez{' '}
          <code style={{ color: C.cyan }}>npm run dev</code>.
        </p>
        <p style={{ color: C.faint, fontSize: 13, lineHeight: 1.7, marginTop: 12 }}>
          En production (GitHub Pages), ces valeurs sont injectées par le workflow depuis les
          secrets du dépôt.
        </p>
      </div>
    </div>
  )
}

// ============================================================================
//  AUTH PROPRIÉTAIRE
// ============================================================================

function AuthScreen() {
  const [mode, setMode] = useState('login') // login | signup
  const [account, setAccount] = useState('solo') // solo | groupe
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [info, setInfo] = useState('')

  async function submit(e) {
    e.preventDefault()
    setErr('')
    setInfo('')
    setBusy(true)
    try {
      if (mode === 'signup') {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { data: { account_type: account } },
        })
        if (error) throw error

        // Supabase renvoie un user sans identités quand l'e-mail existe déjà.
        if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
          setMode('login')
          setErr('Cet e-mail est déjà utilisé. Connectez-vous ci-dessous.')
          return
        }
        if (data.session) return // compte auto-confirmé → connexion directe
        setInfo('Compte créé. Vérifiez votre boîte mail pour confirmer, puis connectez-vous.')
        setMode('login')
      } else {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        })
        if (error) throw error
      }
    } catch (e2) {
      setErr(frAuthError(e2))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      style={{
        ...S.page,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 20,
      }}
    >
      <div style={{ width: '100%', maxWidth: 420 }}>
        <div style={{ textAlign: 'center', marginBottom: 26 }}>
          <div style={{ fontSize: 46, marginBottom: 8 }}>🍸</div>
          <Logo size={16} />
          <div style={{ color: C.dim, fontSize: 13, marginTop: 8 }}>
            Scanne. Commande. Trinque.
          </div>
        </div>

        <form onSubmit={submit} style={S.card}>
          <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
            {['login', 'signup'].map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => {
                  setMode(m)
                  setErr('')
                  setInfo('')
                }}
                style={{
                  flex: 1,
                  minHeight: 44,
                  borderRadius: 12,
                  border: 'none',
                  cursor: 'pointer',
                  fontWeight: 800,
                  fontSize: 14,
                  background: mode === m ? C.primary : C.surfaceHi,
                  color: mode === m ? '#fff' : C.dim,
                }}
              >
                {m === 'login' ? 'Connexion' : 'Créer un compte'}
              </button>
            ))}
          </div>

          {mode === 'signup' && (
            <Field label="TYPE DE COMPTE">
              <div style={{ display: 'flex', gap: 8 }}>
                {[
                  { k: 'solo', t: 'Un seul bar', e: '🍺' },
                  { k: 'groupe', t: 'Groupe / plusieurs bars', e: '🏙️' },
                ].map((o) => (
                  <button
                    key={o.k}
                    type="button"
                    onClick={() => setAccount(o.k)}
                    style={{
                      flex: 1,
                      padding: '12px 8px',
                      borderRadius: 12,
                      cursor: 'pointer',
                      border: `1px solid ${account === o.k ? C.primary : C.lineHi}`,
                      background: account === o.k ? 'rgba(177,78,255,.14)' : 'transparent',
                      color: account === o.k ? C.text : C.dim,
                      fontSize: 12,
                      fontWeight: 700,
                      lineHeight: 1.4,
                    }}
                  >
                    <div style={{ fontSize: 20, marginBottom: 4 }}>{o.e}</div>
                    {o.t}
                  </button>
                ))}
              </div>
            </Field>
          )}

          <Field label="E-MAIL">
            <input
              style={S.input}
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="vous@votrebar.fr"
            />
          </Field>

          <Field label="MOT DE PASSE">
            <input
              style={S.input}
              type="password"
              required
              minLength={6}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="6 caractères minimum"
            />
          </Field>

          {err && (
            <div
              style={{
                background: 'rgba(255,61,139,.12)',
                border: `1px solid ${C.hot}55`,
                color: C.hot,
                padding: 12,
                borderRadius: 12,
                fontSize: 13,
                marginBottom: 12,
                fontWeight: 600,
              }}
            >
              {err}
            </div>
          )}
          {info && (
            <div
              style={{
                background: 'rgba(61,255,168,.1)',
                border: `1px solid ${C.ok}55`,
                color: C.ok,
                padding: 12,
                borderRadius: 12,
                fontSize: 13,
                marginBottom: 12,
                fontWeight: 600,
              }}
            >
              {info}
            </div>
          )}

          <button type="submit" disabled={busy} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
            {busy ? '…' : mode === 'login' ? 'Se connecter' : 'Créer mon compte'}
          </button>
        </form>

        <div style={{ textAlign: 'center', color: C.faint, fontSize: 11, marginTop: 20, lineHeight: 1.7 }}>
          Aucun paiement en ligne · Le règlement se fait au bar
        </div>
      </div>
    </div>
  )
}

// ============================================================================
//  CÔTÉ CLIENT — /r/{bar_id}/t/{table_number}
// ============================================================================

const LANG_LABEL = {
  fr: 'Français',
  en: 'English',
  es: 'Español',
  it: 'Italiano',
  de: 'Deutsch',
  pt: 'Português',
  nl: 'Nederlands',
  ar: 'العربية',
}

function tr(item, lang) {
  if (!lang || lang === 'fr') return { name: item.name, description: item.description }
  const t = item.translations?.[lang]
  return {
    name: t?.name || item.name,
    description: t?.description || item.description,
  }
}

function ClientApp({ barId, tableNumber }) {
  const [bar, setBar] = useState(null)
  const [settings, setSettings] = useState(null)
  const [table, setTable] = useState(null)
  const [items, setItems] = useState([])
  const [promos, setPromos] = useState([])
  const [loading, setLoading] = useState(true)
  const [fatal, setFatal] = useState('')

  const [step, setStep] = useState('type') // type | menu | sent
  const [orderType, setOrderType] = useState('sur_place')
  const [lang, setLang] = useState('fr')
  const [cart, setCart] = useState([])
  const [category, setCategory] = useState(null)
  const [sheetItem, setSheetItem] = useState(null)
  const [cartOpen, setCartOpen] = useState(false)
  const [checkoutOpen, setCheckoutOpen] = useState(false)
  const [orderId, setOrderId] = useState(null)
  const [toast, showToast] = useToast()

  const storeKey = `tapz:order:${barId}:${tableNumber}`

  // ---- Chargement initial -------------------------------------------------
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const [barRes, setRes, menuRes, promoRes] = await Promise.all([
          supabase.from('bars').select('*').eq('id', barId).single(),
          supabase.from('bar_settings').select('*').eq('bar_id', barId).maybeSingle(),
          supabase
            .from('menu_items')
            .select('*')
            .eq('bar_id', barId)
            .order('category')
            .order('sort_order'),
          supabase.from('promotions').select('*').eq('bar_id', barId).eq('active', true),
        ])
        if (cancelled) return
        if (barRes.error) throw barRes.error

        setBar(barRes.data)
        setSettings(setRes.data || { default_eta_min: 10, accept_orders: true, languages: ['fr'] })
        setItems(menuRes.data || [])
        setPromos(promoRes.data || [])

        // Table enregistrée à la volée si le QR pointe vers un numéro inconnu.
        const { data: tid } = await supabase.rpc('ensure_table', {
          p_bar: barId,
          p_number: tableNumber,
        })
        if (tid) {
          const { data: t } = await supabase.from('tables').select('*').eq('id', tid).single()
          if (!cancelled) setTable(t)
        }

        // Reprise du suivi après refresh / verrouillage du téléphone.
        const saved = LS.get(storeKey)
        if (saved?.orderId) {
          const { data: o } = await supabase
            .from('orders')
            .select('id, created_at')
            .eq('id', saved.orderId)
            .maybeSingle()
          const fresh = o && Date.now() - new Date(o.created_at).getTime() < 12 * 3600 * 1000
          if (fresh && !cancelled) {
            setOrderId(o.id)
            setStep('sent')
          } else {
            LS.del(storeKey)
          }
        }
      } catch (e) {
        if (!cancelled) setFatal(e.message || 'Établissement introuvable.')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [barId, tableNumber, storeKey])

  const categories = useMemo(() => {
    const order = settings?.category_order
    const found = [...new Set(items.filter((i) => i.available).map((i) => i.category))]
    if (Array.isArray(order) && order.length) {
      const ranked = order.filter((c) => found.includes(c))
      return [...ranked, ...found.filter((c) => !ranked.includes(c))]
    }
    return found
  }, [items, settings])

  useEffect(() => {
    if (!category && categories.length) setCategory(categories[0])
  }, [categories, category])

  const subtotal = useMemo(() => cart.reduce((s, l) => s + lineTotal(l), 0), [cart])
  const cartCount = useMemo(() => cart.reduce((s, l) => s + l.quantity, 0), [cart])

  const autoPromo = useMemo(
    () => promos.filter((p) => !p.code && promoActiveNow(p) && subtotal >= Number(p.min_total || 0))[0] || null,
    [promos, subtotal]
  )

  function addToCart(item, options = [], extras = [], quantity = 1) {
    unlockAudio()
    tick()
    vibrate([16])
    setCart((prev) => {
      const sig = JSON.stringify([
        item.id,
        options.map((o) => o.id).sort(),
        extras.map((e) => e.id).sort(),
      ])
      const found = prev.find((l) => l.sig === sig)
      if (found) {
        return prev.map((l) => (l.sig === sig ? { ...l, quantity: l.quantity + quantity } : l))
      }
      return [...prev, { key: uid(), sig, item, options, extras, quantity }]
    })
  }

  const setQty = (key, delta) =>
    setCart((prev) =>
      prev
        .map((l) => (l.key === key ? { ...l, quantity: l.quantity + delta } : l))
        .filter((l) => l.quantity > 0)
    )

  // ---- Envoi de la commande ----------------------------------------------
  async function submitOrder({ name, email, note, promoCode }) {
    const codePromo = promoCode
      ? promos.find(
          (p) =>
            (p.code || '').toUpperCase() === promoCode.trim().toUpperCase() && promoActiveNow(p)
        )
      : null
    const promo = codePromo || autoPromo
    const discount = computeDiscount(promo, subtotal)
    const total = Math.max(0, Math.round((subtotal - discount) * 100) / 100)
    const eta = Number(settings?.default_eta_min || 10)

    const { data: order, error } = await supabase
      .from('orders')
      .insert({
        bar_id: barId,
        table_id: table?.id ?? null,
        status: 'PENDING',
        subtotal,
        discount,
        total,
        promo_code: promo?.code || (promo ? promo.label : null),
        note: note?.trim() || null,
        customer_name: name?.trim() || null,
        customer_email: email?.trim() || null,
        order_type: orderType,
        estimated_ready_at: new Date(Date.now() + eta * 60000).toISOString(),
      })
      .select()
      .single()

    if (error) throw error

    const rows = cart.map((l) => ({
      order_id: order.id,
      menu_item_id: l.item.id,
      name_snapshot: l.item.name,
      unit_price: lineUnitPrice(l),
      vat_rate: l.item.vat_rate ?? 20,
      quantity: l.quantity,
      detail: {
        options: l.options.map((o) => ({ id: o.id, name: o.name, price: o.price })),
        extras: l.extras.map((e) => ({ id: e.id, name: e.name, price: e.price })),
      },
    }))
    if (rows.length) {
      const { error: e2 } = await supabase.from('order_items').insert(rows)
      if (e2) throw e2
    }

    LS.set(storeKey, { orderId: order.id, at: Date.now() })
    setOrderId(order.id)
    setCart([])
    setCheckoutOpen(false)
    setCartOpen(false)
    setStep('sent')

    // Notifie le comptoir (best-effort, ne bloque jamais le client).
    sendPush({
      barId,
      role: 'staff',
      title: '🔔 Nouvelle commande',
      body: `Table ${tableNumber} · ${eur(total)}`,
      requireInteraction: true,
      tag: `tapz-staff-${barId}`,
    })

    if (email?.trim()) {
      supabase.functions.invoke('send-receipt', { body: { orderId: order.id } }).catch(() => {})
    }
  }

  // ---- Rendu --------------------------------------------------------------
  if (loading) return <div style={S.page}><Spinner label="Ouverture de la carte…" /></div>

  if (fatal)
    return (
      <div style={{ ...S.page, padding: 24 }}>
        <Empty emoji="🚫" title="Établissement introuvable" sub={fatal} />
      </div>
    )

  if (step === 'sent' && orderId)
    return (
      <TrackingScreen
        orderId={orderId}
        bar={bar}
        tableNumber={tableNumber}
        onNewOrder={() => {
          LS.del(storeKey)
          setOrderId(null)
          setStep('menu')
        }}
      />
    )

  if (step === 'type')
    return (
      <TypeScreen
        bar={bar}
        settings={settings}
        table={table}
        tableNumber={tableNumber}
        onPick={(t) => {
          unlockAudio()
          setOrderType(t)
          setStep('menu')
        }}
      />
    )

  const visible = items.filter((i) => i.available && i.category === category)
  const langs = settings?.languages?.length ? settings.languages : ['fr']

  return (
    <div style={S.page}>
      {/* Hero */}
      <div
        style={{
          padding: '18px 18px 14px',
          background: `linear-gradient(160deg, rgba(177,78,255,.22), rgba(0,229,255,.06) 55%, transparent)`,
          borderBottom: `1px solid ${C.line}`,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <Logo size={11} />
          {langs.length > 1 && (
            <select
              value={lang}
              onChange={(e) => setLang(e.target.value)}
              style={{
                background: C.surfaceHi,
                color: C.text,
                border: `1px solid ${C.lineHi}`,
                borderRadius: 10,
                padding: '6px 8px',
                fontSize: 12,
              }}
            >
              {langs.map((l) => (
                <option key={l} value={l}>
                  {LANG_LABEL[l] || l}
                </option>
              ))}
            </select>
          )}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 12 }}>
          {bar?.logo_url ? (
            <img
              src={bar.logo_url}
              alt=""
              style={{ width: 48, height: 48, borderRadius: 14, objectFit: 'cover' }}
            />
          ) : (
            <div style={{ fontSize: 38 }}>{bar?.logo_emoji || '🍸'}</div>
          )}
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 23, fontWeight: 900, lineHeight: 1.1 }}>{bar?.name}</div>
            <div style={{ color: C.cyan, fontSize: 13, fontWeight: 700, marginTop: 3 }}>
              {table?.label ? `${table.label} · ` : ''}Table {tableNumber} ·{' '}
              {orderType === 'sur_place' ? 'Sur place' : 'À emporter'}
            </div>
          </div>
        </div>
        {settings?.service_message && (
          <div
            style={{
              marginTop: 12,
              padding: 10,
              borderRadius: 12,
              background: 'rgba(255,176,32,.12)',
              border: `1px solid ${C.warn}44`,
              color: C.warn,
              fontSize: 12,
              fontWeight: 700,
            }}
          >
            {settings.service_message}
          </div>
        )}
      </div>

      {/* Catégories (sticky) */}
      <div
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 40,
          background: `${C.bg}f2`,
          backdropFilter: 'blur(10px)',
          borderBottom: `1px solid ${C.line}`,
          padding: '10px 14px',
          display: 'flex',
          gap: 8,
          overflowX: 'auto',
        }}
      >
        {categories.map((c) => (
          <button
            key={c}
            onClick={() => setCategory(c)}
            style={{
              ...S.chip,
              borderColor: category === c ? C.primary : C.lineHi,
              background: category === c ? 'rgba(177,78,255,.18)' : 'transparent',
              color: category === c ? C.text : C.dim,
            }}
          >
            {c}
          </button>
        ))}
      </div>

      {/* Carte */}
      <div style={{ padding: 14, display: 'grid', gap: 12 }}>
        {visible.length === 0 && (
          <Empty emoji="🍹" title="Rien dans cette catégorie" sub="Choisissez-en une autre." />
        )}
        {visible.map((item) => (
          <ItemCard
            key={item.id}
            item={item}
            lang={lang}
            onAdd={() => {
              const composable =
                (item.supplements || []).length > 0 || (item.extras || []).length > 0
              if (composable) setSheetItem(item)
              else addToCart(item)
            }}
          />
        ))}
      </div>

      {/* Panier flottant */}
      {cartCount > 0 && (
        <div
          style={{
            position: 'fixed',
            left: 12,
            right: 12,
            bottom: 'calc(env(safe-area-inset-bottom) + 12px)',
            zIndex: 50,
          }}
        >
          <button
            onClick={() => setCartOpen(true)}
            style={{
              ...S.btn,
              minHeight: 58,
              justifyContent: 'space-between',
              padding: '0 18px',
              fontSize: 16,
            }}
          >
            <span style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span
                style={{
                  background: 'rgba(0,0,0,.28)',
                  borderRadius: 999,
                  padding: '3px 11px',
                  fontSize: 14,
                }}
              >
                {cartCount}
              </span>
              Voir le panier
            </span>
            <span style={S.money}>{eur(subtotal)}</span>
          </button>
        </div>
      )}

      <OptionsSheet
        item={sheetItem}
        lang={lang}
        onClose={() => setSheetItem(null)}
        onConfirm={(options, extras, qty) => {
          addToCart(sheetItem, options, extras, qty)
          setSheetItem(null)
        }}
      />

      <CartSheet
        open={cartOpen}
        cart={cart}
        lang={lang}
        subtotal={subtotal}
        autoPromo={autoPromo}
        onClose={() => setCartOpen(false)}
        onQty={setQty}
        onCheckout={() => {
          setCartOpen(false)
          setCheckoutOpen(true)
        }}
      />

      <CheckoutSheet
        open={checkoutOpen}
        subtotal={subtotal}
        promos={promos}
        autoPromo={autoPromo}
        etaMin={settings?.default_eta_min || 10}
        onClose={() => setCheckoutOpen(false)}
        onSubmit={async (payload) => {
          try {
            await submitOrder(payload)
          } catch (e) {
            showToast(
              e.message?.includes('row-level security')
                ? "Le bar n'accepte pas de commandes pour le moment."
                : e.message || 'Envoi impossible.',
              'error'
            )
          }
        }}
      />

      <Toast toast={toast} />
    </div>
  )
}

function TypeScreen({ bar, settings, table, tableNumber, onPick }) {
  const closed = settings && settings.accept_orders === false
  return (
    <div
      style={{
        ...S.page,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        padding: 24,
      }}
    >
      <div style={{ textAlign: 'center', marginBottom: 34 }}>
        {bar?.logo_url ? (
          <img
            src={bar.logo_url}
            alt=""
            style={{ width: 84, height: 84, borderRadius: 24, objectFit: 'cover', marginBottom: 14 }}
          />
        ) : (
          <div style={{ fontSize: 60, marginBottom: 10 }}>{bar?.logo_emoji || '🍸'}</div>
        )}
        <div style={{ fontSize: 27, fontWeight: 900 }}>{bar?.name}</div>
        <div style={{ color: C.cyan, fontSize: 14, fontWeight: 700, marginTop: 6 }}>
          {table?.label ? `${table.label} · ` : ''}Table {tableNumber}
        </div>
      </div>

      {closed ? (
        <div style={{ ...S.card, textAlign: 'center', borderColor: `${C.hot}55` }}>
          <div style={{ fontSize: 34, marginBottom: 8 }}>🌙</div>
          <div style={{ fontWeight: 800, marginBottom: 6 }}>Commandes fermées</div>
          <div style={{ color: C.dim, fontSize: 13 }}>
            {settings?.service_message || 'Le comptoir ne prend plus de commandes pour le moment.'}
          </div>
        </div>
      ) : (
        <div style={{ display: 'grid', gap: 12 }}>
          {[
            { k: 'sur_place', e: '🪩', t: 'Sur place', s: 'Servi à votre table' },
            { k: 'a_emporter', e: '🥤', t: 'À emporter', s: 'À récupérer au comptoir' },
          ].map((o) => (
            <button
              key={o.k}
              onClick={() => onPick(o.k)}
              style={{
                ...S.card,
                display: 'flex',
                alignItems: 'center',
                gap: 16,
                cursor: 'pointer',
                textAlign: 'left',
                minHeight: 84,
                color: C.text,
              }}
            >
              <div style={{ fontSize: 34 }}>{o.e}</div>
              <div>
                <div style={{ fontSize: 17, fontWeight: 800 }}>{o.t}</div>
                <div style={{ color: C.dim, fontSize: 13, marginTop: 2 }}>{o.s}</div>
              </div>
            </button>
          ))}
        </div>
      )}

      <div style={{ textAlign: 'center', marginTop: 30 }}>
        <Logo size={11} />
        <div style={{ color: C.faint, fontSize: 11, marginTop: 10 }}>
          Paiement au bar uniquement
        </div>
      </div>
    </div>
  )
}

function ItemCard({ item, lang, onAdd }) {
  const t = tr(item, lang)
  const out = item.stock != null && item.stock <= 0
  return (
    <div
      style={{
        ...S.card,
        padding: 0,
        overflow: 'hidden',
        opacity: out ? 0.5 : 1,
        display: 'flex',
      }}
    >
      <div
        style={{
          width: 92,
          flexShrink: 0,
          background: `linear-gradient(140deg, rgba(177,78,255,.28), rgba(0,229,255,.12))`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 34,
        }}
      >
        {item.photo_url ? (
          <img
            src={item.photo_url}
            alt=""
            style={{ width: '100%', height: '100%', objectFit: 'cover' }}
          />
        ) : (
          item.emoji || '🍹'
        )}
      </div>

      <div style={{ flex: 1, padding: 12, minWidth: 0 }}>
        <div style={{ display: 'flex', gap: 6, marginBottom: 5, flexWrap: 'wrap' }}>
          {item.is_popular && (
            <span
              style={{
                fontSize: 10,
                fontWeight: 900,
                color: C.hot,
                background: 'rgba(255,61,139,.14)',
                border: `1px solid ${C.hot}55`,
                borderRadius: 999,
                padding: '2px 8px',
                letterSpacing: 0.5,
              }}
            >
              🔥 POPULAIRE
            </span>
          )}
          {item.is_menu && (
            <span
              style={{
                fontSize: 10,
                fontWeight: 900,
                color: C.cyan,
                background: 'rgba(0,229,255,.12)',
                border: `1px solid ${C.cyan}55`,
                borderRadius: 999,
                padding: '2px 8px',
                letterSpacing: 0.5,
              }}
            >
              FORMULE
            </span>
          )}
        </div>

        <div style={{ fontWeight: 800, fontSize: 15, lineHeight: 1.25 }}>{t.name}</div>
        {t.description && (
          <div
            style={{
              color: C.dim,
              fontSize: 12.5,
              marginTop: 4,
              lineHeight: 1.45,
              display: '-webkit-box',
              WebkitLineClamp: 2,
              WebkitBoxOrient: 'vertical',
              overflow: 'hidden',
            }}
          >
            {t.description}
          </div>
        )}

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            marginTop: 10,
            gap: 10,
          }}
        >
          <div style={{ ...S.money, fontSize: 17, fontWeight: 900, color: C.primary }}>
            {eur(item.price)}
          </div>
          <button
            disabled={out}
            onClick={onAdd}
            style={{
              minHeight: 40,
              minWidth: 88,
              borderRadius: 12,
              border: 'none',
              background: out ? C.surfaceHi : C.primary,
              color: out ? C.faint : '#fff',
              fontWeight: 800,
              fontSize: 14,
              cursor: out ? 'not-allowed' : 'pointer',
              boxShadow: out ? 'none' : '0 0 16px rgba(177,78,255,.4)',
            }}
          >
            {out ? 'Épuisé' : 'Ajouter'}
          </button>
        </div>
      </div>
    </div>
  )
}

/** Tunnel d'options : base alcool → sirop → garnitures → extras. */
function OptionsSheet({ item, lang, onClose, onConfirm }) {
  const [picked, setPicked] = useState({})
  const [extras, setExtras] = useState([])
  const [qty, setQty] = useState(1)

  useEffect(() => {
    if (!item) return
    const init = {}
    for (const g of item.supplements || []) {
      init[g.id] = g.required && (g.options || [])[0] ? [(g.options || [])[0].id] : []
    }
    setPicked(init)
    setExtras([])
    setQty(1)
  }, [item])

  if (!item) return null
  const t = tr(item, lang)
  const groups = item.supplements || []

  const toggle = (g, optId) => {
    setPicked((prev) => {
      const cur = prev[g.id] || []
      const max = g.max ?? (g.multiple ? 99 : 1)
      if (cur.includes(optId)) {
        const next = cur.filter((x) => x !== optId)
        if (g.required && next.length === 0) return prev
        return { ...prev, [g.id]: next }
      }
      if (max === 1) return { ...prev, [g.id]: [optId] }
      if (cur.length >= max) return prev
      return { ...prev, [g.id]: [...cur, optId] }
    })
  }

  const chosen = groups.flatMap((g) =>
    (picked[g.id] || [])
      .map((id) => (g.options || []).find((o) => o.id === id))
      .filter(Boolean)
      .map((o) => ({ ...o, groupId: g.id, groupName: g.name }))
  )
  const chosenExtras = (item.extras || []).filter((e) => extras.includes(e.id))
  const unit =
    Number(item.price || 0) +
    chosen.reduce((s, o) => s + Number(o.price || 0), 0) +
    chosenExtras.reduce((s, e) => s + Number(e.price || 0), 0)

  const missing = groups.filter((g) => g.required && (picked[g.id] || []).length < (g.min ?? 1))

  return (
    <Sheet open={!!item} onClose={onClose} title={t.name}>
      {t.description && (
        <div style={{ color: C.dim, fontSize: 13, marginTop: -6, marginBottom: 16, lineHeight: 1.5 }}>
          {t.description}
        </div>
      )}

      {groups.map((g) => (
        <div key={g.id} style={{ marginBottom: 18 }}>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 8,
            }}
          >
            <div style={{ fontWeight: 800, fontSize: 14 }}>{g.name}</div>
            <div style={{ fontSize: 11, color: g.required ? C.hot : C.faint, fontWeight: 700 }}>
              {g.required ? 'OBLIGATOIRE' : 'OPTIONNEL'}
              {g.max > 1 ? ` · max ${g.max}` : ''}
            </div>
          </div>
          <div style={{ display: 'grid', gap: 8 }}>
            {(g.options || []).map((o) => {
              const on = (picked[g.id] || []).includes(o.id)
              return (
                <button
                  key={o.id}
                  onClick={() => toggle(g, o.id)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    minHeight: 48,
                    padding: '0 14px',
                    borderRadius: 12,
                    cursor: 'pointer',
                    border: `1px solid ${on ? C.primary : C.lineHi}`,
                    background: on ? 'rgba(177,78,255,.15)' : 'transparent',
                    color: C.text,
                    fontSize: 14,
                    fontWeight: on ? 800 : 600,
                  }}
                >
                  <span>{o.name}</span>
                  <span style={{ ...S.money, color: Number(o.price) ? C.cyan : C.faint, fontSize: 13 }}>
                    {Number(o.price) ? `+${eur(o.price)}` : 'inclus'}
                  </span>
                </button>
              )
            })}
          </div>
        </div>
      ))}

      {(item.extras || []).length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <div style={{ fontWeight: 800, fontSize: 14, marginBottom: 8 }}>Ajouts</div>
          <div style={{ display: 'grid', gap: 8 }}>
            {(item.extras || []).map((e) => {
              const on = extras.includes(e.id)
              return (
                <button
                  key={e.id}
                  onClick={() =>
                    setExtras((p) => (on ? p.filter((x) => x !== e.id) : [...p, e.id]))
                  }
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    minHeight: 48,
                    padding: '0 14px',
                    borderRadius: 12,
                    cursor: 'pointer',
                    border: `1px solid ${on ? C.cyan : C.lineHi}`,
                    background: on ? 'rgba(0,229,255,.12)' : 'transparent',
                    color: C.text,
                    fontSize: 14,
                    fontWeight: on ? 800 : 600,
                  }}
                >
                  <span>{on ? '✓ ' : ''}{e.name}</span>
                  <span style={{ ...S.money, color: C.cyan, fontSize: 13 }}>+{eur(e.price)}</span>
                </button>
              )
            })}
          </div>
        </div>
      )}

      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: 14,
          gap: 12,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          {[-1, 1].map((d) => (
            <button
              key={d}
              onClick={() => setQty((q) => Math.max(1, q + d))}
              style={{
                width: 44,
                height: 44,
                borderRadius: 12,
                border: `1px solid ${C.lineHi}`,
                background: C.surfaceHi,
                color: C.text,
                fontSize: 20,
                fontWeight: 800,
                cursor: 'pointer',
                order: d < 0 ? 0 : 2,
              }}
            >
              {d < 0 ? '−' : '+'}
            </button>
          ))}
          <div style={{ ...S.money, fontSize: 18, fontWeight: 900, order: 1, minWidth: 24, textAlign: 'center' }}>
            {qty}
          </div>
        </div>
        <div style={{ ...S.money, fontSize: 20, fontWeight: 900, color: C.primary }}>
          {eur(unit * qty)}
        </div>
      </div>

      <button
        disabled={missing.length > 0}
        onClick={() => onConfirm(chosen, chosenExtras, qty)}
        style={{ ...S.btn, opacity: missing.length ? 0.5 : 1 }}
      >
        {missing.length ? `Choisissez : ${missing[0].name}` : 'Ajouter au panier'}
      </button>
    </Sheet>
  )
}

function CartSheet({ open, cart, lang, subtotal, autoPromo, onClose, onQty, onCheckout }) {
  const discount = computeDiscount(autoPromo, subtotal)
  return (
    <Sheet open={open} onClose={onClose} title="Votre panier">
      {cart.length === 0 && <Empty emoji="🛒" title="Panier vide" />}
      <div style={{ display: 'grid', gap: 10 }}>
        {cart.map((l) => {
          const t = tr(l.item, lang)
          const detail = [...l.options.map((o) => o.name), ...l.extras.map((e) => e.name)].join(' · ')
          return (
            <div
              key={l.key}
              style={{
                display: 'flex',
                gap: 12,
                alignItems: 'center',
                padding: 12,
                borderRadius: 14,
                background: C.surfaceHi,
                border: `1px solid ${C.line}`,
              }}
            >
              <div style={{ fontSize: 24 }}>{l.item.emoji || '🍹'}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 800, fontSize: 14 }}>{t.name}</div>
                {detail && (
                  <div style={{ color: C.faint, fontSize: 11.5, marginTop: 2 }}>{detail}</div>
                )}
                <div style={{ ...S.money, color: C.cyan, fontSize: 13, marginTop: 3, fontWeight: 700 }}>
                  {eur(lineTotal(l))}
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <button
                  onClick={() => onQty(l.key, -1)}
                  style={{
                    width: 34,
                    height: 34,
                    borderRadius: 10,
                    border: `1px solid ${C.lineHi}`,
                    background: 'transparent',
                    color: C.text,
                    fontSize: 17,
                    cursor: 'pointer',
                  }}
                >
                  −
                </button>
                <div style={{ ...S.money, fontWeight: 900, minWidth: 18, textAlign: 'center' }}>
                  {l.quantity}
                </div>
                <button
                  onClick={() => onQty(l.key, 1)}
                  style={{
                    width: 34,
                    height: 34,
                    borderRadius: 10,
                    border: 'none',
                    background: C.primary,
                    color: '#fff',
                    fontSize: 17,
                    cursor: 'pointer',
                  }}
                >
                  +
                </button>
              </div>
            </div>
          )
        })}
      </div>

      {cart.length > 0 && (
        <>
          {discount > 0 && (
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                marginTop: 16,
                color: C.ok,
                fontSize: 14,
                fontWeight: 700,
              }}
            >
              <span>🎉 {autoPromo.label}</span>
              <span style={S.money}>−{eur(discount)}</span>
            </div>
          )}
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'baseline',
              marginTop: 14,
              paddingTop: 14,
              borderTop: `1px solid ${C.lineHi}`,
            }}
          >
            <span style={{ fontSize: 15, fontWeight: 700, color: C.dim }}>Total</span>
            <span style={{ ...S.money, fontSize: 26, fontWeight: 900, color: C.primary }}>
              {eur(subtotal - discount)}
            </span>
          </div>
          <div style={{ marginTop: 14 }}>
            <button onClick={onCheckout} style={S.btn}>
              Continuer
            </button>
          </div>
        </>
      )}
    </Sheet>
  )
}

function CheckoutSheet({ open, subtotal, promos, autoPromo, etaMin, onClose, onSubmit }) {
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [note, setNote] = useState('')
  const [promoCode, setPromoCode] = useState('')
  const [busy, setBusy] = useState(false)

  const codePromo = promos.find(
    (p) => p.code && p.code.toUpperCase() === promoCode.trim().toUpperCase() && promoActiveNow(p)
  )
  const promo = codePromo || autoPromo
  const discount = computeDiscount(promo, subtotal)
  const total = Math.max(0, subtotal - discount)
  const codeTyped = promoCode.trim().length > 0

  return (
    <Sheet open={open} onClose={onClose} title="Finaliser la commande">
      <Field label="VOTRE PRÉNOM (pour vous appeler au comptoir)">
        <input
          style={S.input}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Alex"
        />
      </Field>

      <Field label="E-MAIL (facultatif — pour recevoir le récapitulatif)">
        <input
          style={S.input}
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="vous@email.fr"
        />
      </Field>

      <Field label="NOTE POUR LE COMPTOIR">
        <textarea
          style={{ ...S.input, minHeight: 78, paddingTop: 12, resize: 'vertical' }}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Sans glace, peu sucré, allergie…"
        />
      </Field>

      <Field label="CODE PROMO">
        <input
          style={{
            ...S.input,
            textTransform: 'uppercase',
            borderColor: codeTyped ? (codePromo ? C.ok : C.hot) : C.lineHi,
          }}
          value={promoCode}
          onChange={(e) => setPromoCode(e.target.value)}
          placeholder="HAPPY"
        />
        {codeTyped && (
          <div
            style={{
              fontSize: 12,
              marginTop: 6,
              color: codePromo ? C.ok : C.hot,
              fontWeight: 700,
            }}
          >
            {codePromo ? `✓ ${codePromo.label} appliqué` : 'Code inconnu ou expiré'}
          </div>
        )}
      </Field>

      <div
        style={{
          background: C.surfaceHi,
          border: `1px solid ${C.line}`,
          borderRadius: 14,
          padding: 14,
          marginBottom: 14,
        }}
      >
        <Row k="Sous-total" v={eur(subtotal)} />
        {discount > 0 && <Row k={promo.label} v={`−${eur(discount)}`} color={C.ok} />}
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'baseline',
            marginTop: 10,
            paddingTop: 10,
            borderTop: `1px solid ${C.lineHi}`,
          }}
        >
          <span style={{ fontWeight: 800 }}>TOTAL</span>
          <span style={{ ...S.money, fontSize: 24, fontWeight: 900, color: C.primary }}>
            {eur(total)}
          </span>
        </div>
      </div>

      <div
        style={{
          background: 'rgba(255,61,139,.1)',
          border: `1px solid ${C.hot}55`,
          borderRadius: 14,
          padding: 14,
          marginBottom: 16,
          textAlign: 'center',
        }}
      >
        <div style={{ color: C.hot, fontWeight: 900, fontSize: 14, letterSpacing: 0.4 }}>
          💳 À RÉGLER AU BAR
        </div>
        <div style={{ color: C.dim, fontSize: 12, marginTop: 5, lineHeight: 1.5 }}>
          Aucun paiement en ligne. Le comptoir prépare, vous réglez sur place.
          <br />
          Prêt dans ~{etaMin} min.
        </div>
      </div>

      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true)
          await onSubmit({ name, email, note, promoCode })
          setBusy(false)
        }}
        style={{ ...S.btn, opacity: busy ? 0.6 : 1, minHeight: 56 }}
      >
        {busy ? 'Envoi…' : 'Envoyer au comptoir'}
      </button>
    </Sheet>
  )
}

function Row({ k, v, color }) {
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        fontSize: 14,
        marginBottom: 6,
        color: color || C.dim,
        fontWeight: color ? 700 : 500,
      }}
    >
      <span>{k}</span>
      <span style={S.money}>{v}</span>
    </div>
  )
}

// ============================================================================
//  SUIVI CLIENT + FACTURE / RÉCAPITULATIF
// ============================================================================

function TrackingScreen({ orderId, bar, tableNumber, onNewOrder }) {
  const [order, setOrder] = useState(null)
  const [items, setItems] = useState([])
  const [table, setTable] = useState(null)
  const [now, setNow] = useState(Date.now())
  const [pushOn, setPushOn] = useState(false)
  const [toast, showToast] = useToast()
  const lastStatus = useRef(null)

  const refresh = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, tables ( number, label ), order_items ( * )')
      .eq('id', orderId)
      .maybeSingle()
    if (!data) return
    setOrder(data)
    setItems(data.order_items || [])
    setTable(data.tables || null)
  }, [orderId])

  useEffect(() => {
    refresh()
    // Realtime + polling de secours (réseau capricieux au fond d'un bar).
    const channel = supabase
      .channel(`order-${orderId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'orders', filter: `id=eq.${orderId}` },
        (payload) => setOrder((prev) => ({ ...(prev || {}), ...payload.new }))
      )
      .subscribe()
    const poll = setInterval(refresh, 12000)
    const clock = setInterval(() => setNow(Date.now()), 1000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
      clearInterval(clock)
    }
  }, [orderId, refresh])

  // Sonnerie douce + vibration quand la commande passe à "prête".
  useEffect(() => {
    if (!order) return
    if (lastStatus.current && lastStatus.current !== order.status && order.status === 'READY') {
      chime()
      vibrate([250, 120, 250, 120, 450])
    }
    lastStatus.current = order.status
  }, [order])

  // Messages du Service Worker (push reçu écran verrouillé).
  useEffect(() => {
    const on = (e) => {
      if (e.data?.type === 'TAPZ_PUSH') refresh()
    }
    navigator.serviceWorker?.addEventListener('message', on)
    return () => navigator.serviceWorker?.removeEventListener('message', on)
  }, [refresh])

  if (!order) return <div style={S.page}><Spinner label="Suivi de votre commande…" /></div>

  const st = STATUS[order.status] || STATUS.PENDING
  const steps = [
    { k: 'PENDING', t: 'Reçue', e: '📩' },
    { k: 'PREPARING', t: 'Au shaker', e: '🍹' },
    { k: 'READY', t: 'Prête', e: '🔔' },
    { k: 'DONE', t: 'Servie', e: '🥂' },
  ]
  const stepIdx = Math.max(0, steps.findIndex((s) => s.k === order.status))

  const etaMs = order.estimated_ready_at ? new Date(order.estimated_ready_at).getTime() - now : 0
  const etaSec = Math.max(0, Math.round(etaMs / 1000))
  const mm = String(Math.floor(etaSec / 60)).padStart(2, '0')
  const ss = String(etaSec % 60).padStart(2, '0')

  async function downloadInvoice() {
    try {
      const canvas = await renderInvoiceCanvas({ bar, order, items, table, tableNumber })
      const blob = canvasesToPdfBlob([canvas], { quality: 0.94 })
      await shareOrDownload(blob, `TAPZ-recap-${order.code}.pdf`, 'Récapitulatif TAPZ')
    } catch (e) {
      showToast('Génération impossible : ' + e.message, 'error')
    }
  }

  return (
    <div style={{ ...S.page, padding: 16 }}>
      <div style={{ textAlign: 'center', margin: '10px 0 22px' }}>
        <Logo size={11} />
        <div style={{ fontSize: 12, color: C.dim, marginTop: 8 }}>
          {bar?.name} · Table {tableNumber}
        </div>
        <div
          style={{
            fontSize: 13,
            color: C.cyan,
            fontWeight: 900,
            marginTop: 4,
            letterSpacing: 1.5,
          }}
        >
          #{order.code}
        </div>
      </div>

      {/* État */}
      <div
        style={{
          ...S.card,
          textAlign: 'center',
          borderColor: `${st.color}66`,
          boxShadow: `0 0 34px ${st.color}22`,
        }}
      >
        <div
          style={{
            fontSize: 46,
            marginBottom: 8,
            animation: order.status === 'READY' ? 'tapzpulse 1.1s infinite' : 'none',
          }}
        >
          {steps[stepIdx]?.e || '📩'}
        </div>
        <div style={{ fontSize: 21, fontWeight: 900, color: st.color }}>{st.label}</div>

        {order.status === 'READY' && (
          <div style={{ color: C.ok, fontSize: 13, marginTop: 8, fontWeight: 700, lineHeight: 1.5 }}>
            Présentez-vous au comptoir avec le code #{order.code}
            <br />
            et réglez sur place.
          </div>
        )}

        {(order.status === 'PENDING' || order.status === 'PREPARING') && (
          <>
            <div style={{ color: C.dim, fontSize: 13, marginTop: 8 }}>Prête dans environ</div>
            <div
              style={{
                ...S.money,
                fontSize: 46,
                fontWeight: 900,
                letterSpacing: 2,
                marginTop: 2,
                color: etaSec === 0 ? C.warn : C.text,
              }}
            >
              {etaSec === 0 ? 'bientôt' : `${mm}:${ss}`}
            </div>
          </>
        )}

        {/* Barre de progression */}
        <div style={{ display: 'flex', gap: 6, marginTop: 20 }}>
          {steps.map((s, i) => (
            <div key={s.k} style={{ flex: 1 }}>
              <div
                style={{
                  height: 5,
                  borderRadius: 3,
                  background: i <= stepIdx ? st.color : C.surfaceHi,
                  boxShadow: i <= stepIdx ? `0 0 10px ${st.color}88` : 'none',
                  transition: 'background .3s',
                }}
              />
              <div
                style={{
                  fontSize: 10,
                  marginTop: 6,
                  color: i <= stepIdx ? C.text : C.faint,
                  fontWeight: i === stepIdx ? 800 : 500,
                }}
              >
                {s.t}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Notifications */}
      {pushSupported() && order.status !== 'DONE' && (
        <button
          onClick={async () => {
            const ok = await subscribePush({ orderId, barId: order.bar_id, role: 'customer' })
            setPushOn(ok)
            showToast(
              ok ? 'Vous serez prévenu même écran verrouillé.' : 'Notifications refusées.',
              ok ? 'ok' : 'error'
            )
          }}
          style={{
            ...S.btnGhost,
            marginTop: 12,
            borderColor: pushOn ? C.ok : C.lineHi,
            color: pushOn ? C.ok : C.text,
          }}
        >
          {pushOn ? '✓ Notifications activées' : '🔔 Me prévenir quand c’est prêt'}
        </button>
      )}

      {/* Facture / récapitulatif */}
      <div style={{ ...S.card, marginTop: 12 }}>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            marginBottom: 12,
          }}
        >
          <div style={{ fontWeight: 900, fontSize: 16 }}>Récapitulatif</div>
          <div style={{ fontSize: 11, color: C.faint }}>{dateFR(order.created_at)}</div>
        </div>

        {items.map((it) => {
          const opts = [
            ...(it.detail?.options || []).map((o) => o.name),
            ...(it.detail?.extras || []).map((e) => e.name),
          ].join(' · ')
          return (
            <div
              key={it.id}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                gap: 12,
                padding: '9px 0',
                borderBottom: `1px solid ${C.line}`,
              }}
            >
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 700 }}>{it.name_snapshot}</div>
                {opts && <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>{opts}</div>}
                <div style={{ fontSize: 11.5, color: C.dim, marginTop: 2 }}>
                  {it.quantity} × {eur(it.unit_price)}
                </div>
              </div>
              <div style={{ ...S.money, fontWeight: 800, whiteSpace: 'nowrap' }}>
                {eur(Number(it.unit_price) * Number(it.quantity))}
              </div>
            </div>
          )
        })}

        {Number(order.discount) > 0 && (
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              marginTop: 10,
              color: C.ok,
              fontWeight: 700,
              fontSize: 14,
            }}
          >
            <span>{order.promo_code || 'Remise'}</span>
            <span style={S.money}>−{eur(order.discount)}</span>
          </div>
        )}

        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'baseline',
            marginTop: 14,
            paddingTop: 14,
            borderTop: `1px solid ${C.lineHi}`,
          }}
        >
          <span style={{ fontWeight: 900, fontSize: 15 }}>TOTAL</span>
          <span style={{ ...S.money, fontSize: 27, fontWeight: 900, color: C.primary }}>
            {eur(order.total)}
          </span>
        </div>

        <div
          style={{
            marginTop: 12,
            padding: 11,
            borderRadius: 12,
            background: order.paid ? 'rgba(61,255,168,.12)' : 'rgba(255,61,139,.1)',
            border: `1px solid ${order.paid ? C.ok : C.hot}55`,
            color: order.paid ? C.ok : C.hot,
            fontWeight: 900,
            fontSize: 13,
            textAlign: 'center',
            letterSpacing: 0.4,
          }}
        >
          {order.paid ? '✓ RÉGLÉ' : '💳 À RÉGLER AU BAR'}
        </div>

        {order.note && (
          <div style={{ marginTop: 12, fontSize: 12, color: C.dim }}>
            <strong style={{ color: C.text }}>Note :</strong> {order.note}
          </div>
        )}

        <div style={{ marginTop: 14 }}>
          <button onClick={downloadInvoice} style={S.btnGhost}>
            📄 Télécharger / imprimer le récapitulatif (PDF)
          </button>
        </div>
      </div>

      {order.status === 'DONE' && <ReviewBox barId={order.bar_id} orderId={order.id} />}

      <div style={{ marginTop: 12 }}>
        <button onClick={onNewOrder} style={S.btnGhost}>
          + Commander autre chose
        </button>
      </div>

      <div style={{ textAlign: 'center', color: C.faint, fontSize: 11, marginTop: 22 }}>
        Propulsé par TAPZ · Paiement au comptoir
      </div>

      <Toast toast={toast} />
    </div>
  )
}

function ReviewBox({ barId, orderId }) {
  const [rating, setRating] = useState(0)
  const [comment, setComment] = useState('')
  const [sent, setSent] = useState(false)

  if (sent)
    return (
      <div style={{ ...S.card, marginTop: 12, textAlign: 'center', borderColor: `${C.ok}55` }}>
        <div style={{ fontSize: 30 }}>🥂</div>
        <div style={{ fontWeight: 800, marginTop: 6 }}>Merci pour votre retour !</div>
      </div>
    )

  return (
    <div style={{ ...S.card, marginTop: 12 }}>
      <div style={{ fontWeight: 900, marginBottom: 10 }}>Votre soirée s’est bien passée ?</div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            onClick={() => setRating(n)}
            style={{
              flex: 1,
              minHeight: 46,
              borderRadius: 12,
              border: `1px solid ${n <= rating ? C.warn : C.lineHi}`,
              background: n <= rating ? 'rgba(255,176,32,.14)' : 'transparent',
              fontSize: 20,
              cursor: 'pointer',
            }}
          >
            {n <= rating ? '★' : '☆'}
          </button>
        ))}
      </div>
      <textarea
        style={{ ...S.input, minHeight: 70, paddingTop: 12 }}
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        placeholder="Un mot pour l’équipe (facultatif)"
      />
      <div style={{ marginTop: 10 }}>
        <button
          disabled={!rating}
          onClick={async () => {
            await supabase
              .from('reviews')
              .insert({ bar_id: barId, order_id: orderId, rating, comment: comment || null })
            setSent(true)
          }}
          style={{ ...S.btn, opacity: rating ? 1 : 0.5 }}
        >
          Envoyer
        </button>
      </div>
    </div>
  )
}

/**
 * Facture / récapitulatif A4 rendue en Canvas 2D natif (150 dpi).
 * Volontairement pas de html2canvas : rendu identique partout, iOS inclus.
 */
async function renderInvoiceCanvas({ bar, order, items, table, tableNumber }) {
  const W = 1240
  const H = 1754
  const { canvas, ctx } = makeCanvas(W, H, 1)

  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, W, H)

  // Bandeau
  const grad = ctx.createLinearGradient(0, 0, W, 220)
  grad.addColorStop(0, '#0A0713')
  grad.addColorStop(1, '#2A1250')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, W, 220)

  ctx.fillStyle = '#B14EFF'
  ctx.font = '900 26px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('T A P Z', 70, 58)

  ctx.fillStyle = '#FFFFFF'
  ctx.font = '900 46px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(bar?.name || 'Bar', 70, 96)

  ctx.fillStyle = '#9C93B8'
  ctx.font = '400 22px -apple-system, Segoe UI, Roboto, Arial'
  const legal = [bar?.address, bar?.city, bar?.phone].filter(Boolean).join(' · ')
  if (legal) ctx.fillText(legal, 70, 154)

  ctx.textAlign = 'right'
  ctx.fillStyle = '#00E5FF'
  ctx.font = '900 40px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(`#${order.code}`, W - 70, 88)
  ctx.fillStyle = '#9C93B8'
  ctx.font = '400 20px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(dateFR(order.created_at), W - 70, 140)
  ctx.textAlign = 'left'

  // Contexte commande
  let y = 268
  ctx.fillStyle = '#141024'
  ctx.font = '800 24px -apple-system, Segoe UI, Roboto, Arial'
  const ctxLine = [
    table?.label ? `${table.label} — Table ${table?.number ?? tableNumber}` : `Table ${table?.number ?? tableNumber}`,
    order.order_type === 'a_emporter' ? 'À emporter' : 'Sur place',
    order.customer_name ? `Client : ${order.customer_name}` : null,
  ]
    .filter(Boolean)
    .join('   ·   ')
  ctx.fillText(ctxLine, 70, y)
  y += 54

  ctx.strokeStyle = '#E3DEF2'
  ctx.lineWidth = 2
  ctx.beginPath()
  ctx.moveTo(70, y)
  ctx.lineTo(W - 70, y)
  ctx.stroke()
  y += 26

  // En-têtes de colonnes
  ctx.fillStyle = '#6F668C'
  ctx.font = '800 18px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('DÉSIGNATION', 70, y)
  ctx.textAlign = 'center'
  ctx.fillText('QTÉ', W - 430, y)
  ctx.textAlign = 'right'
  ctx.fillText('P.U.', W - 260, y)
  ctx.fillText('TOTAL', W - 70, y)
  ctx.textAlign = 'left'
  y += 40

  // Lignes
  for (const it of items) {
    if (y > H - 420) break
    ctx.fillStyle = '#141024'
    ctx.font = '700 24px -apple-system, Segoe UI, Roboto, Arial'
    const nameLines = wrapText(ctx, it.name_snapshot, W - 620, 2)
    nameLines.forEach((l, i) => ctx.fillText(l, 70, y + i * 30))

    const opts = [
      ...(it.detail?.options || []).map((o) => o.name),
      ...(it.detail?.extras || []).map((e) => e.name),
    ].join(' · ')

    let lineH = nameLines.length * 30
    if (opts) {
      ctx.fillStyle = '#8A83A6'
      ctx.font = '400 18px -apple-system, Segoe UI, Roboto, Arial'
      const optLines = wrapText(ctx, opts, W - 620, 2)
      optLines.forEach((l, i) => ctx.fillText(l, 70, y + lineH + i * 24))
      lineH += optLines.length * 24
    }

    ctx.fillStyle = '#141024'
    ctx.font = '700 24px -apple-system, Segoe UI, Roboto, Arial'
    ctx.textAlign = 'center'
    ctx.fillText(String(it.quantity), W - 430, y)
    ctx.textAlign = 'right'
    ctx.fillText(eur(it.unit_price), W - 260, y)
    ctx.font = '800 24px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(eur(Number(it.unit_price) * Number(it.quantity)), W - 70, y)
    ctx.textAlign = 'left'

    y += Math.max(lineH, 34) + 16
    ctx.strokeStyle = '#F0EDF8'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(70, y - 8)
    ctx.lineTo(W - 70, y - 8)
    ctx.stroke()
  }

  // Totaux
  y = Math.max(y + 20, H - 400)
  ctx.textAlign = 'right'
  ctx.fillStyle = '#6F668C'
  ctx.font = '600 22px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('Sous-total', W - 260, y)
  ctx.fillStyle = '#141024'
  ctx.fillText(eur(order.subtotal ?? order.total), W - 70, y)
  y += 36

  if (Number(order.discount) > 0) {
    ctx.fillStyle = '#1D9E63'
    ctx.fillText(order.promo_code || 'Remise', W - 260, y)
    ctx.fillText(`−${eur(order.discount)}`, W - 70, y)
    y += 36
  }

  // Détail TVA (indicatif — marché français)
  const vatGroups = {}
  for (const it of items) {
    const rate = Number(it.vat_rate ?? 20)
    const ttc = Number(it.unit_price) * Number(it.quantity)
    vatGroups[rate] = (vatGroups[rate] || 0) + ttc
  }
  ctx.font = '400 18px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillStyle = '#8A83A6'
  for (const rate of Object.keys(vatGroups).sort()) {
    const ttc = vatGroups[rate]
    const tva = ttc - ttc / (1 + Number(rate) / 100)
    ctx.fillText(`dont TVA ${rate}%`, W - 260, y)
    ctx.fillText(eur(tva), W - 70, y)
    y += 28
  }

  y += 14
  ctx.fillStyle = '#141024'
  ctx.font = '900 34px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('TOTAL', W - 300, y)
  ctx.fillStyle = '#7A1FD6'
  ctx.font = '900 42px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(eur(order.total), W - 70, y - 4)
  ctx.textAlign = 'left'

  // Mention de règlement
  y += 60
  ctx.fillStyle = order.paid ? '#0E7A4A' : '#C41E63'
  roundRect(ctx, 70, y, W - 140, 84, 18)
  ctx.globalAlpha = 0.1
  ctx.fill()
  ctx.globalAlpha = 1
  ctx.lineWidth = 2
  ctx.strokeStyle = order.paid ? '#0E7A4A' : '#C41E63'
  roundRect(ctx, 70, y, W - 140, 84, 18)
  ctx.stroke()
  ctx.fillStyle = order.paid ? '#0E7A4A' : '#C41E63'
  ctx.font = '900 30px -apple-system, Segoe UI, Roboto, Arial'
  ctx.textAlign = 'center'
  ctx.fillText(
    order.paid ? '✓ RÉGLÉ' : 'À RÉGLER AU BAR — AUCUN PAIEMENT EN LIGNE',
    W / 2,
    y + 26
  )
  ctx.textAlign = 'left'

  // Pied de page
  ctx.fillStyle = '#8A83A6'
  ctx.font = '400 17px -apple-system, Segoe UI, Roboto, Arial'
  const footer = [
    bar?.siret ? `SIRET ${bar.siret}` : null,
    bar?.tva_number ? `TVA ${bar.tva_number}` : null,
  ]
    .filter(Boolean)
    .join(' · ')
  ctx.textAlign = 'center'
  if (footer) ctx.fillText(footer, W / 2, H - 96)
  ctx.fillStyle = '#B14EFF'
  ctx.font = '800 16px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('Récapitulatif généré par TAPZ — ce document ne vaut pas reçu de paiement', W / 2, H - 62)
  ctx.textAlign = 'left'

  return canvas
}

// ============================================================================
//  ADMIN — coquille, bars, navigation
// ============================================================================

const TABS = [
  { k: 'live', t: 'Live', e: '⚡' },
  { k: 'caisse', t: 'Caisse', e: '🧾' },
  { k: 'carte', t: 'Carte', e: '🍸' },
  { k: 'clients', t: 'Clients', e: '👥' },
  { k: 'promos', t: 'Promos', e: '🎉' },
  { k: 'qr', t: 'QR', e: '⬛' },
  { k: 'reglages', t: 'Réglages', e: '⚙️' },
]

function AdminApp({ session }) {
  const [bars, setBars] = useState(null)
  const [groups, setGroups] = useState([])
  const [barId, setBarId] = useState(LS.get('tapz:bar', null))
  const [tab, setTab] = useState('live')
  const [switcher, setSwitcher] = useState(false)
  const [toast, showToast] = useToast()

  const loadBars = useCallback(async () => {
    const uidUser = session.user.id
    const { data: gs } = await supabase.from('groups').select('*').eq('owner_id', uidUser)
    setGroups(gs || [])
    const gids = (gs || []).map((g) => g.id)

    const own = await supabase.from('bars').select('*').eq('owner_id', uidUser)
    let all = own.data || []
    if (gids.length) {
      const grouped = await supabase.from('bars').select('*').in('group_id', gids)
      const seen = new Set(all.map((b) => b.id))
      all = [...all, ...(grouped.data || []).filter((b) => !seen.has(b.id))]
    }
    all.sort((a, b) => a.name.localeCompare(b.name))
    setBars(all)
    setBarId((cur) => (all.find((b) => b.id === cur) ? cur : all[0]?.id ?? null))
  }, [session.user.id])

  useEffect(() => {
    loadBars()
  }, [loadBars])

  useEffect(() => {
    if (barId) LS.set('tapz:bar', barId)
  }, [barId])

  if (bars === null) return <div style={S.page}><Spinner /></div>
  if (bars.length === 0)
    return <Onboarding session={session} onDone={loadBars} />

  const bar = bars.find((b) => b.id === barId) || bars[0]

  return (
    <div style={{ ...S.page, paddingBottom: 96 }}>
      {/* Barre du haut */}
      <div
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 60,
          background: `${C.bg}f2`,
          backdropFilter: 'blur(10px)',
          borderBottom: `1px solid ${C.line}`,
          padding: '12px 14px',
          display: 'flex',
          alignItems: 'center',
          gap: 12,
        }}
      >
        <button
          onClick={() => setSwitcher(true)}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            background: 'transparent',
            border: 'none',
            color: C.text,
            cursor: 'pointer',
            padding: 0,
            flex: 1,
            minWidth: 0,
            textAlign: 'left',
          }}
        >
          <span style={{ fontSize: 24 }}>{bar.logo_emoji || '🍸'}</span>
          <span style={{ minWidth: 0 }}>
            <span
              style={{
                display: 'block',
                fontWeight: 900,
                fontSize: 16,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {bar.name}
            </span>
            <span style={{ display: 'block', fontSize: 11, color: C.dim }}>
              {bars.length > 1 ? `${bars.length} établissements · changer` : 'Tableau de bord'}
            </span>
          </span>
        </button>
        <Logo size={10} />
      </div>

      <div style={{ padding: 14 }}>
        {tab === 'live' && <LiveTab bar={bar} showToast={showToast} />}
        {tab === 'caisse' && <CaisseTab bar={bar} showToast={showToast} />}
        {tab === 'carte' && <MenuTab bar={bar} bars={bars} showToast={showToast} />}
        {tab === 'clients' && <ClientsTab bar={bar} />}
        {tab === 'promos' && <PromosTab bar={bar} showToast={showToast} />}
        {tab === 'qr' && <QrTab bar={bar} showToast={showToast} />}
        {tab === 'reglages' && (
          <SettingsTab
            bar={bar}
            bars={bars}
            groups={groups}
            session={session}
            onReload={loadBars}
            showToast={showToast}
          />
        )}
      </div>

      {/* Navigation basse */}
      <div
        style={{
          position: 'fixed',
          left: 0,
          right: 0,
          bottom: 0,
          zIndex: 60,
          background: `${C.surface}f5`,
          backdropFilter: 'blur(12px)',
          borderTop: `1px solid ${C.line}`,
          display: 'flex',
          padding: '8px 4px calc(env(safe-area-inset-bottom) + 8px)',
          overflowX: 'auto',
        }}
      >
        {TABS.map((t) => (
          <button
            key={t.k}
            onClick={() => {
              unlockAudio()
              setTab(t.k)
            }}
            style={{
              flex: '1 0 auto',
              minWidth: 62,
              background: 'transparent',
              border: 'none',
              cursor: 'pointer',
              padding: '6px 4px',
              color: tab === t.k ? C.primary : C.faint,
            }}
          >
            <div style={{ fontSize: 19, opacity: tab === t.k ? 1 : 0.65 }}>{t.e}</div>
            <div style={{ fontSize: 10, fontWeight: 800, marginTop: 3 }}>{t.t}</div>
          </button>
        ))}
      </div>

      <Sheet open={switcher} onClose={() => setSwitcher(false)} title="Mes établissements">
        <div style={{ display: 'grid', gap: 8 }}>
          {bars.map((b) => (
            <button
              key={b.id}
              onClick={() => {
                setBarId(b.id)
                setSwitcher(false)
              }}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 12,
                minHeight: 58,
                padding: '0 14px',
                borderRadius: 14,
                cursor: 'pointer',
                border: `1px solid ${b.id === bar.id ? C.primary : C.lineHi}`,
                background: b.id === bar.id ? 'rgba(177,78,255,.14)' : 'transparent',
                color: C.text,
                textAlign: 'left',
              }}
            >
              <span style={{ fontSize: 22 }}>{b.logo_emoji || '🍸'}</span>
              <span style={{ fontWeight: 800 }}>{b.name}</span>
            </button>
          ))}
        </div>
        <div style={{ marginTop: 16 }}>
          <button
            onClick={() => {
              setSwitcher(false)
              setTab('reglages')
            }}
            style={S.btnGhost}
          >
            + Ajouter un établissement
          </button>
        </div>
        <div style={{ marginTop: 10 }}>
          <button
            onClick={() => supabase.auth.signOut()}
            style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
          >
            Se déconnecter
          </button>
        </div>
      </Sheet>

      <Toast toast={toast} />
    </div>
  )
}

function Onboarding({ session, onDone }) {
  const [name, setName] = useState('')
  const [emoji, setEmoji] = useState('🍸')
  const [tables, setTables] = useState(12)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const isGroup = session.user.user_metadata?.account_type === 'groupe'

  async function create() {
    setBusy(true)
    setErr('')
    try {
      let groupId = null
      if (isGroup) {
        const { data: g, error: ge } = await supabase
          .from('groups')
          .insert({ name: `${name || 'Mon groupe'}`, owner_id: session.user.id })
          .select()
          .single()
        if (ge) throw ge
        groupId = g.id
      }

      const { data: bar, error } = await supabase
        .from('bars')
        .insert({
          name: name.trim() || 'Mon bar',
          owner_id: session.user.id,
          group_id: groupId,
          logo_emoji: emoji,
          tables_count: Number(tables) || 10,
          slug: (name || 'bar')
            .toLowerCase()
            .normalize('NFD')
            .replace(/[̀-ͯ]/g, '')
            .replace(/[^a-z0-9]+/g, '-')
            .replace(/^-|-$/g, '')
            .slice(0, 40) + '-' + uid().slice(0, 4),
        })
        .select()
        .single()
      if (error) throw error

      const rows = Array.from({ length: Number(tables) || 10 }, (_, i) => ({
        bar_id: bar.id,
        number: i + 1,
      }))
      await supabase.from('tables').insert(rows)
      await seedMenu(bar.id)
      onDone()
    } catch (e) {
      setErr(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div style={{ ...S.page, padding: 20, display: 'flex', alignItems: 'center' }}>
      <div style={{ width: '100%', maxWidth: 460, margin: '0 auto' }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <Logo size={14} />
          <div style={{ fontSize: 24, fontWeight: 900, marginTop: 14 }}>
            Créons votre établissement
          </div>
          <div style={{ color: C.dim, fontSize: 13, marginTop: 6 }}>
            {isGroup ? 'Mode groupe · vous pourrez en ajouter d’autres' : 'Deux minutes, montre en main'}
          </div>
        </div>

        <div style={S.card}>
          <Field label="NOM DU BAR">
            <input
              style={S.input}
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Le Néon"
              autoFocus
            />
          </Field>

          <Field label="EMBLÈME">
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {['🍸', '🍺', '🥃', '🍾', '🪩', '🎶', '🍹', '🌃'].map((e) => (
                <button
                  key={e}
                  onClick={() => setEmoji(e)}
                  style={{
                    width: 48,
                    height: 48,
                    fontSize: 24,
                    borderRadius: 12,
                    cursor: 'pointer',
                    border: `1px solid ${emoji === e ? C.primary : C.lineHi}`,
                    background: emoji === e ? 'rgba(177,78,255,.16)' : 'transparent',
                  }}
                >
                  {e}
                </button>
              ))}
            </div>
          </Field>

          <Field label="NOMBRE DE TABLES / ZONES">
            <input
              style={S.input}
              type="number"
              min={1}
              max={200}
              value={tables}
              onChange={(e) => setTables(e.target.value)}
            />
          </Field>

          {err && (
            <div style={{ color: C.hot, fontSize: 13, marginBottom: 10, fontWeight: 700 }}>{err}</div>
          )}

          <button disabled={busy || !name.trim()} onClick={create} style={{ ...S.btn, opacity: busy || !name.trim() ? 0.5 : 1 }}>
            {busy ? 'Création…' : 'Créer mon bar'}
          </button>
          <div style={{ color: C.faint, fontSize: 11, marginTop: 12, textAlign: 'center' }}>
            Une carte de démarrage (cocktails, shots, softs) sera pré-remplie.
          </div>
        </div>

        <div style={{ marginTop: 14, textAlign: 'center' }}>
          <button
            onClick={() => supabase.auth.signOut()}
            style={{ background: 'none', border: 'none', color: C.faint, fontSize: 12, cursor: 'pointer' }}
          >
            Se déconnecter
          </button>
        </div>
      </div>
    </div>
  )
}

/** Carte de démarrage — vocabulaire bar / nuit. */
async function seedMenu(barId) {
  const base = [
    {
      name: 'Mojito',
      description: 'Rhum blanc, menthe fraîche, citron vert, eau gazeuse',
      price: 9.5,
      category: 'Cocktails',
      emoji: '🍹',
      is_popular: true,
      sort_order: 1,
      supplements: [
        {
          id: 'base',
          name: 'Base alcool',
          required: true,
          min: 1,
          max: 1,
          options: [
            { id: 'rhum', name: 'Rhum blanc', price: 0 },
            { id: 'rhum-amb', name: 'Rhum ambré', price: 1.5 },
            { id: 'sans', name: 'Sans alcool (Virgin)', price: -1 },
          ],
        },
        {
          id: 'sirop',
          name: 'Sirop',
          required: false,
          max: 2,
          options: [
            { id: 'fraise', name: 'Fraise', price: 0.5 },
            { id: 'passion', name: 'Fruit de la passion', price: 0.5 },
            { id: 'gingembre', name: 'Gingembre', price: 0.5 },
          ],
        },
      ],
      extras: [{ id: 'double', name: 'Double shot', price: 3 }],
    },
    {
      name: 'Negroni',
      description: 'Gin, campari, vermouth rouge, zeste d’orange',
      price: 11,
      category: 'Cocktails',
      emoji: '🍸',
      sort_order: 2,
      supplements: [],
      extras: [{ id: 'double', name: 'Double shot', price: 3.5 }],
    },
    {
      name: 'Spritz',
      description: 'Apérol, prosecco, eau pétillante',
      price: 9,
      category: 'Cocktails',
      emoji: '🥂',
      is_popular: true,
      sort_order: 3,
    },
    {
      name: 'Tequila',
      description: 'Shot, sel & citron',
      price: 4.5,
      category: 'Shots',
      emoji: '🥃',
      sort_order: 1,
    },
    {
      name: 'Tournée de 6 shots',
      description: 'Au choix du comptoir',
      price: 24,
      category: 'Shots',
      emoji: '🔥',
      is_menu: true,
      sort_order: 2,
    },
    {
      name: 'Pinte blonde',
      description: '50 cl pression',
      price: 7,
      category: 'Bières',
      emoji: '🍺',
      is_popular: true,
      sort_order: 1,
    },
    {
      name: 'Demi blonde',
      description: '25 cl pression',
      price: 4,
      category: 'Bières',
      emoji: '🍺',
      sort_order: 2,
    },
    {
      name: 'Coca / Sprite',
      description: '33 cl',
      price: 3.5,
      category: 'Softs',
      emoji: '🥤',
      sort_order: 1,
      is_alcohol: false,
      vat_rate: 10,
    },
    {
      name: 'Eau plate',
      description: '50 cl',
      price: 3,
      category: 'Softs',
      emoji: '💧',
      sort_order: 2,
      is_alcohol: false,
      vat_rate: 10,
    },
    {
      name: 'Planche à partager',
      description: 'Charcuterie, fromages, pain',
      price: 16,
      category: 'À grignoter',
      emoji: '🧀',
      sort_order: 1,
      is_alcohol: false,
      vat_rate: 10,
    },
  ]

  const rows = base.map((b) => ({
    bar_id: barId,
    supplements: [],
    extras: [],
    is_alcohol: true,
    vat_rate: 20,
    ...b,
  }))
  await supabase.from('menu_items').insert(rows)
  await supabase
    .from('bar_settings')
    .upsert(
      {
        bar_id: barId,
        category_order: ['Cocktails', 'Shots', 'Bières', 'Softs', 'À grignoter'],
      },
      { onConflict: 'bar_id' }
    )
}

// ============================================================================
//  ADMIN · LIVE — kanban comptoir temps réel
// ============================================================================

const COLUMNS = [
  { k: 'PENDING', t: 'À accepter', color: C.hot, action: 'Accepter', next: 'PREPARING' },
  { k: 'PREPARING', t: 'Au shaker', color: C.warn, action: 'Prête', next: 'READY' },
  { k: 'READY', t: 'Prête', color: C.ok, action: 'Servie', next: 'DONE' },
  { k: 'DONE', t: 'Servies', color: C.dim, action: null, next: null },
]

function LiveTab({ bar, showToast }) {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [detail, setDetail] = useState(null)
  const [etaFor, setEtaFor] = useState(null)
  const [staffPush, setStaffPush] = useState(false)
  const alarm = useRef(null)

  if (!alarm.current) alarm.current = new Alarm()

  const load = useCallback(async () => {
    const since = new Date(Date.now() - 14 * 3600 * 1000).toISOString()
    const { data } = await supabase
      .from('orders')
      .select('*, tables ( number, label ), order_items ( * )')
      .eq('bar_id', bar.id)
      .gte('created_at', since)
      .order('created_at', { ascending: false })
    setOrders(data || [])
    setLoading(false)
  }, [bar.id])

  useEffect(() => {
    load()
    const channel = supabase
      .channel(`live-${bar.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'orders', filter: `bar_id=eq.${bar.id}` },
        () => load()
      )
      .subscribe()
    const poll = setInterval(load, 15000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
    }
  }, [bar.id, load])

  const pending = orders.filter((o) => o.status === 'PENDING')

  // L'alarme hurle tant qu'une commande n'a pas été explicitement acceptée.
  useEffect(() => {
    const a = alarm.current
    if (pending.length > 0) a.start()
    else a.stop()
    return () => {}
  }, [pending.length])

  useEffect(() => () => alarm.current?.stop(), [])

  async function move(order, next) {
    unlockAudio()
    const patch = { status: next }
    if (next === 'PREPARING' && !order.estimated_ready_at) {
      patch.estimated_ready_at = new Date(Date.now() + 10 * 60000).toISOString()
    }
    const { error } = await supabase.from('orders').update(patch).eq('id', order.id)
    if (error) return showToast(error.message, 'error')

    if (next === 'READY') {
      sendPush({
        orderId: order.id,
        title: '🔔 Votre commande est prête',
        body: `#${order.code} — présentez-vous au comptoir. À régler sur place.`,
        requireInteraction: true,
      })
    }
    load()
  }

  async function setEta(order, minutes) {
    await supabase
      .from('orders')
      .update({ estimated_ready_at: new Date(Date.now() + minutes * 60000).toISOString() })
      .eq('id', order.id)
    setEtaFor(null)
    showToast(`Temps annoncé : ${minutes} min`, 'ok')
    load()
    sendPush({
      orderId: order.id,
      title: 'Mise à jour du temps',
      body: `Votre commande #${order.code} sera prête dans ~${minutes} min.`,
    })
  }

  if (loading) return <Spinner />

  const stat = (k) => orders.filter((o) => o.status === k).length
  const ca = orders
    .filter((o) => o.status !== 'CANCELLED')
    .reduce((s, o) => s + Number(o.total || 0), 0)

  return (
    <div>
      {/* Bandeau alerte */}
      {pending.length > 0 && (
        <div
          style={{
            background: 'rgba(255,61,139,.16)',
            border: `1px solid ${C.hot}`,
            borderRadius: 14,
            padding: 14,
            marginBottom: 14,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            animation: 'tapzpulse 1s infinite',
          }}
        >
          <div style={{ fontSize: 26 }}>🔔</div>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 900, color: C.hot }}>
              {pending.length} commande{pending.length > 1 ? 's' : ''} en attente
            </div>
            <div style={{ fontSize: 12, color: C.dim, marginTop: 2 }}>
              L’alarme s’arrête quand vous acceptez.
            </div>
          </div>
        </div>
      )}

      {/* Stats du service */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        {[
          { t: 'En attente', v: stat('PENDING'), c: C.hot },
          { t: 'En cours', v: stat('PREPARING'), c: C.warn },
          { t: 'Prêtes', v: stat('READY'), c: C.ok },
          { t: 'Encaissé', v: eur(ca), c: C.primary },
        ].map((s) => (
          <div
            key={s.t}
            style={{
              flex: 1,
              background: C.surface,
              border: `1px solid ${C.line}`,
              borderRadius: 14,
              padding: '10px 8px',
              textAlign: 'center',
            }}
          >
            <div style={{ ...S.money, fontSize: 17, fontWeight: 900, color: s.c }}>{s.v}</div>
            <div style={{ fontSize: 10, color: C.faint, marginTop: 3 }}>{s.t}</div>
          </div>
        ))}
      </div>

      {!pushSupported() ? null : (
        <button
          onClick={async () => {
            const ok = await subscribePush({ barId: bar.id, role: 'staff' })
            setStaffPush(ok)
            showToast(ok ? 'Alertes comptoir activées.' : 'Notifications refusées.', ok ? 'ok' : 'error')
          }}
          style={{
            ...S.btnGhost,
            marginBottom: 14,
            borderColor: staffPush ? C.ok : C.lineHi,
            color: staffPush ? C.ok : C.text,
          }}
        >
          {staffPush ? '✓ Alertes comptoir activées' : '🔔 Recevoir les alertes sur cet appareil'}
        </button>
      )}

      {/* Kanban */}
      <div style={{ display: 'flex', gap: 12, overflowX: 'auto', paddingBottom: 8 }}>
        {COLUMNS.map((col) => {
          const list = orders.filter((o) => o.status === col.k)
          return (
            <div key={col.k} style={{ minWidth: 264, flex: '1 0 264px' }}>
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 8,
                  marginBottom: 10,
                  paddingBottom: 8,
                  borderBottom: `2px solid ${col.color}55`,
                }}
              >
                <div style={{ width: 8, height: 8, borderRadius: 4, background: col.color }} />
                <div style={{ fontWeight: 900, fontSize: 14 }}>{col.t}</div>
                <div style={{ marginLeft: 'auto', color: C.faint, fontSize: 12, fontWeight: 800 }}>
                  {list.length}
                </div>
              </div>

              <div style={{ display: 'grid', gap: 10 }}>
                {list.length === 0 && (
                  <div style={{ color: C.faint, fontSize: 12, padding: '18px 0', textAlign: 'center' }}>
                    —
                  </div>
                )}
                {list.map((o) => (
                  <div
                    key={o.id}
                    style={{
                      background: C.surface,
                      border: `1px solid ${o.status === 'PENDING' ? C.hot : C.line}`,
                      borderRadius: 14,
                      padding: 12,
                    }}
                  >
                    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                      <div>
                        <div style={{ fontWeight: 900, fontSize: 15 }}>
                          Table {o.tables?.number ?? '—'}
                          {o.tables?.label ? (
                            <span style={{ color: C.cyan, fontSize: 11, fontWeight: 700 }}>
                              {' '}
                              {o.tables.label}
                            </span>
                          ) : null}
                        </div>
                        <div style={{ fontSize: 11, color: C.faint, marginTop: 2 }}>
                          #{o.code} · {timeFR(o.created_at)}
                          {o.order_type === 'a_emporter' ? ' · à emporter' : ''}
                        </div>
                      </div>
                      <div style={{ ...S.money, fontWeight: 900, color: C.primary }}>
                        {eur(o.total)}
                      </div>
                    </div>

                    <div style={{ marginTop: 8, display: 'grid', gap: 3 }}>
                      {(o.order_items || []).slice(0, 4).map((it) => (
                        <div key={it.id} style={{ fontSize: 12.5, color: C.dim }}>
                          <strong style={{ color: C.text }}>{it.quantity}×</strong> {it.name_snapshot}
                          {(it.detail?.options || []).length > 0 && (
                            <span style={{ color: C.faint }}>
                              {' '}
                              ({(it.detail.options || []).map((x) => x.name).join(', ')})
                            </span>
                          )}
                        </div>
                      ))}
                      {(o.order_items || []).length > 4 && (
                        <button
                          onClick={() => setDetail(o)}
                          style={{
                            background: 'none',
                            border: 'none',
                            color: C.cyan,
                            fontSize: 12,
                            padding: 0,
                            cursor: 'pointer',
                            textAlign: 'left',
                          }}
                        >
                          + {(o.order_items || []).length - 4} autres…
                        </button>
                      )}
                    </div>

                    {o.note && (
                      <div
                        style={{
                          marginTop: 8,
                          padding: 8,
                          borderRadius: 10,
                          background: 'rgba(255,176,32,.1)',
                          border: `1px solid ${C.warn}44`,
                          color: C.warn,
                          fontSize: 11.5,
                          fontWeight: 600,
                        }}
                      >
                        📝 {o.note}
                      </div>
                    )}

                    {!o.paid && o.status === 'DONE' && (
                      <div style={{ marginTop: 8, fontSize: 11, color: C.hot, fontWeight: 800 }}>
                        À encaisser
                      </div>
                    )}

                    {col.action && (
                      <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                        <button
                          onClick={() => move(o, col.next)}
                          style={{
                            flex: 1,
                            minHeight: 44,
                            borderRadius: 12,
                            border: 'none',
                            cursor: 'pointer',
                            fontWeight: 900,
                            fontSize: 14,
                            background: col.color,
                            color: col.k === 'PENDING' ? '#fff' : '#0A0713',
                          }}
                        >
                          {col.action}
                        </button>
                        {o.status === 'PREPARING' && (
                          <button
                            onClick={() => setEtaFor(o)}
                            style={{
                              width: 46,
                              minHeight: 44,
                              borderRadius: 12,
                              border: `1px solid ${C.lineHi}`,
                              background: 'transparent',
                              color: C.text,
                              cursor: 'pointer',
                              fontSize: 16,
                            }}
                          >
                            ⏱
                          </button>
                        )}
                        <button
                          onClick={() => setDetail(o)}
                          style={{
                            width: 46,
                            minHeight: 44,
                            borderRadius: 12,
                            border: `1px solid ${C.lineHi}`,
                            background: 'transparent',
                            color: C.text,
                            cursor: 'pointer',
                          }}
                        >
                          ⋯
                        </button>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )
        })}
      </div>

      {/* Réglage ETA */}
      <Sheet open={!!etaFor} onClose={() => setEtaFor(null)} title="Temps de préparation">
        <div style={{ color: C.dim, fontSize: 13, marginBottom: 14 }}>
          Le compte à rebours du client est mis à jour immédiatement.
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 8 }}>
          {[5, 10, 15, 20, 30, 45].map((m) => (
            <button
              key={m}
              onClick={() => setEta(etaFor, m)}
              style={{
                minHeight: 56,
                borderRadius: 14,
                border: `1px solid ${C.lineHi}`,
                background: C.surfaceHi,
                color: C.text,
                fontSize: 16,
                fontWeight: 900,
                cursor: 'pointer',
              }}
            >
              {m} min
            </button>
          ))}
        </div>
      </Sheet>

      {/* Détail commande */}
      <Sheet
        open={!!detail}
        onClose={() => setDetail(null)}
        title={detail ? `Table ${detail.tables?.number ?? '—'} · #${detail.code}` : ''}
      >
        {detail && (
          <>
            <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
              {(detail.order_items || []).map((it) => (
                <div
                  key={it.id}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    gap: 10,
                    padding: 10,
                    borderRadius: 12,
                    background: C.surfaceHi,
                  }}
                >
                  <div>
                    <div style={{ fontWeight: 800, fontSize: 14 }}>
                      {it.quantity}× {it.name_snapshot}
                    </div>
                    {[...(it.detail?.options || []), ...(it.detail?.extras || [])].length > 0 && (
                      <div style={{ fontSize: 11.5, color: C.faint, marginTop: 3 }}>
                        {[...(it.detail?.options || []), ...(it.detail?.extras || [])]
                          .map((x) => x.name)
                          .join(' · ')}
                      </div>
                    )}
                  </div>
                  <div style={{ ...S.money, fontWeight: 800 }}>
                    {eur(Number(it.unit_price) * Number(it.quantity))}
                  </div>
                </div>
              ))}
            </div>

            {detail.customer_name && (
              <div style={{ fontSize: 13, color: C.dim, marginBottom: 6 }}>
                Client : <strong style={{ color: C.text }}>{detail.customer_name}</strong>
              </div>
            )}
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                paddingTop: 12,
                borderTop: `1px solid ${C.lineHi}`,
                fontSize: 20,
                fontWeight: 900,
              }}
            >
              <span>Total</span>
              <span style={{ ...S.money, color: C.primary }}>{eur(detail.total)}</span>
            </div>

            <div style={{ display: 'grid', gap: 8, marginTop: 16 }}>
              {detail.status !== 'CANCELLED' && detail.status !== 'DONE' && (
                <button
                  onClick={async () => {
                    await supabase.from('orders').update({ status: 'CANCELLED' }).eq('id', detail.id)
                    setDetail(null)
                    load()
                  }}
                  style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
                >
                  Annuler la commande
                </button>
              )}
              <button onClick={() => setDetail(null)} style={S.btnGhost}>
                Fermer
              </button>
            </div>
          </>
        )}
      </Sheet>
    </div>
  )
}

// ============================================================================
//  ADMIN · CAISSE — additions par table, fusion de notes, marquage "réglé"
// ============================================================================

function CaisseTab({ bar, showToast }) {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState([])
  const [payFor, setPayFor] = useState(null)
  const [showPaid, setShowPaid] = useState(false)

  const load = useCallback(async () => {
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString()
    const { data } = await supabase
      .from('orders')
      .select('*, tables ( number, label ), order_items ( * )')
      .eq('bar_id', bar.id)
      .neq('status', 'CANCELLED')
      .gte('created_at', since)
      .order('created_at', { ascending: true })
    setOrders(data || [])
    setLoading(false)
  }, [bar.id])

  useEffect(() => {
    load()
    const channel = supabase
      .channel(`caisse-${bar.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'orders', filter: `bar_id=eq.${bar.id}` },
        () => load()
      )
      .subscribe()
    return () => supabase.removeChannel(channel)
  }, [bar.id, load])

  const visible = orders.filter((o) => (showPaid ? true : !o.paid))

  const byTable = useMemo(() => {
    const map = new Map()
    for (const o of visible) {
      const key = o.tables?.number ?? 'À emporter'
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(o)
    }
    return [...map.entries()].sort((a, b) => String(a[0]).localeCompare(String(b[0]), 'fr', { numeric: true }))
  }, [visible])

  const selectedOrders = orders.filter((o) => selected.includes(o.id))
  const selectedTotal = selectedOrders.reduce((s, o) => s + Number(o.total || 0), 0)

  const toggle = (id) =>
    setSelected((p) => (p.includes(id) ? p.filter((x) => x !== id) : [...p, id]))

  async function markPaid(method) {
    const ids = selectedOrders.map((o) => o.id)
    const { error } = await supabase
      .from('orders')
      .update({ paid: true, paid_method: method })
      .in('id', ids)
    if (error) return showToast(error.message, 'error')
    showToast(`${ids.length} commande(s) marquée(s) réglée(s) — ${eur(selectedTotal)}`, 'ok')
    setSelected([])
    setPayFor(null)
    load()
  }

  async function printNote() {
    const canvas = await renderNoteCanvas({ bar, orders: selectedOrders })
    const blob = canvasesToPdfBlob([canvas], { quality: 0.94 })
    await shareOrDownload(blob, `TAPZ-addition-${Date.now()}.pdf`, 'Addition')
  }

  if (loading) return <Spinner />

  const unpaidTotal = orders.filter((o) => !o.paid).reduce((s, o) => s + Number(o.total || 0), 0)
  const paidTotal = orders.filter((o) => o.paid).reduce((s, o) => s + Number(o.total || 0), 0)

  return (
    <div style={{ paddingBottom: selected.length ? 120 : 0 }}>
      <div
        style={{
          background: 'rgba(255,61,139,.08)',
          border: `1px solid ${C.hot}44`,
          borderRadius: 14,
          padding: 14,
          marginBottom: 14,
        }}
      >
        <div style={{ fontSize: 12, color: C.dim, marginBottom: 8, lineHeight: 1.5 }}>
          L’encaissement se fait physiquement au bar. Ici, on ne fait que le
          <strong style={{ color: C.text }}> suivi</strong> : cochez les commandes réglées.
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 10, color: C.faint }}>RESTE À ENCAISSER</div>
            <div style={{ ...S.money, fontSize: 21, fontWeight: 900, color: C.hot }}>
              {eur(unpaidTotal)}
            </div>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 10, color: C.faint }}>DÉJÀ RÉGLÉ (24 H)</div>
            <div style={{ ...S.money, fontSize: 21, fontWeight: 900, color: C.ok }}>
              {eur(paidTotal)}
            </div>
          </div>
        </div>
      </div>

      <button
        onClick={() => setShowPaid((v) => !v)}
        style={{ ...S.btnGhost, marginBottom: 14, minHeight: 42, fontSize: 13 }}
      >
        {showPaid ? 'Masquer les commandes réglées' : 'Afficher aussi les commandes réglées'}
      </button>

      {byTable.length === 0 && (
        <Empty emoji="🧾" title="Rien à encaisser" sub="Les additions apparaîtront ici." />
      )}

      {byTable.map(([tableKey, list]) => {
        const tot = list.reduce((s, o) => s + Number(o.total || 0), 0)
        const allSel = list.every((o) => selected.includes(o.id))
        return (
          <div key={tableKey} style={{ ...S.card, marginBottom: 12, padding: 14 }}>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                marginBottom: 10,
              }}
            >
              <div>
                <div style={{ fontWeight: 900, fontSize: 16 }}>
                  {typeof tableKey === 'number' ? `Table ${tableKey}` : tableKey}
                  {list[0]?.tables?.label ? (
                    <span style={{ color: C.cyan, fontSize: 12 }}> · {list[0].tables.label}</span>
                  ) : null}
                </div>
                <div style={{ fontSize: 11, color: C.faint, marginTop: 2 }}>
                  {list.length} commande{list.length > 1 ? 's' : ''}
                </div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ ...S.money, fontWeight: 900, fontSize: 18, color: C.primary }}>
                  {eur(tot)}
                </div>
                <button
                  onClick={() =>
                    setSelected((p) => {
                      const ids = list.map((o) => o.id)
                      return allSel ? p.filter((x) => !ids.includes(x)) : [...new Set([...p, ...ids])]
                    })
                  }
                  style={{
                    background: 'none',
                    border: 'none',
                    color: C.cyan,
                    fontSize: 11.5,
                    fontWeight: 800,
                    cursor: 'pointer',
                    padding: '4px 0 0',
                  }}
                >
                  {allSel ? 'Tout décocher' : 'Tout sélectionner'}
                </button>
              </div>
            </div>

            <div style={{ display: 'grid', gap: 8 }}>
              {list.map((o) => {
                const sel = selected.includes(o.id)
                return (
                  <button
                    key={o.id}
                    onClick={() => toggle(o.id)}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 12,
                      padding: 12,
                      borderRadius: 12,
                      cursor: 'pointer',
                      textAlign: 'left',
                      border: `1px solid ${sel ? C.primary : C.line}`,
                      background: sel ? 'rgba(177,78,255,.12)' : C.surfaceHi,
                      color: C.text,
                    }}
                  >
                    <div
                      style={{
                        width: 22,
                        height: 22,
                        borderRadius: 7,
                        flexShrink: 0,
                        border: `2px solid ${sel ? C.primary : C.lineHi}`,
                        background: sel ? C.primary : 'transparent',
                        color: '#fff',
                        fontSize: 13,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontWeight: 900,
                      }}
                    >
                      {sel ? '✓' : ''}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 13.5, fontWeight: 800 }}>
                        #{o.code} · {timeFR(o.created_at)}
                        {o.paid && (
                          <span style={{ color: C.ok, fontSize: 11, marginLeft: 8 }}>✓ réglé</span>
                        )}
                      </div>
                      <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                        {(o.order_items || [])
                          .map((it) => `${it.quantity}× ${it.name_snapshot}`)
                          .join(' · ')
                          .slice(0, 90)}
                      </div>
                    </div>
                    <div style={{ ...S.money, fontWeight: 900 }}>{eur(o.total)}</div>
                  </button>
                )
              })}
            </div>
          </div>
        )
      })}

      {/* Barre d'addition */}
      {selected.length > 0 && (
        <div
          style={{
            position: 'fixed',
            left: 12,
            right: 12,
            bottom: 'calc(env(safe-area-inset-bottom) + 78px)',
            zIndex: 70,
            background: C.surfaceHi,
            border: `1px solid ${C.primary}`,
            borderRadius: 16,
            padding: 14,
            boxShadow: '0 0 34px rgba(177,78,255,.35)',
          }}
        >
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'baseline',
              marginBottom: 10,
            }}
          >
            <div style={{ fontSize: 13, color: C.dim, fontWeight: 700 }}>
              {selected.length} commande{selected.length > 1 ? 's' : ''} fusionnée
              {selected.length > 1 ? 's' : ''}
            </div>
            <div style={{ ...S.money, fontSize: 24, fontWeight: 900, color: C.primary }}>
              {eur(selectedTotal)}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={printNote} style={{ ...S.btnGhost, minHeight: 46, flex: 1 }}>
              📄 Note
            </button>
            <button
              onClick={() => setPayFor(true)}
              style={{ ...S.btn, minHeight: 46, flex: 2, boxShadow: 'none' }}
            >
              Marquer réglé
            </button>
          </div>
        </div>
      )}

      <Sheet open={!!payFor} onClose={() => setPayFor(null)} title="Encaissement">
        <div style={{ color: C.dim, fontSize: 13, marginBottom: 16, lineHeight: 1.55 }}>
          Total à encaisser : <strong style={{ color: C.primary }}>{eur(selectedTotal)}</strong>.
          <br />
          TAPZ ne traite aucun paiement — indiquez simplement le moyen utilisé au comptoir.
        </div>
        <div style={{ display: 'grid', gap: 8 }}>
          {[
            { k: 'especes', t: '💶 Espèces' },
            { k: 'cb', t: '💳 Carte bancaire' },
            { k: 'autre', t: '🎟️ Autre / avoir' },
          ].map((m) => (
            <button key={m.k} onClick={() => markPaid(m.k)} style={{ ...S.btnGhost, minHeight: 52 }}>
              {m.t}
            </button>
          ))}
        </div>
      </Sheet>
    </div>
  )
}

/** Note d'addition (fusion de plusieurs commandes) — Canvas → PDF. */
async function renderNoteCanvas({ bar, orders }) {
  const W = 1240
  const H = 1754
  const { canvas, ctx } = makeCanvas(W, H, 1)
  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, W, H)

  ctx.fillStyle = '#0A0713'
  ctx.fillRect(0, 0, W, 170)
  ctx.fillStyle = '#B14EFF'
  ctx.font = '900 24px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('T A P Z', 70, 44)
  ctx.fillStyle = '#FFFFFF'
  ctx.font = '900 40px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(`${bar?.name || 'Bar'} — Addition`, 70, 84)
  ctx.fillStyle = '#9C93B8'
  ctx.font = '400 20px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(dateFR(new Date()), 70, 132)

  let y = 224
  let grand = 0

  for (const o of orders) {
    ctx.fillStyle = '#141024'
    ctx.font = '800 26px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(
      `Table ${o.tables?.number ?? '—'} · #${o.code} · ${timeFR(o.created_at)}`,
      70,
      y
    )
    y += 40

    for (const it of o.order_items || []) {
      if (y > H - 260) break
      ctx.fillStyle = '#3D3757'
      ctx.font = '400 22px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText(`${it.quantity} × ${it.name_snapshot}`, 96, y)
      ctx.textAlign = 'right'
      ctx.fillStyle = '#141024'
      ctx.font = '700 22px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText(eur(Number(it.unit_price) * Number(it.quantity)), W - 70, y)
      ctx.textAlign = 'left'
      y += 32
    }

    grand += Number(o.total || 0)
    y += 10
    ctx.strokeStyle = '#EDE9F6'
    ctx.beginPath()
    ctx.moveTo(70, y)
    ctx.lineTo(W - 70, y)
    ctx.stroke()
    y += 30
  }

  y = Math.max(y + 20, H - 300)
  ctx.fillStyle = '#141024'
  ctx.font = '900 36px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('TOTAL', 70, y)
  ctx.textAlign = 'right'
  ctx.fillStyle = '#7A1FD6'
  ctx.font = '900 46px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(eur(grand), W - 70, y - 6)
  ctx.textAlign = 'center'

  ctx.fillStyle = '#C41E63'
  ctx.font = '900 26px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('À RÉGLER AU BAR — AUCUN PAIEMENT EN LIGNE', W / 2, y + 80)
  ctx.fillStyle = '#8A83A6'
  ctx.font = '400 17px -apple-system, Segoe UI, Roboto, Arial'
  const legal = [bar?.siret ? `SIRET ${bar.siret}` : '', bar?.tva_number ? `TVA ${bar.tva_number}` : '']
    .filter(Boolean)
    .join(' · ')
  if (legal) ctx.fillText(legal, W / 2, H - 90)
  ctx.textAlign = 'left'

  return canvas
}

// ============================================================================
//  ADMIN · CARTE — CRUD, catégories, traduction, copie, exports
// ============================================================================

const EMPTY_ITEM = {
  name: '',
  description: '',
  price: 0,
  category: 'Cocktails',
  emoji: '🍹',
  photo_url: '',
  is_popular: false,
  is_menu: false,
  available: true,
  stock: null,
  sort_order: 0,
  is_alcohol: true,
  vat_rate: 20,
  supplements: [],
  extras: [],
}

function MenuTab({ bar, bars, showToast }) {
  const [items, setItems] = useState([])
  const [settings, setSettings] = useState(null)
  const [loading, setLoading] = useState(true)
  const [editing, setEditing] = useState(null)
  const [tools, setTools] = useState(false)
  const [exporting, setExporting] = useState(false)
  const [margin, setMargin] = useState(0)
  const [copyTo, setCopyTo] = useState('')
  const [busy, setBusy] = useState('')

  const load = useCallback(async () => {
    const [it, st] = await Promise.all([
      supabase.from('menu_items').select('*').eq('bar_id', bar.id).order('category').order('sort_order'),
      supabase.from('bar_settings').select('*').eq('bar_id', bar.id).maybeSingle(),
    ])
    setItems(it.data || [])
    setSettings(st.data || null)
    setMargin(Number(st.data?.export_margin_pct || 0))
    setLoading(false)
  }, [bar.id])

  useEffect(() => {
    load()
  }, [load])

  const categories = useMemo(() => {
    const found = [...new Set(items.map((i) => i.category))]
    const order = settings?.category_order
    if (Array.isArray(order) && order.length) {
      const ranked = order.filter((c) => found.includes(c))
      return [...ranked, ...found.filter((c) => !ranked.includes(c))]
    }
    return found
  }, [items, settings])

  async function saveCategoryOrder(next) {
    setSettings((s) => ({ ...(s || {}), category_order: next }))
    await supabase
      .from('bar_settings')
      .upsert({ bar_id: bar.id, category_order: next }, { onConflict: 'bar_id' })
  }

  function moveCategory(cat, dir) {
    const arr = [...categories]
    const i = arr.indexOf(cat)
    const j = i + dir
    if (j < 0 || j >= arr.length) return
    ;[arr[i], arr[j]] = [arr[j], arr[i]]
    saveCategoryOrder(arr)
  }

  async function removeItem(id) {
    await supabase.from('menu_items').delete().eq('id', id)
    setEditing(null)
    load()
  }

  // ---- Traduction automatique -------------------------------------------
  async function translateMenu(langs) {
    setBusy('translate')
    try {
      const payload = items.map((i) => ({
        id: i.id,
        name: i.name,
        description: i.description || '',
      }))
      const { data, error } = await supabase.functions.invoke('translate-menu', {
        body: { targetLangs: langs, items: payload },
      })
      if (error) throw error
      const translations = data?.translations || {}
      let n = 0
      for (const item of items) {
        const t = translations[item.id]
        if (!t) continue
        await supabase
          .from('menu_items')
          .update({ translations: { ...(item.translations || {}), ...t } })
          .eq('id', item.id)
        n++
      }
      await supabase
        .from('bar_settings')
        .upsert(
          { bar_id: bar.id, languages: [...new Set(['fr', ...langs])] },
          { onConflict: 'bar_id' }
        )
      showToast(`${n} articles traduits.`, 'ok')
      load()
    } catch (e) {
      showToast('Traduction indisponible : ' + (e.message || 'Edge Function absente'), 'error')
    } finally {
      setBusy('')
    }
  }

  // ---- Copie de la carte vers un autre bar du compte ---------------------
  async function copyMenu(targetId) {
    if (!targetId) return
    setBusy('copy')
    try {
      const rows = items.map((i) => ({
        bar_id: targetId,
        name: i.name,
        description: i.description,
        price: i.price,
        category: i.category,
        emoji: i.emoji,
        photo_url: i.photo_url, // les photos sont partagées (Storage public)
        is_popular: i.is_popular,
        is_menu: i.is_menu,
        available: i.available,
        stock: i.stock,
        sort_order: i.sort_order,
        is_alcohol: i.is_alcohol,
        vat_rate: i.vat_rate,
        translations: i.translations,
        supplements: i.supplements, // sous-groupes d'options conservés
        extras: i.extras,
      }))
      const { error } = await supabase.from('menu_items').insert(rows)
      if (error) throw error
      if (settings?.category_order?.length) {
        await supabase
          .from('bar_settings')
          .upsert(
            { bar_id: targetId, category_order: settings.category_order },
            { onConflict: 'bar_id' }
          )
      }
      showToast(`${rows.length} articles copiés.`, 'ok')
      setCopyTo('')
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy('')
    }
  }

  // ---- Exports -----------------------------------------------------------
  async function exportPdf() {
    setExporting(true)
    try {
      await supabase
        .from('bar_settings')
        .upsert({ bar_id: bar.id, export_margin_pct: Number(margin) || 0 }, { onConflict: 'bar_id' })
      const canvases = await renderMenuPdfCanvases({ bar, items, categories, margin })
      const blob = canvasesToPdfBlob(canvases, { quality: 0.92 })
      await shareOrDownload(blob, `TAPZ-carte-${bar.slug || bar.id.slice(0, 6)}.pdf`, 'Carte')
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setExporting(false)
    }
  }

  async function exportPng() {
    setExporting(true)
    try {
      const canvas = await renderMenuStoryCanvas({ bar, items, categories, margin })
      await canvasToPng(canvas, `TAPZ-story-${bar.slug || 'carte'}.png`, 'Carte TAPZ')
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setExporting(false)
    }
  }

  if (loading) return <Spinner />

  return (
    <div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <button onClick={() => setEditing({ ...EMPTY_ITEM })} style={{ ...S.btn, minHeight: 46 }}>
          + Ajouter
        </button>
        <button
          onClick={() => setTools(true)}
          style={{ ...S.btnGhost, minHeight: 46, width: 'auto', padding: '0 18px' }}
        >
          ⋯
        </button>
      </div>

      {items.length === 0 && (
        <Empty emoji="🍸" title="Carte vide" sub="Ajoutez votre premier cocktail." />
      )}

      {categories.map((cat, ci) => (
        <div key={cat} style={{ marginBottom: 18 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
            <div style={{ fontWeight: 900, fontSize: 15, flex: 1 }}>{cat}</div>
            <button
              onClick={() => moveCategory(cat, -1)}
              disabled={ci === 0}
              style={{ ...miniBtn, opacity: ci === 0 ? 0.3 : 1 }}
            >
              ↑
            </button>
            <button
              onClick={() => moveCategory(cat, 1)}
              disabled={ci === categories.length - 1}
              style={{ ...miniBtn, opacity: ci === categories.length - 1 ? 0.3 : 1 }}
            >
              ↓
            </button>
          </div>

          <div style={{ display: 'grid', gap: 8 }}>
            {items
              .filter((i) => i.category === cat)
              .map((i) => (
                <button
                  key={i.id}
                  onClick={() => setEditing(i)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 12,
                    padding: 12,
                    borderRadius: 14,
                    cursor: 'pointer',
                    textAlign: 'left',
                    border: `1px solid ${C.line}`,
                    background: C.surface,
                    color: C.text,
                    opacity: i.available ? 1 : 0.45,
                  }}
                >
                  <div style={{ fontSize: 24 }}>
                    {i.photo_url ? (
                      <img
                        src={i.photo_url}
                        alt=""
                        style={{ width: 40, height: 40, borderRadius: 10, objectFit: 'cover' }}
                      />
                    ) : (
                      i.emoji || '🍹'
                    )}
                  </div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 800, fontSize: 14 }}>
                      {i.name}
                      {i.is_popular && <span style={{ color: C.hot, fontSize: 11 }}> 🔥</span>}
                      {!i.available && (
                        <span style={{ color: C.faint, fontSize: 11 }}> · masqué</span>
                      )}
                    </div>
                    <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                      {(i.supplements || []).length > 0
                        ? `${i.supplements.length} groupe(s) d'options`
                        : i.description?.slice(0, 46) || '—'}
                    </div>
                  </div>
                  <div style={{ ...S.money, fontWeight: 900, color: C.primary }}>{eur(i.price)}</div>
                </button>
              ))}
          </div>
        </div>
      ))}

      <ItemEditor
        item={editing}
        bar={bar}
        categories={categories}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null)
          load()
        }}
        onDelete={removeItem}
        showToast={showToast}
      />

      <Sheet open={tools} onClose={() => setTools(false)} title="Outils de la carte">
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontWeight: 900, marginBottom: 8 }}>🌍 Traduction automatique</div>
          <div style={{ color: C.dim, fontSize: 12.5, marginBottom: 10, lineHeight: 1.5 }}>
            Traduit noms et descriptions. Les noms de cocktails établis sont conservés.
          </div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {['en', 'es', 'it', 'de'].map((l) => (
              <button
                key={l}
                disabled={busy === 'translate'}
                onClick={() => translateMenu([l])}
                style={{ ...S.chip, padding: '10px 14px', color: C.text }}
              >
                {busy === 'translate' ? '…' : LANG_LABEL[l]}
              </button>
            ))}
          </div>
        </div>

        <div style={{ marginBottom: 20 }}>
          <div style={{ fontWeight: 900, marginBottom: 8 }}>📤 Export</div>
          <Field label={`MARGE APPLIQUÉE À L'EXPORT : ${margin}% (n'affecte pas la carte réelle)`}>
            <input
              type="range"
              min={-30}
              max={60}
              step={5}
              value={margin}
              onChange={(e) => setMargin(Number(e.target.value))}
              style={{ width: '100%', accentColor: C.primary }}
            />
          </Field>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              disabled={exporting}
              onClick={exportPdf}
              style={{ ...S.btnGhost, minHeight: 48, flex: 1 }}
            >
              📄 PDF A4
            </button>
            <button
              disabled={exporting}
              onClick={exportPng}
              style={{ ...S.btnGhost, minHeight: 48, flex: 1 }}
            >
              🖼️ Story PNG
            </button>
          </div>
        </div>

        {bars.length > 1 && (
          <div>
            <div style={{ fontWeight: 900, marginBottom: 8 }}>📋 Copier la carte</div>
            <div style={{ color: C.dim, fontSize: 12.5, marginBottom: 10, lineHeight: 1.5 }}>
              Photos et sous-groupes d’options inclus.
            </div>
            <select
              value={copyTo}
              onChange={(e) => setCopyTo(e.target.value)}
              style={{ ...S.input, marginBottom: 10 }}
            >
              <option value="">Choisir l’établissement cible…</option>
              {bars
                .filter((b) => b.id !== bar.id)
                .map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.name}
                  </option>
                ))}
            </select>
            <button
              disabled={!copyTo || busy === 'copy'}
              onClick={() => copyMenu(copyTo)}
              style={{ ...S.btn, opacity: !copyTo ? 0.5 : 1 }}
            >
              {busy === 'copy' ? 'Copie…' : `Copier ${items.length} articles`}
            </button>
          </div>
        )}
      </Sheet>
    </div>
  )
}

const miniBtn = {
  width: 34,
  height: 34,
  borderRadius: 10,
  border: `1px solid ${C.lineHi}`,
  background: 'transparent',
  color: C.text,
  cursor: 'pointer',
  fontSize: 14,
}

function ItemEditor({ item, bar, categories, onClose, onSaved, onDelete, showToast }) {
  const [f, setF] = useState(EMPTY_ITEM)
  const [busy, setBusy] = useState(false)
  const [tab, setTab] = useState('base')
  const fileRef = useRef(null)

  useEffect(() => {
    if (item) setF({ ...EMPTY_ITEM, ...item, supplements: item.supplements || [], extras: item.extras || [] })
  }, [item])

  if (!item) return null
  const set = (k, v) => setF((p) => ({ ...p, [k]: v }))

  async function uploadPhoto(file) {
    if (!file) return
    setBusy(true)
    try {
      const ext = (file.name.split('.').pop() || 'jpg').toLowerCase()
      const path = `${bar.id}/menu/${uid()}.${ext}`
      const { error } = await supabase.storage.from('tapz').upload(path, file, { upsert: true })
      if (error) throw error
      const { data } = supabase.storage.from('tapz').getPublicUrl(path)
      set('photo_url', data.publicUrl)
    } catch (e) {
      showToast('Upload impossible : ' + e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  async function save() {
    setBusy(true)
    try {
      const payload = {
        bar_id: bar.id,
        name: f.name.trim(),
        description: f.description?.trim() || null,
        price: Number(f.price) || 0,
        category: (f.category || 'Cocktails').trim(),
        emoji: f.emoji || '🍹',
        photo_url: f.photo_url || null,
        is_popular: !!f.is_popular,
        is_menu: !!f.is_menu,
        available: !!f.available,
        stock: f.stock === '' || f.stock === null ? null : Number(f.stock),
        sort_order: Number(f.sort_order) || 0,
        is_alcohol: !!f.is_alcohol,
        vat_rate: Number(f.vat_rate) || 20,
        supplements: f.supplements || [],
        extras: f.extras || [],
        translations: f.translations || {},
      }
      const { error } = f.id
        ? await supabase.from('menu_items').update(payload).eq('id', f.id)
        : await supabase.from('menu_items').insert(payload)
      if (error) throw error
      onSaved()
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  // --- éditeur de groupes d'options ---
  const addGroup = () =>
    set('supplements', [
      ...(f.supplements || []),
      { id: uid(), name: 'Nouveau groupe', required: false, min: 0, max: 1, options: [] },
    ])
  const updGroup = (gi, patch) =>
    set(
      'supplements',
      f.supplements.map((g, i) => (i === gi ? { ...g, ...patch } : g))
    )
  const delGroup = (gi) =>
    set('supplements', f.supplements.filter((_, i) => i !== gi))
  const addOption = (gi) =>
    updGroup(gi, {
      options: [...(f.supplements[gi].options || []), { id: uid(), name: 'Option', price: 0 }],
    })
  const updOption = (gi, oi, patch) =>
    updGroup(gi, {
      options: f.supplements[gi].options.map((o, i) => (i === oi ? { ...o, ...patch } : o)),
    })
  const delOption = (gi, oi) =>
    updGroup(gi, { options: f.supplements[gi].options.filter((_, i) => i !== oi) })

  return (
    <Sheet open={!!item} onClose={onClose} title={f.id ? 'Modifier' : 'Nouvel article'}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        {[
          { k: 'base', t: 'Général' },
          { k: 'options', t: 'Options' },
        ].map((t) => (
          <button
            key={t.k}
            onClick={() => setTab(t.k)}
            style={{
              flex: 1,
              minHeight: 42,
              borderRadius: 12,
              border: 'none',
              cursor: 'pointer',
              fontWeight: 800,
              fontSize: 13,
              background: tab === t.k ? C.primary : C.surfaceHi,
              color: tab === t.k ? '#fff' : C.dim,
            }}
          >
            {t.t}
          </button>
        ))}
      </div>

      {tab === 'base' ? (
        <>
          <Field label="NOM">
            <input style={S.input} value={f.name} onChange={(e) => set('name', e.target.value)} />
          </Field>
          <Field label="DESCRIPTION">
            <textarea
              style={{ ...S.input, minHeight: 68, paddingTop: 12 }}
              value={f.description || ''}
              onChange={(e) => set('description', e.target.value)}
            />
          </Field>

          <div style={{ display: 'flex', gap: 10 }}>
            <div style={{ flex: 1 }}>
              <Field label="PRIX (€)">
                <input
                  style={S.input}
                  type="number"
                  step="0.5"
                  value={f.price}
                  onChange={(e) => set('price', e.target.value)}
                />
              </Field>
            </div>
            <div style={{ flex: 1 }}>
              <Field label="TVA (%)">
                <select
                  style={S.input}
                  value={f.vat_rate}
                  onChange={(e) => set('vat_rate', e.target.value)}
                >
                  <option value={20}>20 % (alcool)</option>
                  <option value={10}>10 % (soft / nourriture sur place)</option>
                  <option value={5.5}>5,5 % (à emporter)</option>
                </select>
              </Field>
            </div>
          </div>

          <Field label="CATÉGORIE">
            <input
              style={S.input}
              list="tapz-cats"
              value={f.category}
              onChange={(e) => set('category', e.target.value)}
            />
            <datalist id="tapz-cats">
              {categories.map((c) => (
                <option key={c} value={c} />
              ))}
            </datalist>
          </Field>

          <Field label="EMOJI">
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {['🍹', '🍸', '🍺', '🥃', '🥂', '🍾', '🥤', '💧', '🔥', '🧀', '🍟', '🎶'].map((e) => (
                <button
                  key={e}
                  onClick={() => set('emoji', e)}
                  style={{
                    width: 42,
                    height: 42,
                    fontSize: 20,
                    borderRadius: 11,
                    cursor: 'pointer',
                    border: `1px solid ${f.emoji === e ? C.primary : C.lineHi}`,
                    background: f.emoji === e ? 'rgba(177,78,255,.16)' : 'transparent',
                  }}
                >
                  {e}
                </button>
              ))}
            </div>
          </Field>

          <Field label="PHOTO">
            <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              {f.photo_url && (
                <img
                  src={f.photo_url}
                  alt=""
                  style={{ width: 56, height: 56, borderRadius: 12, objectFit: 'cover' }}
                />
              )}
              <button
                onClick={() => fileRef.current?.click()}
                style={{ ...S.btnGhost, minHeight: 44, flex: 1 }}
              >
                {busy ? '…' : f.photo_url ? 'Remplacer' : 'Ajouter une photo'}
              </button>
              {f.photo_url && (
                <button
                  onClick={() => set('photo_url', '')}
                  style={{ ...miniBtn, width: 44, height: 44, color: C.hot }}
                >
                  ✕
                </button>
              )}
              <input
                ref={fileRef}
                type="file"
                accept="image/*"
                hidden
                onChange={(e) => uploadPhoto(e.target.files?.[0])}
              />
            </div>
          </Field>

          <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
            {[
              { k: 'is_popular', t: '🔥 Badge « Populaire »' },
              { k: 'is_menu', t: '🎫 Formule / menu' },
              { k: 'available', t: '👁️ Visible sur la carte' },
              { k: 'is_alcohol', t: '🥃 Contient de l’alcool' },
            ].map((o) => (
              <button
                key={o.k}
                onClick={() => set(o.k, !f[o.k])}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  minHeight: 46,
                  padding: '0 14px',
                  borderRadius: 12,
                  cursor: 'pointer',
                  border: `1px solid ${f[o.k] ? C.primary : C.lineHi}`,
                  background: f[o.k] ? 'rgba(177,78,255,.12)' : 'transparent',
                  color: C.text,
                  fontSize: 13.5,
                  fontWeight: 700,
                }}
              >
                <span>{o.t}</span>
                <span style={{ color: f[o.k] ? C.primary : C.faint, fontWeight: 900 }}>
                  {f[o.k] ? 'OUI' : 'NON'}
                </span>
              </button>
            ))}
          </div>

          <Field label="STOCK (vide = illimité)">
            <input
              style={S.input}
              type="number"
              value={f.stock ?? ''}
              onChange={(e) => set('stock', e.target.value === '' ? null : e.target.value)}
              placeholder="illimité"
            />
          </Field>
        </>
      ) : (
        <>
          <div style={{ color: C.dim, fontSize: 12.5, marginBottom: 14, lineHeight: 1.55 }}>
            Groupes composables (base alcool, sirop, garnitures…). Un groupe
            <strong style={{ color: C.text }}> obligatoire</strong> force un choix avant l’ajout au panier.
          </div>

          {(f.supplements || []).map((g, gi) => (
            <div
              key={g.id}
              style={{
                border: `1px solid ${C.lineHi}`,
                borderRadius: 14,
                padding: 12,
                marginBottom: 12,
                background: C.surfaceHi,
              }}
            >
              <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
                <input
                  style={{ ...S.input, minHeight: 42 }}
                  value={g.name}
                  onChange={(e) => updGroup(gi, { name: e.target.value })}
                  placeholder="Nom du groupe"
                />
                <button onClick={() => delGroup(gi)} style={{ ...miniBtn, width: 42, height: 42, color: C.hot }}>
                  ✕
                </button>
              </div>

              <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
                <button
                  onClick={() => updGroup(gi, { required: !g.required, min: !g.required ? 1 : 0 })}
                  style={{
                    ...S.chip,
                    flex: 1,
                    minHeight: 38,
                    color: g.required ? C.hot : C.dim,
                    borderColor: g.required ? C.hot : C.lineHi,
                  }}
                >
                  {g.required ? 'Obligatoire' : 'Optionnel'}
                </button>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <span style={{ fontSize: 11, color: C.faint }}>max</span>
                  <input
                    style={{ ...S.input, minHeight: 38, width: 62, padding: '0 8px', textAlign: 'center' }}
                    type="number"
                    min={1}
                    value={g.max ?? 1}
                    onChange={(e) => updGroup(gi, { max: Number(e.target.value) || 1 })}
                  />
                </div>
              </div>

              {(g.options || []).map((o, oi) => (
                <div key={o.id} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                  <input
                    style={{ ...S.input, minHeight: 40, flex: 2 }}
                    value={o.name}
                    onChange={(e) => updOption(gi, oi, { name: e.target.value })}
                  />
                  <input
                    style={{ ...S.input, minHeight: 40, width: 82, textAlign: 'right' }}
                    type="number"
                    step="0.5"
                    value={o.price}
                    onChange={(e) => updOption(gi, oi, { price: Number(e.target.value) || 0 })}
                  />
                  <button
                    onClick={() => delOption(gi, oi)}
                    style={{ ...miniBtn, width: 40, height: 40, color: C.faint }}
                  >
                    ✕
                  </button>
                </div>
              ))}

              <button onClick={() => addOption(gi)} style={{ ...S.btnGhost, minHeight: 40, fontSize: 13 }}>
                + Option
              </button>
            </div>
          ))}

          <button onClick={addGroup} style={{ ...S.btnGhost, marginBottom: 18 }}>
            + Groupe d’options
          </button>

          <div style={{ fontWeight: 900, marginBottom: 8 }}>Ajouts payants</div>
          {(f.extras || []).map((e2, i) => (
            <div key={e2.id} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
              <input
                style={{ ...S.input, minHeight: 40, flex: 2 }}
                value={e2.name}
                onChange={(ev) =>
                  set(
                    'extras',
                    f.extras.map((x, j) => (j === i ? { ...x, name: ev.target.value } : x))
                  )
                }
              />
              <input
                style={{ ...S.input, minHeight: 40, width: 82, textAlign: 'right' }}
                type="number"
                step="0.5"
                value={e2.price}
                onChange={(ev) =>
                  set(
                    'extras',
                    f.extras.map((x, j) => (j === i ? { ...x, price: Number(ev.target.value) || 0 } : x))
                  )
                }
              />
              <button
                onClick={() => set('extras', f.extras.filter((_, j) => j !== i))}
                style={{ ...miniBtn, width: 40, height: 40, color: C.faint }}
              >
                ✕
              </button>
            </div>
          ))}
          <button
            onClick={() => set('extras', [...(f.extras || []), { id: uid(), name: 'Ajout', price: 2 }])}
            style={{ ...S.btnGhost, minHeight: 42, fontSize: 13 }}
          >
            + Ajout
          </button>
        </>
      )}

      <div style={{ display: 'grid', gap: 8, marginTop: 18 }}>
        <button disabled={busy || !f.name.trim()} onClick={save} style={{ ...S.btn, opacity: busy || !f.name.trim() ? 0.5 : 1 }}>
          {busy ? '…' : 'Enregistrer'}
        </button>
        {f.id && (
          <button
            onClick={() => onDelete(f.id)}
            style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
          >
            Supprimer
          </button>
        )}
      </div>
    </Sheet>
  )
}

// ============================================================================
//  EXPORTS CARTE — Canvas 2D natif (PDF A4 multi-pages + story PNG)
// ============================================================================

async function renderMenuPdfCanvases({ bar, items, categories, margin }) {
  const W = 1240
  const H = 1754
  const M = 80
  const canvases = []
  let ctx, canvas, y

  const newPage = (first) => {
    const made = makeCanvas(W, H, 1)
    canvas = made.canvas
    ctx = made.ctx
    canvases.push(canvas)

    ctx.fillStyle = '#0A0713'
    ctx.fillRect(0, 0, W, H)
    // Halo néon discret
    const g = ctx.createRadialGradient(W / 2, 0, 40, W / 2, 0, 900)
    g.addColorStop(0, 'rgba(177,78,255,.34)')
    g.addColorStop(1, 'rgba(10,7,19,0)')
    ctx.fillStyle = g
    ctx.fillRect(0, 0, W, 620)

    if (first) {
      ctx.textAlign = 'center'
      ctx.fillStyle = '#B14EFF'
      ctx.font = '900 22px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText('T A P Z', W / 2, 88)
      ctx.fillStyle = '#F4F1FF'
      ctx.font = '900 68px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText(bar?.name || 'Notre carte', W / 2, 130)
      ctx.fillStyle = '#9C93B8'
      ctx.font = '400 24px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText('LA CARTE', W / 2, 218)
      ctx.textAlign = 'left'
      y = 300
    } else {
      y = 150
    }
  }

  newPage(true)

  for (const cat of categories) {
    const list = items.filter((i) => i.category === cat && i.available)
    if (!list.length) continue

    if (y > H - 320) newPage(false)

    // Titre de catégorie
    ctx.fillStyle = '#00E5FF'
    ctx.font = '900 34px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(cat.toUpperCase(), M, y)
    y += 20
    ctx.strokeStyle = 'rgba(0,229,255,.35)'
    ctx.lineWidth = 2
    ctx.beginPath()
    ctx.moveTo(M, y + 18)
    ctx.lineTo(W - M, y + 18)
    ctx.stroke()
    y += 54

    for (const it of list) {
      if (y > H - 150) {
        newPage(false)
        ctx.fillStyle = '#00E5FF'
        ctx.font = '900 26px -apple-system, Segoe UI, Roboto, Arial'
        ctx.fillText(`${cat.toUpperCase()} (suite)`, M, y)
        y += 56
      }

      ctx.fillStyle = '#F4F1FF'
      ctx.font = '800 30px -apple-system, Segoe UI, Roboto, Arial'
      const name = `${it.emoji || ''} ${it.name}`.trim()
      ctx.fillText(name, M, y)

      ctx.textAlign = 'right'
      ctx.fillStyle = '#B14EFF'
      ctx.font = '900 30px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText(eur(withMargin(it.price, margin)), W - M, y)
      ctx.textAlign = 'left'

      let h = 40
      if (it.description) {
        ctx.fillStyle = '#9C93B8'
        ctx.font = '400 21px -apple-system, Segoe UI, Roboto, Arial'
        const lines = wrapText(ctx, it.description, W - M * 2 - 200, 2)
        lines.forEach((l, i) => ctx.fillText(l, M, y + 34 + i * 26))
        h += lines.length * 26
      }
      if (it.is_popular) {
        ctx.fillStyle = '#FF3D8B'
        ctx.font = '900 16px -apple-system, Segoe UI, Roboto, Arial'
        ctx.fillText('★ POPULAIRE', M, y + h)
        h += 26
      }
      y += h + 20
    }
    y += 24
  }

  // Pied de page sur chaque page
  canvases.forEach((cv, i) => {
    const c2 = cv.getContext('2d')
    c2.textAlign = 'center'
    c2.fillStyle = '#4A4266'
    c2.font = '600 17px -apple-system, Segoe UI, Roboto, Arial'
    c2.fillText(
      `${bar?.name || ''} · Commande par QR code — paiement au bar · page ${i + 1}/${canvases.length}`,
      W / 2,
      H - 56
    )
    c2.textAlign = 'left'
  })

  return canvases
}

async function renderMenuStoryCanvas({ bar, items, categories, margin }) {
  const W = 1080
  const H = 1920
  const { canvas, ctx } = makeCanvas(W, H, 1)

  ctx.fillStyle = '#0A0713'
  ctx.fillRect(0, 0, W, H)
  const g = ctx.createLinearGradient(0, 0, W, H)
  g.addColorStop(0, 'rgba(177,78,255,.32)')
  g.addColorStop(0.55, 'rgba(0,229,255,.08)')
  g.addColorStop(1, 'rgba(255,61,139,.14)')
  ctx.fillStyle = g
  ctx.fillRect(0, 0, W, H)

  ctx.textAlign = 'center'
  ctx.fillStyle = '#B14EFF'
  ctx.font = '900 26px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('T A P Z', W / 2, 120)

  const logo = bar?.logo_url ? await loadImage(bar.logo_url) : null
  if (logo) {
    ctx.save()
    roundRect(ctx, W / 2 - 70, 168, 140, 140, 34)
    ctx.clip()
    ctx.drawImage(logo, W / 2 - 70, 168, 140, 140)
    ctx.restore()
  } else {
    ctx.font = '400 96px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(bar?.logo_emoji || '🍸', W / 2, 180)
  }

  ctx.fillStyle = '#F4F1FF'
  ctx.font = '900 74px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText(bar?.name || 'Notre carte', W / 2, 350)
  ctx.fillStyle = '#00E5FF'
  ctx.font = '800 28px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('CE SOIR AU COMPTOIR', W / 2, 448)
  ctx.textAlign = 'left'

  // Sélection : populaires d'abord, puis le reste
  const pool = [
    ...items.filter((i) => i.available && i.is_popular),
    ...items.filter((i) => i.available && !i.is_popular),
  ].slice(0, 9)

  let y = 540
  for (const it of pool) {
    ctx.fillStyle = 'rgba(255,255,255,.05)'
    roundRect(ctx, 70, y, W - 140, 116, 22)
    ctx.fill()
    ctx.strokeStyle = 'rgba(255,255,255,.1)'
    ctx.lineWidth = 2
    roundRect(ctx, 70, y, W - 140, 116, 22)
    ctx.stroke()

    ctx.font = '400 44px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillStyle = '#fff'
    ctx.fillText(it.emoji || '🍹', 100, y + 34)

    ctx.fillStyle = '#F4F1FF'
    ctx.font = '800 34px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(it.name.slice(0, 26), 168, y + 28)

    if (it.description) {
      ctx.fillStyle = '#9C93B8'
      ctx.font = '400 22px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText(wrapText(ctx, it.description, W - 460, 1)[0] || '', 168, y + 72)
    }

    ctx.textAlign = 'right'
    ctx.fillStyle = '#B14EFF'
    ctx.font = '900 38px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(eur(withMargin(it.price, margin)), W - 100, y + 40)
    ctx.textAlign = 'left'

    if (it.is_popular) {
      ctx.fillStyle = '#FF3D8B'
      ctx.font = '900 15px -apple-system, Segoe UI, Roboto, Arial'
      ctx.fillText('★ POPULAIRE', 168, y + 96)
    }

    y += 132
  }

  ctx.textAlign = 'center'
  ctx.fillStyle = '#FF3D8B'
  ctx.font = '900 30px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('SCANNE · COMMANDE · TRINQUE', W / 2, H - 190)
  ctx.fillStyle = '#6F668C'
  ctx.font = '600 22px -apple-system, Segoe UI, Roboto, Arial'
  ctx.fillText('Commande au QR code — règlement au bar', W / 2, H - 140)
  ctx.textAlign = 'left'

  return canvas
}

// ============================================================================
//  ADMIN · CRM CLIENTS
// ============================================================================

function ClientsTab({ bar }) {
  const [rows, setRows] = useState([])
  const [reviews, setReviews] = useState([])
  const [loading, setLoading] = useState(true)
  const [q, setQ] = useState('')

  useEffect(() => {
    ;(async () => {
      const [c, r] = await Promise.all([
        supabase
          .from('customers')
          .select('*')
          .eq('bar_id', bar.id)
          .order('total_spent', { ascending: false }),
        supabase
          .from('reviews')
          .select('*')
          .eq('bar_id', bar.id)
          .order('created_at', { ascending: false })
          .limit(20),
      ])
      setRows(c.data || [])
      setReviews(r.data || [])
      setLoading(false)
    })()
  }, [bar.id])

  if (loading) return <Spinner />

  const filtered = rows.filter((r) =>
    `${r.name || ''} ${r.email || ''}`.toLowerCase().includes(q.toLowerCase())
  )
  const avg = reviews.length
    ? (reviews.reduce((s, r) => s + r.rating, 0) / reviews.length).toFixed(1)
    : null

  return (
    <div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        {[
          { t: 'Clients', v: rows.length, c: C.primary },
          { t: 'CA cumulé', v: eur(rows.reduce((s, r) => s + Number(r.total_spent || 0), 0)), c: C.cyan },
          { t: 'Note', v: avg ? `${avg} ★` : '—', c: C.warn },
        ].map((s) => (
          <div
            key={s.t}
            style={{
              flex: 1,
              background: C.surface,
              border: `1px solid ${C.line}`,
              borderRadius: 14,
              padding: '12px 8px',
              textAlign: 'center',
            }}
          >
            <div style={{ ...S.money, fontSize: 16, fontWeight: 900, color: s.c }}>{s.v}</div>
            <div style={{ fontSize: 10, color: C.faint, marginTop: 3 }}>{s.t}</div>
          </div>
        ))}
      </div>

      <input
        style={{ ...S.input, marginBottom: 14 }}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Rechercher un client…"
      />

      {filtered.length === 0 && (
        <Empty
          emoji="👥"
          title="Pas encore de clients"
          sub="Le CRM se remplit quand une commande avec e-mail est servie."
        />
      )}

      <div style={{ display: 'grid', gap: 8 }}>
        {filtered.map((r) => (
          <div key={r.id} style={{ ...S.card, padding: 12, display: 'flex', gap: 12, alignItems: 'center' }}>
            <div
              style={{
                width: 42,
                height: 42,
                borderRadius: 12,
                background: 'rgba(177,78,255,.16)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontWeight: 900,
                color: C.primary,
                flexShrink: 0,
              }}
            >
              {(r.name || r.email || '?').slice(0, 1).toUpperCase()}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontWeight: 800, fontSize: 14 }}>{r.name || 'Client'}</div>
              <div
                style={{
                  fontSize: 11.5,
                  color: C.faint,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {r.email} · {r.orders_count} commande{r.orders_count > 1 ? 's' : ''}
                {r.last_order_at ? ` · ${dateFR(r.last_order_at).slice(0, 10)}` : ''}
              </div>
            </div>
            <div style={{ ...S.money, fontWeight: 900, color: C.primary }}>{eur(r.total_spent)}</div>
          </div>
        ))}
      </div>

      {reviews.length > 0 && (
        <>
          <div style={{ fontWeight: 900, fontSize: 15, margin: '22px 0 10px' }}>Derniers avis</div>
          <div style={{ display: 'grid', gap: 8 }}>
            {reviews.map((r) => (
              <div key={r.id} style={{ ...S.card, padding: 12 }}>
                <div style={{ color: C.warn, fontSize: 14 }}>
                  {'★'.repeat(r.rating)}
                  <span style={{ color: C.faint }}>{'☆'.repeat(5 - r.rating)}</span>
                  <span style={{ color: C.faint, fontSize: 11, marginLeft: 8 }}>
                    {dateFR(r.created_at)}
                  </span>
                </div>
                {r.comment && (
                  <div style={{ fontSize: 13, color: C.dim, marginTop: 6, lineHeight: 1.5 }}>
                    « {r.comment} »
                  </div>
                )}
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

// ============================================================================
//  ADMIN · PROMOTIONS / HAPPY HOUR
// ============================================================================

const EMPTY_PROMO = {
  label: 'Happy hour',
  code: '',
  kind: 'percent',
  value: 20,
  min_total: 0,
  days_of_week: [0, 1, 2, 3, 4, 5, 6],
  start_time: '18:00',
  end_time: '20:00',
  active: true,
}

const DAYS = ['D', 'L', 'M', 'M', 'J', 'V', 'S']

function PromosTab({ bar, showToast }) {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [editing, setEditing] = useState(null)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('promotions')
      .select('*')
      .eq('bar_id', bar.id)
      .order('created_at', { ascending: false })
    setRows(data || [])
    setLoading(false)
  }, [bar.id])

  useEffect(() => {
    load()
  }, [load])

  async function save(p) {
    const payload = {
      bar_id: bar.id,
      label: p.label?.trim() || 'Promo',
      code: p.code?.trim() ? p.code.trim().toUpperCase() : null,
      kind: p.kind,
      value: Number(p.value) || 0,
      min_total: Number(p.min_total) || 0,
      days_of_week: p.days_of_week,
      start_time: p.start_time || null,
      end_time: p.end_time || null,
      active: !!p.active,
    }
    const { error } = p.id
      ? await supabase.from('promotions').update(payload).eq('id', p.id)
      : await supabase.from('promotions').insert(payload)
    if (error) return showToast(error.message, 'error')
    setEditing(null)
    load()
  }

  if (loading) return <Spinner />

  return (
    <div>
      <button onClick={() => setEditing({ ...EMPTY_PROMO })} style={{ ...S.btn, marginBottom: 14 }}>
        + Nouvelle promotion
      </button>

      {rows.length === 0 && (
        <Empty
          emoji="🎉"
          title="Aucune promotion"
          sub="Happy hour automatique ou code promo saisi par le client."
        />
      )}

      <div style={{ display: 'grid', gap: 8 }}>
        {rows.map((p) => {
          const live = promoActiveNow(p)
          return (
            <button
              key={p.id}
              onClick={() => setEditing(p)}
              style={{
                ...S.card,
                padding: 14,
                cursor: 'pointer',
                textAlign: 'left',
                color: C.text,
                borderColor: live ? `${C.ok}66` : C.line,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10 }}>
                <div>
                  <div style={{ fontWeight: 900, fontSize: 15 }}>
                    {p.label}
                    {live && (
                      <span style={{ color: C.ok, fontSize: 11, marginLeft: 8 }}>● EN COURS</span>
                    )}
                    {!p.active && (
                      <span style={{ color: C.faint, fontSize: 11, marginLeft: 8 }}>désactivée</span>
                    )}
                  </div>
                  <div style={{ fontSize: 11.5, color: C.faint, marginTop: 3 }}>
                    {p.code ? `Code ${p.code}` : 'Automatique'}
                    {p.start_time && ` · ${p.start_time.slice(0, 5)}–${p.end_time?.slice(0, 5)}`}
                    {p.min_total > 0 && ` · dès ${eur(p.min_total)}`}
                  </div>
                  <div style={{ display: 'flex', gap: 4, marginTop: 7 }}>
                    {DAYS.map((d, i) => (
                      <span
                        key={i}
                        style={{
                          width: 20,
                          height: 20,
                          borderRadius: 6,
                          fontSize: 10,
                          fontWeight: 900,
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          background: (p.days_of_week || []).includes(i) ? C.primary : C.surfaceHi,
                          color: (p.days_of_week || []).includes(i) ? '#fff' : C.faint,
                        }}
                      >
                        {d}
                      </span>
                    ))}
                  </div>
                </div>
                <div style={{ ...S.money, fontWeight: 900, fontSize: 20, color: C.ok }}>
                  −{p.kind === 'amount' ? eur(p.value) : `${p.value}%`}
                </div>
              </div>
            </button>
          )
        })}
      </div>

      <PromoEditor
        promo={editing}
        onClose={() => setEditing(null)}
        onSave={save}
        onDelete={async (id) => {
          await supabase.from('promotions').delete().eq('id', id)
          setEditing(null)
          load()
        }}
      />
    </div>
  )
}

function PromoEditor({ promo, onClose, onSave, onDelete }) {
  const [f, setF] = useState(EMPTY_PROMO)
  useEffect(() => {
    if (promo) setF({ ...EMPTY_PROMO, ...promo })
  }, [promo])
  if (!promo) return null
  const set = (k, v) => setF((p) => ({ ...p, [k]: v }))

  return (
    <Sheet open={!!promo} onClose={onClose} title={f.id ? 'Modifier la promo' : 'Nouvelle promo'}>
      <Field label="NOM AFFICHÉ">
        <input style={S.input} value={f.label} onChange={(e) => set('label', e.target.value)} />
      </Field>

      <Field label="CODE (vide = happy hour automatique)">
        <input
          style={{ ...S.input, textTransform: 'uppercase' }}
          value={f.code || ''}
          onChange={(e) => set('code', e.target.value)}
          placeholder="HAPPY"
        />
      </Field>

      <div style={{ display: 'flex', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <Field label="TYPE">
            <select style={S.input} value={f.kind} onChange={(e) => set('kind', e.target.value)}>
              <option value="percent">Pourcentage</option>
              <option value="amount">Montant fixe</option>
            </select>
          </Field>
        </div>
        <div style={{ flex: 1 }}>
          <Field label={f.kind === 'percent' ? 'REMISE (%)' : 'REMISE (€)'}>
            <input
              style={S.input}
              type="number"
              value={f.value}
              onChange={(e) => set('value', e.target.value)}
            />
          </Field>
        </div>
      </div>

      <Field label="PANIER MINIMUM (€)">
        <input
          style={S.input}
          type="number"
          value={f.min_total}
          onChange={(e) => set('min_total', e.target.value)}
        />
      </Field>

      <Field label="JOURS">
        <div style={{ display: 'flex', gap: 6 }}>
          {DAYS.map((d, i) => {
            const on = (f.days_of_week || []).includes(i)
            return (
              <button
                key={i}
                onClick={() =>
                  set(
                    'days_of_week',
                    on ? f.days_of_week.filter((x) => x !== i) : [...(f.days_of_week || []), i]
                  )
                }
                style={{
                  flex: 1,
                  minHeight: 44,
                  borderRadius: 11,
                  cursor: 'pointer',
                  border: `1px solid ${on ? C.primary : C.lineHi}`,
                  background: on ? 'rgba(177,78,255,.16)' : 'transparent',
                  color: on ? C.text : C.faint,
                  fontWeight: 900,
                }}
              >
                {d}
              </button>
            )
          })}
        </div>
      </Field>

      <div style={{ display: 'flex', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <Field label="DÉBUT">
            <input
              style={S.input}
              type="time"
              value={(f.start_time || '').slice(0, 5)}
              onChange={(e) => set('start_time', e.target.value)}
            />
          </Field>
        </div>
        <div style={{ flex: 1 }}>
          <Field label="FIN">
            <input
              style={S.input}
              type="time"
              value={(f.end_time || '').slice(0, 5)}
              onChange={(e) => set('end_time', e.target.value)}
            />
          </Field>
        </div>
      </div>
      <div style={{ color: C.faint, fontSize: 11.5, marginTop: -6, marginBottom: 14 }}>
        Un créneau à cheval sur minuit (22:00 → 02:00) est géré.
      </div>

      <button
        onClick={() => set('active', !f.active)}
        style={{
          ...S.btnGhost,
          marginBottom: 14,
          borderColor: f.active ? C.ok : C.lineHi,
          color: f.active ? C.ok : C.dim,
        }}
      >
        {f.active ? '✓ Promotion active' : 'Promotion désactivée'}
      </button>

      <div style={{ display: 'grid', gap: 8 }}>
        <button onClick={() => onSave(f)} style={S.btn}>
          Enregistrer
        </button>
        {f.id && (
          <button
            onClick={() => onDelete(f.id)}
            style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
          >
            Supprimer
          </button>
        )}
      </div>
    </Sheet>
  )
}

// ============================================================================
//  ADMIN · QR CODES
//  URL stable : /r/{bar_id}/t/{table_number}
// ============================================================================

function QrTab({ bar, showToast }) {
  const [tables, setTables] = useState([])
  const [loading, setLoading] = useState(true)
  const [preview, setPreview] = useState(null)
  const [previewSrc, setPreviewSrc] = useState('')
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('tables')
      .select('*')
      .eq('bar_id', bar.id)
      .order('number')
    setTables(data || [])
    setLoading(false)
  }, [bar.id])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (!preview) return setPreviewSrc('')
    QRCode.toDataURL(tableUrl(bar.id, preview.number), {
      width: 720,
      margin: 1,
      errorCorrectionLevel: 'M',
      color: { dark: '#0A0713', light: '#FFFFFF' },
    }).then(setPreviewSrc)
  }, [preview, bar.id])

  async function addTable() {
    const next = (tables.at(-1)?.number || 0) + 1
    const { error } = await supabase.from('tables').insert({ bar_id: bar.id, number: next })
    if (error) return showToast(error.message, 'error')
    load()
  }

  async function saveLabel(t, label) {
    await supabase.from('tables').update({ label: label || null }).eq('id', t.id)
    setPreview((p) => (p ? { ...p, label } : p))
    load()
  }

  async function removeTable(t) {
    await supabase.from('tables').delete().eq('id', t.id)
    setPreview(null)
    load()
  }

  async function exportAll() {
    setBusy(true)
    try {
      const canvases = await renderQrSheets(bar, tables)
      const blob = canvasesToPdfBlob(canvases, { quality: 0.95 })
      const res = await shareOrDownload(
        blob,
        `TAPZ-QR-${bar.slug || bar.id.slice(0, 6)}.pdf`,
        'QR codes TAPZ'
      )
      if (res === 'downloaded') showToast('PDF téléchargé.', 'ok')
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  async function exportOne(t) {
    setBusy(true)
    try {
      const canvas = await renderQrCard(bar, t, 1080, 1350)
      await canvasToPng(canvas, `TAPZ-QR-table-${t.number}.png`, `QR table ${t.number}`)
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <Spinner />

  return (
    <div>
      <div
        style={{
          ...S.card,
          marginBottom: 14,
          background: 'rgba(0,229,255,.06)',
          borderColor: `${C.cyan}44`,
        }}
      >
        <div style={{ fontWeight: 900, marginBottom: 6 }}>⬛ Vos QR codes</div>
        <div style={{ color: C.dim, fontSize: 12.5, lineHeight: 1.6 }}>
          Chaque table a une URL fixe. Imprimez, plastifiez, collez sur la table —
          l’URL ne changera jamais, même si vous modifiez la carte.
        </div>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <button disabled={busy || !tables.length} onClick={exportAll} style={{ ...S.btn, minHeight: 48 }}>
          {busy ? '…' : `📄 Exporter les ${tables.length} QR (PDF, 6/page)`}
        </button>
        <button
          onClick={addTable}
          style={{ ...S.btnGhost, minHeight: 48, width: 'auto', padding: '0 18px' }}
        >
          +
        </button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(96px,1fr))', gap: 10 }}>
        {tables.map((t) => (
          <button
            key={t.id}
            onClick={() => setPreview(t)}
            style={{
              ...S.card,
              padding: 12,
              cursor: 'pointer',
              textAlign: 'center',
              color: C.text,
            }}
          >
            <div style={{ fontSize: 22, fontWeight: 900, color: C.primary }}>{t.number}</div>
            <div
              style={{
                fontSize: 10.5,
                color: t.label ? C.cyan : C.faint,
                marginTop: 4,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {t.label || 'Table'}
            </div>
          </button>
        ))}
      </div>

      {tables.length === 0 && (
        <Empty emoji="⬛" title="Aucune table" sub="Ajoutez-en une avec le bouton +." />
      )}

      <Sheet
        open={!!preview}
        onClose={() => setPreview(null)}
        title={preview ? `Table ${preview.number}` : ''}
      >
        {preview && (
          <>
            <div style={{ textAlign: 'center', marginBottom: 16 }}>
              {previewSrc ? (
                <img
                  src={previewSrc}
                  alt=""
                  style={{ width: 220, height: 220, borderRadius: 16, background: '#fff', padding: 8 }}
                />
              ) : (
                <div style={{ height: 220 }} />
              )}
              <div
                style={{
                  fontSize: 11,
                  color: C.faint,
                  marginTop: 10,
                  wordBreak: 'break-all',
                  lineHeight: 1.5,
                }}
              >
                {tableUrl(bar.id, preview.number)}
              </div>
            </div>

            <Field label="LIBELLÉ DE LA ZONE">
              <input
                style={S.input}
                defaultValue={preview.label || ''}
                onBlur={(e) => saveLabel(preview, e.target.value.trim())}
                placeholder="Carré VIP, Terrasse, Comptoir…"
              />
            </Field>

            <div style={{ display: 'grid', gap: 8 }}>
              <button onClick={() => exportOne(preview)} style={S.btn}>
                🖼️ Télécharger ce QR (PNG)
              </button>
              <button
                onClick={() => {
                  navigator.clipboard?.writeText(tableUrl(bar.id, preview.number))
                  showToast('Lien copié.', 'ok')
                }}
                style={S.btnGhost}
              >
                Copier le lien
              </button>
              <button
                onClick={() => removeTable(preview)}
                style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
              >
                Supprimer la table
              </button>
            </div>
          </>
        )}
      </Sheet>
    </div>
  )
}

/** Carte QR d'une table (canvas autonome, réutilisée pour PNG et PDF). */
async function renderQrCard(bar, table, W = 1080, H = 1350) {
  const { canvas, ctx } = makeCanvas(W, H, 1)
  const url = tableUrl(bar.id, table.number)
  const qrData = await QRCode.toDataURL(url, {
    width: 900,
    margin: 1,
    errorCorrectionLevel: 'M',
    color: { dark: '#0A0713', light: '#FFFFFF' },
  })
  const qr = await loadImage(qrData)

  ctx.fillStyle = '#0A0713'
  ctx.fillRect(0, 0, W, H)
  const g = ctx.createLinearGradient(0, 0, W, H)
  g.addColorStop(0, 'rgba(177,78,255,.34)')
  g.addColorStop(1, 'rgba(0,229,255,.12)')
  ctx.fillStyle = g
  ctx.fillRect(0, 0, W, H)

  ctx.textAlign = 'center'
  ctx.fillStyle = '#F4F1FF'
  ctx.font = `900 ${Math.round(W * 0.055)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText(bar.name || 'Bar', W / 2, H * 0.07)

  ctx.fillStyle = '#00E5FF'
  ctx.font = `800 ${Math.round(W * 0.036)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText(
    table.label ? `${table.label.toUpperCase()} · TABLE ${table.number}` : `TABLE ${table.number}`,
    W / 2,
    H * 0.135
  )

  const qs = W * 0.66
  const qx = (W - qs) / 2
  const qy = H * 0.21
  ctx.fillStyle = '#FFFFFF'
  roundRect(ctx, qx - 22, qy - 22, qs + 44, qs + 44, 34)
  ctx.fill()
  if (qr) ctx.drawImage(qr, qx, qy, qs, qs)

  ctx.fillStyle = '#F4F1FF'
  ctx.font = `900 ${Math.round(W * 0.05)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText('SCANNEZ POUR COMMANDER', W / 2, qy + qs + 84)

  ctx.fillStyle = '#9C93B8'
  ctx.font = `500 ${Math.round(W * 0.028)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText('Ouvrez l’appareil photo · pas d’application à installer', W / 2, qy + qs + 140)

  ctx.fillStyle = '#FF3D8B'
  ctx.font = `900 ${Math.round(W * 0.03)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText('PAIEMENT AU BAR', W / 2, qy + qs + 196)

  ctx.fillStyle = '#B14EFF'
  ctx.font = `900 ${Math.round(W * 0.026)}px -apple-system, Segoe UI, Roboto, Arial`
  ctx.fillText('T A P Z', W / 2, H - 56)
  ctx.textAlign = 'left'

  return canvas
}

/** Planche A4 de QR codes — 6 par page (2 colonnes × 3 lignes). */
async function renderQrSheets(bar, tables) {
  const W = 1240
  const H = 1754
  const perPage = 6
  const cols = 2
  const rows = 3
  const pad = 46
  const cellW = (W - pad * (cols + 1)) / cols
  const cellH = (H - 120 - pad * (rows + 1)) / rows
  const pages = []

  for (let p = 0; p < Math.ceil(tables.length / perPage); p++) {
    const { canvas, ctx } = makeCanvas(W, H, 1)
    ctx.fillStyle = '#FFFFFF'
    ctx.fillRect(0, 0, W, H)

    // En-tête de planche
    ctx.fillStyle = '#0A0713'
    ctx.fillRect(0, 0, W, 86)
    ctx.fillStyle = '#B14EFF'
    ctx.font = '900 20px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText('T A P Z', 46, 30)
    ctx.fillStyle = '#FFFFFF'
    ctx.font = '800 26px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(bar.name || 'Bar', 150, 26)
    ctx.textAlign = 'right'
    ctx.fillStyle = '#9C93B8'
    ctx.font = '400 18px -apple-system, Segoe UI, Roboto, Arial'
    ctx.fillText(
      `Page ${p + 1}/${Math.ceil(tables.length / perPage)} · découpez le long des pointillés`,
      W - 46,
      32
    )
    ctx.textAlign = 'left'

    const slice = tables.slice(p * perPage, (p + 1) * perPage)
    for (let i = 0; i < slice.length; i++) {
      const t = slice[i]
      const cx = pad + (i % cols) * (cellW + pad)
      const cy = 120 + pad + Math.floor(i / cols) * (cellH + pad)

      // Repères de découpe
      ctx.strokeStyle = '#D8D2E8'
      ctx.setLineDash([8, 8])
      ctx.lineWidth = 1.5
      roundRect(ctx, cx - 14, cy - 14, cellW + 28, cellH + 28, 16)
      ctx.stroke()
      ctx.setLineDash([])

      const card = await renderQrCard(bar, t, 620, 780)
      ctx.drawImage(card, cx, cy, cellW, cellH)
    }

    pages.push(canvas)
  }

  return pages
}

// ============================================================================
//  ADMIN · RÉGLAGES
// ============================================================================

function SettingsTab({ bar, bars, groups, session, onReload, showToast }) {
  const [f, setF] = useState(bar)
  const [st, setSt] = useState(null)
  const [busy, setBusy] = useState(false)
  const [newBar, setNewBar] = useState(false)
  const logoRef = useRef(null)

  useEffect(() => setF(bar), [bar])

  useEffect(() => {
    supabase
      .from('bar_settings')
      .select('*')
      .eq('bar_id', bar.id)
      .maybeSingle()
      .then(({ data }) => setSt(data || { bar_id: bar.id, default_eta_min: 10, accept_orders: true, languages: ['fr'] }))
  }, [bar.id])

  const setBarField = (k, v) => setF((p) => ({ ...p, [k]: v }))
  const setSetting = (k, v) => setSt((p) => ({ ...p, [k]: v }))

  async function saveAll() {
    setBusy(true)
    try {
      const { error: e1 } = await supabase
        .from('bars')
        .update({
          name: f.name?.trim() || bar.name,
          logo_emoji: f.logo_emoji,
          logo_url: f.logo_url || null,
          address: f.address || null,
          city: f.city || null,
          phone: f.phone || null,
          siret: f.siret || null,
          tva_number: f.tva_number || null,
        })
        .eq('id', bar.id)
      if (e1) throw e1

      const { error: e2 } = await supabase.from('bar_settings').upsert(
        {
          bar_id: bar.id,
          default_eta_min: Number(st.default_eta_min) || 10,
          accept_orders: !!st.accept_orders,
          service_message: st.service_message || null,
          receipt_footer: st.receipt_footer || null,
          languages: st.languages?.length ? st.languages : ['fr'],
          export_margin_pct: Number(st.export_margin_pct) || 0,
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'bar_id' }
      )
      if (e2) throw e2

      showToast('Réglages enregistrés.', 'ok')
      onReload()
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  async function uploadLogo(file) {
    if (!file) return
    setBusy(true)
    try {
      const ext = (file.name.split('.').pop() || 'jpg').toLowerCase()
      const path = `${bar.id}/logo-${uid()}.${ext}`
      const { error } = await supabase.storage.from('tapz').upload(path, file, { upsert: true })
      if (error) throw error
      const { data } = supabase.storage.from('tapz').getPublicUrl(path)
      setBarField('logo_url', data.publicUrl)
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  /** Partage d'un réglage vers tous les bars du même compte (mode groupe). */
  async function shareSettings() {
    setBusy(true)
    try {
      const others = bars.filter((b) => b.id !== bar.id)
      for (const b of others) {
        await supabase.from('bar_settings').upsert(
          {
            bar_id: b.id,
            default_eta_min: Number(st.default_eta_min) || 10,
            languages: st.languages,
            receipt_footer: st.receipt_footer,
            export_margin_pct: Number(st.export_margin_pct) || 0,
          },
          { onConflict: 'bar_id' }
        )
      }
      showToast(`Réglages partagés vers ${others.length} établissement(s).`, 'ok')
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  if (!st) return <Spinner />

  return (
    <div>
      {/* Ouverture / fermeture des commandes */}
      <div
        style={{
          ...S.card,
          marginBottom: 14,
          borderColor: st.accept_orders ? `${C.ok}55` : `${C.hot}55`,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ fontSize: 26 }}>{st.accept_orders ? '🟢' : '🔴'}</div>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 900 }}>
              {st.accept_orders ? 'Commandes ouvertes' : 'Commandes fermées'}
            </div>
            <div style={{ fontSize: 12, color: C.dim, marginTop: 2 }}>
              {st.accept_orders ? 'Les clients peuvent commander.' : 'Les QR affichent « fermé ».'}
            </div>
          </div>
          <button
            onClick={() => setSetting('accept_orders', !st.accept_orders)}
            style={{
              minHeight: 44,
              padding: '0 18px',
              borderRadius: 12,
              border: 'none',
              cursor: 'pointer',
              fontWeight: 900,
              background: st.accept_orders ? C.hot : C.ok,
              color: st.accept_orders ? '#fff' : '#0A0713',
            }}
          >
            {st.accept_orders ? 'Fermer' : 'Ouvrir'}
          </button>
        </div>
      </div>

      <Section title="Établissement">
        <Field label="NOM">
          <input style={S.input} value={f.name || ''} onChange={(e) => setBarField('name', e.target.value)} />
        </Field>

        <Field label="LOGO">
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            {f.logo_url ? (
              <img
                src={f.logo_url}
                alt=""
                style={{ width: 52, height: 52, borderRadius: 14, objectFit: 'cover' }}
              />
            ) : (
              <div style={{ fontSize: 32 }}>{f.logo_emoji}</div>
            )}
            <button onClick={() => logoRef.current?.click()} style={{ ...S.btnGhost, minHeight: 44, flex: 1 }}>
              {f.logo_url ? 'Remplacer' : 'Importer un logo'}
            </button>
            {f.logo_url && (
              <button
                onClick={() => setBarField('logo_url', '')}
                style={{ ...miniBtn, width: 44, height: 44, color: C.hot }}
              >
                ✕
              </button>
            )}
            <input
              ref={logoRef}
              type="file"
              accept="image/*"
              hidden
              onChange={(e) => uploadLogo(e.target.files?.[0])}
            />
          </div>
        </Field>

        <Field label="EMBLÈME (repli sans logo)">
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {['🍸', '🍺', '🥃', '🍾', '🪩', '🎶', '🍹', '🌃'].map((e) => (
              <button
                key={e}
                onClick={() => setBarField('logo_emoji', e)}
                style={{
                  width: 44,
                  height: 44,
                  fontSize: 21,
                  borderRadius: 12,
                  cursor: 'pointer',
                  border: `1px solid ${f.logo_emoji === e ? C.primary : C.lineHi}`,
                  background: f.logo_emoji === e ? 'rgba(177,78,255,.16)' : 'transparent',
                }}
              >
                {e}
              </button>
            ))}
          </div>
        </Field>
      </Section>

      <Section title="Mentions de la facture (France)">
        <div style={{ color: C.faint, fontSize: 12, marginBottom: 12, lineHeight: 1.55 }}>
          Ces informations apparaissent sur le récapitulatif PDF et l’e-mail. Toutes facultatives.
        </div>
        <Field label="ADRESSE">
          <input style={S.input} value={f.address || ''} onChange={(e) => setBarField('address', e.target.value)} />
        </Field>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label="VILLE">
              <input style={S.input} value={f.city || ''} onChange={(e) => setBarField('city', e.target.value)} />
            </Field>
          </div>
          <div style={{ flex: 1 }}>
            <Field label="TÉLÉPHONE">
              <input style={S.input} value={f.phone || ''} onChange={(e) => setBarField('phone', e.target.value)} />
            </Field>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label="SIRET">
              <input style={S.input} value={f.siret || ''} onChange={(e) => setBarField('siret', e.target.value)} />
            </Field>
          </div>
          <div style={{ flex: 1 }}>
            <Field label="N° TVA INTRACOM.">
              <input
                style={S.input}
                value={f.tva_number || ''}
                onChange={(e) => setBarField('tva_number', e.target.value)}
              />
            </Field>
          </div>
        </div>
      </Section>

      <Section title="Service">
        <Field label={`TEMPS DE PRÉPARATION PAR DÉFAUT : ${st.default_eta_min} MIN`}>
          <input
            type="range"
            min={2}
            max={45}
            value={st.default_eta_min}
            onChange={(e) => setSetting('default_eta_min', Number(e.target.value))}
            style={{ width: '100%', accentColor: C.primary }}
          />
        </Field>

        <Field label="MESSAGE AFFICHÉ AUX CLIENTS">
          <input
            style={S.input}
            value={st.service_message || ''}
            onChange={(e) => setSetting('service_message', e.target.value)}
            placeholder="Happy hour jusqu'à 20 h 🍹"
          />
        </Field>

        <Field label="MENTION EN BAS DU RÉCAPITULATIF">
          <input
            style={S.input}
            value={st.receipt_footer || ''}
            onChange={(e) => setSetting('receipt_footer', e.target.value)}
            placeholder="Merci et à très vite. À régler au bar."
          />
        </Field>

        <Field label="LANGUES DE LA CARTE">
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {['fr', 'en', 'es', 'it', 'de'].map((l) => {
              const on = (st.languages || ['fr']).includes(l)
              return (
                <button
                  key={l}
                  onClick={() =>
                    setSetting(
                      'languages',
                      on
                        ? (st.languages || []).filter((x) => x !== l || l === 'fr')
                        : [...(st.languages || []), l]
                    )
                  }
                  style={{
                    ...S.chip,
                    padding: '10px 14px',
                    borderColor: on ? C.primary : C.lineHi,
                    color: on ? C.text : C.dim,
                    background: on ? 'rgba(177,78,255,.14)' : 'transparent',
                  }}
                >
                  {LANG_LABEL[l]}
                </button>
              )
            })}
          </div>
        </Field>
      </Section>

      {bars.length > 1 && (
        <Section title="Groupe">
          <div style={{ color: C.dim, fontSize: 12.5, marginBottom: 12, lineHeight: 1.6 }}>
            Vous gérez <strong style={{ color: C.text }}>{bars.length} établissements</strong>
            {groups.length ? ` (groupe « ${groups[0].name} »)` : ''}. Vous pouvez propager les
            réglages de service de ce bar vers tous les autres.
          </div>
          <button onClick={shareSettings} disabled={busy} style={S.btnGhost}>
            Partager ces réglages avec les autres bars
          </button>
        </Section>
      )}

      <div style={{ display: 'grid', gap: 8, marginTop: 6 }}>
        <button disabled={busy} onClick={saveAll} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
          {busy ? '…' : 'Enregistrer'}
        </button>
        <button onClick={() => setNewBar(true)} style={S.btnGhost}>
          + Ajouter un établissement
        </button>
        <button
          onClick={() => supabase.auth.signOut()}
          style={{ ...S.btnGhost, borderColor: `${C.hot}55`, color: C.hot }}
        >
          Se déconnecter
        </button>
      </div>

      <div style={{ textAlign: 'center', marginTop: 24, color: C.faint, fontSize: 11, lineHeight: 1.8 }}>
        <Logo size={10} />
        <div style={{ marginTop: 8 }}>
          {session.user.email}
          <br />
          TAPZ ne traite aucun paiement en ligne.
        </div>
      </div>

      <NewBarSheet
        open={newBar}
        onClose={() => setNewBar(false)}
        session={session}
        groupId={groups[0]?.id ?? null}
        onCreated={() => {
          setNewBar(false)
          onReload()
        }}
        showToast={showToast}
      />
    </div>
  )
}

function Section({ title, children }) {
  return (
    <div style={{ ...S.card, marginBottom: 14 }}>
      <div style={{ fontWeight: 900, fontSize: 15, marginBottom: 14 }}>{title}</div>
      {children}
    </div>
  )
}

function NewBarSheet({ open, onClose, session, groupId, onCreated, showToast }) {
  const [name, setName] = useState('')
  const [emoji, setEmoji] = useState('🍺')
  const [tables, setTables] = useState(10)
  const [seed, setSeed] = useState(true)
  const [busy, setBusy] = useState(false)

  async function create() {
    setBusy(true)
    try {
      let gid = groupId
      if (!gid) {
        const { data: g } = await supabase
          .from('groups')
          .insert({ name: 'Mon groupe', owner_id: session.user.id })
          .select()
          .single()
        gid = g?.id ?? null
      }
      const { data: bar, error } = await supabase
        .from('bars')
        .insert({
          name: name.trim() || 'Nouveau bar',
          owner_id: session.user.id,
          group_id: gid,
          logo_emoji: emoji,
          tables_count: Number(tables) || 10,
          slug:
            (name || 'bar')
              .toLowerCase()
              .normalize('NFD')
              .replace(/[̀-ͯ]/g, '')
              .replace(/[^a-z0-9]+/g, '-')
              .replace(/^-|-$/g, '')
              .slice(0, 40) +
            '-' +
            uid().slice(0, 4),
        })
        .select()
        .single()
      if (error) throw error

      await supabase.from('tables').insert(
        Array.from({ length: Number(tables) || 10 }, (_, i) => ({ bar_id: bar.id, number: i + 1 }))
      )
      if (seed) await seedMenu(bar.id)
      onCreated()
    } catch (e) {
      showToast(e.message, 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Sheet open={open} onClose={onClose} title="Nouvel établissement">
      <Field label="NOM">
        <input style={S.input} value={name} onChange={(e) => setName(e.target.value)} />
      </Field>
      <Field label="EMBLÈME">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {['🍸', '🍺', '🥃', '🍾', '🪩', '🎶'].map((e) => (
            <button
              key={e}
              onClick={() => setEmoji(e)}
              style={{
                width: 44,
                height: 44,
                fontSize: 21,
                borderRadius: 12,
                cursor: 'pointer',
                border: `1px solid ${emoji === e ? C.primary : C.lineHi}`,
                background: emoji === e ? 'rgba(177,78,255,.16)' : 'transparent',
              }}
            >
              {e}
            </button>
          ))}
        </div>
      </Field>
      <Field label="NOMBRE DE TABLES">
        <input
          style={S.input}
          type="number"
          min={1}
          value={tables}
          onChange={(e) => setTables(e.target.value)}
        />
      </Field>
      <button
        onClick={() => setSeed((v) => !v)}
        style={{ ...S.btnGhost, marginBottom: 14, borderColor: seed ? C.primary : C.lineHi }}
      >
        {seed ? '✓ Pré-remplir une carte de démarrage' : 'Démarrer avec une carte vide'}
      </button>
      <button disabled={busy || !name.trim()} onClick={create} style={{ ...S.btn, opacity: busy || !name.trim() ? 0.5 : 1 }}>
        {busy ? 'Création…' : 'Créer'}
      </button>
    </Sheet>
  )
}


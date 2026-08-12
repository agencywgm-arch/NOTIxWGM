// ============================================================================
//  NOTI CALLING — Outil de commande par QR code
//  Feuille de route v2.0 · août 2026 · cas pilote Noti Club
//
//  PRINCIPE VALIDÉ : aucun paiement en ligne. La plateforme affiche le prix,
//  l'encaissement se fait à 100 % au bar. C'est un outil de commande + file
//  + CRM + communication, pas une caisse.
//
//  URL de QR stable — NE JAMAIS CASSER : /s/{scan_point_id}
//  Phase 1 : un QR à l'entrée, un QR au bar. Aucun QR sur les tables.
// ============================================================================

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import QRCode from 'qrcode'
import { supabase, isConfigured, frError, BASE_PATH, scanUrl } from './lib/supabase.js'
import { C, S, FONT, GRADIENT, eur, timeFR, dateFR, phoneFR } from './lib/theme.js'
import {
  canvasesToPdfBlob,
  shareOrDownload,
  downloadBlob,
  makeCanvas,
  roundRect,
  wrapText,
  loadImage,
  canvasToPng,
} from './lib/pdf.js'
import { Alarm, chime, tick, unlockAudio } from './lib/sound.js'
import { pushSupported, registerServiceWorker, subscribePush, notify, vibrate } from './lib/push.js'

// ----------------------------------------------------------------------------
//  Routeur minimal
// ----------------------------------------------------------------------------

function currentRoute() {
  if (typeof window === 'undefined') return '/'
  const p = window.location.pathname
  const base = BASE_PATH.replace(/\/$/, '')
  return (base && p.startsWith(base) ? p.slice(base.length) : p) || '/'
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

/** /s/{scan_point_id} */
function parseScanRoute(route) {
  const m = route.match(/^\/s\/([0-9a-fA-F-]{36})\/?$/)
  return m ? m[1] : null
}

// ----------------------------------------------------------------------------
//  Utilitaires
// ----------------------------------------------------------------------------

const LS = {
  get(k, d = null) {
    try {
      const v = localStorage.getItem(k)
      return v ? JSON.parse(v) : d
    } catch (_) {
      return d
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

const UNIVERSES = [
  { k: 'drinks', t: 'Boissons', en: 'Drinks', es: 'Bebidas', e: '🥂' },
  { k: 'food', t: 'Food', en: 'Food', es: 'Comida', e: '🍽️' },
  { k: 'bottles', t: 'Bouteilles', en: 'Bottles', es: 'Botellas', e: '🍾' },
]

const ORDER_STATUS = {
  RECEIVED: { label: 'Reçue', short: 'Reçue', color: C.indigo, step: 1 },
  READY: { label: 'Prête à retirer', short: 'Prête', color: C.terracotta, step: 2 },
  PICKED_UP: { label: 'Retirée', short: 'Retirée', color: C.ok, step: 3 },
  PAID: { label: 'Réglée', short: 'Réglée', color: C.ok, step: 4 },
  UNPAID: { label: 'Impayée', short: 'Impayée', color: C.danger, step: 4 },
  CANCELLED: { label: 'Annulée', short: 'Annulée', color: C.faint, step: 0 },
}

const TAG_LABEL = {
  vip: 'VIP',
  habitue: 'Habitué',
  gros_panier: 'Gros panier',
  incident: 'Incident',
}

// Multilingue FR / EN / ES (feuille de route §04 — pas de RTL)
const T = {
  fr: {
    welcome: 'Bienvenue',
    start: 'Commander',
    identify: 'Faisons connaissance',
    firstName: 'Prénom',
    backAgain: 'Bon retour parmi nous',
    order: 'Commander',
    cart: 'Panier',
    total: 'Total',
    send: 'Envoyer la commande',
    payAtBar: 'À régler au bar',
    soldOut: 'Épuisé',
    note: 'Note pour le bar',
    promo: 'Code promo',
    pickupCode: 'Code de retrait',
    ready: 'Prête à retirer',
    newOrder: 'Nouvelle commande',
  },
  en: {
    welcome: 'Welcome',
    start: 'Order',
    identify: 'Let’s get to know you',
    firstName: 'First name',
    backAgain: 'Welcome back',
    order: 'Order',
    cart: 'Cart',
    total: 'Total',
    send: 'Send order',
    payAtBar: 'Pay at the bar',
    soldOut: 'Sold out',
    note: 'Note for the bar',
    promo: 'Promo code',
    pickupCode: 'Pickup code',
    ready: 'Ready for pickup',
    newOrder: 'New order',
  },
  es: {
    welcome: 'Bienvenido',
    start: 'Pedir',
    identify: 'Vamos a conocernos',
    firstName: 'Nombre',
    backAgain: 'Bienvenido de nuevo',
    order: 'Pedir',
    cart: 'Carrito',
    total: 'Total',
    send: 'Enviar pedido',
    payAtBar: 'Pagar en la barra',
    soldOut: 'Agotado',
    note: 'Nota para la barra',
    promo: 'Código promocional',
    pickupCode: 'Código de recogida',
    ready: 'Listo para recoger',
    newOrder: 'Nuevo pedido',
  },
}

const useT = (lang) => T[lang] || T.fr

/** Traduction d'un produit selon la langue choisie. */
function tr(p, lang) {
  if (!lang || lang === 'fr') return { name: p.name, description: p.description }
  const t = p.translations?.[lang]
  return { name: t?.name || p.name, description: t?.description || p.description }
}

const lineUnit = (l) =>
  Number(l.basePrice || 0) + (l.options || []).reduce((s, o) => s + Number(o.price || 0), 0)
const lineTotal = (l) => lineUnit(l) * l.quantity

// ----------------------------------------------------------------------------
//  Composants partagés
// ----------------------------------------------------------------------------

function Keyframes() {
  return (
    <style>{`
      @keyframes notispin{to{transform:rotate(360deg)}}
      @keyframes notipulse{0%,100%{opacity:1}50%{opacity:.5}}
      @keyframes notiin{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
      @keyframes notiglow{0%,100%{box-shadow:0 0 0 0 rgba(185,106,76,.35)}50%{box-shadow:0 0 0 14px rgba(185,106,76,0)}}
    `}</style>
  )
}

function Spinner({ label = 'Chargement…' }) {
  return (
    <div
      style={{
        minHeight: '55vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 14,
        color: C.dim,
      }}
    >
      <Keyframes />
      <div
        style={{
          width: 32,
          height: 32,
          borderRadius: '50%',
          border: `3px solid ${C.line}`,
          borderTopColor: C.terracotta,
          animation: 'notispin .8s linear infinite',
        }}
      />
      <div style={{ fontSize: 13 }}>{label}</div>
    </div>
  )
}

/** Logo Noti Calling : cercle dégradé + « NOTI » bold + « Calling » en script. */
function Logo({ size = 1, stacked = true }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 * size, justifyContent: 'center' }}>
      <div
        style={{
          width: 34 * size,
          height: 34 * size,
          borderRadius: '50%',
          background: GRADIENT,
          flexShrink: 0,
        }}
      />
      <div style={{ lineHeight: 0.95, textAlign: 'left' }}>
        <div
          style={{
            fontFamily: FONT.display,
            fontSize: 24 * size,
            fontWeight: 700,
            color: C.terracotta,
            letterSpacing: 0.5,
          }}
        >
          Noti
        </div>
        <div
          style={{
            fontFamily: FONT.script,
            fontSize: 26 * size,
            color: C.indigo,
            marginTop: -4 * size,
            marginLeft: stacked ? 6 * size : 0,
          }}
        >
          Calling
        </div>
      </div>
    </div>
  )
}

function Toast({ toast }) {
  if (!toast) return null
  const color = toast.kind === 'error' ? C.danger : toast.kind === 'ok' ? C.ok : C.indigo
  return (
    <div
      style={{
        position: 'fixed',
        left: 16,
        right: 16,
        bottom: 'calc(env(safe-area-inset-bottom) + 92px)',
        zIndex: 9000,
        background: C.paper,
        border: `1.5px solid ${color}`,
        color: C.text,
        borderRadius: 14,
        padding: '14px 16px',
        fontSize: 14,
        fontWeight: 500,
        boxShadow: '0 12px 36px rgba(28,42,74,.16)',
        animation: 'notiin .18s ease',
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
    setTimeout(() => setToast(null), 4200)
  }, [])
  return [toast, show]
}

function Sheet({ open, onClose, title, children, maxHeight = '88vh' }) {
  if (!open) return null
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 8000,
        background: 'rgba(28,42,74,.42)',
        backdropFilter: 'blur(4px)',
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
          background: C.creamSoft,
          borderRadius: '24px 24px 0 0',
          padding: 22,
          paddingBottom: 'calc(env(safe-area-inset-bottom) + 22px)',
          animation: 'notiin .2s ease',
        }}
      >
        <div
          style={{ width: 44, height: 4, borderRadius: 2, background: C.lineHi, margin: '0 auto 18px' }}
        />
        {title && (
          <div style={{ ...S.h1, fontSize: 23, marginBottom: 16 }}>{title}</div>
        )}
        {children}
      </div>
    </div>
  )
}

function Field({ label, children, hint }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <label style={S.label}>{label}</label>
      {children}
      {hint && <div style={{ fontSize: 11.5, color: C.faint, marginTop: 6 }}>{hint}</div>}
    </div>
  )
}

function Empty({ emoji = '✨', title, sub }) {
  return (
    <div style={{ textAlign: 'center', padding: '44px 20px', color: C.dim }}>
      <div style={{ fontSize: 40, marginBottom: 12 }}>{emoji}</div>
      <div style={{ ...S.h1, fontSize: 19, marginBottom: 6 }}>{title}</div>
      {sub && <div style={{ fontSize: 13.5, lineHeight: 1.6 }}>{sub}</div>}
    </div>
  )
}

function Banner({ tone = 'info', children }) {
  const map = {
    info: { bg: 'rgba(106,95,214,.09)', bd: C.indigo, fg: C.indigo },
    warn: { bg: 'rgba(201,130,31,.10)', bd: C.warn, fg: C.warn },
    danger: { bg: 'rgba(192,57,43,.09)', bd: C.danger, fg: C.danger },
    ok: { bg: 'rgba(46,125,91,.10)', bd: C.ok, fg: C.ok },
  }[tone]
  return (
    <div
      style={{
        background: map.bg,
        border: `1.5px solid ${map.bd}55`,
        color: map.fg,
        borderRadius: 14,
        padding: 14,
        fontSize: 13.5,
        lineHeight: 1.55,
        fontWeight: 500,
      }}
    >
      {children}
    </div>
  )
}

/** Bandeau de rappel : la plateforme n'encaisse jamais. */
function PayAtBar({ compact = false }) {
  return (
    <div
      style={{
        background: 'rgba(185,106,76,.10)',
        border: `1.5px solid ${C.terracotta}55`,
        borderRadius: 14,
        padding: compact ? 10 : 14,
        textAlign: 'center',
      }}
    >
      <div
        style={{
          fontFamily: FONT.label,
          fontSize: compact ? 12 : 13.5,
          fontWeight: 600,
          letterSpacing: 1,
          textTransform: 'uppercase',
          color: C.terracotta,
        }}
      >
        Règlement au bar
      </div>
      {!compact && (
        <div style={{ fontSize: 12.5, color: C.dim, marginTop: 5, lineHeight: 1.5 }}>
          Aucun paiement en ligne. Vous réglez au comptoir en retirant votre commande.
        </div>
      )}
    </div>
  )
}

// ============================================================================
//  RACINE
// ============================================================================

export default function App() {
  const route = useRoute()
  const scanPointId = parseScanRoute(route)
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
  if (session === undefined)
    return (
      <div style={S.page}>
        <Spinner />
      </div>
    )
  if (scanPointId) return <ClientApp scanPointId={scanPointId} session={session} />
  return session ? <StaffApp session={session} /> : <StaffLogin />
}

function ConfigScreen() {
  return (
    <div style={{ ...S.page, padding: 24 }}>
      <Keyframes />
      <div style={{ padding: '24px 0' }}>
        <Logo />
      </div>
      <div style={S.card}>
        <div style={{ ...S.h1, fontSize: 22, marginBottom: 12 }}>Configuration requise</div>
        <p style={{ color: C.dim, fontSize: 14, lineHeight: 1.7 }}>
          Renseignez <code style={{ color: C.terracotta }}>VITE_SUPABASE_URL</code> et{' '}
          <code style={{ color: C.terracotta }}>VITE_SUPABASE_ANON_KEY</code> dans un fichier{' '}
          <code style={{ color: C.terracotta }}>.env</code> (voir{' '}
          <code style={{ color: C.terracotta }}>.env.example</code>), puis relancez{' '}
          <code style={{ color: C.terracotta }}>npm run dev</code>.
        </p>
      </div>
    </div>
  )
}

// ============================================================================
//  CÔTÉ CLIENT — /s/{scan_point_id}
//  Parcours : accueil → identification (prénom) → reconnaissance → espace commande
// ============================================================================

function ClientApp({ scanPointId, session }) {
  const [scanPoint, setScanPoint] = useState(null)
  const [event, setEvent] = useState(null)
  const [venue, setVenue] = useState(null)
  const [customer, setCustomer] = useState(null)
  const [loading, setLoading] = useState(true)
  const [fatal, setFatal] = useState('')
  const [step, setStep] = useState('welcome') // welcome|identify|hello|app
  const [lang, setLang] = useState(LS.get('noti:lang', 'fr'))
  const [toast, showToast] = useToast()

  useEffect(() => LS.set('noti:lang', lang), [lang])

  // ---- Chargement de la vitrine (lisible sans être identifié) -------------
  useEffect(() => {
    let dead = false
    ;(async () => {
      try {
        const { data: sp, error } = await supabase
          .from('scan_points')
          .select('*, events ( *, venues ( * ) )')
          .eq('id', scanPointId)
          .single()
        if (error) throw error
        if (dead) return
        setScanPoint(sp)
        setEvent(sp.events)
        setVenue(sp.events?.venues ?? null)
        if (sp.events?.languages?.length && !sp.events.languages.includes(lang)) {
          setLang(sp.events.languages[0])
        }
      } catch (e) {
        if (!dead) setFatal(frError(e))
      } finally {
        if (!dead) setLoading(false)
      }
    })()
    return () => {
      dead = true
    }
  }, [scanPointId])

  // ---- Chargement du client identifié -------------------------------------
  const loadCustomer = useCallback(async () => {
    if (!session?.user) {
      setCustomer(null)
      return null
    }
    const { data } = await supabase
      .from('customers')
      .select('*')
      .eq('auth_user_id', session.user.id)
      .maybeSingle()
    setCustomer(data ?? null)
    return data ?? null
  }, [session])

  useEffect(() => {
    loadCustomer()
  }, [loadCustomer])

  // ---- Aiguillage du parcours ---------------------------------------------
  useEffect(() => {
    if (loading || fatal) return
    if (!session?.user || !customer) {
      setStep((s) => (s === 'welcome' || s === 'identify' ? s : 'welcome'))
      return
    }
    setStep((s) => (s === 'hello' || s === 'app' ? s : 'hello'))
  }, [loading, fatal, session, customer])

  if (loading)
    return (
      <div style={S.page}>
        <Spinner label="Ouverture…" />
      </div>
    )

  if (fatal)
    return (
      <div style={{ ...S.page, padding: 24 }}>
        <Keyframes />
        <Empty emoji="🚫" title="QR code inconnu" sub={fatal} />
      </div>
    )

  const shared = { event, venue, scanPoint, lang, setLang, showToast }

  if (step === 'welcome')
    return <WelcomeScreen {...shared} onStart={() => setStep(session?.user ? 'hello' : 'identify')} />

  if (step === 'identify')
    return (
      <IdentifyScreen
        {...shared}
        onVerified={async () => {
          await loadCustomer()
        }}
      />
    )

  if (step === 'hello')
    return (
      <RecognitionScreen
        {...shared}
        customer={customer}
        onEnter={async () => {
          // La présence est enregistrée après la reconnaissance, pour que le
          // message « déjà venu » se base sur les soirées PRÉCÉDENTES.
          await supabase.rpc('register_scan', { p_scan_point: scanPointId, p_group_size: 1 })
          setStep('app')
        }}
      />
    )

  return (
    <>
      <OrderingApp {...shared} customer={customer} onReloadCustomer={loadCustomer} />
      <Toast toast={toast} />
    </>
  )
}

// ------------------------------------------------------------------ Accueil
function WelcomeScreen({ event, venue, scanPoint, lang, setLang, onStart }) {
  const t = useT(lang)
  const closed = event && (!event.is_active || !event.accept_orders)

  return (
    <div
      style={{
        ...S.page,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        padding: 26,
        background: `radial-gradient(120% 60% at 50% 0%, rgba(243,182,216,.35), rgba(247,241,233,0) 60%), ${C.cream}`,
      }}
    >
      <Keyframes />

      <div style={{ textAlign: 'center', marginBottom: 30 }}>
        <div style={{ marginBottom: 22 }}>
          <Logo size={1.5} />
        </div>
        <div
          style={{
            fontFamily: FONT.label,
            fontSize: 12,
            letterSpacing: 2.4,
            textTransform: 'uppercase',
            color: C.dim,
          }}
        >
          {venue?.name}
        </div>
        <h1 style={{ ...S.h1, fontSize: 34, marginTop: 10 }}>{event?.name}</h1>
        {event?.starts_at && (
          <div style={{ color: C.dim, fontSize: 13.5, marginTop: 8 }}>
            {dateFR(event.starts_at)}
            {event.closes_at ? ` → ${timeFR(event.closes_at)}` : ''}
          </div>
        )}
        <div
          style={{
            display: 'inline-block',
            marginTop: 14,
            padding: '6px 14px',
            borderRadius: 999,
            background: GRADIENT,
            color: C.navy,
            fontFamily: FONT.label,
            fontSize: 11.5,
            fontWeight: 600,
            letterSpacing: 1.2,
            textTransform: 'uppercase',
          }}
        >
          {scanPoint?.kind === 'bar' ? 'Point bar' : scanPoint?.kind === 'table' ? scanPoint.label || 'Table' : 'Entrée'}
        </div>
      </div>

      {event?.welcome_message && (
        <div style={{ marginBottom: 16 }}>
          <Banner tone="info">{event.welcome_message}</Banner>
        </div>
      )}

      {closed ? (
        <Banner tone="warn">
          {event?.service_message || 'Les commandes sont fermées pour le moment.'}
        </Banner>
      ) : (
        <>
          <div style={{ ...S.card, marginBottom: 16 }}>
            <div style={{ display: 'grid', gap: 14 }}>
              {[
                { n: '1', t: 'Vous commandez ici', s: 'Sans payer en ligne' },
                { n: '2', t: 'Le bar prépare', s: 'Vous suivez en direct' },
                { n: '3', t: 'Vous retirez au bar', s: 'Avec votre code de retrait' },
                { n: '4', t: 'Vous réglez sur place', s: 'Au comptoir, comme d’habitude' },
              ].map((s) => (
                <div key={s.n} style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
                  <div
                    style={{
                      width: 30,
                      height: 30,
                      flexShrink: 0,
                      borderRadius: '50%',
                      background: GRADIENT,
                      color: C.navy,
                      fontFamily: FONT.label,
                      fontWeight: 600,
                      fontSize: 14,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                    }}
                  >
                    {s.n}
                  </div>
                  <div>
                    <div style={{ fontWeight: 500, fontSize: 14.5 }}>{s.t}</div>
                    <div style={{ fontSize: 12, color: C.dim }}>{s.s}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <button
            onClick={() => {
              unlockAudio()
              onStart()
            }}
            style={S.btn}
          >
            {t.start}
          </button>
        </>
      )}

      {(event?.languages?.length ?? 0) > 1 && (
        <div style={{ display: 'flex', gap: 8, justifyContent: 'center', marginTop: 22 }}>
          {event.languages.map((l) => (
            <button
              key={l}
              onClick={() => setLang(l)}
              style={{
                ...S.chip,
                borderColor: lang === l ? C.terracotta : C.lineHi,
                color: lang === l ? C.terracotta : C.dim,
              }}
            >
              {l.toUpperCase()}
            </button>
          ))}
        </div>
      )}

      <div style={{ marginTop: 22 }}>
        <PayAtBar />
      </div>
    </div>
  )
}

// ------------------------------------------------------------ Identification
// Une session anonyme Supabase (aucun SMS, aucun compte) porte le prénom saisi.
function IdentifyScreen({ lang, onVerified }) {
  const t = useT(lang)
  const [firstName, setFirstName] = useState(LS.get('noti:firstName', ''))
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  async function submit() {
    setErr('')
    if (!firstName.trim()) return setErr('Le prénom est obligatoire.')
    setBusy(true)
    try {
      const { data } = await supabase.auth.getSession()
      if (!data.session) {
        const { error } = await supabase.auth.signInAnonymously()
        if (error) throw error
      }
      const { error: e2 } = await supabase.rpc('upsert_me', { p_first_name: firstName.trim() })
      if (e2) throw e2
      LS.set('noti:firstName', firstName)
      await onVerified()
    } catch (e) {
      setErr(frError(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div style={{ ...S.page, padding: 26, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
      <Keyframes />
      <div style={{ textAlign: 'center', marginBottom: 26 }}>
        <Logo />
        <h1 style={{ ...S.h1, fontSize: 26, marginTop: 20 }}>{t.identify}</h1>
        <div style={{ color: C.dim, fontSize: 13.5, marginTop: 8, lineHeight: 1.6 }}>
          Comment souhaitez-vous être appelé·e au retrait de votre commande ?
        </div>
      </div>

      <div style={S.card}>
        <Field label={t.firstName}>
          <input
            style={S.input}
            value={firstName}
            onChange={(e) => setFirstName(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && submit()}
            autoComplete="given-name"
            placeholder="Alex"
            autoFocus
          />
        </Field>

        {err && (
          <div style={{ marginBottom: 12 }}>
            <Banner tone="danger">{err}</Banner>
          </div>
        )}

        <button disabled={busy} onClick={submit} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
          {busy ? '…' : t.start}
        </button>
      </div>

      <div style={{ textAlign: 'center', color: C.faint, fontSize: 11.5, marginTop: 20, lineHeight: 1.7 }}>
        En commandant, vous acceptez nos CGU — retrait et règlement au bar obligatoires.
        <br />
        Données hébergées dans l’Union européenne. Aucun paiement en ligne.
      </div>
    </div>
  )
}

// ------------------------------------------------------ Reconnaissance client
function RecognitionScreen({ lang, customer, event, onEnter }) {
  const t = useT(lang)
  const [busy, setBusy] = useState(false)
  const returning = (customer?.events_count ?? 0) >= 1
  const incident = (customer?.tags || []).includes('incident')
  const vip = (customer?.tags || []).includes('vip')

  return (
    <div
      style={{
        ...S.page,
        padding: 26,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        background: `radial-gradient(120% 55% at 50% 0%, rgba(244,165,122,.3), rgba(247,241,233,0) 60%), ${C.cream}`,
      }}
    >
      <Keyframes />
      <div style={{ textAlign: 'center', marginBottom: 26 }}>
        <div style={{ fontSize: 46, marginBottom: 12 }}>{incident ? '🤝' : vip ? '⭐' : returning ? '🥂' : '👋'}</div>
        <h1 style={{ ...S.h1, fontSize: 30 }}>
          {incident
            ? 'Ravi de vous revoir'
            : returning
              ? t.backAgain
              : `${t.welcome}, ${customer?.first_name || ''}`}
        </h1>
        {returning && !incident && (
          <div style={{ color: C.dim, fontSize: 14, marginTop: 10, lineHeight: 1.6 }}>
            {customer.events_count === 1
              ? 'Deuxième soirée avec nous — content de vous retrouver.'
              : `${customer.events_count} soirées passées avec nous. Merci de votre fidélité.`}
          </div>
        )}
        {vip && (
          <div style={{ marginTop: 14 }}>
            <span
              style={{
                padding: '6px 14px',
                borderRadius: 999,
                background: GRADIENT,
                color: C.navy,
                fontFamily: FONT.label,
                fontSize: 12,
                fontWeight: 600,
                letterSpacing: 1.4,
              }}
            >
              STATUT VIP
            </span>
          </div>
        )}
      </div>

      {incident && (
        <div style={{ marginBottom: 16 }}>
          <Banner tone="warn">
            Une commande d’une soirée précédente est restée impayée. Merci de régulariser auprès du
            bar — l’équipe vous accompagnera.
          </Banner>
        </div>
      )}

      {event?.service_message && (
        <div style={{ marginBottom: 16 }}>
          <Banner tone="info">{event.service_message}</Banner>
        </div>
      )}

      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true)
          await onEnter()
        }}
        style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}
      >
        {busy ? '…' : t.order}
      </button>
    </div>
  )
}

// ============================================================================
//  ESPACE COMMANDE CLIENT
// ============================================================================

function OrderingApp({ event, venue, scanPoint, lang, setLang, customer, showToast, onReloadCustomer }) {
  const t = useT(lang)
  const [products, setProducts] = useState([])
  const [orders, setOrders] = useState([])
  const [messages, setMessages] = useState([])
  const [loading, setLoading] = useState(true)
  const [view, setView] = useState('menu')
  const [universe, setUniverse] = useState('drinks')
  const [subcat, setSubcat] = useState(null)
  const [sheetProduct, setSheetProduct] = useState(null)
  const [cartOpen, setCartOpen] = useState(false)
  const [checkoutOpen, setCartCheckout] = useState(false)
  const [cart, setCart] = useState([])
  const [pushOn, setPushOn] = useState(false)
  const [reviewFor, setReviewFor] = useState(null)
  const lastReady = useRef(new Set())

  // ---- Chargement ---------------------------------------------------------
  const loadOrders = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, order_items ( * )')
      .eq('event_id', event.id)
      .eq('customer_id', customer.id)
      .order('created_at', { ascending: false })
    setOrders(data || [])
  }, [event.id, customer.id])

  const loadMessages = useCallback(async () => {
    const { data } = await supabase
      .from('messages')
      .select('*')
      .eq('event_id', event.id)
      .order('created_at', { ascending: false })
      .limit(20)
    setMessages(data || [])
  }, [event.id])

  useEffect(() => {
    let dead = false
    ;(async () => {
      const { data } = await supabase
        .from('products')
        .select('*')
        .eq('venue_id', venue.id)
        .eq('is_listed', true)
        .order('universe')
        .order('sort_order')
      if (dead) return
      setProducts(data || [])
      await loadOrders()
      await loadMessages()
      setLoading(false)
    })()
    return () => {
      dead = true
    }
  }, [venue.id, loadOrders, loadMessages])

  // ---- Temps réel (WebSocket) + repli en polling doux ---------------------
  useEffect(() => {
    const ch = supabase
      .channel(`client-${customer.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'orders', filter: `customer_id=eq.${customer.id}` },
        () => loadOrders()
      )
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `event_id=eq.${event.id}` },
        () => loadMessages()
      )
      .subscribe()

    const poll = setInterval(() => {
      loadOrders()
      loadMessages()
    }, 20000)

    const onSw = (e) => {
      if (e.data?.type === 'NOTI_PUSH') loadOrders()
    }
    navigator.serviceWorker?.addEventListener('message', onSw)

    return () => {
      supabase.removeChannel(ch)
      clearInterval(poll)
      navigator.serviceWorker?.removeEventListener('message', onSw)
    }
  }, [customer.id, event.id, loadOrders, loadMessages])

  // ---- Sonnerie douce quand une commande passe à « prête » ----------------
  useEffect(() => {
    for (const o of orders) {
      if (o.status === 'READY' && !lastReady.current.has(o.id)) {
        lastReady.current.add(o.id)
        chime()
        vibrate([250, 120, 250, 120, 450])
      }
    }
  }, [orders])

  // ---- Discipline de la file (§06) ---------------------------------------
  const readyOrder = orders.find((o) => o.status === 'READY')
  const blocked = Boolean(readyOrder)
  const activeOrders = orders.filter((o) => ['RECEIVED', 'READY'].includes(o.status))
  const pendingPayment = orders.filter((o) => ['PICKED_UP', 'UNPAID'].includes(o.status))

  // ---- Catalogue ----------------------------------------------------------
  const universesAvailable = useMemo(
    () => UNIVERSES.filter((u) => products.some((p) => p.universe === u.k)),
    [products]
  )

  useEffect(() => {
    if (universesAvailable.length && !universesAvailable.some((u) => u.k === universe)) {
      setUniverse(universesAvailable[0].k)
    }
  }, [universesAvailable, universe])

  const subcats = useMemo(
    () => [...new Set(products.filter((p) => p.universe === universe).map((p) => p.subcategory))],
    [products, universe]
  )

  useEffect(() => {
    setSubcat((s) => (subcats.includes(s) ? s : subcats[0] ?? null))
  }, [subcats])

  const visible = products.filter((p) => p.universe === universe && p.subcategory === subcat)

  const subtotal = cart.reduce((s, l) => s + lineTotal(l), 0)
  const cartCount = cart.reduce((s, l) => s + l.quantity, 0)

  function addToCart(product, variant, options, quantity) {
    tick()
    vibrate([14])
    const sig = JSON.stringify([product.id, variant?.id ?? null, (options || []).map((o) => o.id).sort()])
    setCart((prev) => {
      const found = prev.find((l) => l.sig === sig)
      if (found) return prev.map((l) => (l.sig === sig ? { ...l, quantity: l.quantity + quantity } : l))
      return [
        ...prev,
        {
          key: uid(),
          sig,
          product,
          variantId: variant?.id ?? null,
          variantLabel: variant?.label ?? null,
          basePrice: variant ? Number(variant.price) : Number(product.price),
          options: options || [],
          quantity,
        },
      ]
    })
  }

  const setQty = (key, delta) =>
    setCart((prev) =>
      prev.map((l) => (l.key === key ? { ...l, quantity: l.quantity + delta } : l)).filter((l) => l.quantity > 0)
    )

  async function submitOrder({ note, promo }) {
    const items = cart.map((l) => ({
      product_id: l.product.id,
      quantity: l.quantity,
      variant_id: l.variantId,
      options: l.options.map((o) => ({ id: o.id, name: o.name, price: o.price })),
    }))

    const { data, error } = await supabase.rpc('place_order', {
      p_event: event.id,
      p_scan_point: scanPoint.id,
      p_items: items,
      p_note: note || null,
      p_promo: promo || null,
    })
    if (error) throw error

    setCart([])
    setCartCheckout(false)
    setCartOpen(false)
    setView('orders')
    await loadOrders()

    // Notification de statut « commande reçue » (best-effort).
    notify({
      eventId: event.id,
      kind: 'status',
      customerId: customer.id,
      orderId: data?.id,
      title: 'Commande reçue',
      body: `Votre commande ${data?.pickup_code} est bien arrivée au bar. Vous serez prévenu dès qu’elle est prête.`,
    })
    return data
  }

  if (loading)
    return (
      <div style={S.page}>
        <Spinner label="Chargement de la carte…" />
      </div>
    )

  const unread = messages.filter((m) => m.kind !== 'status' && !m.read_at)

  return (
    <div style={{ ...S.page, paddingBottom: 110 }}>
      <Keyframes />

      {/* En-tête */}
      <div
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 50,
          background: `${C.cream}f2`,
          backdropFilter: 'blur(10px)',
          borderBottom: `1px solid ${C.line}`,
          padding: '12px 16px',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <Logo size={0.72} />
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            {(event?.languages?.length ?? 0) > 1 && (
              <select
                value={lang}
                onChange={(e) => setLang(e.target.value)}
                style={{
                  background: 'transparent',
                  border: `1px solid ${C.lineHi}`,
                  borderRadius: 10,
                  padding: '5px 7px',
                  fontSize: 12,
                  color: C.dim,
                }}
              >
                {event.languages.map((l) => (
                  <option key={l} value={l}>
                    {l.toUpperCase()}
                  </option>
                ))}
              </select>
            )}
            <button
              onClick={() => setView(view === 'menu' ? 'orders' : 'menu')}
              style={{
                ...S.chip,
                position: 'relative',
                borderColor: view === 'orders' ? C.terracotta : C.lineHi,
                color: view === 'orders' ? C.terracotta : C.dim,
              }}
            >
              {view === 'menu' ? 'Mes commandes' : 'La carte'}
              {activeOrders.length > 0 && view === 'menu' && (
                <span
                  style={{
                    position: 'absolute',
                    top: -5,
                    right: -5,
                    width: 18,
                    height: 18,
                    borderRadius: 9,
                    background: C.terracotta,
                    color: '#fff',
                    fontSize: 10,
                    fontWeight: 700,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                  }}
                >
                  {activeOrders.length}
                </span>
              )}
            </button>
          </div>
        </div>
      </div>

      <div style={{ padding: 16 }}>
        {/* Message de blocage de file */}
        {blocked && (
          <div style={{ marginBottom: 14 }}>
            <Banner tone="warn">
              <strong>Vous avez une commande prête à retirer.</strong> Récupérez-la d’abord au bar
              avant de pouvoir passer une nouvelle commande — code{' '}
              <strong>{readyOrder.pickup_code}</strong>.
            </Banner>
          </div>
        )}

        {/* Messages de l'organisateur */}
        {unread.length > 0 && (
          <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
            {unread.slice(0, 3).map((m) => (
              <div
                key={m.id}
                style={{
                  background: m.kind === 'individual' ? 'rgba(106,95,214,.10)' : C.paper,
                  border: `1.5px solid ${m.kind === 'individual' ? C.indigo : C.line}`,
                  borderRadius: 14,
                  padding: 14,
                }}
              >
                <div
                  style={{
                    fontFamily: FONT.label,
                    fontSize: 10.5,
                    letterSpacing: 1.4,
                    textTransform: 'uppercase',
                    color: m.kind === 'individual' ? C.indigo : C.terracotta,
                    marginBottom: 5,
                  }}
                >
                  {m.kind === 'individual' ? 'Message pour vous' : 'Annonce de la soirée'} ·{' '}
                  {timeFR(m.created_at)}
                </div>
                <div style={{ fontSize: 14, lineHeight: 1.55 }}>{m.body}</div>
                {m.customer_id === customer.id && (
                  <button
                    onClick={async () => {
                      await supabase
                        .from('messages')
                        .update({ read_at: new Date().toISOString() })
                        .eq('id', m.id)
                      loadMessages()
                    }}
                    style={{
                      background: 'none',
                      border: 'none',
                      color: C.dim,
                      fontSize: 12,
                      padding: '8px 0 0',
                      cursor: 'pointer',
                    }}
                  >
                    Marquer comme lu
                  </button>
                )}
              </div>
            ))}
          </div>
        )}

        {view === 'orders' ? (
          <MyOrders
            orders={orders}
            event={event}
            venue={venue}
            customer={customer}
            lang={lang}
            pushOn={pushOn}
            onEnablePush={async () => {
              const ok = await subscribePush({
                customerId: customer.id,
                eventId: event.id,
                role: 'customer',
              })
              setPushOn(ok)
              showToast(
                ok ? 'Vous serez prévenu même écran verrouillé.' : 'Notifications refusées.',
                ok ? 'ok' : 'error'
              )
            }}
            onReview={(o) => setReviewFor(o)}
            onBackToMenu={() => setView('menu')}
          />
        ) : (
          <>
            {/* Univers */}
            <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
              {universesAvailable.map((u) => (
                <button
                  key={u.k}
                  onClick={() => setUniverse(u.k)}
                  style={{
                    flex: 1,
                    minHeight: 62,
                    borderRadius: 16,
                    cursor: 'pointer',
                    border: `1.5px solid ${universe === u.k ? C.terracotta : C.line}`,
                    background: universe === u.k ? 'rgba(185,106,76,.09)' : C.paper,
                    color: universe === u.k ? C.terracotta : C.dim,
                    fontFamily: FONT.label,
                    fontSize: 12,
                    fontWeight: 600,
                    letterSpacing: 0.8,
                    textTransform: 'uppercase',
                  }}
                >
                  <div style={{ fontSize: 20, marginBottom: 3 }}>{u.e}</div>
                  {lang === 'en' ? u.en : lang === 'es' ? u.es : u.t}
                </button>
              ))}
            </div>

            {/* Sous-catégories */}
            <div
              style={{
                display: 'flex',
                gap: 8,
                overflowX: 'auto',
                paddingBottom: 4,
                marginBottom: 14,
              }}
            >
              {subcats.map((c) => (
                <button
                  key={c}
                  onClick={() => setSubcat(c)}
                  style={{
                    ...S.chip,
                    borderColor: subcat === c ? C.indigo : C.lineHi,
                    color: subcat === c ? C.indigo : C.dim,
                    background: subcat === c ? 'rgba(106,95,214,.08)' : 'transparent',
                  }}
                >
                  {c}
                </button>
              ))}
            </div>

            <div style={{ display: 'grid', gap: 10 }}>
              {visible.map((p) => (
                <ProductCard
                  key={p.id}
                  product={p}
                  lang={lang}
                  disabled={blocked}
                  onAdd={() => {
                    const needsChoice =
                      (p.variants || []).length > 0 || (p.option_groups || []).length > 0
                    if (needsChoice) setSheetProduct(p)
                    else addToCart(p, null, [], 1)
                  }}
                />
              ))}
              {visible.length === 0 && <Empty emoji="🍸" title="Rien dans cette sélection" />}
            </div>
          </>
        )}
      </div>

      {/* Panier flottant */}
      {cartCount > 0 && view === 'menu' && (
        <div
          style={{
            position: 'fixed',
            left: 14,
            right: 14,
            bottom: 'calc(env(safe-area-inset-bottom) + 14px)',
            zIndex: 60,
          }}
        >
          <button
            onClick={() => setCartOpen(true)}
            style={{
              ...S.btn,
              minHeight: 58,
              justifyContent: 'space-between',
              padding: '0 20px',
              boxShadow: '0 10px 30px rgba(185,106,76,.35)',
            }}
          >
            <span style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span
                style={{
                  background: 'rgba(255,255,255,.25)',
                  borderRadius: 999,
                  padding: '3px 11px',
                  fontSize: 13,
                }}
              >
                {cartCount}
              </span>
              {t.cart}
            </span>
            <span style={{ ...S.money, textTransform: 'none', fontSize: 16 }}>{eur(subtotal)}</span>
          </button>
        </div>
      )}

      <ProductSheet
        product={sheetProduct}
        lang={lang}
        onClose={() => setSheetProduct(null)}
        onConfirm={(variant, options, qty) => {
          addToCart(sheetProduct, variant, options, qty)
          setSheetProduct(null)
        }}
      />

      <CartSheet
        open={cartOpen}
        cart={cart}
        lang={lang}
        subtotal={subtotal}
        onClose={() => setCartOpen(false)}
        onQty={setQty}
        onCheckout={() => {
          setCartOpen(false)
          setCartCheckout(true)
        }}
      />

      <CheckoutSheet
        open={checkoutOpen}
        lang={lang}
        subtotal={subtotal}
        prepMin={event.default_prep_min ?? 1}
        onClose={() => setCartCheckout(false)}
        onSubmit={async (payload) => {
          try {
            await submitOrder(payload)
          } catch (e) {
            showToast(frError(e), 'error')
          }
        }}
      />

      <ReviewSheet
        order={reviewFor}
        event={event}
        customer={customer}
        onClose={() => setReviewFor(null)}
        onDone={() => {
          setReviewFor(null)
          showToast('Merci pour votre retour !', 'ok')
        }}
      />
    </div>
  )
}

// ------------------------------------------------------------ Carte produit
function ProductCard({ product, lang, disabled, onAdd }) {
  const t = useT(lang)
  const info = tr(product, lang)
  const out = product.sold_out
  const priceFrom = (product.variants || []).length
    ? Math.min(...product.variants.map((v) => Number(v.price)))
    : Number(product.price)

  return (
    <div
      style={{
        ...S.card,
        padding: 14,
        display: 'flex',
        gap: 14,
        alignItems: 'center',
        opacity: out ? 0.55 : 1,
        background: out ? 'rgba(28,42,74,.03)' : C.paper,
      }}
    >
      {product.image_url && (
        <img
          src={product.image_url}
          alt=""
          style={{ width: 58, height: 58, borderRadius: 12, objectFit: 'cover', flexShrink: 0 }}
        />
      )}

      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', gap: 6, alignItems: 'center', flexWrap: 'wrap' }}>
          <div style={{ fontWeight: 500, fontSize: 15.5 }}>{info.name}</div>
          {product.is_popular && !out && (
            <span
              style={{
                fontFamily: FONT.label,
                fontSize: 9.5,
                fontWeight: 600,
                letterSpacing: 1,
                color: C.indigo,
                border: `1px solid ${C.indigo}55`,
                borderRadius: 999,
                padding: '2px 8px',
              }}
            >
              POPULAIRE
            </span>
          )}
          {out && (
            <span
              style={{
                fontFamily: FONT.label,
                fontSize: 9.5,
                fontWeight: 600,
                letterSpacing: 1,
                color: C.danger,
                border: `1px solid ${C.danger}55`,
                borderRadius: 999,
                padding: '2px 8px',
              }}
            >
              {t.soldOut.toUpperCase()}
            </span>
          )}
        </div>

        {info.description && (
          <div style={{ color: C.dim, fontSize: 12.5, marginTop: 3, lineHeight: 1.45 }}>
            {info.description}
          </div>
        )}

        <div style={{ ...S.money, fontSize: 15, fontWeight: 600, color: C.terracotta, marginTop: 6 }}>
          {(product.variants || []).length > 0 ? `dès ${eur(priceFrom)}` : eur(product.price)}
        </div>
      </div>

      <button
        disabled={out || disabled}
        onClick={onAdd}
        title={disabled ? 'Retirez d’abord votre commande prête' : undefined}
        style={{
          width: 46,
          height: 46,
          flexShrink: 0,
          borderRadius: 14,
          border: 'none',
          cursor: out || disabled ? 'not-allowed' : 'pointer',
          background: out || disabled ? 'rgba(28,42,74,.07)' : C.terracotta,
          color: out || disabled ? C.faint : '#fff',
          fontSize: 22,
          fontWeight: 300,
        }}
      >
        +
      </button>
    </div>
  )
}

// ------------------------------------- Tunnel de choix (format + options)
function ProductSheet({ product, lang, onClose, onConfirm }) {
  const [variantId, setVariantId] = useState(null)
  const [picked, setPicked] = useState({})
  const [qty, setQty] = useState(1)

  useEffect(() => {
    if (!product) return
    setVariantId((product.variants || [])[0]?.id ?? null)
    const init = {}
    for (const g of product.option_groups || []) {
      init[g.id] = g.required && (g.options || [])[0] ? [(g.options || [])[0].id] : []
    }
    setPicked(init)
    setQty(1)
  }, [product])

  if (!product) return null
  const info = tr(product, lang)
  const variants = product.variants || []
  const groups = product.option_groups || []
  const variant = variants.find((v) => v.id === variantId) || null

  const toggle = (g, id) =>
    setPicked((prev) => {
      const cur = prev[g.id] || []
      const max = g.max ?? 1
      if (cur.includes(id)) {
        const next = cur.filter((x) => x !== id)
        if (g.required && !next.length) return prev
        return { ...prev, [g.id]: next }
      }
      if (max === 1) return { ...prev, [g.id]: [id] }
      if (cur.length >= max) return prev
      return { ...prev, [g.id]: [...cur, id] }
    })

  const chosen = groups.flatMap((g) =>
    (picked[g.id] || [])
      .map((id) => (g.options || []).find((o) => o.id === id))
      .filter(Boolean)
  )
  const unit =
    (variant ? Number(variant.price) : Number(product.price)) +
    chosen.reduce((s, o) => s + Number(o.price || 0), 0)
  const missing = groups.filter((g) => g.required && (picked[g.id] || []).length < (g.min ?? 1))

  return (
    <Sheet open={!!product} onClose={onClose} title={info.name}>
      {info.description && (
        <div style={{ color: C.dim, fontSize: 13.5, marginTop: -8, marginBottom: 18, lineHeight: 1.55 }}>
          {info.description}
        </div>
      )}

      {variants.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <div style={S.label}>Format</div>
          <div style={{ display: 'grid', gap: 8 }}>
            {variants.map((v) => (
              <button
                key={v.id}
                onClick={() => setVariantId(v.id)}
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  minHeight: 50,
                  padding: '0 15px',
                  borderRadius: 12,
                  cursor: 'pointer',
                  border: `1.5px solid ${variantId === v.id ? C.terracotta : C.lineHi}`,
                  background: variantId === v.id ? 'rgba(185,106,76,.08)' : C.paper,
                  color: C.text,
                  fontSize: 14.5,
                }}
              >
                <span>{v.label}</span>
                <span style={{ ...S.money, fontWeight: 600, color: C.terracotta }}>{eur(v.price)}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {groups.map((g) => (
        <div key={g.id} style={{ marginBottom: 18 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
            <div style={S.label}>{g.name}</div>
            <div
              style={{
                fontFamily: FONT.label,
                fontSize: 10.5,
                letterSpacing: 1,
                color: g.required ? C.terracotta : C.faint,
              }}
            >
              {g.required ? 'OBLIGATOIRE' : 'OPTIONNEL'}
              {g.max > 1 ? ` · MAX ${g.max}` : ''}
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
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    minHeight: 48,
                    padding: '0 15px',
                    borderRadius: 12,
                    cursor: 'pointer',
                    border: `1.5px solid ${on ? C.indigo : C.lineHi}`,
                    background: on ? 'rgba(106,95,214,.08)' : C.paper,
                    color: C.text,
                    fontSize: 14,
                  }}
                >
                  <span>{on ? '✓ ' : ''}{o.name}</span>
                  <span style={{ ...S.money, fontSize: 13, color: Number(o.price) ? C.indigo : C.faint }}>
                    {Number(o.price) ? `+${eur(o.price)}` : 'inclus'}
                  </span>
                </button>
              )
            })}
          </div>
        </div>
      ))}

      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: 16,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <button
            onClick={() => setQty((q) => Math.max(1, q - 1))}
            style={stepBtn}
          >
            −
          </button>
          <div style={{ ...S.money, fontSize: 19, fontWeight: 600, minWidth: 22, textAlign: 'center' }}>
            {qty}
          </div>
          <button onClick={() => setQty((q) => Math.min(30, q + 1))} style={stepBtn}>
            +
          </button>
        </div>
        <div style={{ ...S.money, fontSize: 21, fontWeight: 600, color: C.terracotta }}>
          {eur(unit * qty)}
        </div>
      </div>

      <button
        disabled={missing.length > 0}
        onClick={() => onConfirm(variant, chosen, qty)}
        style={{ ...S.btn, opacity: missing.length ? 0.5 : 1 }}
      >
        {missing.length ? `Choisissez : ${missing[0].name}` : 'Ajouter'}
      </button>
    </Sheet>
  )
}

const stepBtn = {
  width: 44,
  height: 44,
  borderRadius: 12,
  border: `1.5px solid ${C.lineHi}`,
  background: C.paper,
  color: C.text,
  fontSize: 20,
  cursor: 'pointer',
}

// --------------------------------------------------------------------- Panier
function CartSheet({ open, cart, lang, subtotal, onClose, onQty, onCheckout }) {
  const t = useT(lang)
  return (
    <Sheet open={open} onClose={onClose} title={t.cart}>
      {cart.length === 0 && <Empty emoji="🥂" title="Panier vide" />}
      <div style={{ display: 'grid', gap: 10 }}>
        {cart.map((l) => {
          const info = tr(l.product, lang)
          const detail = [l.variantLabel, ...l.options.map((o) => o.name)].filter(Boolean).join(' · ')
          return (
            <div
              key={l.key}
              style={{
                display: 'flex',
                gap: 12,
                alignItems: 'center',
                padding: 12,
                borderRadius: 14,
                background: C.paper,
                border: `1px solid ${C.line}`,
              }}
            >
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 500, fontSize: 14.5 }}>{info.name}</div>
                {detail && <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>{detail}</div>}
                <div style={{ ...S.money, fontSize: 13.5, color: C.terracotta, marginTop: 3, fontWeight: 600 }}>
                  {eur(lineTotal(l))}
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <button onClick={() => onQty(l.key, -1)} style={{ ...stepBtn, width: 34, height: 34, fontSize: 17 }}>
                  −
                </button>
                <div style={{ ...S.money, fontWeight: 600, minWidth: 18, textAlign: 'center' }}>
                  {l.quantity}
                </div>
                <button
                  onClick={() => onQty(l.key, 1)}
                  style={{ ...stepBtn, width: 34, height: 34, fontSize: 17, background: C.terracotta, color: '#fff', border: 'none' }}
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
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'baseline',
              marginTop: 18,
              paddingTop: 16,
              borderTop: `1px solid ${C.lineHi}`,
            }}
          >
            <span style={{ ...S.label, marginBottom: 0 }}>{t.total}</span>
            <span style={{ ...S.money, fontSize: 26, fontWeight: 600, color: C.terracotta }}>
              {eur(subtotal)}
            </span>
          </div>
          <div style={{ marginTop: 16 }}>
            <button onClick={onCheckout} style={S.btn}>
              Continuer
            </button>
          </div>
        </>
      )}
    </Sheet>
  )
}

// ----------------------------------------------------------------- Validation
function CheckoutSheet({ open, lang, subtotal, prepMin, onClose, onSubmit }) {
  const t = useT(lang)
  const [note, setNote] = useState('')
  const [promo, setPromo] = useState('')
  const [busy, setBusy] = useState(false)

  return (
    <Sheet open={open} onClose={onClose} title="Valider la commande">
      <Field label={t.note}>
        <textarea
          style={{ ...S.input, minHeight: 76, paddingTop: 12, resize: 'vertical' }}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Sans glace, peu sucré, allergie…"
        />
      </Field>

      <Field label={t.promo}>
        <input
          style={{ ...S.input, textTransform: 'uppercase' }}
          value={promo}
          onChange={(e) => setPromo(e.target.value)}
          placeholder="Optionnel"
        />
      </Field>

      <div
        style={{
          background: C.paper,
          border: `1px solid ${C.line}`,
          borderRadius: 14,
          padding: 16,
          marginBottom: 14,
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'baseline',
        }}
      >
        <span style={{ ...S.label, marginBottom: 0 }}>{t.total}</span>
        <span style={{ ...S.money, fontSize: 25, fontWeight: 600, color: C.terracotta }}>
          {eur(subtotal)}
        </span>
      </div>

      <div style={{ marginBottom: 16 }}>
        <PayAtBar />
      </div>

      <div style={{ marginBottom: 16 }}>
        <Banner tone="info">
          Prête dans environ <strong>{prepMin} min</strong>. Merci de récupérer votre commande dans
          les 5 minutes une fois prête — elle reste due même si elle n’est pas retirée.
        </Banner>
      </div>

      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true)
          await onSubmit({ note, promo })
          setBusy(false)
        }}
        style={{ ...S.btn, opacity: busy ? 0.6 : 1, minHeight: 58 }}
      >
        {busy ? 'Envoi…' : t.send}
      </button>
    </Sheet>
  )
}

// ------------------------------------------------------- Suivi des commandes
function MyOrders({ orders, event, venue, customer, lang, pushOn, onEnablePush, onReview, onBackToMenu }) {
  const t = useT(lang)
  const [now, setNow] = useState(Date.now())

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  if (!orders.length)
    return (
      <>
        <Empty
          emoji="🍹"
          title="Aucune commande pour l’instant"
          sub="Vos commandes de la soirée apparaîtront ici."
        />
        <button onClick={onBackToMenu} style={S.btnGhost}>
          Voir la carte
        </button>
      </>
    )

  return (
    <div style={{ display: 'grid', gap: 14 }}>
      {pushSupported() && (
        <button
          onClick={onEnablePush}
          style={{
            ...S.btnGhost,
            borderColor: pushOn ? C.ok : C.terracotta,
            color: pushOn ? C.ok : C.terracotta,
          }}
        >
          {pushOn ? '✓ Notifications activées' : 'Me prévenir quand c’est prêt'}
        </button>
      )}

      {orders.map((o) => (
        <OrderCard
          key={o.id}
          order={o}
          event={event}
          venue={venue}
          customer={customer}
          lang={lang}
          now={now}
          onReview={() => onReview(o)}
        />
      ))}

      <button onClick={onBackToMenu} style={S.btnGhost}>
        Voir la carte
      </button>
    </div>
  )
}

function OrderCard({ order, event, venue, customer, lang, now, onReview }) {
  const t = useT(lang)
  const st = ORDER_STATUS[order.status] || ORDER_STATUS.RECEIVED
  const items = order.order_items || []
  const etaMs = order.estimated_ready_at ? new Date(order.estimated_ready_at).getTime() - now : 0
  const etaSec = Math.max(0, Math.round(etaMs / 1000))
  const mm = String(Math.floor(etaSec / 60)).padStart(2, '0')
  const ss = String(etaSec % 60).padStart(2, '0')

  const steps = ['RECEIVED', 'READY', 'PICKED_UP', 'PAID']
  const idx = Math.max(0, steps.indexOf(order.status === 'UNPAID' ? 'PICKED_UP' : order.status))

  async function downloadRecap() {
    const canvas = await renderRecapCanvas({ venue, event, order, items, customer })
    const blob = canvasesToPdfBlob([canvas], { quality: 0.94 })
    await shareOrDownload(blob, `NotiCalling-${order.pickup_code}.pdf`, 'Récapitulatif')
  }

  return (
    <div
      style={{
        ...S.card,
        padding: 0,
        overflow: 'hidden',
        border: `1.5px solid ${order.status === 'READY' ? C.terracotta : C.line}`,
      }}
    >
      {/* Code de retrait */}
      <div
        style={{
          background: order.status === 'READY' ? GRADIENT : C.creamSoft,
          padding: 18,
          textAlign: 'center',
          borderBottom: `1px solid ${C.line}`,
        }}
      >
        <div
          style={{
            ...S.label,
            marginBottom: 4,
            color: order.status === 'READY' ? C.navy : C.dim,
          }}
        >
          {t.pickupCode}
        </div>
        <div
          style={{
            fontFamily: FONT.label,
            fontSize: 46,
            fontWeight: 600,
            letterSpacing: 8,
            color: C.navy,
            lineHeight: 1.1,
            animation: order.status === 'READY' ? 'notipulse 1.6s infinite' : 'none',
          }}
        >
          {order.pickup_code}
        </div>
        <div style={{ fontSize: 12.5, color: order.status === 'READY' ? C.navy : C.dim, marginTop: 6 }}>
          {order.status === 'READY'
            ? 'Présentez ce code au bar et réglez sur place'
            : `Commande de ${timeFR(order.created_at)}`}
        </div>
      </div>

      <div style={{ padding: 18 }}>
        {/* Statut */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
          <div style={{ width: 9, height: 9, borderRadius: 5, background: st.color }} />
          <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1, color: st.color }}>
            {st.label.toUpperCase()}
          </div>
          {order.status === 'RECEIVED' && etaSec > 0 && (
            <div style={{ ...S.money, marginLeft: 'auto', fontSize: 20, fontWeight: 600 }}>
              {mm}:{ss}
            </div>
          )}
        </div>

        {/* Progression */}
        {!['CANCELLED'].includes(order.status) && (
          <div style={{ display: 'flex', gap: 5, marginBottom: 16 }}>
            {['Reçue', 'Prête', 'Retirée', 'Réglée'].map((label, i) => (
              <div key={label} style={{ flex: 1 }}>
                <div
                  style={{
                    height: 4,
                    borderRadius: 2,
                    background: i <= idx ? st.color : 'rgba(28,42,74,.10)',
                  }}
                />
                <div
                  style={{
                    fontSize: 9.5,
                    marginTop: 5,
                    fontFamily: FONT.label,
                    letterSpacing: 0.6,
                    color: i <= idx ? C.text : C.faint,
                  }}
                >
                  {label.toUpperCase()}
                </div>
              </div>
            ))}
          </div>
        )}

        {order.status === 'UNPAID' && (
          <div style={{ marginBottom: 14 }}>
            <Banner tone="danger">
              Cette commande n’a pas été réglée en fin de soirée. Elle reste due — merci de vous
              rapprocher de l’établissement.
            </Banner>
          </div>
        )}

        {/* Détail */}
        {items.map((it) => (
          <div
            key={it.id}
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              gap: 12,
              padding: '8px 0',
              borderBottom: `1px solid ${C.line}`,
            }}
          >
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 14 }}>
                <strong style={{ fontWeight: 600 }}>{it.quantity}×</strong> {it.name_snapshot}
              </div>
              {(it.variant_label || (it.detail?.options || []).length > 0) && (
                <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                  {[it.variant_label, ...(it.detail?.options || []).map((o) => o.name)]
                    .filter(Boolean)
                    .join(' · ')}
                </div>
              )}
            </div>
            <div style={{ ...S.money, fontWeight: 500, whiteSpace: 'nowrap' }}>
              {eur(Number(it.unit_price) * Number(it.quantity))}
            </div>
          </div>
        ))}

        {Number(order.discount) > 0 && (
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              marginTop: 10,
              color: C.ok,
              fontSize: 13.5,
            }}
          >
            <span>{order.promo_code}</span>
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
          <span style={{ ...S.label, marginBottom: 0 }}>{t.total}</span>
          <span style={{ ...S.money, fontSize: 24, fontWeight: 600, color: C.terracotta }}>
            {eur(order.total)}
          </span>
        </div>

        {order.note && (
          <div style={{ fontSize: 12.5, color: C.dim, marginTop: 10 }}>
            <strong>Note :</strong> {order.note}
          </div>
        )}

        <div style={{ marginTop: 14 }}>
          {order.status === 'PAID' ? (
            <Banner tone="ok">Réglée au bar — merci !</Banner>
          ) : (
            <PayAtBar compact />
          )}
        </div>

        <div style={{ display: 'grid', gap: 8, marginTop: 12 }}>
          <button onClick={downloadRecap} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12 }}>
            Récapitulatif PDF
          </button>
          {order.status === 'PAID' && (
            <button onClick={onReview} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12, borderColor: C.indigo, color: C.indigo }}>
              Noter le service
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------- Avis
function ReviewSheet({ order, event, customer, onClose, onDone }) {
  const [rating, setRating] = useState(0)
  const [comment, setComment] = useState('')
  const [busy, setBusy] = useState(false)

  if (!order) return null

  return (
    <Sheet open={!!order} onClose={onClose} title="Votre soirée">
      <div style={{ color: C.dim, fontSize: 13.5, marginTop: -8, marginBottom: 18, lineHeight: 1.55 }}>
        Comment s’est passé le service ?
      </div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            onClick={() => setRating(n)}
            style={{
              flex: 1,
              minHeight: 52,
              borderRadius: 12,
              cursor: 'pointer',
              border: `1.5px solid ${n <= rating ? C.terracotta : C.lineHi}`,
              background: n <= rating ? 'rgba(185,106,76,.09)' : C.paper,
              color: n <= rating ? C.terracotta : C.faint,
              fontSize: 22,
            }}
          >
            {n <= rating ? '★' : '☆'}
          </button>
        ))}
      </div>
      <textarea
        style={{ ...S.input, minHeight: 84, paddingTop: 12 }}
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        placeholder="Un mot pour l’équipe (facultatif)"
      />
      <div style={{ marginTop: 14 }}>
        <button
          disabled={!rating || busy}
          onClick={async () => {
            setBusy(true)
            await supabase.from('reviews').insert({
              event_id: event.id,
              customer_id: customer.id,
              order_id: order.id,
              rating,
              comment: comment || null,
            })
            setBusy(false)
            onDone()
          }}
          style={{ ...S.btn, opacity: !rating || busy ? 0.5 : 1 }}
        >
          {busy ? '…' : 'Envoyer'}
        </button>
      </div>
    </Sheet>
  )
}

// ------------------------------------------- Récapitulatif PDF (Canvas natif)
async function renderRecapCanvas({ venue, event, order, items, customer }) {
  const W = 1240
  const H = 1754
  const { canvas, ctx } = makeCanvas(W, H, 1)

  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, W, H)

  // Cadre terracotta (rappel de la carte imprimée)
  ctx.fillStyle = '#B96A4C'
  ctx.fillRect(0, 0, W, 26)
  ctx.fillRect(0, H - 26, W, 26)
  ctx.fillRect(0, 0, 26, H)
  ctx.fillRect(W - 26, 0, 26, H)

  ctx.textAlign = 'center'
  ctx.fillStyle = '#B96A4C'
  ctx.font = '700 52px "Playfair Display", Georgia, serif'
  ctx.fillText('Noti', W / 2 - 40, 96)
  ctx.fillStyle = '#6A5FD6'
  ctx.font = '400 56px "Great Vibes", cursive'
  ctx.fillText('Calling', W / 2 + 60, 118)

  ctx.fillStyle = '#1C2A4A'
  ctx.font = '500 26px Oswald, sans-serif'
  ctx.fillText((event?.name || '').toUpperCase(), W / 2, 190)
  ctx.fillStyle = '#5A6480'
  ctx.font = '400 20px Jost, sans-serif'
  ctx.fillText(`${venue?.name || ''} · ${dateFR(order.created_at)}`, W / 2, 232)

  // Code de retrait
  ctx.fillStyle = '#F7F1E9'
  roundRect(ctx, W / 2 - 220, 280, 440, 140, 22)
  ctx.fill()
  ctx.fillStyle = '#5A6480'
  ctx.font = '500 18px Oswald, sans-serif'
  ctx.fillText('CODE DE RETRAIT', W / 2, 312)
  ctx.fillStyle = '#1C2A4A'
  ctx.font = '600 64px Oswald, sans-serif'
  ctx.fillText(order.pickup_code, W / 2, 350)

  ctx.textAlign = 'left'
  let y = 480
  ctx.fillStyle = '#5A6480'
  ctx.font = '500 17px Oswald, sans-serif'
  ctx.fillText('DÉSIGNATION', 90, y)
  ctx.textAlign = 'center'
  ctx.fillText('QTÉ', W - 400, y)
  ctx.textAlign = 'right'
  ctx.fillText('TOTAL', W - 90, y)
  ctx.textAlign = 'left'
  y += 34
  ctx.strokeStyle = '#E2C8B8'
  ctx.lineWidth = 2
  ctx.beginPath()
  ctx.moveTo(90, y)
  ctx.lineTo(W - 90, y)
  ctx.stroke()
  y += 34

  for (const it of items) {
    if (y > H - 460) break
    ctx.fillStyle = '#1C2A4A'
    ctx.font = '500 23px Jost, sans-serif'
    const lines = wrapText(ctx, it.name_snapshot, W - 560, 2)
    lines.forEach((l, i) => ctx.fillText(l, 90, y + i * 28))
    let h = lines.length * 28

    const extra = [it.variant_label, ...(it.detail?.options || []).map((o) => o.name)]
      .filter(Boolean)
      .join(' · ')
    if (extra) {
      ctx.fillStyle = '#98A0B4'
      ctx.font = '400 17px Jost, sans-serif'
      ctx.fillText(extra, 90, y + h)
      h += 24
    }

    ctx.fillStyle = '#1C2A4A'
    ctx.font = '500 23px Jost, sans-serif'
    ctx.textAlign = 'center'
    ctx.fillText(String(it.quantity), W - 400, y)
    ctx.textAlign = 'right'
    ctx.font = '600 23px Jost, sans-serif'
    ctx.fillText(eur(Number(it.unit_price) * Number(it.quantity)), W - 90, y)
    ctx.textAlign = 'left'

    y += Math.max(h, 30) + 16
  }

  // Totaux + TVA
  y = Math.max(y + 24, H - 420)
  ctx.textAlign = 'right'
  ctx.fillStyle = '#5A6480'
  ctx.font = '400 20px Jost, sans-serif'
  ctx.fillText('Sous-total', W - 300, y)
  ctx.fillStyle = '#1C2A4A'
  ctx.fillText(eur(order.subtotal ?? order.total), W - 90, y)
  y += 34

  if (Number(order.discount) > 0) {
    ctx.fillStyle = '#2E7D5B'
    ctx.fillText(order.promo_code || 'Remise', W - 300, y)
    ctx.fillText(`−${eur(order.discount)}`, W - 90, y)
    y += 34
  }

  const vat = {}
  for (const it of items) {
    const r = Number(it.vat_rate ?? 20)
    vat[r] = (vat[r] || 0) + Number(it.unit_price) * Number(it.quantity)
  }
  ctx.fillStyle = '#98A0B4'
  ctx.font = '400 16px Jost, sans-serif'
  for (const r of Object.keys(vat).sort()) {
    const ttc = vat[r]
    ctx.fillText(`dont TVA ${r} %`, W - 300, y)
    ctx.fillText(eur(ttc - ttc / (1 + Number(r) / 100)), W - 90, y)
    y += 26
  }

  y += 16
  ctx.fillStyle = '#1C2A4A'
  ctx.font = '500 30px Oswald, sans-serif'
  ctx.fillText('TOTAL', W - 320, y)
  ctx.fillStyle = '#B96A4C'
  ctx.font = '600 40px Jost, sans-serif'
  ctx.fillText(eur(order.total), W - 90, y + 2)

  // Mention de règlement
  ctx.textAlign = 'center'
  const paid = order.status === 'PAID'
  ctx.fillStyle = paid ? '#2E7D5B' : '#B96A4C'
  ctx.font = '500 24px Oswald, sans-serif'
  ctx.fillText(
    paid ? 'RÉGLÉE AU BAR' : 'À RÉGLER AU BAR — AUCUN PAIEMENT EN LIGNE',
    W / 2,
    H - 220
  )

  ctx.fillStyle = '#98A0B4'
  ctx.font = '400 15px Jost, sans-serif'
  const legal = [
    venue?.address,
    venue?.city,
    venue?.siret ? `SIRET ${venue.siret}` : null,
    venue?.tva_number ? `TVA ${venue.tva_number}` : null,
  ]
    .filter(Boolean)
    .join(' · ')
  if (legal) ctx.fillText(legal, W / 2, H - 150)
  ctx.fillText(
    'Conformément à l’arrêté ministériel du 24 août 2011, des éthylotests sont à votre disposition.',
    W / 2,
    H - 120
  )
  ctx.fillText(
    'Tarifs en euros, toutes taxes et service inclus. Les chèques ne sont pas acceptés.',
    W / 2,
    H - 96
  )
  ctx.fillStyle = '#6A5FD6'
  ctx.font = '400 15px Jost, sans-serif'
  ctx.fillText('Récapitulatif de commande — ne vaut pas reçu de paiement.', W / 2, H - 64)
  ctx.textAlign = 'left'

  return canvas
}

// ============================================================================
//  CÔTÉ STAFF — connexion e-mail / mot de passe
// ============================================================================

function StaffLogin() {
  const [mode, setMode] = useState('login')
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
        const { data, error } = await supabase.auth.signUp({ email: email.trim(), password })
        if (error) throw error
        if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
          setMode('login')
          setErr('Cet e-mail est déjà utilisé. Connectez-vous ci-dessous.')
          return
        }
        if (data.session) return
        setInfo('Compte créé. Confirmez votre e-mail, puis connectez-vous.')
        setMode('login')
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
        if (error) throw error
      }
    } catch (e2) {
      setErr(frError(e2))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      style={{ ...S.page, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 22 }}
    >
      <Keyframes />
      <div style={{ width: '100%', maxWidth: 420 }}>
        <div style={{ textAlign: 'center', marginBottom: 26 }}>
          <Logo size={1.2} />
          <div
            style={{
              ...S.label,
              marginTop: 18,
              marginBottom: 0,
              letterSpacing: 2.4,
            }}
          >
            Espace équipe
          </div>
        </div>

        <form onSubmit={submit} style={S.card}>
          <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
            {[
              ['login', 'Connexion'],
              ['signup', 'Créer un compte'],
            ].map(([k, label]) => (
              <button
                key={k}
                type="button"
                onClick={() => {
                  setMode(k)
                  setErr('')
                  setInfo('')
                }}
                style={{
                  flex: 1,
                  minHeight: 44,
                  borderRadius: 12,
                  border: 'none',
                  cursor: 'pointer',
                  fontFamily: FONT.label,
                  fontSize: 12.5,
                  fontWeight: 600,
                  letterSpacing: 0.8,
                  textTransform: 'uppercase',
                  background: mode === k ? C.navy : 'rgba(28,42,74,.06)',
                  color: mode === k ? '#fff' : C.dim,
                }}
              >
                {label}
              </button>
            ))}
          </div>

          <Field label="E-mail">
            <input
              style={S.input}
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </Field>
          <Field label="Mot de passe">
            <input
              style={S.input}
              type="password"
              required
              minLength={6}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </Field>

          {err && (
            <div style={{ marginBottom: 12 }}>
              <Banner tone="danger">{err}</Banner>
            </div>
          )}
          {info && (
            <div style={{ marginBottom: 12 }}>
              <Banner tone="ok">{info}</Banner>
            </div>
          )}

          <button type="submit" disabled={busy} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
            {busy ? '…' : mode === 'login' ? 'Se connecter' : 'Créer mon compte'}
          </button>
        </form>

        <div style={{ textAlign: 'center', color: C.faint, fontSize: 11.5, marginTop: 20, lineHeight: 1.7 }}>
          Les clients, eux, se contentent de leur prénom en scannant le QR de la soirée.
        </div>
      </div>
    </div>
  )
}

// ============================================================================
//  CÔTÉ STAFF — coquille
// ============================================================================

const STAFF_TABS = [
  { k: 'bar', t: 'Bar', e: '🍸' },
  { k: 'caisse', t: 'Caisse', e: '🧾' },
  { k: 'orga', t: 'Orga', e: '📡' },
  { k: 'carte', t: 'Carte', e: '📋' },
  { k: 'clients', t: 'Clients', e: '👥' },
  { k: 'qr', t: 'QR', e: '⬛' },
  { k: 'reglages', t: 'Réglages', e: '⚙️' },
]

function StaffApp({ session }) {
  const [venues, setVenues] = useState(null)
  const [venueId, setVenueId] = useState(LS.get('noti:venue', null))
  const [events, setEvents] = useState([])
  const [eventId, setEventId] = useState(LS.get('noti:event', null))
  const [tab, setTab] = useState('bar')
  const [switcher, setSwitcher] = useState(false)
  const [toast, showToast] = useToast()

  const loadVenues = useCallback(async () => {
    const { data: mine } = await supabase.from('venues').select('*').eq('owner_id', session.user.id)
    const { data: memberships } = await supabase
      .from('staff_members')
      .select('venue_id')
      .eq('user_id', session.user.id)
    const ids = (memberships || []).map((m) => m.venue_id)
    let all = mine || []
    if (ids.length) {
      const { data: extra } = await supabase.from('venues').select('*').in('id', ids)
      const seen = new Set(all.map((v) => v.id))
      all = [...all, ...(extra || []).filter((v) => !seen.has(v.id))]
    }
    all.sort((a, b) => a.name.localeCompare(b.name))
    setVenues(all)
    setVenueId((cur) => (all.find((v) => v.id === cur) ? cur : all[0]?.id ?? null))
  }, [session.user.id])

  const loadEvents = useCallback(async () => {
    if (!venueId) return
    const { data } = await supabase
      .from('events')
      .select('*')
      .eq('venue_id', venueId)
      .order('starts_at', { ascending: false, nullsFirst: false })
    setEvents(data || [])
    setEventId((cur) => {
      if (data?.find((e) => e.id === cur)) return cur
      return data?.find((e) => e.is_active)?.id ?? data?.[0]?.id ?? null
    })
  }, [venueId])

  useEffect(() => {
    loadVenues()
  }, [loadVenues])
  useEffect(() => {
    loadEvents()
  }, [loadEvents])
  useEffect(() => {
    if (venueId) LS.set('noti:venue', venueId)
  }, [venueId])
  useEffect(() => {
    if (eventId) LS.set('noti:event', eventId)
  }, [eventId])

  if (venues === null)
    return (
      <div style={S.page}>
        <Spinner />
      </div>
    )

  // Un client (session anonyme) qui atterrirait sur la racine staff.
  if (venues.length === 0 && session.user.is_anonymous) {
    return (
      <div style={{ ...S.page, padding: 26, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <Keyframes />
        <div style={{ textAlign: 'center', marginBottom: 22 }}>
          <Logo />
        </div>
        <Banner tone="info">
          Vous êtes identifié en tant que client. Scannez le QR code de la soirée (à l’entrée ou au
          bar) pour accéder à la carte.
        </Banner>
        <div style={{ marginTop: 16 }}>
          <button onClick={() => supabase.auth.signOut()} style={S.btnGhost}>
            Se déconnecter
          </button>
        </div>
      </div>
    )
  }

  if (venues.length === 0) return <StaffOnboarding session={session} onDone={loadVenues} />

  const venue = venues.find((v) => v.id === venueId) || venues[0]
  const event = events.find((e) => e.id === eventId) || null

  return (
    <div style={{ ...S.page, paddingBottom: 96 }}>
      <Keyframes />

      <div
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 60,
          background: `${C.cream}f2`,
          backdropFilter: 'blur(10px)',
          borderBottom: `1px solid ${C.line}`,
          padding: '12px 16px',
          display: 'flex',
          alignItems: 'center',
          gap: 12,
        }}
      >
        <button
          onClick={() => setSwitcher(true)}
          style={{
            flex: 1,
            minWidth: 0,
            textAlign: 'left',
            background: 'none',
            border: 'none',
            padding: 0,
            cursor: 'pointer',
            color: C.text,
          }}
        >
          <div style={{ ...S.h1, fontSize: 18, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {event?.name || venue.name}
          </div>
          <div style={{ fontSize: 11.5, color: C.dim, marginTop: 2 }}>
            {venue.name}
            {event && !event.is_active ? ' · soirée clôturée' : ''} · changer
          </div>
        </button>
        <Logo size={0.6} />
      </div>

      <div style={{ padding: 16 }}>
        {!event ? (
          <NoEvent venue={venue} onCreated={loadEvents} showToast={showToast} />
        ) : (
          <>
            {tab === 'bar' && <BarTab event={event} venue={venue} onEventChange={loadEvents} showToast={showToast} />}
            {tab === 'caisse' && <CaisseTab event={event} venue={venue} showToast={showToast} />}
            {tab === 'orga' && <OrgaTab event={event} venue={venue} showToast={showToast} onEventChange={loadEvents} />}
            {tab === 'carte' && <CarteTab venue={venue} showToast={showToast} />}
            {tab === 'clients' && <ClientsTab event={event} showToast={showToast} />}
            {tab === 'qr' && <QrTab event={event} venue={venue} showToast={showToast} />}
            {tab === 'reglages' && (
              <ReglagesTab
                venue={venue}
                event={event}
                session={session}
                onReload={() => {
                  loadVenues()
                  loadEvents()
                }}
                showToast={showToast}
              />
            )}
          </>
        )}
      </div>

      <div
        style={{
          position: 'fixed',
          left: 0,
          right: 0,
          bottom: 0,
          zIndex: 60,
          background: `${C.paper}f5`,
          backdropFilter: 'blur(12px)',
          borderTop: `1px solid ${C.line}`,
          display: 'flex',
          padding: '8px 4px calc(env(safe-area-inset-bottom) + 8px)',
          overflowX: 'auto',
        }}
        className="no-print"
      >
        {STAFF_TABS.map((t) => (
          <button
            key={t.k}
            onClick={() => {
              unlockAudio()
              setTab(t.k)
            }}
            style={{
              flex: '1 0 auto',
              minWidth: 60,
              background: 'transparent',
              border: 'none',
              cursor: 'pointer',
              padding: '6px 4px',
              color: tab === t.k ? C.terracotta : C.faint,
            }}
          >
            <div style={{ fontSize: 18, opacity: tab === t.k ? 1 : 0.6 }}>{t.e}</div>
            <div style={{ fontFamily: FONT.label, fontSize: 9.5, fontWeight: 500, marginTop: 3, letterSpacing: 0.5 }}>
              {t.t.toUpperCase()}
            </div>
          </button>
        ))}
      </div>

      <Sheet open={switcher} onClose={() => setSwitcher(false)} title="Lieux & soirées">
        {venues.map((v) => (
          <div key={v.id} style={{ marginBottom: 18 }}>
            <div style={S.label}>{v.name}</div>
            <div style={{ display: 'grid', gap: 8 }}>
              {events
                .filter((e) => e.venue_id === v.id)
                .map((e) => (
                  <button
                    key={e.id}
                    onClick={() => {
                      setVenueId(v.id)
                      setEventId(e.id)
                      setSwitcher(false)
                    }}
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                      minHeight: 54,
                      padding: '0 15px',
                      borderRadius: 12,
                      cursor: 'pointer',
                      border: `1.5px solid ${e.id === eventId ? C.terracotta : C.lineHi}`,
                      background: e.id === eventId ? 'rgba(185,106,76,.08)' : C.paper,
                      color: C.text,
                      textAlign: 'left',
                    }}
                  >
                    <span style={{ fontWeight: 500 }}>{e.name}</span>
                    <span style={{ fontSize: 11, color: e.is_active ? C.ok : C.faint }}>
                      {e.is_active ? 'en cours' : 'clôturée'}
                    </span>
                  </button>
                ))}
              {v.id !== venueId && (
                <button onClick={() => { setVenueId(v.id); setSwitcher(false) }} style={{ ...S.btnGhost, minHeight: 42, fontSize: 12 }}>
                  Basculer sur ce lieu
                </button>
              )}
            </div>
          </div>
        ))}
        <button
          onClick={() => {
            setSwitcher(false)
            setTab('reglages')
          }}
          style={S.btnGhost}
        >
          + Nouvelle soirée / nouveau lieu
        </button>
        <div style={{ marginTop: 10 }}>
          <button
            onClick={() => supabase.auth.signOut()}
            style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
          >
            Se déconnecter
          </button>
        </div>
      </Sheet>

      <Toast toast={toast} />
    </div>
  )
}

function NoEvent({ venue, onCreated, showToast }) {
  const [name, setName] = useState('Noti Calling')
  const [busy, setBusy] = useState(false)
  return (
    <div style={S.card}>
      <div style={{ ...S.h1, fontSize: 21, marginBottom: 8 }}>Aucune soirée</div>
      <div style={{ color: C.dim, fontSize: 13.5, marginBottom: 16, lineHeight: 1.6 }}>
        Créez une soirée pour générer les QR codes et ouvrir les commandes.
      </div>
      <Field label="Nom de la soirée">
        <input style={S.input} value={name} onChange={(e) => setName(e.target.value)} />
      </Field>
      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true)
          const { data, error } = await supabase
            .from('events')
            .insert({ venue_id: venue.id, name: name.trim() || 'Soirée', default_prep_min: 1 })
            .select()
            .single()
          if (error) {
            setBusy(false)
            return showToast(frError(error), 'error')
          }
          await supabase.from('scan_points').insert([
            { event_id: data.id, kind: 'entrance', label: 'Entrée' },
            { event_id: data.id, kind: 'bar', label: 'Bar' },
          ])
          setBusy(false)
          onCreated()
        }}
        style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}
      >
        {busy ? '…' : 'Créer la soirée'}
      </button>
    </div>
  )
}

function StaffOnboarding({ session, onDone }) {
  const [venueName, setVenueName] = useState('Noti Club')
  const [eventName, setEventName] = useState('Noti Calling')
  const [seed, setSeed] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  async function create() {
    setBusy(true)
    setErr('')
    try {
      const { data: venue, error } = await supabase
        .from('venues')
        .insert({
          name: venueName.trim() || 'Mon lieu',
          owner_id: session.user.id,
          slug:
            (venueName || 'lieu')
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

      const { data: ev, error: e2 } = await supabase
        .from('events')
        .insert({ venue_id: venue.id, name: eventName.trim() || 'Soirée', default_prep_min: 1 })
        .select()
        .single()
      if (e2) throw e2

      await supabase.from('scan_points').insert([
        { event_id: ev.id, kind: 'entrance', label: 'Entrée' },
        { event_id: ev.id, kind: 'bar', label: 'Bar' },
      ])

      if (seed) {
        const { error: e3 } = await supabase.rpc('seed_noti_menu', { p_venue: venue.id })
        if (e3) console.warn(e3)
      }
      onDone()
    } catch (e) {
      setErr(frError(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div style={{ ...S.page, padding: 22, display: 'flex', alignItems: 'center' }}>
      <Keyframes />
      <div style={{ width: '100%', maxWidth: 440, margin: '0 auto' }}>
        <div style={{ textAlign: 'center', marginBottom: 26 }}>
          <Logo size={1.2} />
          <h1 style={{ ...S.h1, fontSize: 25, marginTop: 20 }}>Premier lieu</h1>
        </div>

        <div style={S.card}>
          <Field label="Nom du lieu">
            <input style={S.input} value={venueName} onChange={(e) => setVenueName(e.target.value)} />
          </Field>
          <Field label="Première soirée">
            <input style={S.input} value={eventName} onChange={(e) => setEventName(e.target.value)} />
          </Field>

          <button
            onClick={() => setSeed((v) => !v)}
            style={{
              ...S.btnGhost,
              marginBottom: 16,
              borderColor: seed ? C.terracotta : C.lineHi,
              color: seed ? C.terracotta : C.dim,
            }}
          >
            {seed ? '✓ Pré-remplir la carte du Noti Club' : 'Démarrer avec une carte vide'}
          </button>

          {err && (
            <div style={{ marginBottom: 12 }}>
              <Banner tone="danger">{err}</Banner>
            </div>
          )}

          <button disabled={busy} onClick={create} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
            {busy ? 'Création…' : 'Créer'}
          </button>
          <div style={{ color: C.faint, fontSize: 11.5, marginTop: 12, textAlign: 'center', lineHeight: 1.6 }}>
            Deux points de scan sont créés automatiquement : <strong>Entrée</strong> et{' '}
            <strong>Bar</strong>.
          </div>
        </div>

        <div style={{ textAlign: 'center', marginTop: 16 }}>
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

// ============================================================================
//  STAFF · BAR — écran de production temps réel
// ============================================================================

function BarTab({ event, venue, onEventChange, showToast }) {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [prep, setPrep] = useState(event.default_prep_min ?? 1)
  const [detail, setDetail] = useState(null)
  const [soldOutOpen, setSoldOutOpen] = useState(false)
  const [staffPush, setStaffPush] = useState(false)
  const [ack, setAck] = useState(() => new Set(LS.get(`noti:ack:${event.id}`, [])))
  const alarm = useRef(null)
  if (!alarm.current) alarm.current = new Alarm()

  useEffect(() => setPrep(event.default_prep_min ?? 1), [event.default_prep_min])

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, order_items ( * ), customers ( first_name, last_name, phone, tags )')
      .eq('event_id', event.id)
      .neq('status', 'CANCELLED')
      .order('created_at', { ascending: true })
    setOrders(data || [])
    setLoading(false)
  }, [event.id])

  useEffect(() => {
    load()
    const ch = supabase
      .channel(`bar-${event.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'orders', filter: `event_id=eq.${event.id}` },
        () => load()
      )
      .subscribe()
    const poll = setInterval(load, 20000)
    return () => {
      supabase.removeChannel(ch)
      clearInterval(poll)
    }
  }, [event.id, load])

  const received = orders.filter((o) => o.status === 'RECEIVED')
  const ready = orders.filter((o) => o.status === 'READY')
  const pickedUp = orders.filter((o) => o.status === 'PICKED_UP')

  // Alarme : sonne tant qu'une commande reçue n'a pas été explicitement vue.
  const unseen = received.filter((o) => !ack.has(o.id))
  useEffect(() => {
    if (unseen.length > 0) alarm.current.start()
    else alarm.current.stop()
  }, [unseen.length])
  useEffect(() => () => alarm.current?.stop(), [])

  function acknowledge(ids) {
    setAck((prev) => {
      const next = new Set(prev)
      ids.forEach((i) => next.add(i))
      LS.set(`noti:ack:${event.id}`, [...next])
      return next
    })
  }

  async function move(order, status) {
    unlockAudio()
    const { error } = await supabase.from('orders').update({ status }).eq('id', order.id)
    if (error) return showToast(frError(error), 'error')

    if (status === 'READY') {
      notify({
        eventId: event.id,
        kind: 'status',
        customerId: order.customer_id,
        orderId: order.id,
        title: 'Votre commande est prête',
        body: `Commande ${order.pickup_code} : c’est prêt ! Présentez votre code au bar et réglez sur place.`,
        requireInteraction: true,
      })
    }
    load()
  }

  async function savePrep(v) {
    const val = Math.max(1, Math.min(60, v))
    setPrep(val)
    await supabase.from('events').update({ default_prep_min: val }).eq('id', event.id)
    onEventChange?.()
  }

  async function printTicket(order) {
    const canvas = await renderTicketCanvas({ venue, event, order })
    const blob = canvasesToPdfBlob([canvas], { quality: 0.95, pageSize: { w: 226, h: 480 } })
    await shareOrDownload(blob, `ticket-${order.pickup_code}.pdf`, 'Ticket')
    await supabase.from('orders').update({ printed_at: new Date().toISOString() }).eq('id', order.id)
  }

  if (loading) return <Spinner />

  return (
    <div>
      {unseen.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <div
            style={{
              background: 'rgba(185,106,76,.14)',
              border: `2px solid ${C.terracotta}`,
              borderRadius: 16,
              padding: 16,
              animation: 'notiglow 1.2s infinite',
            }}
          >
            <div style={{ ...S.h1, fontSize: 19, color: C.terracotta, marginBottom: 4 }}>
              {unseen.length} nouvelle{unseen.length > 1 ? 's' : ''} commande
              {unseen.length > 1 ? 's' : ''}
            </div>
            <div style={{ fontSize: 12.5, color: C.dim, marginBottom: 12 }}>
              L’alarme s’arrête uniquement quand vous accusez réception.
            </div>
            <button onClick={() => acknowledge(unseen.map((o) => o.id))} style={{ ...S.btn, minHeight: 48 }}>
              J’ai vu — couper l’alarme
            </button>
          </div>
        </div>
      )}

      {/* Temps de préparation annoncé */}
      <div style={{ ...S.card, padding: 14, marginBottom: 14 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ flex: 1 }}>
            <div style={S.label}>Temps annoncé</div>
            <div style={{ fontSize: 12, color: C.dim }}>Appliqué aux nouvelles commandes</div>
          </div>
          <button onClick={() => savePrep(prep - 1)} style={stepBtn}>
            −
          </button>
          <div style={{ ...S.money, fontSize: 22, fontWeight: 600, minWidth: 56, textAlign: 'center' }}>
            {prep} min
          </div>
          <button onClick={() => savePrep(prep + 1)} style={stepBtn}>
            +
          </button>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }} className="no-print">
        <button onClick={() => setSoldOutOpen(true)} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12 }}>
          Marquer un article épuisé
        </button>
        {pushSupported() && (
          <button
            onClick={async () => {
              const ok = await subscribePush({ venueId: venue.id, eventId: event.id, role: 'staff' })
              setStaffPush(ok)
              showToast(ok ? 'Alertes activées sur cet appareil.' : 'Notifications refusées.', ok ? 'ok' : 'error')
            }}
            style={{
              ...S.btnGhost,
              minHeight: 44,
              fontSize: 12,
              borderColor: staffPush ? C.ok : C.terracotta,
              color: staffPush ? C.ok : C.terracotta,
            }}
          >
            {staffPush ? '✓ Alertes' : 'Alertes'}
          </button>
        )}
      </div>

      <div style={{ display: 'flex', gap: 12, overflowX: 'auto', paddingBottom: 8 }}>
        {[
          { title: 'Reçues', list: received, color: C.indigo, action: 'Prête', next: 'READY' },
          { title: 'Prêtes', list: ready, color: C.terracotta, action: 'Retirée', next: 'PICKED_UP' },
          { title: 'Retirées', list: pickedUp, color: C.ok, action: 'Réglée', next: 'PAID' },
        ].map((col) => (
          <div key={col.title} style={{ minWidth: 268, flex: '1 0 268px' }}>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                paddingBottom: 8,
                marginBottom: 10,
                borderBottom: `2px solid ${col.color}44`,
              }}
            >
              <div style={{ width: 8, height: 8, borderRadius: 4, background: col.color }} />
              <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1 }}>
                {col.title.toUpperCase()}
              </div>
              <div style={{ marginLeft: 'auto', color: C.faint, fontWeight: 600 }}>{col.list.length}</div>
            </div>

            <div style={{ display: 'grid', gap: 10 }}>
              {col.list.length === 0 && (
                <div style={{ color: C.faint, fontSize: 12, textAlign: 'center', padding: '16px 0' }}>—</div>
              )}
              {col.list.map((o) => (
                <div
                  key={o.id}
                  style={{
                    background: C.paper,
                    border: `1.5px solid ${!ack.has(o.id) && o.status === 'RECEIVED' ? C.terracotta : C.line}`,
                    borderRadius: 14,
                    padding: 13,
                  }}
                >
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                    <div>
                      <div
                        style={{
                          fontFamily: FONT.label,
                          fontSize: 20,
                          fontWeight: 600,
                          letterSpacing: 2,
                          color: C.navy,
                        }}
                      >
                        {o.pickup_code}
                      </div>
                      <div style={{ fontSize: 12.5, marginTop: 2, fontWeight: 500 }}>
                        {o.customers?.first_name} {o.customers?.last_name}
                      </div>
                      <div style={{ fontSize: 11, color: C.faint, marginTop: 1 }}>
                        {timeFR(o.created_at)}
                        {(o.customers?.tags || []).includes('vip') && (
                          <span style={{ color: C.indigo, fontWeight: 600 }}> · VIP</span>
                        )}
                      </div>
                    </div>
                    <div style={{ ...S.money, fontWeight: 600, color: C.terracotta }}>{eur(o.total)}</div>
                  </div>

                  <div style={{ marginTop: 9, display: 'grid', gap: 3 }}>
                    {(o.order_items || []).slice(0, 5).map((it) => (
                      <div key={it.id} style={{ fontSize: 12.5, color: C.dim }}>
                        <strong style={{ color: C.text, fontWeight: 600 }}>{it.quantity}×</strong>{' '}
                        {it.name_snapshot}
                        {it.variant_label ? ` (${it.variant_label})` : ''}
                        {(it.detail?.options || []).length > 0 && (
                          <span style={{ color: C.faint }}>
                            {' '}
                            — {(it.detail.options || []).map((x) => x.name).join(', ')}
                          </span>
                        )}
                      </div>
                    ))}
                    {(o.order_items || []).length > 5 && (
                      <button
                        onClick={() => setDetail(o)}
                        style={{ background: 'none', border: 'none', color: C.indigo, fontSize: 12, padding: 0, textAlign: 'left', cursor: 'pointer' }}
                      >
                        + {(o.order_items || []).length - 5} autres…
                      </button>
                    )}
                  </div>

                  {o.note && (
                    <div
                      style={{
                        marginTop: 9,
                        padding: 8,
                        borderRadius: 10,
                        background: 'rgba(201,130,31,.10)',
                        color: C.warn,
                        fontSize: 11.5,
                      }}
                    >
                      {o.note}
                    </div>
                  )}

                  <div style={{ display: 'flex', gap: 6, marginTop: 11 }}>
                    <button
                      onClick={() => {
                        acknowledge([o.id])
                        move(o, col.next)
                      }}
                      style={{
                        flex: 1,
                        minHeight: 44,
                        borderRadius: 12,
                        border: 'none',
                        cursor: 'pointer',
                        fontFamily: FONT.label,
                        fontWeight: 600,
                        letterSpacing: 0.8,
                        fontSize: 13,
                        textTransform: 'uppercase',
                        background: col.color,
                        color: '#fff',
                      }}
                    >
                      {col.action}
                    </button>
                    <button onClick={() => printTicket(o)} title="Imprimer le ticket (optionnel)" style={{ ...stepBtn, width: 44, height: 44, fontSize: 15 }}>
                      🖨
                    </button>
                    <button onClick={() => setDetail(o)} style={{ ...stepBtn, width: 44, height: 44, fontSize: 15 }}>
                      ⋯
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      <SoldOutSheet open={soldOutOpen} venue={venue} onClose={() => setSoldOutOpen(false)} />

      <Sheet open={!!detail} onClose={() => setDetail(null)} title={detail ? `Commande ${detail.pickup_code}` : ''}>
        {detail && (
          <>
            <div style={{ marginBottom: 14, fontSize: 13.5 }}>
              <strong>
                {detail.customers?.first_name} {detail.customers?.last_name}
              </strong>
              <div style={{ color: C.dim, fontSize: 12.5, marginTop: 3 }}>
                {phoneFR(detail.customers?.phone)}
              </div>
            </div>
            <div style={{ display: 'grid', gap: 8, marginBottom: 16 }}>
              {(detail.order_items || []).map((it) => (
                <div
                  key={it.id}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    padding: 11,
                    borderRadius: 12,
                    background: C.paper,
                    border: `1px solid ${C.line}`,
                  }}
                >
                  <div>
                    <div style={{ fontWeight: 500, fontSize: 14 }}>
                      {it.quantity}× {it.name_snapshot}
                    </div>
                    {(it.variant_label || (it.detail?.options || []).length > 0) && (
                      <div style={{ fontSize: 11.5, color: C.faint, marginTop: 3 }}>
                        {[it.variant_label, ...(it.detail?.options || []).map((o) => o.name)]
                          .filter(Boolean)
                          .join(' · ')}
                      </div>
                    )}
                  </div>
                  <div style={{ ...S.money, fontWeight: 600 }}>
                    {eur(Number(it.unit_price) * Number(it.quantity))}
                  </div>
                </div>
              ))}
            </div>
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                paddingTop: 12,
                borderTop: `1px solid ${C.lineHi}`,
                fontSize: 20,
              }}
            >
              <span style={{ fontFamily: FONT.label, fontWeight: 600 }}>TOTAL</span>
              <span style={{ ...S.money, fontWeight: 600, color: C.terracotta }}>{eur(detail.total)}</span>
            </div>
            <div style={{ display: 'grid', gap: 8, marginTop: 16 }}>
              <button onClick={() => printTicket(detail)} style={S.btnGhost}>
                Imprimer le ticket
              </button>
              <button
                onClick={async () => {
                  await supabase.from('orders').update({ status: 'CANCELLED' }).eq('id', detail.id)
                  setDetail(null)
                  load()
                }}
                style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
              >
                Annuler la commande
              </button>
            </div>
          </>
        )}
      </Sheet>
    </div>
  )
}

/** Marquer un article épuisé en un clic — il reste visible, grisé (§08). */
function SoldOutSheet({ open, venue, onClose }) {
  const [products, setProducts] = useState([])
  const [q, setQ] = useState('')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('id, name, subcategory, universe, sold_out')
      .eq('venue_id', venue.id)
      .eq('is_listed', true)
      .order('universe')
      .order('sort_order')
    setProducts(data || [])
  }, [venue.id])

  useEffect(() => {
    if (open) load()
  }, [open, load])

  async function toggle(p) {
    await supabase.from('products').update({ sold_out: !p.sold_out }).eq('id', p.id)
    setProducts((prev) => prev.map((x) => (x.id === p.id ? { ...x, sold_out: !x.sold_out } : x)))
  }

  const filtered = products.filter((p) => p.name.toLowerCase().includes(q.toLowerCase()))

  return (
    <Sheet open={open} onClose={onClose} title="Disponibilité">
      <div style={{ marginBottom: 12 }}>
        <Banner tone="info">
          Un article épuisé <strong>reste visible</strong> sur la carte mais devient non
          commandable — le client comprend que c’est une rupture, pas un bug.
        </Banner>
      </div>
      <input
        style={{ ...S.input, marginBottom: 12 }}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Rechercher un article…"
      />
      <div style={{ display: 'grid', gap: 6 }}>
        {filtered.slice(0, 60).map((p) => (
          <button
            key={p.id}
            onClick={() => toggle(p)}
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              minHeight: 48,
              padding: '0 14px',
              borderRadius: 12,
              cursor: 'pointer',
              border: `1.5px solid ${p.sold_out ? C.danger : C.lineHi}`,
              background: p.sold_out ? 'rgba(192,57,43,.07)' : C.paper,
              color: C.text,
              textAlign: 'left',
            }}
          >
            <span style={{ fontSize: 14 }}>
              {p.name}
              <span style={{ color: C.faint, fontSize: 11 }}> · {p.subcategory}</span>
            </span>
            <span
              style={{
                fontFamily: FONT.label,
                fontSize: 11,
                fontWeight: 600,
                color: p.sold_out ? C.danger : C.ok,
              }}
            >
              {p.sold_out ? 'ÉPUISÉ' : 'DISPO'}
            </span>
          </button>
        ))}
      </div>
    </Sheet>
  )
}

// ============================================================================
//  STAFF · CAISSE — suivi d'encaissement (aucun paiement traité ici)
// ============================================================================

function CaisseTab({ event, venue, showToast }) {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState([])
  const [payOpen, setPayOpen] = useState(false)
  const [showPaid, setShowPaid] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, order_items ( * ), customers ( first_name, last_name, phone )')
      .eq('event_id', event.id)
      .neq('status', 'CANCELLED')
      .order('created_at', { ascending: true })
    setOrders(data || [])
    setLoading(false)
  }, [event.id])

  useEffect(() => {
    load()
    const ch = supabase
      .channel(`caisse-${event.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'orders', filter: `event_id=eq.${event.id}` },
        () => load()
      )
      .subscribe()
    return () => supabase.removeChannel(ch)
  }, [event.id, load])

  const visible = orders.filter((o) => (showPaid ? true : o.status !== 'PAID'))

  const byCustomer = useMemo(() => {
    const map = new Map()
    for (const o of visible) {
      const key = o.customer_id
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(o)
    }
    return [...map.entries()]
  }, [visible])

  const selectedOrders = orders.filter((o) => selected.includes(o.id))
  const selectedTotal = selectedOrders.reduce((s, o) => s + Number(o.total || 0), 0)

  async function markPaid(method) {
    const { error } = await supabase
      .from('orders')
      .update({ status: 'PAID', paid_method: method })
      .in('id', selected)
    if (error) return showToast(frError(error), 'error')
    showToast(`${selected.length} commande(s) réglée(s) — ${eur(selectedTotal)}`, 'ok')
    setSelected([])
    setPayOpen(false)
    load()
  }

  if (loading) return <Spinner />

  const due = orders.filter((o) => o.status !== 'PAID').reduce((s, o) => s + Number(o.total || 0), 0)
  const cashed = orders.filter((o) => o.status === 'PAID').reduce((s, o) => s + Number(o.total || 0), 0)
  const unpaid = orders.filter((o) => o.status === 'UNPAID')

  return (
    <div style={{ paddingBottom: selected.length ? 120 : 0 }}>
      <div style={{ marginBottom: 14 }}>
        <Banner tone="info">
          L’encaissement se fait au bar, sur votre système habituel. Ici, on ne fait que le{' '}
          <strong>suivi</strong> : cochez ce qui a été réglé.
        </Banner>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        {[
          { t: 'Reste dû', v: eur(due), c: C.terracotta },
          { t: 'Encaissé', v: eur(cashed), c: C.ok },
          { t: 'Impayés', v: unpaid.length, c: C.danger },
        ].map((s) => (
          <div key={s.t} style={{ ...S.card, flex: 1, padding: '12px 10px', textAlign: 'center' }}>
            <div style={{ ...S.money, fontSize: 17, fontWeight: 600, color: s.c }}>{s.v}</div>
            <div style={{ ...S.label, marginBottom: 0, marginTop: 4, fontSize: 9.5 }}>{s.t}</div>
          </div>
        ))}
      </div>

      <button
        onClick={() => setShowPaid((v) => !v)}
        style={{ ...S.btnGhost, minHeight: 42, fontSize: 12, marginBottom: 14 }}
      >
        {showPaid ? 'Masquer les commandes réglées' : 'Afficher aussi les réglées'}
      </button>

      {byCustomer.length === 0 && <Empty emoji="🧾" title="Rien à encaisser" />}

      {byCustomer.map(([cid, list]) => {
        const c = list[0].customers
        const tot = list.reduce((s, o) => s + Number(o.total || 0), 0)
        const allSel = list.every((o) => selected.includes(o.id))
        return (
          <div key={cid} style={{ ...S.card, padding: 14, marginBottom: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10 }}>
              <div>
                <div style={{ fontWeight: 500, fontSize: 15 }}>
                  {c?.first_name} {c?.last_name}
                </div>
                <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                  {list.length} commande{list.length > 1 ? 's' : ''}
                </div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ ...S.money, fontWeight: 600, fontSize: 18, color: C.terracotta }}>
                  {eur(tot)}
                </div>
                <button
                  onClick={() =>
                    setSelected((p) => {
                      const ids = list.map((o) => o.id)
                      return allSel ? p.filter((x) => !ids.includes(x)) : [...new Set([...p, ...ids])]
                    })
                  }
                  style={{ background: 'none', border: 'none', color: C.indigo, fontSize: 11.5, cursor: 'pointer', padding: '4px 0 0' }}
                >
                  {allSel ? 'Tout décocher' : 'Tout sélectionner'}
                </button>
              </div>
            </div>

            <div style={{ display: 'grid', gap: 8 }}>
              {list.map((o) => {
                const sel = selected.includes(o.id)
                const st = ORDER_STATUS[o.status]
                return (
                  <button
                    key={o.id}
                    onClick={() =>
                      setSelected((p) => (p.includes(o.id) ? p.filter((x) => x !== o.id) : [...p, o.id]))
                    }
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 12,
                      padding: 11,
                      borderRadius: 12,
                      cursor: 'pointer',
                      textAlign: 'left',
                      border: `1.5px solid ${sel ? C.terracotta : C.line}`,
                      background: sel ? 'rgba(185,106,76,.08)' : C.creamSoft,
                      color: C.text,
                    }}
                  >
                    <div
                      style={{
                        width: 22,
                        height: 22,
                        flexShrink: 0,
                        borderRadius: 6,
                        border: `2px solid ${sel ? C.terracotta : C.lineHi}`,
                        background: sel ? C.terracotta : 'transparent',
                        color: '#fff',
                        fontSize: 13,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                      }}
                    >
                      {sel ? '✓' : ''}
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1.4 }}>
                        {o.pickup_code}
                        <span style={{ color: st.color, fontSize: 10.5, marginLeft: 8, letterSpacing: 0.5 }}>
                          {st.short.toUpperCase()}
                        </span>
                      </div>
                      <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                        {(o.order_items || []).map((it) => `${it.quantity}× ${it.name_snapshot}`).join(' · ').slice(0, 80)}
                      </div>
                    </div>
                    <div style={{ ...S.money, fontWeight: 600 }}>{eur(o.total)}</div>
                  </button>
                )
              })}
            </div>
          </div>
        )
      })}

      {selected.length > 0 && (
        <div
          style={{
            position: 'fixed',
            left: 14,
            right: 14,
            bottom: 'calc(env(safe-area-inset-bottom) + 78px)',
            zIndex: 70,
            background: C.paper,
            border: `1.5px solid ${C.terracotta}`,
            borderRadius: 16,
            padding: 14,
            boxShadow: '0 12px 32px rgba(28,42,74,.18)',
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 10 }}>
            <div style={{ fontSize: 13, color: C.dim }}>
              {selected.length} commande{selected.length > 1 ? 's' : ''}
            </div>
            <div style={{ ...S.money, fontSize: 23, fontWeight: 600, color: C.terracotta }}>
              {eur(selectedTotal)}
            </div>
          </div>
          <button onClick={() => setPayOpen(true)} style={{ ...S.btn, minHeight: 48 }}>
            Marquer réglé
          </button>
        </div>
      )}

      <Sheet open={payOpen} onClose={() => setPayOpen(false)} title="Encaissement">
        <div style={{ marginBottom: 16 }}>
          <Banner tone="info">
            Total encaissé au bar : <strong>{eur(selectedTotal)}</strong>. Noti Calling ne traite
            aucun paiement — indiquez simplement le moyen utilisé.
          </Banner>
        </div>
        <div style={{ display: 'grid', gap: 8 }}>
          {[
            ['especes', 'Espèces'],
            ['cb', 'Carte bancaire'],
            ['autre', 'Autre / avoir'],
          ].map(([k, label]) => (
            <button key={k} onClick={() => markPaid(k)} style={{ ...S.btnGhost, minHeight: 52 }}>
              {label}
            </button>
          ))}
        </div>
      </Sheet>
    </div>
  )
}

// ============================================================================
//  STAFF · ORGA — pilotage temps réel, interaction, reporting
// ============================================================================

function OrgaTab({ event, venue, showToast, onEventChange }) {
  const [live, setLive] = useState(null)
  const [board, setBoard] = useState([])
  const [messages, setMessages] = useState([])
  const [broadcastOpen, setBroadcastOpen] = useState(false)
  const [dmFor, setDmFor] = useState(null)
  const [report, setReport] = useState(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [l, b, m] = await Promise.all([
      supabase.from('v_event_live').select('*').eq('event_id', event.id).maybeSingle(),
      supabase
        .from('v_event_leaderboard')
        .select('*')
        .eq('event_id', event.id)
        .order('total_spent', { ascending: false })
        .limit(20),
      supabase
        .from('messages')
        .select('*')
        .eq('event_id', event.id)
        .neq('kind', 'status')
        .order('created_at', { ascending: false })
        .limit(10),
    ])
    setLive(l.data || null)
    setBoard(b.data || [])
    setMessages(m.data || [])
  }, [event.id])

  useEffect(() => {
    load()
    const ch = supabase
      .channel(`orga-${event.id}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'orders', filter: `event_id=eq.${event.id}` }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'attendances', filter: `event_id=eq.${event.id}` }, load)
      .subscribe()
    const poll = setInterval(load, 25000)
    return () => {
      supabase.removeChannel(ch)
      clearInterval(poll)
    }
  }, [event.id, load])

  async function loadReport() {
    setBusy(true)
    const { data, error } = await supabase.rpc('event_report', { p_event: event.id })
    setBusy(false)
    if (error) return showToast(frError(error), 'error')
    setReport(data)
  }

  function exportCsv() {
    if (!board.length) return showToast('Rien à exporter.', 'error')
    const head = ['Prénom', 'Nom', 'Tags', 'Commandes', 'Total EUR', 'Dernière commande']
    const rows = board.map((r) => [
      r.first_name ?? '',
      r.last_name ?? '',
      (r.tags || []).join('|'),
      r.orders_count,
      Number(r.total_spent).toFixed(2),
      r.last_order_at ? dateFR(r.last_order_at) : '',
    ])
    const csv =
      '﻿' +
      [head, ...rows]
        .map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(';'))
        .join('\r\n')
    downloadBlob(new Blob([csv], { type: 'text/csv;charset=utf-8' }), `noti-${event.id.slice(0, 8)}.csv`)
  }

  async function exportReportPdf() {
    if (!report) return
    const canvas = await renderReportCanvas({ venue, event, report })
    const blob = canvasesToPdfBlob([canvas], { quality: 0.94 })
    await shareOrDownload(blob, `noti-rapport-${event.id.slice(0, 8)}.pdf`, 'Rapport')
  }

  const stat = (t, v, c) => (
    <div key={t} style={{ ...S.card, flex: 1, minWidth: 92, padding: '13px 10px', textAlign: 'center' }}>
      <div style={{ ...S.money, fontSize: 21, fontWeight: 600, color: c }}>{v}</div>
      <div style={{ ...S.label, marginBottom: 0, marginTop: 4, fontSize: 9.5 }}>{t}</div>
    </div>
  )

  return (
    <div>
      {/* Temps réel */}
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
        {stat('Présents', live?.headcount ?? 0, C.indigo)}
        {stat('En prépa', live?.in_preparation ?? 0, C.navy)}
        {stat('À retirer', live?.awaiting_pickup ?? 0, C.terracotta)}
        {stat('Encaissé', eur(live?.revenue_paid ?? 0), C.ok)}
      </div>

      {(live?.unpaid_count ?? 0) > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Banner tone="danger">
            <strong>{live.unpaid_count} commande(s) impayée(s)</strong> — tracées et rattachées à
            l’identité vérifiée du client (preuve horodatée).
          </Banner>
        </div>
      )}

      {/* Communication */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        <button onClick={() => setBroadcastOpen(true)} style={{ ...S.btn, minHeight: 48 }}>
          Diffuser un message
        </button>
      </div>

      {messages.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <div style={S.label}>Derniers envois</div>
          <div style={{ display: 'grid', gap: 6 }}>
            {messages.slice(0, 4).map((m) => (
              <div key={m.id} style={{ ...S.card, padding: 11 }}>
                <div style={{ fontSize: 10.5, color: C.faint, fontFamily: FONT.label, letterSpacing: 1 }}>
                  {m.kind === 'individual' ? 'INDIVIDUEL' : 'DIFFUSION'} · {timeFR(m.created_at)}
                </div>
                <div style={{ fontSize: 13, marginTop: 4 }}>{m.body}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Leaderboard */}
      <div style={{ ...S.h2, marginBottom: 10 }}>Leaderboard</div>
      {board.length === 0 && <Empty emoji="🏆" title="Pas encore de commande" />}
      <div style={{ display: 'grid', gap: 8, marginBottom: 18 }}>
        {board.map((r, i) => (
          <div key={r.customer_id} style={{ ...S.card, padding: 12, display: 'flex', gap: 12, alignItems: 'center' }}>
            <div
              style={{
                width: 30,
                height: 30,
                flexShrink: 0,
                borderRadius: '50%',
                background: i < 3 ? GRADIENT : 'rgba(28,42,74,.06)',
                color: i < 3 ? C.navy : C.dim,
                fontFamily: FONT.label,
                fontWeight: 600,
                fontSize: 13,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              {i + 1}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontWeight: 500, fontSize: 14 }}>
                {r.first_name} {r.last_name}
                {(r.tags || []).includes('vip') && (
                  <span style={{ color: C.indigo, fontSize: 11 }}> · VIP</span>
                )}
              </div>
              <div style={{ fontSize: 11.5, color: C.faint }}>
                {r.orders_count} commande{r.orders_count > 1 ? 's' : ''}
              </div>
            </div>
            <div style={{ ...S.money, fontWeight: 600, color: C.terracotta }}>{eur(r.total_spent)}</div>
            <button onClick={() => setDmFor(r)} title="Message individuel" style={{ ...stepBtn, width: 38, height: 38, fontSize: 14 }}>
              ✉
            </button>
          </div>
        ))}
      </div>

      {/* Reporting */}
      <div style={{ ...S.h2, marginBottom: 10 }}>Reporting</div>
      <div style={{ display: 'grid', gap: 8, marginBottom: 18 }}>
        <button onClick={loadReport} disabled={busy} style={S.btnGhost}>
          {busy ? '…' : 'Générer la fiche de soirée'}
        </button>
        {report && (
          <>
            <div style={{ ...S.card, padding: 14 }}>
              {[
                ['Commandes', report.orders_total],
                ['Panier moyen', eur(report.average_basket)],
                ['Encaissé', eur(report.revenue_paid)],
                ['Impayé', eur(report.revenue_unpaid)],
                ['Présents', report.headcount],
                ['Nouveaux', report.new_customers],
                ['Habitués', report.returning_customers],
                ['Note moyenne', report.rating_avg ? `${report.rating_avg} / 5` : '—'],
              ].map(([k, v]) => (
                <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', fontSize: 13.5 }}>
                  <span style={{ color: C.dim }}>{k}</span>
                  <span style={{ ...S.money, fontWeight: 600 }}>{v}</span>
                </div>
              ))}
              {(report.top_products || []).length > 0 && (
                <>
                  <div style={{ ...S.label, marginTop: 12 }}>Top produits</div>
                  {report.top_products.slice(0, 6).map((p) => (
                    <div key={p.name} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, padding: '3px 0' }}>
                      <span>{p.name}</span>
                      <span style={S.money}>
                        {p.qty} · {eur(p.revenue)}
                      </span>
                    </div>
                  ))}
                </>
              )}
            </div>
            <button onClick={exportReportPdf} style={S.btnGhost}>
              Exporter la fiche en PDF
            </button>
          </>
        )}
        <button onClick={exportCsv} style={S.btnGhost}>
          Exporter les clients (CSV)
        </button>
      </div>

      {/* Clôture */}
      {event.is_active && (
        <button
          onClick={async () => {
            if (!confirm('Clôturer la soirée ? Les commandes non réglées passeront en « impayé ».')) return
            const { data, error } = await supabase.rpc('close_event', { p_event: event.id })
            if (error) return showToast(frError(error), 'error')
            showToast(`Soirée clôturée · ${data} commande(s) passée(s) en impayé.`, 'ok')
            onEventChange?.()
          }}
          style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
        >
          Clôturer la soirée
        </button>
      )}

      <BroadcastSheet
        open={broadcastOpen}
        event={event}
        onClose={() => setBroadcastOpen(false)}
        onSent={(n) => {
          setBroadcastOpen(false)
          showToast(`Message diffusé à ${n} personne(s).`, 'ok')
          load()
        }}
        showToast={showToast}
      />

      <DirectMessageSheet
        target={dmFor}
        event={event}
        onClose={() => setDmFor(null)}
        onSent={() => {
          setDmFor(null)
          showToast('Message envoyé.', 'ok')
          load()
        }}
        showToast={showToast}
      />
    </div>
  )
}

const BROADCAST_TEMPLATES = [
  'La cuisine ferme dans 1 h — c’est le moment de commander.',
  'Réassort effectué : les articles épuisés sont de nouveau disponibles.',
  'La soirée se termine dans 1 h, pensez à récupérer vos commandes.',
  'Happy hour : un extra offert sur toute commande passée dans les 30 minutes.',
]

function BroadcastSheet({ open, event, onClose, onSent, showToast }) {
  const [body, setBody] = useState('')
  const [busy, setBusy] = useState(false)

  return (
    <Sheet open={open} onClose={onClose} title="Diffusion">
      <div style={{ marginBottom: 12 }}>
        <Banner tone="info">
          Le message part à toutes les personnes présentes sur la soirée, en notification et en SMS.
        </Banner>
      </div>

      <Field label="Modèles">
        <div style={{ display: 'grid', gap: 6 }}>
          {BROADCAST_TEMPLATES.map((t) => (
            <button
              key={t}
              onClick={() => setBody(t)}
              style={{
                ...S.chip,
                textAlign: 'left',
                whiteSpace: 'normal',
                lineHeight: 1.4,
                padding: '10px 13px',
              }}
            >
              {t}
            </button>
          ))}
        </div>
      </Field>

      <Field label="Message">
        <textarea
          style={{ ...S.input, minHeight: 96, paddingTop: 12 }}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          placeholder="Votre annonce…"
        />
      </Field>

      <button
        disabled={!body.trim() || busy}
        onClick={async () => {
          setBusy(true)
          const res = await notify({
            eventId: event.id,
            kind: 'broadcast',
            body: body.trim(),
            title: event.name,
          })
          setBusy(false)
          if (!res) return showToast('Envoi impossible (Edge Function notify).', 'error')
          setBody('')
          onSent(res.recipients ?? 0)
        }}
        style={{ ...S.btn, opacity: !body.trim() || busy ? 0.5 : 1 }}
      >
        {busy ? 'Envoi…' : 'Diffuser'}
      </button>
    </Sheet>
  )
}

function DirectMessageSheet({ target, event, onClose, onSent, showToast }) {
  const [body, setBody] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (target)
      setBody(
        `Hey ${target.first_name || ''}, l’orga de la soirée te cherche — passe au bar, on a quelque chose pour toi !`
      )
  }, [target])

  if (!target) return null

  return (
    <Sheet open={!!target} onClose={onClose} title={`Message à ${target.first_name || 'ce client'}`}>
      <Field label="Message">
        <textarea
          style={{ ...S.input, minHeight: 110, paddingTop: 12 }}
          value={body}
          onChange={(e) => setBody(e.target.value)}
        />
      </Field>
      <button
        disabled={!body.trim() || busy}
        onClick={async () => {
          setBusy(true)
          const res = await notify({
            eventId: event.id,
            kind: 'individual',
            customerId: target.customer_id,
            body: body.trim(),
            title: event.name,
          })
          setBusy(false)
          if (!res) return showToast('Envoi impossible (Edge Function notify).', 'error')
          onSent()
        }}
        style={{ ...S.btn, opacity: !body.trim() || busy ? 0.5 : 1 }}
      >
        {busy ? 'Envoi…' : 'Envoyer'}
      </button>
    </Sheet>
  )
}

// ============================================================================
//  STAFF · CARTE
// ============================================================================

const EMPTY_PRODUCT = {
  universe: 'drinks',
  subcategory: 'Cocktails',
  name: '',
  description: '',
  price: 0,
  is_popular: false,
  sold_out: false,
  is_listed: true,
  sort_order: 0,
  is_alcohol: true,
  vat_rate: 20,
  variants: [],
  option_groups: [],
}

function CarteTab({ venue, showToast }) {
  const [products, setProducts] = useState([])
  const [loading, setLoading] = useState(true)
  const [universe, setUniverse] = useState('drinks')
  const [editing, setEditing] = useState(null)
  const [busy, setBusy] = useState('')

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('products')
      .select('*')
      .eq('venue_id', venue.id)
      .order('universe')
      .order('sort_order')
    setProducts(data || [])
    setLoading(false)
  }, [venue.id])

  useEffect(() => {
    load()
  }, [load])

  async function toggleSoldOut(p) {
    await supabase.from('products').update({ sold_out: !p.sold_out }).eq('id', p.id)
    load()
  }

  async function translate(langs) {
    setBusy('translate')
    try {
      const items = products.map((p) => ({ id: p.id, name: p.name, description: p.description || '' }))
      const { data, error } = await supabase.functions.invoke('translate-menu', {
        body: { targetLangs: langs, items },
      })
      if (error) throw error
      let n = 0
      for (const p of products) {
        const t = data?.translations?.[p.id]
        if (!t) continue
        await supabase
          .from('products')
          .update({ translations: { ...(p.translations || {}), ...t } })
          .eq('id', p.id)
        n++
      }
      showToast(`${n} articles traduits.`, 'ok')
      load()
    } catch (e) {
      showToast('Traduction indisponible : ' + frError(e), 'error')
    } finally {
      setBusy('')
    }
  }

  if (loading) return <Spinner />

  const list = products.filter((p) => p.universe === universe)
  const subcats = [...new Set(list.map((p) => p.subcategory))]

  return (
    <div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <button onClick={() => setEditing({ ...EMPTY_PRODUCT, universe })} style={{ ...S.btn, minHeight: 46 }}>
          + Article
        </button>
        <button
          disabled={busy === 'translate'}
          onClick={() => translate(['en', 'es'])}
          style={{ ...S.btnGhost, minHeight: 46, width: 'auto', padding: '0 16px', fontSize: 12 }}
        >
          {busy === 'translate' ? '…' : 'EN / ES'}
        </button>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        {UNIVERSES.map((u) => (
          <button
            key={u.k}
            onClick={() => setUniverse(u.k)}
            style={{
              ...S.chip,
              flex: 1,
              minHeight: 44,
              borderColor: universe === u.k ? C.terracotta : C.lineHi,
              color: universe === u.k ? C.terracotta : C.dim,
              background: universe === u.k ? 'rgba(185,106,76,.08)' : 'transparent',
            }}
          >
            {u.e} {u.t}
          </button>
        ))}
      </div>

      {list.length === 0 && <Empty emoji="📋" title="Aucun article dans cet univers" />}

      {subcats.map((sc) => (
        <div key={sc} style={{ marginBottom: 18 }}>
          <div style={{ ...S.h2, marginBottom: 8, fontSize: 13 }}>{sc}</div>
          <div style={{ display: 'grid', gap: 8 }}>
            {list
              .filter((p) => p.subcategory === sc)
              .map((p) => (
                <div
                  key={p.id}
                  style={{
                    ...S.card,
                    padding: 12,
                    display: 'flex',
                    gap: 10,
                    alignItems: 'center',
                    opacity: p.is_listed ? 1 : 0.5,
                  }}
                >
                  <button
                    onClick={() => setEditing(p)}
                    style={{ flex: 1, minWidth: 0, background: 'none', border: 'none', textAlign: 'left', cursor: 'pointer', color: C.text, padding: 0 }}
                  >
                    <div style={{ fontWeight: 500, fontSize: 14 }}>
                      {p.name}
                      {p.is_popular && <span style={{ color: C.indigo, fontSize: 11 }}> · populaire</span>}
                      {!p.is_listed && <span style={{ color: C.faint, fontSize: 11 }}> · retiré</span>}
                    </div>
                    <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                      {(p.variants || []).length
                        ? p.variants.map((v) => `${v.label} ${eur(v.price)}`).join(' · ')
                        : eur(p.price)}
                    </div>
                  </button>
                  <button
                    onClick={() => toggleSoldOut(p)}
                    style={{
                      minHeight: 38,
                      padding: '0 12px',
                      borderRadius: 10,
                      cursor: 'pointer',
                      border: `1.5px solid ${p.sold_out ? C.danger : C.lineHi}`,
                      background: p.sold_out ? 'rgba(192,57,43,.08)' : 'transparent',
                      color: p.sold_out ? C.danger : C.dim,
                      fontFamily: FONT.label,
                      fontSize: 10.5,
                      fontWeight: 600,
                      letterSpacing: 0.8,
                    }}
                  >
                    {p.sold_out ? 'ÉPUISÉ' : 'DISPO'}
                  </button>
                </div>
              ))}
          </div>
        </div>
      ))}

      <ProductEditor
        product={editing}
        venue={venue}
        subcats={[...new Set(products.map((p) => p.subcategory))]}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null)
          load()
        }}
        showToast={showToast}
      />
    </div>
  )
}

function ProductEditor({ product, venue, subcats, onClose, onSaved, showToast }) {
  const [f, setF] = useState(EMPTY_PRODUCT)
  const [busy, setBusy] = useState(false)
  const fileRef = useRef(null)

  useEffect(() => {
    if (product)
      setF({ ...EMPTY_PRODUCT, ...product, variants: product.variants || [], option_groups: product.option_groups || [] })
  }, [product])

  if (!product) return null
  const set = (k, v) => setF((p) => ({ ...p, [k]: v }))

  async function upload(file) {
    if (!file) return
    setBusy(true)
    try {
      const ext = (file.name.split('.').pop() || 'jpg').toLowerCase()
      const path = `${venue.id}/products/${uid()}.${ext}`
      const { error } = await supabase.storage.from('noti').upload(path, file, { upsert: true })
      if (error) throw error
      set('image_url', supabase.storage.from('noti').getPublicUrl(path).data.publicUrl)
    } catch (e) {
      showToast(frError(e), 'error')
    } finally {
      setBusy(false)
    }
  }

  async function save() {
    setBusy(true)
    try {
      const payload = {
        venue_id: venue.id,
        universe: f.universe,
        subcategory: (f.subcategory || 'Divers').trim(),
        name: f.name.trim(),
        description: f.description?.trim() || null,
        price: Number(f.price) || 0,
        image_url: f.image_url || null,
        is_popular: !!f.is_popular,
        sold_out: !!f.sold_out,
        is_listed: !!f.is_listed,
        sort_order: Number(f.sort_order) || 0,
        is_alcohol: !!f.is_alcohol,
        vat_rate: Number(f.vat_rate) || 20,
        variants: f.variants || [],
        option_groups: f.option_groups || [],
        translations: f.translations || {},
      }
      const { error } = f.id
        ? await supabase.from('products').update(payload).eq('id', f.id)
        : await supabase.from('products').insert(payload)
      if (error) throw error
      onSaved()
    } catch (e) {
      showToast(frError(e), 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Sheet open={!!product} onClose={onClose} title={f.id ? 'Modifier' : 'Nouvel article'}>
      <Field label="Univers">
        <div style={{ display: 'flex', gap: 8 }}>
          {UNIVERSES.map((u) => (
            <button
              key={u.k}
              onClick={() => set('universe', u.k)}
              style={{
                ...S.chip,
                flex: 1,
                minHeight: 42,
                borderColor: f.universe === u.k ? C.terracotta : C.lineHi,
                color: f.universe === u.k ? C.terracotta : C.dim,
              }}
            >
              {u.t}
            </button>
          ))}
        </div>
      </Field>

      <Field label="Nom">
        <input style={S.input} value={f.name} onChange={(e) => set('name', e.target.value)} />
      </Field>
      <Field label="Description">
        <textarea
          style={{ ...S.input, minHeight: 66, paddingTop: 12 }}
          value={f.description || ''}
          onChange={(e) => set('description', e.target.value)}
        />
      </Field>

      <Field label="Sous-catégorie">
        <input style={S.input} list="noti-subcats" value={f.subcategory} onChange={(e) => set('subcategory', e.target.value)} />
        <datalist id="noti-subcats">
          {subcats.map((c) => (
            <option key={c} value={c} />
          ))}
        </datalist>
      </Field>

      <div style={{ display: 'flex', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <Field label="Prix (€)">
            <input style={S.input} type="number" step="0.5" value={f.price} onChange={(e) => set('price', e.target.value)} />
          </Field>
        </div>
        <div style={{ flex: 1 }}>
          <Field label="TVA">
            <select style={S.input} value={f.vat_rate} onChange={(e) => set('vat_rate', e.target.value)}>
              <option value={20}>20 % — alcool</option>
              <option value={10}>10 % — soft / food sur place</option>
              <option value={5.5}>5,5 % — à emporter</option>
            </select>
          </Field>
        </div>
      </div>

      <Field label="Photo">
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          {f.image_url && (
            <img src={f.image_url} alt="" style={{ width: 52, height: 52, borderRadius: 12, objectFit: 'cover' }} />
          )}
          <button onClick={() => fileRef.current?.click()} style={{ ...S.btnGhost, minHeight: 44, flex: 1, fontSize: 12 }}>
            {busy ? '…' : f.image_url ? 'Remplacer' : 'Ajouter'}
          </button>
          <input ref={fileRef} type="file" accept="image/*" hidden onChange={(e) => upload(e.target.files?.[0])} />
        </div>
      </Field>

      <div style={{ display: 'grid', gap: 8, marginBottom: 16 }}>
        {[
          ['is_popular', 'Badge « Populaire »'],
          ['sold_out', 'Épuisé (visible mais non commandable)'],
          ['is_listed', 'Présent sur la carte'],
          ['is_alcohol', 'Contient de l’alcool'],
        ].map(([k, label]) => (
          <button
            key={k}
            onClick={() => set(k, !f[k])}
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              minHeight: 46,
              padding: '0 14px',
              borderRadius: 12,
              cursor: 'pointer',
              border: `1.5px solid ${f[k] ? C.terracotta : C.lineHi}`,
              background: f[k] ? 'rgba(185,106,76,.07)' : C.paper,
              color: C.text,
              fontSize: 13.5,
            }}
          >
            <span>{label}</span>
            <span style={{ fontFamily: FONT.label, fontWeight: 600, color: f[k] ? C.terracotta : C.faint }}>
              {f[k] ? 'OUI' : 'NON'}
            </span>
          </button>
        ))}
      </div>

      {/* Formats */}
      <div style={S.label}>Formats (12 cl / 75 cl / magnum…)</div>
      {(f.variants || []).map((v, i) => (
        <div key={v.id} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
          <input
            style={{ ...S.input, minHeight: 42, flex: 2 }}
            value={v.label}
            onChange={(e) =>
              set('variants', f.variants.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)))
            }
          />
          <input
            style={{ ...S.input, minHeight: 42, width: 88, textAlign: 'right' }}
            type="number"
            step="0.5"
            value={v.price}
            onChange={(e) =>
              set('variants', f.variants.map((x, j) => (j === i ? { ...x, price: Number(e.target.value) || 0 } : x)))
            }
          />
          <button
            onClick={() => set('variants', f.variants.filter((_, j) => j !== i))}
            style={{ ...stepBtn, width: 42, height: 42, color: C.danger }}
          >
            ✕
          </button>
        </div>
      ))}
      <button
        onClick={() => set('variants', [...(f.variants || []), { id: uid(), label: '75 cl', price: Number(f.price) || 0 }])}
        style={{ ...S.btnGhost, minHeight: 40, fontSize: 12, marginBottom: 18 }}
      >
        + Format
      </button>

      <div style={{ display: 'grid', gap: 8 }}>
        <button disabled={busy || !f.name.trim()} onClick={save} style={{ ...S.btn, opacity: busy || !f.name.trim() ? 0.5 : 1 }}>
          {busy ? '…' : 'Enregistrer'}
        </button>
        {f.id && (
          <button
            onClick={async () => {
              await supabase.from('products').delete().eq('id', f.id)
              onSaved()
            }}
            style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
          >
            Supprimer
          </button>
        )}
      </div>
    </Sheet>
  )
}

// ============================================================================
//  STAFF · CLIENTS — base cross-événement, tags & segmentation
// ============================================================================

const ALL_TAGS = ['vip', 'habitue', 'gros_panier', 'incident']

function ClientsTab({ event, showToast }) {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [q, setQ] = useState('')
  const [filter, setFilter] = useState(null)
  const [detail, setDetail] = useState(null)

  const load = useCallback(async () => {
    // Clients présents sur cette soirée (la RLS limite déjà à nos événements).
    const { data: att } = await supabase
      .from('attendances')
      .select('customer_id, group_size, first_scan_at, customers ( * )')
      .eq('event_id', event.id)
    const list = (att || [])
      .map((a) => ({ ...a.customers, group_size: a.group_size, seen_at: a.first_scan_at }))
      .filter((c) => c?.id)
    list.sort((a, b) => Number(b.total_spent || 0) - Number(a.total_spent || 0))
    setRows(list)
    setLoading(false)
  }, [event.id])

  useEffect(() => {
    load()
  }, [load])

  async function toggleTag(customer, tag) {
    const tags = customer.tags || []
    const next = tags.includes(tag) ? tags.filter((t) => t !== tag) : [...tags, tag]
    const { error } = await supabase.from('customers').update({ tags: next }).eq('id', customer.id)
    if (error) return showToast(frError(error), 'error')
    setDetail((d) => (d ? { ...d, tags: next } : d))
    load()
  }

  if (loading) return <Spinner />

  const filtered = rows.filter(
    (r) =>
      `${r.first_name || ''} ${r.last_name || ''} ${r.phone || ''}`
        .toLowerCase()
        .includes(q.toLowerCase()) && (!filter || (r.tags || []).includes(filter))
  )

  return (
    <div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        {[
          { t: 'Présents', v: rows.length, c: C.indigo },
          { t: 'Habitués', v: rows.filter((r) => (r.tags || []).includes('habitue')).length, c: C.terracotta },
          { t: 'Incidents', v: rows.filter((r) => (r.tags || []).includes('incident')).length, c: C.danger },
        ].map((s) => (
          <div key={s.t} style={{ ...S.card, flex: 1, padding: '12px 8px', textAlign: 'center' }}>
            <div style={{ ...S.money, fontSize: 19, fontWeight: 600, color: s.c }}>{s.v}</div>
            <div style={{ ...S.label, marginBottom: 0, marginTop: 3, fontSize: 9.5 }}>{s.t}</div>
          </div>
        ))}
      </div>

      <input
        style={{ ...S.input, marginBottom: 10 }}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Rechercher…"
      />

      <div style={{ display: 'flex', gap: 6, marginBottom: 14, overflowX: 'auto' }}>
        <button
          onClick={() => setFilter(null)}
          style={{ ...S.chip, borderColor: !filter ? C.terracotta : C.lineHi, color: !filter ? C.terracotta : C.dim }}
        >
          Tous
        </button>
        {ALL_TAGS.map((t) => (
          <button
            key={t}
            onClick={() => setFilter(filter === t ? null : t)}
            style={{
              ...S.chip,
              borderColor: filter === t ? C.terracotta : C.lineHi,
              color: filter === t ? C.terracotta : C.dim,
            }}
          >
            {TAG_LABEL[t]}
          </button>
        ))}
      </div>

      {filtered.length === 0 && <Empty emoji="👥" title="Personne pour l’instant" />}

      <div style={{ display: 'grid', gap: 8 }}>
        {filtered.map((r) => (
          <button
            key={r.id}
            onClick={() => setDetail(r)}
            style={{ ...S.card, padding: 12, display: 'flex', gap: 12, alignItems: 'center', cursor: 'pointer', textAlign: 'left', color: C.text }}
          >
            <div
              style={{
                width: 40,
                height: 40,
                flexShrink: 0,
                borderRadius: '50%',
                background: (r.tags || []).includes('vip') ? GRADIENT : 'rgba(28,42,74,.06)',
                color: (r.tags || []).includes('vip') ? C.navy : C.dim,
                fontFamily: FONT.label,
                fontWeight: 600,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              {(r.first_name || '?').slice(0, 1).toUpperCase()}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontWeight: 500, fontSize: 14 }}>
                {r.first_name} {r.last_name}
              </div>
              <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                {r.events_count || 1} soirée
                {(r.events_count || 1) > 1 ? 's' : ''} · {r.orders_count || 0} commande
                {(r.orders_count || 0) > 1 ? 's' : ''}
                {r.group_size > 1 ? ` · groupe de ${r.group_size}` : ''}
              </div>
              {(r.tags || []).length > 0 && (
                <div style={{ display: 'flex', gap: 4, marginTop: 5, flexWrap: 'wrap' }}>
                  {(r.tags || []).map((t) => (
                    <span
                      key={t}
                      style={{
                        fontFamily: FONT.label,
                        fontSize: 9,
                        letterSpacing: 0.8,
                        padding: '2px 7px',
                        borderRadius: 999,
                        color: t === 'incident' ? C.danger : C.indigo,
                        border: `1px solid ${t === 'incident' ? C.danger : C.indigo}44`,
                      }}
                    >
                      {(TAG_LABEL[t] || t).toUpperCase()}
                    </span>
                  ))}
                </div>
              )}
            </div>
            <div style={{ ...S.money, fontWeight: 600, color: C.terracotta }}>{eur(r.total_spent)}</div>
          </button>
        ))}
      </div>

      <Sheet
        open={!!detail}
        onClose={() => setDetail(null)}
        title={detail ? `${detail.first_name || ''} ${detail.last_name || ''}` : ''}
      >
        {detail && (
          <>
            <div style={{ ...S.card, padding: 14, marginBottom: 14 }}>
              {[
                ['Soirées', detail.events_count || 1],
                ['Commandes réglées', detail.orders_count || 0],
                ['Total dépensé', eur(detail.total_spent)],
                ['Impayés', detail.unpaid_count || 0],
                ['Première venue', detail.first_seen_at ? dateFR(detail.first_seen_at) : '—'],
              ].map(([k, v]) => (
                <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 13.5 }}>
                  <span style={{ color: C.dim }}>{k}</span>
                  <span style={{ ...S.money, fontWeight: 500 }}>{v}</span>
                </div>
              ))}
            </div>

            <div style={S.label}>Segmentation</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 16 }}>
              {ALL_TAGS.map((t) => {
                const on = (detail.tags || []).includes(t)
                return (
                  <button
                    key={t}
                    onClick={() => toggleTag(detail, t)}
                    style={{
                      ...S.chip,
                      minHeight: 42,
                      borderColor: on ? C.terracotta : C.lineHi,
                      color: on ? C.terracotta : C.dim,
                      background: on ? 'rgba(185,106,76,.08)' : 'transparent',
                    }}
                  >
                    {on ? '✓ ' : ''}
                    {TAG_LABEL[t]}
                  </button>
                )
              })}
            </div>
          </>
        )}
      </Sheet>
    </div>
  )
}

// ============================================================================
//  STAFF · QR CODES — /s/{scan_point_id}
// ============================================================================

function QrTab({ event, venue, showToast }) {
  const [points, setPoints] = useState([])
  const [loading, setLoading] = useState(true)
  const [preview, setPreview] = useState(null)
  const [src, setSrc] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase
      .from('scan_points')
      .select('*')
      .eq('event_id', event.id)
      .order('created_at')
    setPoints(data || [])
    setLoading(false)
  }, [event.id])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (!preview) return setSrc('')
    QRCode.toDataURL(scanUrl(preview.id), {
      width: 720,
      margin: 1,
      errorCorrectionLevel: 'M',
      color: { dark: '#1C2A4A', light: '#FFFFFF' },
    }).then(setSrc)
  }, [preview])

  async function addPoint(kind) {
    const { error } = await supabase
      .from('scan_points')
      .insert({ event_id: event.id, kind, label: kind === 'bar' ? 'Bar' : 'Entrée' })
    if (error) return showToast(frError(error), 'error')
    load()
  }

  async function exportAll() {
    setBusy(true)
    try {
      const canvases = []
      for (const p of points) canvases.push(await renderQrPoster(venue, event, p, 1240, 1754))
      const blob = canvasesToPdfBlob(canvases, { quality: 0.95 })
      await shareOrDownload(blob, `noti-qr-${event.id.slice(0, 8)}.pdf`, 'QR codes')
    } catch (e) {
      showToast(frError(e), 'error')
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <Spinner />

  return (
    <div>
      <div style={{ marginBottom: 14 }}>
        <Banner tone="info">
          Phase 1 : un QR à l’<strong>entrée</strong>, un QR au <strong>bar</strong>. Aucun QR sur
          les tables — le service à table arrive en phase 2, sur la même URL.
        </Banner>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <button disabled={busy || !points.length} onClick={exportAll} style={{ ...S.btn, minHeight: 48 }}>
          {busy ? '…' : 'Exporter les affiches (PDF)'}
        </button>
      </div>

      <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
        {points.map((p) => (
          <button
            key={p.id}
            onClick={() => setPreview(p)}
            style={{ ...S.card, padding: 14, display: 'flex', gap: 12, alignItems: 'center', cursor: 'pointer', textAlign: 'left', color: C.text }}
          >
            <div style={{ fontSize: 26 }}>{p.kind === 'bar' ? '🍸' : p.kind === 'table' ? '🪑' : '🚪'}</div>
            <div style={{ flex: 1 }}>
              <div style={{ fontWeight: 500 }}>{p.label || (p.kind === 'bar' ? 'Bar' : 'Entrée')}</div>
              <div style={{ fontSize: 11.5, color: C.faint }}>
                {p.kind === 'bar' ? 'Point bar' : p.kind === 'table' ? `Table ${p.table_number ?? ''}` : 'Point entrée'}
              </div>
            </div>
            <div style={{ color: C.indigo, fontSize: 20 }}>›</div>
          </button>
        ))}
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button onClick={() => addPoint('entrance')} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12 }}>
          + Entrée
        </button>
        <button onClick={() => addPoint('bar')} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12 }}>
          + Bar
        </button>
      </div>

      <Sheet open={!!preview} onClose={() => setPreview(null)} title={preview?.label || 'QR code'}>
        {preview && (
          <>
            <div style={{ textAlign: 'center', marginBottom: 16 }}>
              {src ? (
                <img src={src} alt="" style={{ width: 216, height: 216, borderRadius: 14, background: '#fff', padding: 8 }} />
              ) : (
                <div style={{ height: 216 }} />
              )}
              <div style={{ fontSize: 11, color: C.faint, marginTop: 10, wordBreak: 'break-all' }}>
                {scanUrl(preview.id)}
              </div>
            </div>

            <Field label="Libellé">
              <input
                style={S.input}
                defaultValue={preview.label || ''}
                onBlur={async (e) => {
                  await supabase.from('scan_points').update({ label: e.target.value.trim() || null }).eq('id', preview.id)
                  load()
                }}
              />
            </Field>

            <div style={{ display: 'grid', gap: 8 }}>
              <button
                onClick={async () => {
                  const canvas = await renderQrPoster(venue, event, preview, 1080, 1350)
                  await canvasToPng(canvas, `noti-qr-${preview.kind}.png`, 'QR Noti Calling')
                }}
                style={S.btn}
              >
                Télécharger l’affiche (PNG)
              </button>
              <button
                onClick={() => {
                  navigator.clipboard?.writeText(scanUrl(preview.id))
                  showToast('Lien copié.', 'ok')
                }}
                style={S.btnGhost}
              >
                Copier le lien
              </button>
              {points.length > 1 && (
                <button
                  onClick={async () => {
                    await supabase.from('scan_points').delete().eq('id', preview.id)
                    setPreview(null)
                    load()
                  }}
                  style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
                >
                  Supprimer ce point de scan
                </button>
              )}
            </div>
          </>
        )}
      </Sheet>
    </div>
  )
}

// ============================================================================
//  STAFF · RÉGLAGES
// ============================================================================

function ReglagesTab({ venue, event, session, onReload, showToast }) {
  const [v, setV] = useState(venue)
  const [e, setE] = useState(event)
  const [busy, setBusy] = useState(false)
  const [newEvent, setNewEvent] = useState(false)

  useEffect(() => setV(venue), [venue])
  useEffect(() => setE(event), [event])

  async function save() {
    setBusy(true)
    try {
      const { error: e1 } = await supabase
        .from('venues')
        .update({
          name: v.name?.trim() || venue.name,
          address: v.address || null,
          city: v.city || null,
          phone: v.phone || null,
          siret: v.siret || null,
          tva_number: v.tva_number || null,
        })
        .eq('id', venue.id)
      if (e1) throw e1

      const { error: e2 } = await supabase
        .from('events')
        .update({
          name: e.name?.trim() || event.name,
          default_prep_min: Number(e.default_prep_min) || 1,
          closes_at: e.closes_at || null,
          accept_orders: !!e.accept_orders,
          service_message: e.service_message || null,
          welcome_message: e.welcome_message || null,
          languages: e.languages?.length ? e.languages : ['fr'],
        })
        .eq('id', event.id)
      if (e2) throw e2

      showToast('Réglages enregistrés.', 'ok')
      onReload()
    } catch (err) {
      showToast(frError(err), 'error')
    } finally {
      setBusy(false)
    }
  }

  const toLocalInput = (iso) => {
    if (!iso) return ''
    const d = new Date(iso)
    const off = d.getTimezoneOffset()
    return new Date(d.getTime() - off * 60000).toISOString().slice(0, 16)
  }

  return (
    <div>
      <div style={{ ...S.card, marginBottom: 14 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ fontSize: 24 }}>{e.accept_orders ? '🟢' : '🔴'}</div>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 500 }}>
              {e.accept_orders ? 'Commandes ouvertes' : 'Commandes fermées'}
            </div>
            <div style={{ fontSize: 12, color: C.dim, marginTop: 2 }}>
              {e.accept_orders ? 'Les clients peuvent commander.' : 'Les QR affichent « fermé ».'}
            </div>
          </div>
          <button
            onClick={() => setE({ ...e, accept_orders: !e.accept_orders })}
            style={{
              minHeight: 44,
              padding: '0 16px',
              borderRadius: 12,
              border: 'none',
              cursor: 'pointer',
              fontFamily: FONT.label,
              fontWeight: 600,
              letterSpacing: 0.8,
              fontSize: 12,
              background: e.accept_orders ? C.danger : C.ok,
              color: '#fff',
            }}
          >
            {e.accept_orders ? 'FERMER' : 'OUVRIR'}
          </button>
        </div>
      </div>

      <div style={{ ...S.card, marginBottom: 14 }}>
        <div style={{ ...S.h2, marginBottom: 14 }}>Soirée</div>
        <Field label="Nom">
          <input style={S.input} value={e.name || ''} onChange={(ev) => setE({ ...e, name: ev.target.value })} />
        </Field>
        <Field label={`Temps de préparation par défaut : ${e.default_prep_min} min`}>
          <input
            type="range"
            min={1}
            max={30}
            value={e.default_prep_min || 1}
            onChange={(ev) => setE({ ...e, default_prep_min: Number(ev.target.value) })}
            style={{ width: '100%', accentColor: C.terracotta }}
          />
        </Field>
        <Field label="Heure de fermeture" hint="Déclenche la relance renforcée une heure avant.">
          <input
            style={S.input}
            type="datetime-local"
            value={toLocalInput(e.closes_at)}
            onChange={(ev) => setE({ ...e, closes_at: ev.target.value ? new Date(ev.target.value).toISOString() : null })}
          />
        </Field>
        <Field label="Message d'accueil">
          <input
            style={S.input}
            value={e.welcome_message || ''}
            onChange={(ev) => setE({ ...e, welcome_message: ev.target.value })}
            placeholder="Bienvenue à bord — la soirée démarre !"
          />
        </Field>
        <Field label="Message de service">
          <input
            style={S.input}
            value={e.service_message || ''}
            onChange={(ev) => setE({ ...e, service_message: ev.target.value })}
            placeholder="Happy hour jusqu'à 22 h"
          />
        </Field>
        <Field label="Langues">
          <div style={{ display: 'flex', gap: 8 }}>
            {['fr', 'en', 'es'].map((l) => {
              const on = (e.languages || ['fr']).includes(l)
              return (
                <button
                  key={l}
                  onClick={() =>
                    setE({
                      ...e,
                      languages: on
                        ? (e.languages || []).filter((x) => x !== l || l === 'fr')
                        : [...(e.languages || []), l],
                    })
                  }
                  style={{
                    ...S.chip,
                    flex: 1,
                    minHeight: 44,
                    borderColor: on ? C.terracotta : C.lineHi,
                    color: on ? C.terracotta : C.dim,
                  }}
                >
                  {l.toUpperCase()}
                </button>
              )
            })}
          </div>
        </Field>
      </div>

      <div style={{ ...S.card, marginBottom: 14 }}>
        <div style={{ ...S.h2, marginBottom: 14 }}>Lieu & mentions légales</div>
        <Field label="Nom du lieu">
          <input style={S.input} value={v.name || ''} onChange={(ev) => setV({ ...v, name: ev.target.value })} />
        </Field>
        <Field label="Adresse">
          <input style={S.input} value={v.address || ''} onChange={(ev) => setV({ ...v, address: ev.target.value })} />
        </Field>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label="Ville">
              <input style={S.input} value={v.city || ''} onChange={(ev) => setV({ ...v, city: ev.target.value })} />
            </Field>
          </div>
          <div style={{ flex: 1 }}>
            <Field label="Téléphone">
              <input style={S.input} value={v.phone || ''} onChange={(ev) => setV({ ...v, phone: ev.target.value })} />
            </Field>
          </div>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label="SIRET">
              <input style={S.input} value={v.siret || ''} onChange={(ev) => setV({ ...v, siret: ev.target.value })} />
            </Field>
          </div>
          <div style={{ flex: 1 }}>
            <Field label="N° TVA">
              <input style={S.input} value={v.tva_number || ''} onChange={(ev) => setV({ ...v, tva_number: ev.target.value })} />
            </Field>
          </div>
        </div>
      </div>

      <div style={{ display: 'grid', gap: 8 }}>
        <button disabled={busy} onClick={save} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
          {busy ? '…' : 'Enregistrer'}
        </button>
        <button onClick={() => setNewEvent(true)} style={S.btnGhost}>
          + Nouvelle soirée
        </button>
        <button
          onClick={() => supabase.auth.signOut()}
          style={{ ...S.btnGhost, borderColor: C.danger, color: C.danger }}
        >
          Se déconnecter
        </button>
      </div>

      <div style={{ textAlign: 'center', marginTop: 22, color: C.faint, fontSize: 11, lineHeight: 1.8 }}>
        {session.user.email}
        <br />
        Noti Calling ne traite aucun paiement en ligne.
      </div>

      <NewEventSheet
        open={newEvent}
        venue={venue}
        onClose={() => setNewEvent(false)}
        onCreated={() => {
          setNewEvent(false)
          onReload()
        }}
        showToast={showToast}
      />
    </div>
  )
}

function NewEventSheet({ open, venue, onClose, onCreated, showToast }) {
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)

  return (
    <Sheet open={open} onClose={onClose} title="Nouvelle soirée">
      <div style={{ marginBottom: 14 }}>
        <Banner tone="info">
          La carte du lieu est réutilisée automatiquement. Deux points de scan (entrée + bar) sont
          créés avec de nouveaux QR codes.
        </Banner>
      </div>
      <Field label="Nom">
        <input style={S.input} value={name} onChange={(e) => setName(e.target.value)} placeholder="Noti Calling #2" />
      </Field>
      <button
        disabled={busy || !name.trim()}
        onClick={async () => {
          setBusy(true)
          const { data, error } = await supabase
            .from('events')
            .insert({ venue_id: venue.id, name: name.trim(), default_prep_min: 1 })
            .select()
            .single()
          if (error) {
            setBusy(false)
            return showToast(frError(error), 'error')
          }
          await supabase.from('scan_points').insert([
            { event_id: data.id, kind: 'entrance', label: 'Entrée' },
            { event_id: data.id, kind: 'bar', label: 'Bar' },
          ])
          setBusy(false)
          onCreated()
        }}
        style={{ ...S.btn, opacity: busy || !name.trim() ? 0.5 : 1 }}
      >
        {busy ? '…' : 'Créer'}
      </button>
    </Sheet>
  )
}

// ============================================================================
//  RENDUS CANVAS — affiche QR, ticket bar, fiche de soirée
// ============================================================================

async function renderQrPoster(venue, event, point, W = 1080, H = 1350) {
  const { canvas, ctx } = makeCanvas(W, H, 1)
  const qr = await loadImage(
    await QRCode.toDataURL(scanUrl(point.id), {
      width: 900,
      margin: 1,
      errorCorrectionLevel: 'M',
      color: { dark: '#1C2A4A', light: '#FFFFFF' },
    })
  )

  ctx.fillStyle = '#F7F1E9'
  ctx.fillRect(0, 0, W, H)

  // Cadre terracotta
  const b = Math.round(W * 0.028)
  ctx.fillStyle = '#B96A4C'
  ctx.fillRect(0, 0, W, b)
  ctx.fillRect(0, H - b, W, b)
  ctx.fillRect(0, 0, b, H)
  ctx.fillRect(W - b, 0, b, H)

  ctx.textAlign = 'center'
  ctx.fillStyle = '#B96A4C'
  ctx.font = `700 ${Math.round(W * 0.075)}px "Playfair Display", Georgia, serif`
  ctx.fillText('Noti', W / 2 - W * 0.045, H * 0.105)
  ctx.fillStyle = '#6A5FD6'
  ctx.font = `400 ${Math.round(W * 0.082)}px "Great Vibes", cursive`
  ctx.fillText('Calling', W / 2 + W * 0.07, H * 0.128)

  ctx.fillStyle = '#1C2A4A'
  ctx.font = `500 ${Math.round(W * 0.032)}px Oswald, sans-serif`
  ctx.fillText((event?.name || '').toUpperCase(), W / 2, H * 0.185)

  // QR
  const qs = W * 0.56
  const qx = (W - qs) / 2
  const qy = H * 0.235
  ctx.fillStyle = '#FFFFFF'
  roundRect(ctx, qx - 24, qy - 24, qs + 48, qs + 48, 28)
  ctx.fill()
  if (qr) ctx.drawImage(qr, qx, qy, qs, qs)

  ctx.fillStyle = '#1C2A4A'
  ctx.font = `500 ${Math.round(W * 0.048)}px Oswald, sans-serif`
  ctx.fillText('SCANNEZ POUR COMMANDER', W / 2, qy + qs + W * 0.095)

  ctx.fillStyle = '#5A6480'
  ctx.font = `400 ${Math.round(W * 0.025)}px Jost, sans-serif`
  ctx.fillText('Ouvrez l’appareil photo — aucune application à installer', W / 2, qy + qs + W * 0.145)

  // Bandeau point de scan
  const label = point.label || (point.kind === 'bar' ? 'Bar' : 'Entrée')
  const bw = W * 0.5
  const by = qy + qs + W * 0.19
  const grad = ctx.createLinearGradient(W / 2 - bw / 2, 0, W / 2 + bw / 2, 0)
  grad.addColorStop(0, '#F3B6D8')
  grad.addColorStop(1, '#F4A57A')
  ctx.fillStyle = grad
  roundRect(ctx, W / 2 - bw / 2, by, bw, W * 0.075, 999)
  ctx.fill()
  ctx.fillStyle = '#1C2A4A'
  ctx.font = `500 ${Math.round(W * 0.03)}px Oswald, sans-serif`
  ctx.fillText(label.toUpperCase(), W / 2, by + W * 0.024)

  ctx.fillStyle = '#B96A4C'
  ctx.font = `500 ${Math.round(W * 0.028)}px Oswald, sans-serif`
  ctx.fillText('RÈGLEMENT AU BAR', W / 2, H - W * 0.115)
  ctx.fillStyle = '#98A0B4'
  ctx.font = `400 ${Math.round(W * 0.019)}px Jost, sans-serif`
  ctx.fillText(venue?.name || '', W / 2, H - W * 0.06)
  ctx.textAlign = 'left'

  return canvas
}

/** Ticket bar 80 mm (impression optionnelle, jamais bloquante). */
async function renderTicketCanvas({ venue, event, order }) {
  const W = 576 // 80 mm à 180 dpi
  const H = 1200
  const { canvas, ctx } = makeCanvas(W, H, 1)
  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, W, H)

  ctx.textAlign = 'center'
  ctx.fillStyle = '#000000'
  ctx.font = '700 34px "Playfair Display", Georgia, serif'
  ctx.fillText('Noti Calling', W / 2, 40)
  ctx.font = '400 20px Jost, sans-serif'
  ctx.fillText(event?.name || '', W / 2, 92)
  ctx.fillText(dateFR(order.created_at), W / 2, 122)

  ctx.font = '500 22px Oswald, sans-serif'
  ctx.fillText('CODE DE RETRAIT', W / 2, 178)
  ctx.font = '600 76px Oswald, sans-serif'
  ctx.fillText(order.pickup_code, W / 2, 212)

  ctx.textAlign = 'left'
  let y = 320
  ctx.font = '400 20px Jost, sans-serif'
  ctx.fillText(`${order.customers?.first_name ?? ''} ${order.customers?.last_name ?? ''}`.trim(), 24, y)
  y += 40

  ctx.beginPath()
  ctx.moveTo(24, y)
  ctx.lineTo(W - 24, y)
  ctx.strokeStyle = '#000'
  ctx.lineWidth = 2
  ctx.stroke()
  y += 26

  for (const it of order.order_items || []) {
    ctx.font = '500 22px Jost, sans-serif'
    ctx.fillText(`${it.quantity}× ${it.name_snapshot}`, 24, y)
    ctx.textAlign = 'right'
    ctx.fillText(eur(Number(it.unit_price) * Number(it.quantity)), W - 24, y)
    ctx.textAlign = 'left'
    y += 28
    const extra = [it.variant_label, ...(it.detail?.options || []).map((o) => o.name)].filter(Boolean).join(' · ')
    if (extra) {
      ctx.font = '400 17px Jost, sans-serif'
      ctx.fillText(`   ${extra}`, 24, y)
      y += 24
    }
  }

  y += 12
  ctx.beginPath()
  ctx.moveTo(24, y)
  ctx.lineTo(W - 24, y)
  ctx.stroke()
  y += 34
  ctx.font = '600 30px Oswald, sans-serif'
  ctx.fillText('TOTAL', 24, y)
  ctx.textAlign = 'right'
  ctx.fillText(eur(order.total), W - 24, y)
  ctx.textAlign = 'center'

  if (order.note) {
    y += 46
    ctx.font = '400 18px Jost, sans-serif'
    wrapText(ctx, `Note : ${order.note}`, W - 48, 3).forEach((l, i) => ctx.fillText(l, W / 2, y + i * 24))
    y += 72
  }

  y += 50
  ctx.font = '500 22px Oswald, sans-serif'
  ctx.fillText('À RÉGLER AU BAR', W / 2, y)
  ctx.font = '400 15px Jost, sans-serif'
  ctx.fillText(venue?.name || '', W / 2, y + 34)
  ctx.textAlign = 'left'

  return canvas
}

async function renderReportCanvas({ venue, event, report }) {
  const W = 1240
  const H = 1754
  const { canvas, ctx } = makeCanvas(W, H, 1)
  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, W, H)

  ctx.fillStyle = '#1C2A4A'
  ctx.fillRect(0, 0, W, 150)
  ctx.textAlign = 'left'
  ctx.fillStyle = '#F7F1E9'
  ctx.font = '700 38px "Playfair Display", Georgia, serif'
  ctx.fillText('Noti Calling — fiche de soirée', 70, 52)
  ctx.fillStyle = '#E2C8B8'
  ctx.font = '400 20px Jost, sans-serif'
  ctx.fillText(`${event?.name ?? ''} · ${venue?.name ?? ''}`, 70, 104)

  let y = 230
  const line = (k, v, big) => {
    ctx.fillStyle = '#5A6480'
    ctx.font = '400 21px Jost, sans-serif'
    ctx.fillText(k, 70, y)
    ctx.textAlign = 'right'
    ctx.fillStyle = big ? '#B96A4C' : '#1C2A4A'
    ctx.font = `600 ${big ? 30 : 22}px Jost, sans-serif`
    ctx.fillText(String(v), W - 70, y)
    ctx.textAlign = 'left'
    y += big ? 48 : 38
  }

  line('Commandes', report.orders_total, true)
  line('Chiffre encaissé', eur(report.revenue_paid), true)
  line('Impayé', eur(report.revenue_unpaid))
  line('Panier moyen', eur(report.average_basket))
  line('Personnes présentes', report.headcount)
  line('Nouveaux clients', report.new_customers)
  line('Habitués', report.returning_customers)
  line('Note moyenne', report.rating_avg ? `${report.rating_avg} / 5 (${report.rating_count} avis)` : '—')

  y += 20
  ctx.fillStyle = '#B96A4C'
  ctx.font = '500 24px Oswald, sans-serif'
  ctx.fillText('TOP PRODUITS', 70, y)
  y += 42
  for (const p of (report.top_products || []).slice(0, 12)) {
    ctx.fillStyle = '#1C2A4A'
    ctx.font = '400 21px Jost, sans-serif'
    ctx.fillText(p.name, 70, y)
    ctx.textAlign = 'right'
    ctx.fillText(`${p.qty} · ${eur(p.revenue)}`, W - 70, y)
    ctx.textAlign = 'left'
    y += 32
  }

  if ((report.hourly || []).length) {
    y += 26
    ctx.fillStyle = '#B96A4C'
    ctx.font = '500 24px Oswald, sans-serif'
    ctx.fillText('RÉPARTITION HORAIRE', 70, y)
    y += 34
    const max = Math.max(...report.hourly.map((h) => h.orders))
    for (const h of report.hourly) {
      const bw = ((W - 260) * h.orders) / (max || 1)
      ctx.fillStyle = '#5A6480'
      ctx.font = '400 18px Jost, sans-serif'
      ctx.fillText(h.hour, 70, y)
      ctx.fillStyle = '#F4A57A'
      roundRect(ctx, 150, y - 14, Math.max(bw, 4), 20, 10)
      ctx.fill()
      ctx.fillStyle = '#1C2A4A'
      ctx.fillText(String(h.orders), 150 + Math.max(bw, 4) + 12, y)
      y += 30
      if (y > H - 140) break
    }
  }

  ctx.textAlign = 'center'
  ctx.fillStyle = '#98A0B4'
  ctx.font = '400 15px Jost, sans-serif'
  ctx.fillText(
    'Aucun paiement en ligne — les montants correspondent aux encaissements enregistrés au bar.',
    W / 2,
    H - 70
  )
  ctx.textAlign = 'left'

  return canvas
}


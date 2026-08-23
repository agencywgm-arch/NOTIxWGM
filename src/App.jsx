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
import { supabase, isConfigured, frError, errorKey, BASE_PATH, scanUrl } from './lib/supabase.js'
import { C, S, FONT, GRADIENT, eur, timeFR, dateFR, phoneFR } from './lib/theme.js'
import { dict, useT, trProduct, LANG_LABEL } from './lib/i18n.js'
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

// ---------------------------------------------------------- Défilement glissé
/**
 * `scrollIntoView({ behavior: 'smooth' })` ne suffisait pas : un tap sur une
 * puce de catégorie lançait DEUX défilements lisses à la suite — la page vers
 * la section, puis la barre de puces pour recentrer la puce active. Or le
 * second `scrollIntoView` remonte aussi jusqu'au document et annule le premier
 * en cours : la page arrivait d'un coup, d'où l'impression de saut brusque.
 *
 * On anime donc nous-mêmes, sur un seul axe à la fois, avec une courbe douce
 * et une durée proportionnelle à la distance (la « glissade »).
 */
function glide(read, write, to) {
  const from = read()
  const dist = to - from
  if (Math.abs(dist) < 1) return
  let reduce = false
  try {
    reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  } catch (_) {}
  if (reduce || typeof requestAnimationFrame === 'undefined') {
    write(to)
    return
  }
  const dur = Math.min(900, Math.max(340, Math.abs(dist) * 0.55))
  const t0 = performance.now()
  // easeInOutCubic : départ et arrivée amortis, vitesse au milieu.
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)
  const step = (now) => {
    const t = Math.min(1, (now - t0) / dur)
    write(from + dist * ease(t))
    if (t < 1) requestAnimationFrame(step)
  }
  requestAnimationFrame(step)
}

// ------------------------------------------------------- Bouton « précédent »
/**
 * Retour terrain : depuis la carte, ouvrir l'espace client puis faire
 * « précédent » faisait SORTIR du site — l'outil n'ayant qu'une seule entrée
 * d'historique, le navigateur remontait au site visité avant. Insupportable en
 * pleine soirée : on perdait son panier.
 *
 * Chaque couche qui s'ouvre (feuille modale, onglet secondaire) pose donc une
 * entrée d'historique. « Précédent » la retire et referme la couche ; on ne
 * quitte le site qu'une fois revenu à l'écran d'explication.
 *
 * Si la couche est fermée autrement (croix, tap derrière, validation), on
 * retire nous-mêmes l'entrée posée pour ne pas laisser d'historique fantôme —
 * d'où la comparaison du marqueur avant `history.back()`.
 */
let backGuardSeq = 0

function useBackGuard(active, onBack) {
  const cb = useRef(onBack)
  cb.current = onBack

  useEffect(() => {
    if (!active || typeof window === 'undefined') return
    const mark = ++backGuardSeq
    window.history.pushState({ notiBack: mark }, '')
    const onPop = () => cb.current?.()
    window.addEventListener('popstate', onPop)
    return () => {
      window.removeEventListener('popstate', onPop)
      if (window.history.state?.notiBack === mark) window.history.back()
    }
  }, [active])
}

/** Le conteneur qui défile réellement autour de `el` (null = le document). */
function scrollBoxOf(el) {
  let n = el?.parentElement
  while (n && n !== document.body && n !== document.documentElement) {
    const s = getComputedStyle(n)
    if (/(auto|scroll|overlay)/.test(s.overflowY) && n.scrollHeight - n.clientHeight > 2) return n
    n = n.parentElement
  }
  return null
}

/**
 * Amène `el` en haut de la zone visible, en réservant `offset` pixels pour les
 * en-têtes collants. Fonctionne aussi bien dans la page que dans une feuille
 * (aperçu carte côté staff), d'où la détection du conteneur.
 */
function glideIntoView(el, offset = 0) {
  if (!el) return
  const box = scrollBoxOf(el)
  if (box) {
    const to = box.scrollTop + el.getBoundingClientRect().top - box.getBoundingClientRect().top - offset
    const max = Math.max(0, box.scrollHeight - box.clientHeight)
    glide(
      () => box.scrollTop,
      (v) => {
        box.scrollTop = v
      },
      Math.max(0, Math.min(max, to))
    )
  } else {
    const to = window.scrollY + el.getBoundingClientRect().top - offset
    const max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
    glide(
      () => window.scrollY,
      (v) => window.scrollTo(0, v),
      Math.max(0, Math.min(max, to))
    )
  }
}

/** Recentre une puce dans sa barre horizontale — sans toucher au défilement de la page. */
function glideChipIntoView(chip) {
  const box = chip?.parentElement
  if (!box) return
  const max = Math.max(0, box.scrollWidth - box.clientWidth)
  if (max < 2) return
  const to = chip.offsetLeft - (box.clientWidth - chip.offsetWidth) / 2
  glide(
    () => box.scrollLeft,
    (v) => {
      box.scrollLeft = v
    },
    Math.max(0, Math.min(max, to))
  )
}

/** Réappelle upsert_me() depuis le profil mis en cache sur l'appareil (auto-guérison). */
function upsertMeFromCache() {
  return supabase.rpc('upsert_me', {
    p_first_name: LS.get('noti:firstName', ''),
    p_last_name: LS.get('noti:lastName', ''),
    p_phone: LS.get('noti:phone', ''),
    p_postal_code: LS.get('noti:postalCode', ''),
    p_birthdate: LS.get('noti:birthdate', ''),
    p_email: LS.get('noti:email', '') || null,
    p_instagram: LS.get('noti:instagram', '') || null,
  })
}

const UNIVERSES = [
  { k: 'drinks', t: 'Boissons', en: 'Drinks', es: 'Bebidas', e: '🥂' },
  { k: 'food', t: 'Food', en: 'Food', es: 'Comida', e: '🍽️' },
  { k: 'bottles', t: 'Bouteilles', en: 'Bottles', es: 'Botellas', e: '🍾' },
]

const ORDER_STATUS = {
  RECEIVED: { label: 'Reçue', short: 'Reçue', color: C.indigo, step: 1 },
  IN_PREP: { label: 'En préparation', short: 'En prépa', color: C.warn, step: 2 },
  READY: { label: 'Prête à retirer', short: 'Prête', color: C.terracotta, step: 3 },
  PICKED_UP: { label: 'Retirée', short: 'Retirée', color: C.ok, step: 4 },
  PAID: { label: 'Réglée', short: 'Réglée', color: C.ok, step: 5 },
  UNPAID: { label: 'Impayée', short: 'Impayée', color: C.danger, step: 5 },
  CANCELLED: { label: 'Annulée', short: 'Annulée', color: C.faint, step: 0 },
}

const TAG_LABEL = {
  vip: 'VIP',
  habitue: 'Habitué',
  gros_panier: 'Gros panier',
  incident: 'Incident',
}

// Retraits en retard — seuils communs au bar et à l'organisation, pour que
// les deux écrans racontent la même chose au même moment.
//  · 15 min : la commande est prête mais non retirée → alerte barman + admin.
//  · 20 min : l'organisateur prend le relais et contacte le client.
// (La relance automatique au client, elle, part dès 5 min : Edge Function
//  « reminders ».)
const RELANCE_MIN = 15
const ESCALADE_MIN = 20

/** Minutes écoulées depuis que la commande est prête à être retirée. */
/**
 * Traduit un solde de crédits en langage client. Le barème ne change pas
 * (1 alcool = 2 crédits, 1 soft = 1 crédit) — c'est juste plus parlant que
 * « 6 crédits » quand on regarde son écran au bar.
 */
function creditsAsDrinks(credits, lang = 'fr') {
  const n = Number(credits) || 0
  const d = dict(lang)
  if (n <= 0) return d.creditsEmpty
  const alcools = Math.floor(n / 2)
  if (alcools === 0) return d.nSofts(n)
  const reste = n % 2
  return d.nAlcohols(alcools) + (reste ? d.plusOneSoft : '') + d.orNSofts(n)
}

function waitingMin(order, now = Date.now()) {
  const from = order.ready_at || order.created_at
  if (!from) return 0
  return Math.max(0, Math.floor((now - new Date(from).getTime()) / 60000))
}

// Multilingue FR / EN / ES — le dictionnaire complet du parcours client vit
// dans src/lib/i18n.js (voir useT / dict / trProduct).

const tr = trProduct

// Libellés de statut côté client : mêmes étapes que ORDER_STATUS (qui reste en
// français pour l'espace staff), traduites via le dictionnaire.
const ST_KEY = {
  RECEIVED: 'stReceived',
  IN_PREP: 'stInPrep',
  READY: 'stReady',
  PICKED_UP: 'stPickedUp',
  PAID: 'stPaid',
  UNPAID: 'stUnpaid',
  CANCELLED: 'stCancelled',
}
const ST_SHORT_KEY = { ...ST_KEY, IN_PREP: 'stInPrepShort', READY: 'stReadyShort' }

const statusLabel = (st, lang, short = false) =>
  dict(lang)[(short ? ST_SHORT_KEY : ST_KEY)[st]] || ORDER_STATUS[st]?.label || st

/**
 * Erreur affichée au client, dans SA langue.
 *
 * Retour terrain : « Could not find the function public.upsert_me(...) in the
 * schema cache » s'est retrouvé affiché tel quel à un client au milieu d'une
 * soirée. Un message interne de PostgREST ne doit JAMAIS atteindre l'écran :
 * seules les erreurs métier connues (clés stables, voir errorKey) sont
 * traduites ; tout le reste devient un message générique, le détail partant
 * dans la console pour le diagnostic.
 */
function clientError(e, lang) {
  const d = dict(lang)
  const k = errorKey(e)
  if (k && d['err_' + k]) return d['err_' + k]
  console.error('[Noti] erreur non traduite', e)
  return d.err_generic
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
  const color =
    toast.kind === 'error' ? C.danger
    : toast.kind === 'ok' ? C.ok
    : toast.kind === 'warn' ? C.warn
    : C.indigo
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

function Sheet({ open, onClose, title, children, maxHeight = '88vh', lang = 'fr' }) {
  // Le « précédent » du navigateur ferme la feuille au lieu de quitter le site.
  useBackGuard(open, onClose)
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
          style={{ width: 44, height: 4, borderRadius: 2, background: C.lineHi, margin: '0 auto 14px' }}
        />
        {/* Flèche de retour explicite : la barre grise ci-dessus n'était pas
            comprise comme un moyen de fermer, et le tap « derrière » la feuille
            n'a aucune affordance. */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: title ? 16 : 8 }}>
          <button
            onClick={onClose}
            aria-label={dict(lang).back}
            style={{
              width: 38,
              height: 38,
              flexShrink: 0,
              borderRadius: 12,
              border: `1.5px solid ${C.lineHi}`,
              background: C.paper,
              color: C.text,
              fontSize: 19,
              lineHeight: 1,
              cursor: 'pointer',
            }}
          >
            ‹
          </button>
          {title && <div style={{ ...S.h1, fontSize: 23, flex: 1, minWidth: 0 }}>{title}</div>}
        </div>
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

/**
 * Date de naissance en trois cases JJ / MM / AAAA.
 *
 * Retour terrain : « faire défiler jusqu'aux années 90 est long et pénible ».
 * Le sélecteur natif d'`<input type="date">` s'ouvre sur le mois courant sur
 * mobile — atteindre 1994 demande des dizaines de gestes. Ici on tape huit
 * chiffres, la case suivante prend le relais toute seule.
 *
 * Les jetons `bday-day` / `bday-month` / `bday-year` sont ceux du standard
 * HTML : le remplissage automatique du navigateur continue de fonctionner,
 * comme sur le code postal.
 *
 * La valeur circulante reste au format ISO (AAAA-MM-JJ), celui de la base.
 */
function BirthdateField({ value, onChange, label }) {
  // Les trois cases ont leur propre état : une saisie partielle (« 1 » dans le
  // jour) ne forme pas encore de date, et la remonter au parent effacerait ce
  // que la personne vient de taper.
  const split = (v) => {
    const mt = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || '')
    return mt ? { d: mt[3], m: mt[2], y: mt[1] } : { d: '', m: '', y: '' }
  }
  const [parts, setParts] = useState(() => split(value))

  // Synchronisation descendante seulement : on ne réécrit les cases que si la
  // date reçue diffère de celle qu'elles composent (chargement de la fiche,
  // remplissage automatique du navigateur).
  const joined =
    parts.d.length === 2 && parts.m.length === 2 && parts.y.length === 4
      ? `${parts.y}-${parts.m}-${parts.d}`
      : ''
  useEffect(() => {
    if ((value || '') !== joined) setParts(split(value))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value])

  const dayRef = useRef(null)
  const monthRef = useRef(null)
  const yearRef = useRef(null)

  const { d, m, y } = parts

  const push = (nd, nm, ny) => {
    setParts({ d: nd, m: nm, y: ny })
    if (nd.length === 2 && nm.length === 2 && ny.length === 4) {
      onChange(`${ny}-${nm}-${nd}`)
    } else if (value) {
      // La date était complète et ne l'est plus : le parent doit le savoir,
      // sinon la validation laisserait passer une saisie tronquée.
      onChange('')
    }
  }

  const digits = (v, max) => v.replace(/\D/g, '').slice(0, max)

  const box = {
    ...S.input,
    textAlign: 'center',
    fontVariantNumeric: 'tabular-nums',
    letterSpacing: 1,
  }

  return (
    <Field label={label}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <input
          ref={dayRef}
          style={{ ...box, width: 62 }}
          inputMode="numeric"
          autoComplete="bday-day"
          placeholder="JJ"
          maxLength={2}
          value={d}
          onChange={(e) => {
            const v = digits(e.target.value, 2)
            push(v, m, y)
            // Deux chiffres saisis : on passe au mois sans que le doigt bouge.
            if (v.length === 2) monthRef.current?.focus()
          }}
        />
        <span style={{ color: C.faint }}>/</span>
        <input
          ref={monthRef}
          style={{ ...box, width: 62 }}
          inputMode="numeric"
          autoComplete="bday-month"
          placeholder="MM"
          maxLength={2}
          value={m}
          onChange={(e) => {
            const v = digits(e.target.value, 2)
            push(d, v, y)
            if (v.length === 2) yearRef.current?.focus()
          }}
          onKeyDown={(e) => {
            if (e.key === 'Backspace' && !m) dayRef.current?.focus()
          }}
        />
        <span style={{ color: C.faint }}>/</span>
        <input
          ref={yearRef}
          style={{ ...box, flex: 1, minWidth: 84 }}
          inputMode="numeric"
          autoComplete="bday-year"
          placeholder="AAAA"
          maxLength={4}
          value={y}
          onChange={(e) => push(d, m, digits(e.target.value, 4))}
          onKeyDown={(e) => {
            if (e.key === 'Backspace' && !y) monthRef.current?.focus()
          }}
        />
      </div>
    </Field>
  )
}

/**
 * Rappel « complétez votre profil ». Volontairement absent de la carte : il
 * s'affiche dans Messages et dans l'espace client, où l'on vient déjà pour
 * gérer sa fiche. `onOpen` absent = on est déjà dans l'espace client, le
 * rappel n'a plus de lien où renvoyer.
 */
function ProfileReminder({ customer, lang, onOpen }) {
  const t = useT(lang)
  const missing = [
    !customer?.postal_code && t.fPostal,
    !customer?.birthdate && t.fBirth,
    !customer?.email && t.fEmail,
    !customer?.instagram && t.fInstagram,
  ].filter(Boolean)
  if (!customer || missing.length === 0) return null

  return (
    <div style={{ marginBottom: 14 }}>
      <Banner tone="info">
        <div style={{ lineHeight: 1.55 }}>
          <strong>{t.completeProfile}</strong>
          <br />
          {missing.join(', ')}
          {onOpen && (
            <>
              {' — '}
              <button
                onClick={onOpen}
                style={{
                  background: 'none',
                  border: 'none',
                  padding: 0,
                  color: C.indigo,
                  fontWeight: 600,
                  cursor: 'pointer',
                  fontSize: 'inherit',
                  textAlign: 'left',
                }}
              >
                {t.goToAccount}
              </button>
            </>
          )}
        </div>
      </Banner>
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
function PayAtBar({ compact = false, lang = 'fr' }) {
  const t = useT(lang)
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
        {t.payTitle}
      </div>
      {!compact && (
        <div style={{ fontSize: 12.5, color: C.dim, marginTop: 5, lineHeight: 1.5 }}>{t.paySub}</div>
      )}
    </div>
  )
}

// ============================================================================
//  RACINE
// ============================================================================

// Filet de sécurité : sans ça, la moindre exception pendant un rendu fait
// disparaître toute l'app (page blanche silencieuse, invisible à distance).
// On affiche l'erreur à l'écran pour qu'elle soit au moins signalable.
class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props)
    this.state = { error: null }
  }
  static getDerivedStateFromError(error) {
    return { error }
  }
  componentDidCatch(error, info) {
    console.error('[Noti] crash', error, info)
  }
  render() {
    if (!this.state.error) return this.props.children
    return (
      <div style={{ ...S.page, padding: 24, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <Keyframes />
        <div style={{ textAlign: 'center', marginBottom: 22 }}>
          <Logo />
        </div>
        <div style={S.card}>
          <div style={{ ...S.h1, fontSize: 20, marginBottom: 10 }}>Un problème est survenu</div>
          <p style={{ color: C.dim, fontSize: 13.5, lineHeight: 1.6, marginBottom: 14 }}>
            L’application a rencontré une erreur inattendue. Réessayez ; si ça persiste, envoyez
            une capture de ce message.
          </p>
          <div
            style={{
              background: 'rgba(192,57,43,.07)',
              border: `1px solid ${C.danger}55`,
              borderRadius: 12,
              padding: 12,
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: C.danger,
              marginBottom: 16,
              wordBreak: 'break-word',
              maxHeight: 160,
              overflowY: 'auto',
            }}
          >
            {String(this.state.error?.message || this.state.error)}
          </div>
          <button onClick={() => window.location.reload()} style={S.btn}>
            Recharger la page
          </button>
        </div>
      </div>
    )
  }
}

export default function App() {
  return (
    <ErrorBoundary>
      <AppInner />
    </ErrorBoundary>
  )
}

function AppInner() {
  const route = useRoute()
  const scanPointId = parseScanRoute(route)
  const [session, setSession] = useState(undefined)
  const [recovery, setRecovery] = useState(false)

  useEffect(() => {
    if (!isConfigured) return
    supabase.auth.getSession().then(({ data }) => setSession(data.session ?? null))
    const { data } = supabase.auth.onAuthStateChange((event, s) => {
      setSession(s ?? null)
      // Supabase ouvre une session temporaire quand on suit le lien reçu par
      // e-mail : on intercepte cet événement pour proposer un nouveau mot de
      // passe avant de laisser entrer dans l'espace équipe.
      if (event === 'PASSWORD_RECOVERY') setRecovery(true)
    })
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
  if (recovery) return <ResetPasswordScreen onDone={() => setRecovery(false)} />
  if (scanPointId) return <ClientApp scanPointId={scanPointId} session={session} />
  return session ? <StaffApp session={session} /> : <StaffLogin />
}

function ResetPasswordScreen({ onDone }) {
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [done, setDone] = useState(false)

  async function submit(e) {
    e.preventDefault()
    setErr('')
    if (password.length < 6) return setErr('6 caractères minimum.')
    if (password !== confirm) return setErr('Les deux mots de passe ne correspondent pas.')
    setBusy(true)
    const { error } = await supabase.auth.updateUser({ password })
    setBusy(false)
    if (error) return setErr(frError(error))
    setDone(true)
  }

  return (
    <div style={{ ...S.page, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 22 }}>
      <Keyframes />
      <div style={{ width: '100%', maxWidth: 420 }}>
        <div style={{ textAlign: 'center', marginBottom: 26 }}>
          <Logo size={1.2} />
          <div style={{ ...S.label, marginTop: 18, marginBottom: 0, letterSpacing: 2.4 }}>
            Nouveau mot de passe
          </div>
        </div>

        <div style={S.card}>
          {done ? (
            <>
              <div style={{ marginBottom: 16 }}>
                <Banner tone="ok">Mot de passe mis à jour.</Banner>
              </div>
              <button onClick={onDone} style={S.btn}>
                Continuer vers l’espace équipe
              </button>
            </>
          ) : (
            <form onSubmit={submit}>
              <Field label="Nouveau mot de passe">
                <input
                  style={S.input}
                  type="password"
                  required
                  minLength={6}
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  autoFocus
                />
              </Field>
              <Field label="Confirmer le mot de passe">
                <input
                  style={S.input}
                  type="password"
                  required
                  minLength={6}
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                />
              </Field>

              {err && (
                <div style={{ marginBottom: 12 }}>
                  <Banner tone="danger">{err}</Banner>
                </div>
              )}

              <button type="submit" disabled={busy} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
                {busy ? '…' : 'Enregistrer'}
              </button>
            </form>
          )}
        </div>
      </div>
    </div>
  )
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
  // welcome : premier passage · identify : formulaire · hello : reconnaissance
  // app : la carte · intro : l'écran d'explication rouvert depuis le logo, sans
  // ressaisie (retour terrain : « en cas de bug ou de perte de repère, on
  // clique sur le logo et on repart d'une base saine »).
  const [step, setStep] = useState('welcome')
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
        if (!sp.events || !sp.events.venues) throw new Error('scan_point_orphan')
        if (dead) return
        setScanPoint(sp)
        setEvent(sp.events)
        setVenue(sp.events.venues)
        if (sp.events?.languages?.length && !sp.events.languages.includes(lang)) {
          setLang(sp.events.languages[0])
        }
      } catch (e) {
        if (!dead) setFatal(clientError(e, lang))
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

  // ---- Entrée dans la carte : enregistre la présence puis ouvre l'app ------
  const enterApp = useCallback(async () => {
    try {
      await supabase.rpc('register_scan', { p_scan_point: scanPointId, p_group_size: 1 })
    } catch (e) {
      // Session valide mais fiche client absente côté serveur (rare : stockage
      // local restauré sans la ligne customers correspondante) — on la recrée
      // puis on retente une fois avant d'abandonner.
      if (String(e?.message || '').includes('not_a_customer')) {
        await upsertMeFromCache()
        await loadCustomer()
        await supabase.rpc('register_scan', { p_scan_point: scanPointId, p_group_size: 1 })
      } else {
        throw e
      }
    }
    setStep('app')
  }, [scanPointId, loadCustomer])

  // ---- Aiguillage du parcours ---------------------------------------------
  // Session persistante (retour terrain) : un appareil déjà identifié ne
  // repasse JAMAIS par le formulaire — il entre directement dans la carte, la
  // présence étant enregistrée au passage. Re-saisir ses coordonnées à chaque
  // venue faisait lâcher les clients, donc perdre la donnée.
  const autoEntered = useRef(false)
  useEffect(() => {
    if (loading || fatal) return
    if (!session?.user || !customer) {
      autoEntered.current = false
      setStep((s) => (s === 'welcome' || s === 'identify' ? s : 'welcome'))
      return
    }
    if (step === 'welcome' && !autoEntered.current) {
      autoEntered.current = true
      enterApp().catch((e) => {
        autoEntered.current = false
        showToast(clientError(e, lang), 'error')
      })
    }
  }, [loading, fatal, session, customer, step, enterApp, showToast, lang])

  // L'écran d'explication rouvert depuis le logo est une couche : « précédent »
  // y renvoie à la carte au lieu de quitter le site.
  useBackGuard(step === 'intro', () => setStep('app'))

  if (loading)
    return (
      <div style={S.page}>
        <Spinner label={dict(lang).opening} />
      </div>
    )

  if (fatal)
    return (
      <div style={{ ...S.page, padding: 24 }}>
        <Keyframes />
        <Empty emoji="🚫" title={dict(lang).unknownQr} sub={fatal} />
      </div>
    )

  const shared = { event, venue, scanPoint, lang, setLang, showToast }

  if (step === 'welcome') {
    // Appareil déjà identifié : l'effet d'aiguillage nous emmène directement
    // dans la carte — on évite de faire clignoter l'accueil au passage.
    if (session?.user && customer)
      return (
        <div style={S.page}>
          <Spinner label={dict(lang).backSoon} />
        </div>
      )
    return <WelcomeScreen {...shared} onStart={() => setStep('identify')} />
  }

  // Écran d'explication rouvert depuis le logo : le client est déjà identifié
  // et déjà compté présent, on le renvoie donc directement dans la carte.
  // « Précédent » y ramène aussi, plutôt que de quitter le site.
  if (step === 'intro')
    return <WelcomeScreen {...shared} onStart={() => setStep('app')} backToMenu />

  if (step === 'identify')
    return (
      <IdentifyScreen
        {...shared}
        onVerified={async () => {
          await loadCustomer()
          setStep('hello')
        }}
      />
    )

  // Écran de reconnaissance : uniquement au tout premier passage sur
  // l'appareil (juste après l'identification). Les venues suivantes entrent
  // directement dans la carte.
  if (step === 'hello')
    return <RecognitionScreen {...shared} customer={customer} onEnter={enterApp} />


  return (
    <>
      <OrderingApp
        {...shared}
        customer={customer}
        onReloadCustomer={loadCustomer}
        onHome={() => setStep('intro')}
      />
      <Toast toast={toast} />
    </>
  )
}

// ------------------------------------------------------------------ Accueil
function WelcomeScreen({ event, venue, scanPoint, lang, setLang, onStart, backToMenu = false }) {
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

      {/* Retour terrain : le nom du lieu au-dessus du logo faisait doublon, et
          le badge du point de scan (« Entrée », « Point bar ») est une donnée
          d'exploitation dont le client n'a pas besoin. On garde « Noti
          Calling », la soirée et son horaire. */}
      <div style={{ textAlign: 'center', marginBottom: 30 }}>
        <div style={{ marginBottom: 22 }}>
          <Logo size={1.5} />
        </div>
        <h1 style={{ ...S.h1, fontSize: 34 }}>{event?.name}</h1>
        {event?.starts_at && (
          <div style={{ color: C.dim, fontSize: 13.5, marginTop: 8 }}>
            {dateFR(event.starts_at)}
            {event.closes_at ? ` → ${timeFR(event.closes_at)}` : ''}
          </div>
        )}
      </div>

      {event?.welcome_message && (
        <div style={{ marginBottom: 16 }}>
          <Banner tone="info">{event.welcome_message}</Banner>
        </div>
      )}

      {closed ? (
        <>
          <Banner tone="warn">{event?.service_message || t.ordersClosed}</Banner>
          {/* Commandes fermées : sans ce bouton, un client venu par le logo
              resterait bloqué sur cet écran. La carte reste consultable. */}
          {backToMenu && (
            <button onClick={onStart} style={{ ...S.btnGhost, marginTop: 16 }}>
              {t.seeMenu}
            </button>
          )}
        </>
      ) : (
        <>
          {/* Levée d'ambiguïté (retour terrain) : plusieurs personnes ont cru
              qu'on ne pouvait plus commander du tout, ou seulement des
              bouteilles à table — et faisaient malgré tout la queue au bar. */}
          <div style={{ marginBottom: 16 }}>
            <Banner tone="info">
              <strong>{t.allMenuHere}</strong>{' '}
              {t.noQueue(t.noQueueStrong, t.noQueueBottles)}
            </Banner>
          </div>

          <div style={{ ...S.card, marginBottom: 16 }}>
            <div style={{ display: 'grid', gap: 14 }}>
              {[
                { n: '1', t: t.step1t, s: t.step1s },
                // Le vrai bénéfice de l'outil, mis en avant : on ne surveille
                // plus le bar, c'est le bar qui prévient.
                { n: '2', t: t.step2t, s: t.step2s, key: true },
                { n: '3', t: t.step3t, s: t.step3s },
                { n: '4', t: t.step4t, s: t.step4s },
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
                    <div
                      style={{
                        fontSize: 12,
                        color: s.key ? C.terracotta : C.dim,
                        fontWeight: s.key ? 600 : 400,
                      }}
                    >
                      {s.s}
                    </div>
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
            {backToMenu ? t.seeMenu : t.start}
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
              {LANG_LABEL[l] || l.toUpperCase()}
            </button>
          ))}
        </div>
      )}

      <div style={{ marginTop: 22 }}>
        <PayAtBar lang={lang} />
      </div>
    </div>
  )
}

// ------------------------------------------------------------ Identification
// Une session anonyme Supabase (aucun SMS, aucun compte) porte la fiche client.
// Obligatoire : prénom, nom, téléphone, code postal, date de naissance — le
// fichier client attendu par l'établissement. E-mail et Instagram restent
// optionnels : le client peut les compléter plus tard depuis son espace
// client (voir ClientProfileSheet), avec un rappel s'ils manquent.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

/**
 * Une date saisie à la main peut être absurde (31/02, année 0012, demain).
 * Le serveur refuse déjà les dates futures ; ici on le dit avant l'aller-retour.
 */
function birthdateIsValid(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || '')
  if (!m) return false
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])]
  if (y < 1900 || mo < 1 || mo > 12 || d < 1 || d > 31) return false
  const dt = new Date(Date.UTC(y, mo - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return false
  return dt.getTime() <= Date.now()
}

function IdentifyScreen({ lang, onVerified }) {
  const t = useT(lang)
  const [firstName, setFirstName] = useState(LS.get('noti:firstName', ''))
  const [lastName, setLastName] = useState(LS.get('noti:lastName', ''))
  const [phone, setPhone] = useState(LS.get('noti:phone', ''))
  const [postalCode, setPostalCode] = useState(LS.get('noti:postalCode', ''))
  const [birthdate, setBirthdate] = useState(LS.get('noti:birthdate', ''))
  const [email, setEmail] = useState(LS.get('noti:email', ''))
  const [instagram, setInstagram] = useState(LS.get('noti:instagram', ''))
  const [showOptional, setShowOptional] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  async function submit() {
    setErr('')
    if (!firstName.trim() || !lastName.trim()) return setErr(t.errNames)
    if (!phone.trim()) return setErr(t.errPhone)
    if (!postalCode.trim()) return setErr(t.errPostal)
    if (!birthdate) return setErr(t.errBirth)
    if (!birthdateIsValid(birthdate)) return setErr(t.errBirthInvalid)
    if (email.trim() && !EMAIL_RE.test(email.trim())) return setErr(t.errEmail)
    setBusy(true)
    try {
      const { data } = await supabase.auth.getSession()
      if (!data.session) {
        const { error } = await supabase.auth.signInAnonymously()
        if (error) throw error
      }
      const { error: e2 } = await supabase.rpc('upsert_me', {
        p_first_name: firstName.trim(),
        p_last_name: lastName.trim(),
        p_phone: phone.trim(),
        p_postal_code: postalCode.trim(),
        p_birthdate: birthdate,
        p_email: email.trim() || null,
        p_instagram: instagram.trim() || null,
      })
      if (e2) throw e2
      LS.set('noti:firstName', firstName)
      LS.set('noti:lastName', lastName)
      LS.set('noti:phone', phone)
      LS.set('noti:postalCode', postalCode)
      LS.set('noti:birthdate', birthdate)
      LS.set('noti:email', email)
      LS.set('noti:instagram', instagram)
      await onVerified()
    } catch (e) {
      setErr(clientError(e, lang))
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
          {t.identifySub}
        </div>
      </div>

      <div style={S.card}>
        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label={t.firstName}>
              <input
                style={S.input}
                value={firstName}
                onChange={(e) => setFirstName(e.target.value)}
                autoComplete="given-name"
                placeholder="Alex"
                autoFocus
              />
            </Field>
          </div>
          <div style={{ flex: 1 }}>
            <Field label={t.lastName}>
              <input
                style={S.input}
                value={lastName}
                onChange={(e) => setLastName(e.target.value)}
                autoComplete="family-name"
                placeholder="Martin"
              />
            </Field>
          </div>
        </div>

        <Field label={t.phone}>
          <input
            style={S.input}
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            autoComplete="tel"
            placeholder="06 12 34 56 78"
          />
        </Field>

        <div style={{ display: 'flex', gap: 10 }}>
          <div style={{ flex: 1 }}>
            <Field label={t.postalCode}>
              <input
                style={S.input}
                inputMode="numeric"
                value={postalCode}
                onChange={(e) => setPostalCode(e.target.value)}
                autoComplete="postal-code"
                placeholder="75011"
              />
            </Field>
          </div>
          <div style={{ flex: 1.35 }}>
            <BirthdateField label={t.birthdate} value={birthdate} onChange={setBirthdate} />
          </div>
        </div>

        {showOptional ? (
          <>
            <Field label={t.email} hint={t.optional}>
              <input
                style={S.input}
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && submit()}
                autoComplete="email"
                placeholder="alex@exemple.fr"
              />
            </Field>
            <Field label={t.instagram} hint={t.optional}>
              <input
                style={S.input}
                value={instagram}
                onChange={(e) => setInstagram(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && submit()}
                placeholder="@alex"
              />
            </Field>
          </>
        ) : (
          <button
            onClick={() => setShowOptional(true)}
            style={{
              background: 'none',
              border: 'none',
              padding: 0,
              marginBottom: 16,
              cursor: 'pointer',
              color: C.indigo,
              fontSize: 13,
              fontWeight: 600,
            }}
          >
            {t.addOptional}
          </button>
        )}

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
        {t.cgu}
        <br />
        {t.dataEu}
      </div>
    </div>
  )
}

// ------------------------------------------------------ Reconnaissance client
function RecognitionScreen({ lang, customer, event, onEnter, showToast }) {
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
            ? t.gladToSeeYou
            : returning
              ? t.backAgain
              : `${t.welcome}, ${customer?.first_name || ''}`}
        </h1>
        {returning && !incident && (
          <div style={{ color: C.dim, fontSize: 14, marginTop: 10, lineHeight: 1.6 }}>
            {customer.events_count === 1 ? t.secondNight : t.nNights(customer.events_count)}
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
              {t.vipStatus}
            </span>
          </div>
        )}
      </div>

      {incident && (
        <div style={{ marginBottom: 16 }}>
          <Banner tone="warn">{t.unpaidPast}</Banner>
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
          try {
            await onEnter()
          } catch (e) {
            showToast?.(clientError(e, lang), 'error')
          } finally {
            setBusy(false)
          }
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

function OrderingApp({ event, venue, scanPoint, lang, setLang, customer, showToast, onReloadCustomer, onHome }) {
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
  const [profileOpen, setProfileOpen] = useState(false)
  const profileIncomplete =
    !customer?.email || !customer?.instagram || !customer?.postal_code || !customer?.birthdate
  const [pass, setPass] = useState(null)
  const [gifts, setGifts] = useState([])
  // Code % / montant classique — saisi une seule fois (même emplacement que
  // le forfait), réappliqué automatiquement à chaque commande tant qu'il
  // n'est pas retiré. Persisté par soirée : survit à un rechargement de page.
  const [promoCode, setPromoCode] = useState(() => LS.get(`noti:promo:${event?.id}`, '') || '')
  const lastReady = useRef(new Set())

  useEffect(() => {
    if (event?.id) LS.set(`noti:promo:${event.id}`, promoCode)
  }, [event?.id, promoCode])

  const loadPass = useCallback(async () => {
    if (!event?.id || !customer?.id) return
    const { data } = await supabase
      .from('event_passes')
      .select('*')
      .eq('event_id', event.id)
      .eq('customer_id', customer.id)
      .maybeSingle()
    setPass(data || null)
  }, [event?.id, customer?.id])

  // Cadeaux qu'il reste au client sur cette soirée (« 1 boisson offerte »).
  const loadGifts = useCallback(async () => {
    if (!event?.id || !customer?.id) return
    const { data } = await supabase.rpc('my_gift_summary', { p_event: event.id })
    setGifts(Array.isArray(data) ? data : [])
  }, [event?.id, customer?.id])

  useEffect(() => {
    loadPass()
    loadGifts()
  }, [loadPass, loadGifts])

  // ---- Explication des crédits, une fois par soirée ------------------------
  // Retour terrain : le barème était expliqué à l'oral, encore et encore. On le
  // dit une seule fois, au bon moment — à l'arrivée sur la carte, et seulement
  // si la personne a réellement des crédits (pass ou code cadeau). Le drapeau
  // reste sur l'appareil : pas de rappel à chaque rechargement de page.
  const [creditsIntro, setCreditsIntro] = useState(false)
  const creditsTotal =
    (pass?.credits_remaining || 0) + gifts.reduce((n, g) => n + (Number(g.remaining) || 0), 0)

  useEffect(() => {
    if (!event?.id || creditsTotal <= 0) return
    const seen = LS.get(`noti:creditsIntro:${event.id}`, false)
    if (!seen) {
      setCreditsIntro(true)
      LS.set(`noti:creditsIntro:${event.id}`, true)
    }
  }, [event?.id, creditsTotal])

  async function convertFoodToken() {
    const { data, error } = await supabase.rpc('convert_food_token', { p_event: event.id })
    if (error) throw error
    setPass(data)
  }

  /**
   * Saisie unifiée : un seul champ pour un code cadeau (article offert), un
   * code forfait (crédits) ou un code promo classique (% / montant). On essaie
   * chaque type dans l'ordre ; le client n'a pas à savoir lequel il détient.
   */
  async function redeemCode(code) {
    // 1. Code cadeau — « une boisson alcoolisée offerte »
    const gift = await supabase.rpc('redeem_gift_code', { p_event: event.id, p_code: code })
    if (!gift.error) {
      await loadGifts()
      return { kind: 'gift', info: gift.data }
    }
    if (!String(gift.error.message || '').includes('invalid_gift_code')) throw gift.error

    // 2. Forfait de groupe à crédits
    const { data, error } = await supabase.rpc('redeem_pass', { p_event: event.id, p_code: code })
    if (!error) {
      setPass(data)
      return { kind: 'credits' }
    }
    if (!String(error.message || '').includes('invalid_pass_code')) throw error

    const { data: check, error: checkErr } = await supabase.rpc('validate_promo_code', {
      p_event: event.id,
      p_code: code,
    })
    if (checkErr) throw checkErr
    if (!check?.valid) throw new Error('invalid_pass_code')

    setPromoCode(code.trim().toUpperCase())
    return { kind: 'promo', info: check }
  }

  function clearCode() {
    setPromoCode('')
  }

  // ---- Chargement ---------------------------------------------------------
  const loadOrders = useCallback(async () => {
    const { data } = await supabase
      .from('orders')
      .select('*, order_items ( * )')
      .eq('event_id', event?.id)
      .eq('customer_id', customer?.id)
      .order('created_at', { ascending: false })
    setOrders(data || [])
  }, [event?.id, customer?.id])

  const loadMessages = useCallback(async () => {
    const { data } = await supabase
      .from('messages')
      .select('*')
      .eq('event_id', event?.id)
      .order('created_at', { ascending: false })
      .limit(20)
    setMessages(data || [])
  }, [event?.id])

  const loadProducts = useCallback(async () => {
    if (!venue?.id) return
    const { data } = await supabase
      .from('products')
      .select('*')
      .eq('venue_id', venue.id)
      .eq('is_listed', true)
      .order('universe')
      .order('sort_order')
    setProducts(data || [])
  }, [venue?.id])

  useEffect(() => {
    if (!venue?.id) return
    let dead = false
    ;(async () => {
      await loadProducts()
      if (dead) return
      await loadOrders()
      await loadMessages()
      setLoading(false)
    })()
    return () => {
      dead = true
    }
  }, [venue?.id, loadProducts, loadOrders, loadMessages])

  // ---- Temps réel (WebSocket) + repli en polling doux ---------------------
  useEffect(() => {
    if (!customer?.id || !event?.id) return
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
      // Rupture de stock : dès que le bar bascule un article en « épuisé », la
      // carte du client se met à jour sans rechargement (l'article reste
      // visible mais devient non commandable).
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'products', filter: `venue_id=eq.${venue?.id}` },
        () => loadProducts()
      )
      .subscribe()

    const poll = setInterval(() => {
      loadOrders()
      loadMessages()
      loadProducts()
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
  }, [customer?.id, event?.id, venue?.id, loadOrders, loadMessages, loadProducts])

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
  const activeOrders = orders.filter((o) => ['RECEIVED', 'IN_PREP', 'READY'].includes(o.status))
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

  // ---- Défilement continu : chaque catégorie s'enchaîne, la puce active se
  // repère automatiquement selon la section visible (pas besoin de cliquer). --
  const sectionRefs = useRef({})
  const chipRefs = useRef({})
  // Pendant le défilement déclenché par un tap, l'observateur est neutralisé :
  // sinon les sections traversées en chemin réécrivaient la puce active et
  // celle-ci restait bloquée sur la catégorie précédente.
  const scrollLock = useRef(0)

  // Hauteur réelle des bandeaux collants (en-tête + barre de puces) : elle sert
  // à poser la section juste sous eux. Mesurée plutôt que codée en dur, sinon
  // le titre de section finissait caché derrière l'en-tête.
  const headerRef = useRef(null)
  const chipsBarRef = useRef(null)
  const [headerH, setHeaderH] = useState(64)

  useEffect(() => {
    const el = headerRef.current
    if (!el) return
    const measure = () => setHeaderH(el.offsetHeight || 64)
    measure()
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(measure) : null
    ro?.observe(el)
    window.addEventListener('resize', measure)
    return () => {
      ro?.disconnect()
      window.removeEventListener('resize', measure)
    }
  }, [])

  useEffect(() => {
    const els = subcats.map((c) => sectionRefs.current[c]).filter(Boolean)
    if (!els.length) return
    const io = new IntersectionObserver(
      (entries) => {
        if (Date.now() < scrollLock.current) return
        const hit = entries.filter((e) => e.isIntersecting)
        if (hit.length) {
          const top = hit.reduce((a, b) => (a.boundingClientRect.top < b.boundingClientRect.top ? a : b))
          setSubcat(top.target.dataset.subcat)
        }
      },
      { rootMargin: `-${headerH + 56}px 0px -75% 0px`, threshold: 0 }
    )
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [subcats, headerH])

  // La puce active est ramenée dans la zone visible de la barre horizontale.
  useEffect(() => {
    if (!subcat) return
    glideChipIntoView(chipRefs.current[subcat])
  }, [subcat])

  // Changer d'onglet ramène en haut : sinon on arrivait au milieu de la page,
  // à la hauteur où l'on avait laissé la carte.
  useEffect(() => {
    window.scrollTo({ top: 0, behavior: 'auto' })
  }, [view])

  // « Précédent » depuis Mes commandes ou Messages revient à la carte, il ne
  // quitte pas l'outil.
  useBackGuard(view !== 'menu', () => setView('menu'))

  function goToSubcat(c) {
    // On marque la puce tout de suite : le retour visuel ne dépend plus de
    // l'arrivée effective de la section dans la fenêtre d'observation (une
    // section courte en fin de carte pouvait ne jamais l'atteindre).
    scrollLock.current = Date.now() + 1100
    setSubcat(c)
    const stuck = headerH + (chipsBarRef.current?.offsetHeight || 52)
    glideIntoView(sectionRefs.current[c], stuck + 10)
  }

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

  async function submitOrder({ note }) {
    const items = cart.map((l) => ({
      product_id: l.product.id,
      quantity: l.quantity,
      variant_id: l.variantId,
      options: l.options.map((o) => ({ id: o.id, name: o.name, price: o.price })),
    }))

    const place = () =>
      supabase.rpc('place_order', {
        p_event: event.id,
        p_scan_point: scanPoint.id,
        p_items: items,
        p_note: note || null,
        p_promo: promoCode || null,
      })

    let { data, error } = await place()
    if (error && String(error.message || '').includes('not_a_customer')) {
      // Session valide mais fiche client absente côté serveur — on la
      // recrée (même profil que la dernière identification) puis on retente.
      await upsertMeFromCache()
      await onReloadCustomer?.()
      ;({ data, error } = await place())
    }
    if (error) throw error

    // Le serveur ignore silencieusement un code invalide plutôt que de bloquer
    // la commande (canal dégradé) — on prévient quand même le client ici.
    // data.promo_code n'est renseigné par place_order() QUE si le code % /
    // montant a réellement été reconnu et appliqué (indépendant du forfait).
    if (promoCode && !data?.promo_code) {
      showToast(t.codeNotApplied, 'error')
    }

    setCart([])
    setCartCheckout(false)
    setCartOpen(false)
    setView('orders')
    await loadOrders()

    await loadGifts()

    if (pass) {
      const hadCredits = pass.credits_remaining > 0
      const { data: fresh } = await supabase
        .from('event_passes')
        .select('*')
        .eq('id', pass.id)
        .maybeSingle()
      setPass(fresh || pass)
      if (hadCredits && fresh && fresh.credits_remaining === 0) {
        showToast(t.creditsExhausted, 'error')
      }
    }

    // Notification de statut « commande reçue » (best-effort).
    notify({
      eventId: event?.id,
      kind: 'status',
      customerId: customer?.id,
      orderId: data?.id,
      title: t.notifReceivedTitle,
      body: t.notifReceivedBody(data?.pickup_code),
    })
    return data
  }

  if (loading)
    return (
      <div style={S.page}>
        <Spinner label={t.loadingMenu} />
      </div>
    )

  const unread = messages.filter((m) => m.kind !== 'status' && !m.read_at)
  const urgentUnread = unread.filter((m) => m.urgent)

  return (
    <div style={{ ...S.page, paddingBottom: 110 }}>
      <Keyframes />

      {/* En-tête : le logo et l'espace client sur la première ligne, la
          navigation sur la seconde. Avant, un seul bouton basculait entre
          « La carte » et « Mes commandes » : depuis les annonces, il affichait
          « Mes commandes » et il fallait deux taps pour revenir à la carte.
          Les trois destinations sont désormais toujours visibles, et celle où
          l'on se trouve est marquée. */}
      <div
        ref={headerRef}
        style={{
          position: 'sticky',
          top: 0,
          zIndex: 50,
          background: `${C.cream}f2`,
          backdropFilter: 'blur(10px)',
          borderBottom: `1px solid ${C.line}`,
          padding: '12px 16px 10px',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          {/* Le logo ramène à l'écran d'explication, sans ressaisie : c'est le
              réflexe attendu quand on est perdu ou qu'un affichage a déraillé. */}
          <button
            onClick={() => onHome?.()}
            aria-label={t.backHome}
            title={t.backHome}
            style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}
          >
            <Logo size={0.72} />
          </button>
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
              onClick={() => setProfileOpen(true)}
              title={t.myAccount}
              style={{
                ...S.chip,
                width: 40,
                minHeight: 0,
                height: 40,
                padding: 0,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 16,
                position: 'relative',
                borderColor: profileIncomplete ? C.terracotta : C.lineHi,
              }}
            >
              👤
              {profileIncomplete && (
                <span
                  style={{
                    position: 'absolute',
                    top: -3,
                    right: -3,
                    width: 11,
                    height: 11,
                    borderRadius: 6,
                    background: C.terracotta,
                    border: `2px solid ${C.cream}`,
                  }}
                />
              )}
            </button>
          </div>
        </div>

        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          {[
            { k: 'menu', label: t.tabMenu, badge: 0 },
            { k: 'orders', label: t.tabOrders, badge: activeOrders.length },
            { k: 'messages', label: t.tabMessages, badge: unread.length },
          ].map((tab) => {
            const on = view === tab.k
            return (
              <button
                key={tab.k}
                onClick={() => setView(tab.k)}
                aria-current={on ? 'page' : undefined}
                style={{
                  ...S.chip,
                  flex: 1,
                  position: 'relative',
                  padding: '9px 4px',
                  fontSize: 11.5,
                  letterSpacing: 0.3,
                  textTransform: 'uppercase',
                  fontWeight: on ? 700 : 500,
                  borderColor: on ? C.terracotta : C.lineHi,
                  color: on ? C.terracotta : C.dim,
                  background: on ? 'rgba(185,106,76,.09)' : 'transparent',
                }}
              >
                {tab.label}
                {tab.badge > 0 && !on && (
                  <span
                    style={{
                      position: 'absolute',
                      top: -5,
                      right: -3,
                      minWidth: 17,
                      height: 17,
                      borderRadius: 9,
                      padding: '0 4px',
                      background: C.terracotta,
                      color: '#fff',
                      fontSize: 10,
                      fontWeight: 700,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      border: `2px solid ${C.cream}`,
                    }}
                  >
                    {tab.badge}
                  </span>
                )}
              </button>
            )
          })}
        </div>
      </div>

      <div style={{ padding: 16 }}>
        {/* Retour terrain : ce rappel était ici, tout en haut de la carte.
            Redemander des informations juste au-dessus de l'espace de commande,
            à quelqu'un qui vient d'en saisir cinq à l'entrée, freinait la
            commande. Il vit désormais dans Messages et dans l'espace client —
            là où on vient justement gérer sa fiche. Voir ProfileReminder. */}

        {/* Forfait Groupe (pass à crédits) et codes promo */}
        <div style={{ marginBottom: 14 }}>
          <PromoCodeCard
            lang={lang}
            pass={pass}
            gifts={gifts}
            promoCode={promoCode}
            onRedeemCode={redeemCode}
            onClearCode={clearCode}
            onConvert={convertFoodToken}
            showToast={showToast}
          />
        </div>

        {/* Message de blocage de file */}
        {blocked && (
          <div style={{ marginBottom: 14 }}>
            <Banner tone="warn">
              <strong>{t.blockedStrong}</strong> {t.blockedRest}{' '}
              <strong>{readyOrder.pickup_code}</strong>.
            </Banner>
          </div>
        )}

        {/* Messages de l'organisateur — pointeur vers le canal dédié.
            Un message urgent (relance de retrait, incident) passe le bandeau au
            rouge : le bandeau normal se noyait dans la page. */}
        {unread.length > 0 && view !== 'messages' && (
          <div style={{ marginBottom: 14 }}>
            <button
              onClick={() => setView('messages')}
              style={{
                ...S.card,
                width: '100%',
                padding: 12,
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                border: `1.5px solid ${urgentUnread.length ? C.danger : `${C.terracotta}55`}`,
                background: urgentUnread.length ? 'rgba(192,57,43,.08)' : C.paper,
                cursor: 'pointer',
                color: C.text,
                textAlign: 'left',
              }}
            >
              <span style={{ fontSize: 18 }}>{urgentUnread.length ? '⚠️' : '💬'}</span>
              <span
                style={{
                  fontSize: 13.5,
                  fontWeight: urgentUnread.length ? 600 : 400,
                  color: urgentUnread.length ? C.danger : C.text,
                }}
              >
                {urgentUnread.length
                  ? t.newUrgent(urgentUnread.length)
                  : t.newMessages(unread.length)}
              </span>
              <span
                style={{
                  marginLeft: 'auto',
                  color: urgentUnread.length ? C.danger : C.terracotta,
                  fontSize: 12,
                  fontWeight: 600,
                }}
              >
                {t.see}
              </span>
            </button>
          </div>
        )}

        {view === 'messages' ? (
          <MessagesView
            lang={lang}
            messages={messages}
            customer={customer}
            onOpenProfile={() => setProfileOpen(true)}
            onMarkRead={async (m) => {
              await supabase.from('messages').update({ read_at: new Date().toISOString() }).eq('id', m.id)
              loadMessages()
            }}
            onBackToMenu={() => setView('menu')}
          />
        ) : view === 'orders' ? (
          <MyOrders
            orders={orders}
            event={event}
            venue={venue}
            customer={customer}
            lang={lang}
            pushOn={pushOn}
            onEnablePush={async () => {
              const ok = await subscribePush({
                customerId: customer?.id,
                eventId: event?.id,
                role: 'customer',
              })
              setPushOn(ok)
              showToast(ok ? t.pushOk : t.pushKo, ok ? 'ok' : 'error')
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

            {/* Sous-catégories — ancres : un tap fait défiler jusqu'à la section,
                la puce active suit ensuite le défilement toute seule. Le voile
                dégradé + la flèche à droite signalent qu'il y en a d'autres :
                en test, plusieurs personnes ne voyaient pas la suite. */}
            <ScrollHint
              sticky
              top={headerH}
              barRef={chipsBarRef}
              style={{ marginBottom: 14, marginLeft: -16, marginRight: -16, paddingLeft: 16, paddingRight: 16 }}
            >
              {subcats.map((c) => (
                <button
                  key={c}
                  ref={(el) => {
                    chipRefs.current[c] = el
                  }}
                  onClick={() => goToSubcat(c)}
                  style={{
                    ...S.chip,
                    flexShrink: 0,
                    borderColor: subcat === c ? C.indigo : C.lineHi,
                    color: subcat === c ? C.indigo : C.dim,
                    background: subcat === c ? 'rgba(106,95,214,.08)' : 'transparent',
                  }}
                >
                  {c}
                </button>
              ))}
            </ScrollHint>

            {subcats.map((c) => (
              <div
                key={c}
                ref={(el) => {
                  sectionRefs.current[c] = el
                }}
                data-subcat={c}
                style={{ marginBottom: 26, scrollMarginTop: headerH + 62 }}
              >
                <div style={{ ...S.h2, marginBottom: 10, fontSize: 13 }}>{c}</div>
                <div style={{ display: 'grid', gap: 10 }}>
                  {products
                    .filter((p) => p.universe === universe && p.subcategory === c)
                    .map((p) => (
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
                </div>
              </div>
            ))}
            {subcats.length === 0 && <Empty emoji="🍸" title={t.nothingHere} />}
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
        event={event}
        cart={cart}
        pass={pass}
        promoCode={promoCode}
        subtotal={subtotal}
        prepMin={event.default_prep_min ?? 1}
        onClose={() => setCartCheckout(false)}
        onSubmit={async (payload) => {
          try {
            await submitOrder(payload)
          } catch (e) {
            showToast(clientError(e, lang), 'error')
          }
        }}
      />

      <CreditsIntroSheet
        open={creditsIntro}
        lang={lang}
        credits={creditsTotal}
        onClose={() => setCreditsIntro(false)}
      />

      <ClientProfileSheet
        lang={lang}
        open={profileOpen}
        customer={customer}
        credits={creditsTotal}
        orders={orders}
        onClose={() => setProfileOpen(false)}
        onSaved={async () => {
          await onReloadCustomer?.()
          showToast(t.profileSaved, 'ok')
        }}
        showToast={showToast}
      />

      <ReviewSheet
        lang={lang}
        order={reviewFor}
        event={event}
        customer={customer}
        onClose={() => setReviewFor(null)}
        onDone={() => {
          setReviewFor(null)
          showToast(t.reviewThanks, 'ok')
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
          style={{ width: 68, height: 68, borderRadius: 14, objectFit: 'cover', flexShrink: 0 }}
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
              {t.popular}
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
          {(product.variants || []).length > 0 ? t.priceFrom(eur(priceFrom)) : eur(product.price)}
        </div>
      </div>

      <button
        disabled={out || disabled}
        onClick={onAdd}
        title={disabled ? t.pickupFirst : undefined}
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
  const t = useT(lang)
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
    <Sheet open={!!product} onClose={onClose} title={info.name} lang={lang}>
      {product.image_url && (
        <img
          src={product.image_url}
          alt=""
          style={{
            width: '100%',
            height: 190,
            objectFit: 'cover',
            borderRadius: 16,
            marginTop: -8,
            marginBottom: 16,
          }}
        />
      )}

      {info.description && (
        <div style={{ color: C.dim, fontSize: 13.5, marginTop: -8, marginBottom: 18, lineHeight: 1.55 }}>
          {info.description}
        </div>
      )}

      {variants.length > 0 && (
        <div style={{ marginBottom: 18 }}>
          <div style={S.label}>{t.format}</div>
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
              {g.required ? t.requiredCaps : t.optionalCaps}
              {g.max > 1 ? ` · ${t.maxCaps} ${g.max}` : ''}
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
                    {Number(o.price) ? `+${eur(o.price)}` : t.included}
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
        {missing.length ? t.chooseFirst(missing[0].name) : t.add}
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

/**
 * Barre défilante horizontalement avec indice visuel de contenu caché.
 * Un voile dégradé + une flèche apparaissent du côté où il reste à défiler,
 * et disparaissent en fin de course.
 */
function ScrollHint({ children, sticky = false, top = 0, style, barRef }) {
  const ref = useRef(null)
  const [edges, setEdges] = useState({ left: false, right: false })

  const measure = useCallback(() => {
    const el = ref.current
    if (!el) return
    const max = el.scrollWidth - el.clientWidth
    setEdges({ left: el.scrollLeft > 4, right: max > 4 && el.scrollLeft < max - 4 })
  }, [])

  useEffect(() => {
    measure()
    const el = ref.current
    if (!el) return
    el.addEventListener('scroll', measure, { passive: true })
    window.addEventListener('resize', measure)
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(measure) : null
    ro?.observe(el)
    return () => {
      el.removeEventListener('scroll', measure)
      window.removeEventListener('resize', measure)
      ro?.disconnect()
    }
  }, [measure, children])

  const veil = (side) => ({
    position: 'absolute',
    top: 0,
    bottom: 0,
    [side]: 0,
    width: 46,
    pointerEvents: 'none',
    display: 'flex',
    alignItems: 'center',
    justifyContent: side === 'right' ? 'flex-end' : 'flex-start',
    paddingLeft: side === 'left' ? 2 : 0,
    paddingRight: side === 'right' ? 2 : 0,
    color: C.terracotta,
    fontSize: 17,
    fontWeight: 700,
    background: `linear-gradient(to ${side}, ${C.cream}00, ${C.cream}f2 62%)`,
    transition: 'opacity .18s',
  })

  return (
    <div
      ref={barRef}
      style={{
        position: sticky ? 'sticky' : 'relative',
        top: sticky ? top : undefined,
        zIndex: sticky ? 40 : undefined,
        background: sticky ? `${C.cream}f2` : undefined,
        backdropFilter: sticky ? 'blur(10px)' : undefined,
        ...style,
      }}
    >
      <div style={{ position: 'relative' }}>
        <div
          ref={ref}
          style={{
            display: 'flex',
            gap: 8,
            overflowX: 'auto',
            paddingBottom: 4,
            scrollbarWidth: 'none',
          }}
        >
          {children}
        </div>
        <div style={{ ...veil('left'), opacity: edges.left ? 1 : 0 }}>‹</div>
        <div style={{ ...veil('right'), opacity: edges.right ? 1 : 0 }}>›</div>
      </div>
    </div>
  )
}

// ------------------------------------------------------- Forfait (crédits)
/**
 * Simule côté client la même consommation de portefeuille que place_order()
 * côté serveur (même ordre d'itération sur le panier) : sert d'aperçu avant
 * envoi, la source de vérité reste le serveur.
 */
/**
 * Miroir du calcul de place_order() : 1 alcool éligible = 2 crédits, 1 soft =
 * 1 crédit, plus le jeton food. Le serveur reste seul juge — ceci ne sert qu'à
 * afficher l'effet du forfait avant de valider.
 */
function estimateWalletDiscount(cart, pass) {
  if (!pass) return { discount: 0, creditsRemaining: 0, foodAvailable: false }
  let creditsRemaining = pass.credits_remaining
  let richardUsed = pass.richard_used
  let foodAvailable = pass.food_token_available
  let discount = 0
  for (const l of cart) {
    const p = l.product
    const unit = Number(l.basePrice) + (l.options || []).reduce((s, o) => s + Number(o.price || 0), 0)
    if (p.credit_once && !richardUsed) {
      const cost = p.credit_kind === 'alcohol' ? 2 : 1
      if (creditsRemaining >= cost) {
        creditsRemaining -= cost
        richardUsed = true
        discount += unit
      }
    } else if (p.credit_kind === 'alcohol' || p.credit_kind === 'soft') {
      const cost = p.credit_kind === 'alcohol' ? 2 : 1
      const units = Math.min(l.quantity, Math.floor(creditsRemaining / cost))
      if (units > 0) {
        creditsRemaining -= units * cost
        discount += units * unit
      }
    } else if (p.universe === 'food' && foodAvailable) {
      foodAvailable = false
      discount += unit
    }
  }
  return { discount, creditsRemaining, foodAvailable }
}

/**
 * Saisie unique pour TOUT code (réduction % / montant, ou forfait de groupe à
 * crédits) — le client n'a pas à savoir de quel type il s'agit, ni à chercher
 * deux emplacements différents.
 */
function PromoCodeCard({ lang, pass, gifts, promoCode, onRedeemCode, onClearCode, onConvert, showToast }) {
  const t = useT(lang)
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [open, setOpen] = useState(false)

  const giftList = Array.isArray(gifts) ? gifts : []
  const hasGift = giftList.length > 0
  const hasPass = Boolean(pass)
  const hasPromo = Boolean(promoCode) && !hasPass

  // Du point de vue du client, il possède des CRÉDITS. Chaque crédit donne un
  // article sur la carte (ce que le staff a paramétré) — on l'exprime donc en
  // « N crédit(s) », pas en « article offert ».
  const giftTotal = giftList.reduce((s, g) => s + (Number(g.remaining) || 0), 0)
  const giftCard = hasGift && (
    <div style={{ ...S.card, padding: 14, border: `1.5px solid ${C.terracotta}`, marginBottom: 10 }}>
      <div style={{ ...S.label, marginBottom: 6 }}>
        💳 {t.myCredits} — {t.nAvailable(giftTotal)}
      </div>
      <div style={{ display: 'grid', gap: 5 }}>
        {giftList.map((g, i) => (
          <div key={i} style={{ fontSize: 14.5, fontWeight: 500, color: C.terracotta }}>
            {giftCatEmoji(g.category)} {t.nCredits(g.remaining)}
            <span style={{ color: C.dim, fontWeight: 400, fontSize: 12 }}>
              {' — '}
              {g.mode === 'product'
                ? g.product_name || t.menuItem
                : t.ofChoice(giftCatLabel(g.category, lang).toLowerCase())}
              {g.max_value ? t.upTo(eur(g.max_value)) : ''}
            </span>
          </div>
        ))}
      </div>
      <div style={{ fontSize: 11.5, color: C.dim, marginTop: 6, lineHeight: 1.5 }}>{t.creditAuto}</div>
    </div>
  )

  if (!hasGift && !hasPass && !hasPromo) {
    return (
      <div style={{ ...S.card, padding: 14 }}>
        {open ? (
          <>
            <div style={{ ...S.label, marginBottom: 8 }}>{t.promo}</div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                style={{ ...S.input, textTransform: 'uppercase', flex: 1 }}
                value={code}
                onChange={(e) => setCode(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && code.trim() && document.activeElement.blur()}
                placeholder={t.promoPlaceholder}
                autoFocus
              />
              <button
                disabled={!code.trim() || busy}
                onClick={async () => {
                  setBusy(true)
                  try {
                    const res = await onRedeemCode(code.trim())
                    setCode('')
                    setOpen(false)
                    showToast(
                      res.kind === 'gift'
                        ? t.creditsAdded
                        : res.kind === 'credits'
                          ? t.passActivated
                          : t.codeActivated,
                      'ok'
                    )
                  } catch (e) {
                    showToast(clientError(e, lang), 'error')
                  } finally {
                    setBusy(false)
                  }
                }}
                style={{
                  ...S.btnGhost,
                  width: 'auto',
                  minHeight: 'auto',
                  padding: '0 18px',
                  opacity: !code.trim() || busy ? 0.5 : 1,
                }}
              >
                {busy ? '…' : t.activate}
              </button>
            </div>
          </>
        ) : (
          <button
            onClick={() => setOpen(true)}
            style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer', color: C.indigo, fontSize: 13, fontWeight: 600 }}
          >
            {t.promoCta}
          </button>
        )}
      </div>
    )
  }

  if (hasPromo) {
    return (
      <>
      {giftCard}
      <div style={{ ...S.card, padding: 14, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <div style={{ ...S.label, marginBottom: 2 }}>{t.activeCode}</div>
          <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1, fontSize: 15 }}>{promoCode}</div>
        </div>
        <button
          onClick={onClearCode}
          style={{ ...S.btnGhost, width: 'auto', minHeight: 'auto', padding: '8px 14px', fontSize: 12 }}
        >
          {t.removeCode}
        </button>
      </div>
      </>
    )
  }

  // Cadeau seul, sans forfait ni code promo : la carte cadeau suffit.
  if (!hasPass) return giftCard

  const canConvert =
    pass.food_token_available && new Date().toLocaleTimeString('fr-FR', { timeZone: 'Europe/Paris', hour12: false }) < '22:00:00'

  return (
    <>
    {giftCard}
    <div style={{ ...S.card, padding: 14, border: `1.5px solid ${C.terracotta}55` }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <div style={{ ...S.label, marginBottom: 2 }}>{t.activePass}</div>
          <div style={{ ...S.money, fontSize: 20, fontWeight: 600, color: C.terracotta }}>
            {t.creditsLeft(pass.credits_remaining)}
          </div>
          <div style={{ fontSize: 11.5, color: C.dim, marginTop: 3 }}>
            {creditsAsDrinks(pass.credits_remaining, lang)}
          </div>
        </div>
        {pass.food_token_total > 0 && (
          <div style={{ textAlign: 'right', fontSize: 12, color: C.dim }}>
            {t.foodToken}
            <br />
            <strong style={{ color: pass.food_token_available ? C.ok : C.faint }}>
              {pass.food_token_available ? t.tokenAvailable : t.tokenUsed}
            </strong>
          </div>
        )}
      </div>
      {canConvert && (
        <button
          disabled={busy}
          onClick={async () => {
            setBusy(true)
            try {
              await onConvert()
              showToast(t.tokenConverted, 'ok')
            } catch (e) {
              showToast(clientError(e, lang), 'error')
            } finally {
              setBusy(false)
            }
          }}
          style={{ ...S.btnGhost, marginTop: 10, minHeight: 40, fontSize: 12.5, opacity: busy ? 0.6 : 1 }}
        >
          {busy ? '…' : t.convertToken}
        </button>
      )}
    </div>
    </>
  )
}

/**
 * Explication du barème des crédits, montrée une seule fois par soirée et
 * seulement à qui en possède. Remplace l'explication orale répétée au bar.
 */
function CreditsIntroSheet({ open, lang, credits, onClose }) {
  const t = useT(lang)
  return (
    <Sheet open={open} onClose={onClose} title={t.creditsIntroTitle} lang={lang}>
      <div
        style={{
          ...S.card,
          textAlign: 'center',
          border: `1.5px solid ${C.terracotta}`,
          marginBottom: 16,
        }}
      >
        <div style={{ fontSize: 34, marginBottom: 6 }}>🎟️</div>
        <div style={{ ...S.money, fontSize: 22, fontWeight: 600, color: C.terracotta }}>
          {t.creditsIntroYouHave(credits)}
        </div>
      </div>

      <div style={{ display: 'grid', gap: 10, marginBottom: 16 }}>
        {[
          { e: '🥤', txt: t.creditsIntroSoft },
          { e: '🍸', txt: t.creditsIntroAlcohol },
        ].map((r) => (
          <div
            key={r.txt}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 12,
              padding: '12px 14px',
              borderRadius: 14,
              background: C.paper,
              border: `1px solid ${C.line}`,
            }}
          >
            <span style={{ fontSize: 22 }}>{r.e}</span>
            <span style={{ fontSize: 15, fontWeight: 500 }}>{r.txt}</span>
          </div>
        ))}
      </div>

      <div style={{ fontSize: 12.5, color: C.dim, lineHeight: 1.55, marginBottom: 16 }}>
        {t.creditsIntroHow}
      </div>

      <button onClick={onClose} style={S.btn}>
        {t.creditsIntroCta}
      </button>
    </Sheet>
  )
}

// -------------------------------------------------------------- Espace client
/**
 * Le client y retrouve ses informations obligatoires (lecture seule — saisies
 * une fois à l'identification) et peut compléter e-mail / Instagram quand il
 * le souhaite : c'est le rappel affiché tant qu'ils manquent qui renvoie ici.
 */
function ClientProfileSheet({ lang, open, customer, onClose, onSaved, showToast, credits = 0, orders = [] }) {
  const t = useT(lang)
  const [phone, setPhone] = useState('')
  const [postalCode, setPostalCode] = useState('')
  const [birthdate, setBirthdate] = useState('')
  const [email, setEmail] = useState('')
  const [instagram, setInstagram] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (open && customer) {
      setPhone(customer.phone || '')
      setPostalCode(customer.postal_code || '')
      setBirthdate(customer.birthdate || '')
      setEmail(customer.email || '')
      setInstagram(customer.instagram || '')
    }
  }, [open, customer])

  if (!customer) return null

  async function save() {
    if (!phone.trim()) return showToast(t.errPhone, 'error')
    if (!postalCode.trim()) return showToast(t.errPostal, 'error')
    if (!birthdate) return showToast(t.errBirth, 'error')
    if (!birthdateIsValid(birthdate)) return showToast(t.errBirthInvalid, 'error')
    if (email.trim() && !EMAIL_RE.test(email.trim())) return showToast(t.errEmail, 'error')
    setBusy(true)
    try {
      const { error } = await supabase.rpc('update_my_optional_profile', {
        p_phone: phone.trim(),
        p_postal_code: postalCode.trim(),
        p_birthdate: birthdate,
        p_email: email.trim() || '',
        p_instagram: instagram.trim() || '',
      })
      if (error) throw error
      LS.set('noti:phone', phone)
      LS.set('noti:postalCode', postalCode)
      LS.set('noti:birthdate', birthdate)
      LS.set('noti:email', email)
      LS.set('noti:instagram', instagram)
      onClose()
      await onSaved?.()
    } catch (e) {
      showToast(clientError(e, lang), 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Sheet open={open} onClose={onClose} title={t.clientSpace} lang={lang}>
      {/* Retour terrain : cet écran n'était qu'un formulaire de collecte. On y
          met d'abord ce qui appartient au client — son nom, sa fidélité, ses
          crédits, ses commandes du soir — la saisie vient après. */}
      <div style={{ ...S.card, marginBottom: 12 }}>
        <div style={{ ...S.h1, fontSize: 21, marginBottom: 4 }}>
          {customer.first_name} {customer.last_name}
        </div>
        <div style={{ fontSize: 12.5, color: C.dim }}>
          {(customer.events_count ?? 0) <= 1 ? t.firstNight : t.myNights(customer.events_count)}
        </div>

        <div
          style={{
            marginTop: 14,
            paddingTop: 14,
            borderTop: `1px solid ${C.line}`,
            display: 'flex',
            alignItems: 'baseline',
            justifyContent: 'space-between',
            gap: 10,
          }}
        >
          <span style={{ ...S.label, marginBottom: 0 }}>🎟️ {t.myCredits}</span>
          <span
            style={{
              ...S.money,
              fontSize: credits > 0 ? 20 : 13,
              fontWeight: 600,
              color: credits > 0 ? C.terracotta : C.faint,
            }}
          >
            {credits > 0 ? t.nCredits(credits) : t.creditsNone}
          </span>
        </div>
        {credits > 0 && (
          <div style={{ fontSize: 11.5, color: C.dim, marginTop: 4, textAlign: 'right' }}>
            {creditsAsDrinks(credits, lang)}
          </div>
        )}
      </div>

      <div style={{ ...S.card, marginBottom: 16 }}>
        <div style={{ ...S.label, marginBottom: 10 }}>{t.myOrdersHere}</div>
        {orders.length === 0 ? (
          <div style={{ fontSize: 13, color: C.faint }}>{t.noOrdersHere}</div>
        ) : (
          <div style={{ display: 'grid', gap: 8 }}>
            {orders.slice(0, 6).map((o) => (
              <div
                key={o.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 10,
                  fontSize: 13.5,
                  paddingBottom: 8,
                  borderBottom: `1px solid ${C.line}`,
                }}
              >
                <span
                  style={{
                    fontFamily: FONT.label,
                    fontWeight: 600,
                    letterSpacing: 1,
                    color: C.navy,
                  }}
                >
                  {o.pickup_code}
                </span>
                <span style={{ color: C.dim, fontSize: 12 }}>{timeFR(o.created_at)}</span>
                <span
                  style={{
                    marginLeft: 'auto',
                    fontSize: 11,
                    fontFamily: FONT.label,
                    letterSpacing: 0.6,
                    color: (ORDER_STATUS[o.status] || ORDER_STATUS.RECEIVED).color,
                  }}
                >
                  {statusLabel(o.status, lang, true).toUpperCase()}
                </span>
                <span style={{ ...S.money, fontWeight: 600 }}>{eur(o.total)}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      <ProfileReminder customer={customer} lang={lang} />

      <div style={{ ...S.label, marginBottom: 10 }}>{t.yourInfo}</div>

      <Field label={t.phone}>
        <input
          style={S.input}
          type="tel"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          autoComplete="tel"
          placeholder="06 12 34 56 78"
        />
      </Field>

      <div style={{ display: 'flex', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <Field label={t.postalCode}>
            <input
              style={S.input}
              inputMode="numeric"
              value={postalCode}
              onChange={(e) => setPostalCode(e.target.value)}
              autoComplete="postal-code"
              placeholder="75011"
            />
          </Field>
        </div>
        <div style={{ flex: 1.35 }}>
          <BirthdateField label={t.birthdate} value={birthdate} onChange={setBirthdate} />
        </div>
      </div>

      <Field label={t.email} hint={t.optional}>
        <input
          style={S.input}
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          autoComplete="email"
          placeholder="alex@exemple.fr"
        />
      </Field>

      <Field label={t.instagram} hint={t.optional}>
        <input style={S.input} value={instagram} onChange={(e) => setInstagram(e.target.value)} placeholder="@alex" />
      </Field>

      <button disabled={busy} onClick={save} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
        {busy ? '…' : t.save}
      </button>
    </Sheet>
  )
}

// --------------------------------------------------------------------- Panier
function CartSheet({ open, cart, lang, subtotal, onClose, onQty, onCheckout }) {
  const t = useT(lang)
  return (
    <Sheet open={open} onClose={onClose} title={t.cart} lang={lang}>
      {cart.length === 0 && <Empty emoji="🥂" title={t.emptyCart} />}
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
              {t.continue}
            </button>
          </div>
        </>
      )}
    </Sheet>
  )
}

// ----------------------------------------------------------------- Validation
function CheckoutSheet({ open, lang, event, cart, pass, promoCode, subtotal, prepMin, onClose, onSubmit }) {
  const t = useT(lang)
  const [note, setNote] = useState('')
  const [promoResult, setPromoResult] = useState(null)
  const [busy, setBusy] = useState(false)

  // Le code (s'il y en a un) est saisi une seule fois, au niveau de la carte
  // (voir PromoCodeCard) — ici on ne fait qu'en afficher l'effet, recalculé
  // automatiquement à chaque ouverture / changement de panier.
  useEffect(() => {
    if (!open || !promoCode) {
      setPromoResult(null)
      return
    }
    let dead = false
    supabase
      .rpc('preview_promo', { p_event: event.id, p_code: promoCode, p_subtotal: subtotal })
      .then(({ data, error }) => {
        if (!dead) setPromoResult(error ? { valid: false } : data)
      })
    return () => {
      dead = true
    }
  }, [open, promoCode, event.id, subtotal])

  const promoDiscount = promoResult?.valid ? Number(promoResult.discount) : 0
  const walletEst = estimateWalletDiscount(cart || [], pass)
  const discount = promoDiscount + walletEst.discount
  const total = Math.max(0, subtotal - discount)

  return (
    <Sheet open={open} onClose={onClose} title={t.validateOrder} lang={lang}>
      <Field label={t.note}>
        <textarea
          style={{ ...S.input, minHeight: 76, paddingTop: 12, resize: 'vertical' }}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder={t.notePlaceholder}
        />
      </Field>

      {promoCode && (
        <div style={{ marginBottom: 14 }}>
          {promoResult == null ? (
            <Banner tone="info">{t.checkingCode(promoCode)}</Banner>
          ) : promoResult.valid ? (
            <Banner tone="ok">{t.codeApplied(promoCode, eur(promoDiscount))}</Banner>
          ) : (
            <Banner tone="danger">{t.codeInvalid(promoCode)}</Banner>
          )}
        </div>
      )}

      {walletEst.discount > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Banner tone="ok">
            {t.walletCovered(eur(walletEst.discount), walletEst.creditsRemaining)}
          </Banner>
        </div>
      )}

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
        <span style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          {discount > 0 && (
            <span style={{ textDecoration: 'line-through', color: C.faint, fontSize: 14 }}>
              {eur(subtotal)}
            </span>
          )}
          <span style={{ ...S.money, fontSize: 25, fontWeight: 600, color: C.terracotta }}>
            {eur(total)}
          </span>
        </span>
      </div>

      <div style={{ marginBottom: 16 }}>
        <PayAtBar lang={lang} />
      </div>

      <div style={{ marginBottom: 16 }}>
        <Banner tone="info">
          <strong>{t.readyIn(prepMin)}</strong> {t.pickup5}
        </Banner>
      </div>

      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true)
          await onSubmit({ note })
          setBusy(false)
        }}
        style={{ ...S.btn, opacity: busy ? 0.6 : 1, minHeight: 58 }}
      >
        {busy ? t.sending : t.send}
      </button>
    </Sheet>
  )
}

// ------------------------------------------------------- Suivi des commandes
// -------------------------------------------------- Canal de discussion
/**
 * Historique complet des messages (diffusions + messages individuels),
 * contrairement au bandeau qui ne montrait que les 3 derniers non lus.
 */
function MessagesView({ lang, messages, customer, onMarkRead, onBackToMenu, onOpenProfile }) {
  const t = useT(lang)
  const shown = messages.filter((m) => m.kind !== 'status' || m.order_id)

  if (!shown.length)
    return (
      <>
        <ProfileReminder customer={customer} lang={lang} onOpen={onOpenProfile} />
        <Empty emoji="💬" title={t.noMessages} sub={t.noMessagesSub} />
        <button onClick={onBackToMenu} style={S.btnGhost}>
          {t.seeMenu}
        </button>
      </>
    )

  return (
    <div style={{ display: 'grid', gap: 8 }}>
      <ProfileReminder customer={customer} lang={lang} onOpen={onOpenProfile} />
      {shown.map((m) => {
        // Trois natures de message, lisibles d'un coup d'œil : le suivi de
        // commande (statut), le message adressé à une personne, l'annonce de la
        // soirée. Un message urgent passe au rouge, quelle que soit sa nature.
        const urgent = Boolean(m.urgent)
        const tone = urgent
          ? { fg: C.danger, bg: 'rgba(192,57,43,.08)', label: t.msgUrgent }
          : m.kind === 'status'
            ? { fg: C.ok, bg: 'rgba(46,125,91,.07)', label: t.msgOrder }
            : m.kind === 'individual'
              ? { fg: C.indigo, bg: 'rgba(106,95,214,.10)', label: t.msgForYou }
              : { fg: C.terracotta, bg: C.paper, label: t.announcement }
        return (
          <div
            key={m.id}
            style={{
              background: tone.bg,
              border: `1.5px solid ${urgent || m.kind !== 'broadcast' ? tone.fg : C.line}`,
              borderRadius: 14,
              padding: 14,
            }}
          >
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                fontFamily: FONT.label,
                fontSize: 10.5,
                letterSpacing: 1.4,
                textTransform: 'uppercase',
                color: tone.fg,
                marginBottom: 5,
              }}
            >
              {urgent && <span aria-hidden>⚠️</span>}
              {tone.label} · {timeFR(m.created_at)}
              {m.customer_id === customer?.id && !m.read_at && (
                <span style={{ width: 7, height: 7, borderRadius: 4, background: tone.fg }} />
              )}
            </div>
            <div style={{ fontSize: 14, lineHeight: 1.55 }}>{m.body}</div>
            {m.customer_id === customer?.id && !m.read_at && (
              <button
                onClick={() => onMarkRead(m)}
                style={{ background: 'none', border: 'none', color: C.dim, fontSize: 12, padding: '8px 0 0', cursor: 'pointer' }}
              >
                {t.markRead}
              </button>
            )}
          </div>
        )
      })}

      {/* La carte reste à un tap, depuis n'importe quel écran secondaire. */}
      <button onClick={onBackToMenu} style={{ ...S.btnGhost, marginTop: 4 }}>
        {t.seeMenu}
      </button>
    </div>
  )
}

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
        <Empty emoji="🍹" title={t.noOrders} sub={t.noOrdersSub} />
        <button onClick={onBackToMenu} style={S.btnGhost}>
          {t.seeMenu}
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
          {pushOn ? t.notifOn : t.notifCta}
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
        {t.seeMenu}
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

  const steps = ['RECEIVED', 'IN_PREP', 'READY', 'PICKED_UP', 'PAID']
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
            ? t.showCodeAtBar
            : t.orderedAt(timeFR(order.created_at))}
        </div>
      </div>

      <div style={{ padding: 18 }}>
        {/* Statut */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
          <div style={{ width: 9, height: 9, borderRadius: 5, background: st.color }} />
          <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1, color: st.color }}>
            {statusLabel(order.status, lang).toUpperCase()}
          </div>
          {(order.status === 'RECEIVED' || order.status === 'IN_PREP') && etaSec > 0 && (
            <div style={{ ...S.money, marginLeft: 'auto', fontSize: 20, fontWeight: 600 }}>
              {mm}:{ss}
            </div>
          )}
        </div>

        {/* Progression */}
        {!['CANCELLED'].includes(order.status) && (
          <div style={{ display: 'flex', gap: 5, marginBottom: 16 }}>
            {steps.map((code, i) => (
              <div key={code} style={{ flex: 1 }}>
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
                  {statusLabel(code, lang, true).toUpperCase()}
                </div>
              </div>
            ))}
          </div>
        )}

        {order.status === 'UNPAID' && (
          <div style={{ marginBottom: 14 }}>
            <Banner tone="danger">{t.unpaidOrder}</Banner>
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
            <strong>{t.noteLabel}</strong> {order.note}
          </div>
        )}

        <div style={{ marginTop: 14 }}>
          {order.status === 'PAID' ? (
            <Banner tone="ok">{t.paidAtBar}</Banner>
          ) : (
            <PayAtBar compact lang={lang} />
          )}
        </div>

        <div style={{ display: 'grid', gap: 8, marginTop: 12 }}>
          <button onClick={downloadRecap} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12 }}>
            {t.pdfRecap}
          </button>
          {order.status === 'PAID' && (
            <button onClick={onReview} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12, borderColor: C.indigo, color: C.indigo }}>
              {t.rateService}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------- Avis
function ReviewSheet({ lang, order, event, customer, onClose, onDone }) {
  const t = useT(lang)
  const [rating, setRating] = useState(0)
  const [comment, setComment] = useState('')
  const [busy, setBusy] = useState(false)

  if (!order) return null

  return (
    <Sheet open={!!order} onClose={onClose} title={t.yourNight} lang={lang}>
      <div style={{ color: C.dim, fontSize: 13.5, marginTop: -8, marginBottom: 18, lineHeight: 1.55 }}>
        {t.howWasService}
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
        placeholder={t.reviewPlaceholder}
      />
      <div style={{ marginTop: 14 }}>
        <button
          disabled={!rating || busy}
          onClick={async () => {
            setBusy(true)
            await supabase.from('reviews').insert({
              event_id: event?.id,
              customer_id: customer?.id,
              order_id: order.id,
              rating,
              comment: comment || null,
            })
            setBusy(false)
            onDone()
          }}
          style={{ ...S.btn, opacity: !rating || busy ? 0.5 : 1 }}
        >
          {busy ? '…' : t.sendShort}
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
      if (mode === 'forgot') {
        const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
          redirectTo: `${window.location.origin}${BASE_PATH}`,
        })
        if (error) throw error
        setInfo('E-mail envoyé si ce compte existe. Suivez le lien reçu pour choisir un nouveau mot de passe.')
      } else if (mode === 'signup') {
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

          {mode !== 'forgot' && (
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
          )}

          {mode === 'login' && (
            <button
              type="button"
              onClick={() => {
                setMode('forgot')
                setErr('')
                setInfo('')
              }}
              style={{
                background: 'none',
                border: 'none',
                color: C.dim,
                fontSize: 12,
                padding: 0,
                marginBottom: 16,
                cursor: 'pointer',
              }}
            >
              Mot de passe oublié ?
            </button>
          )}
          {mode === 'forgot' && (
            <button
              type="button"
              onClick={() => {
                setMode('login')
                setErr('')
                setInfo('')
              }}
              style={{
                background: 'none',
                border: 'none',
                color: C.dim,
                fontSize: 12,
                padding: 0,
                marginBottom: 16,
                cursor: 'pointer',
              }}
            >
              ← Retour à la connexion
            </button>
          )}

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
            {busy
              ? '…'
              : mode === 'forgot'
                ? 'Envoyer le lien'
                : mode === 'login'
                  ? 'Se connecter'
                  : 'Créer mon compte'}
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

/**
 * Trois niveaux d'accès :
 *  · owner   — le créateur du lieu : tout, y compris l'équipe et les mentions légales
 *  · manager — tout sauf la gestion de l'équipe
 *  · staff   — service en salle : bar, caisse, clients (version réduite)
 */
const ROLE_TABS = {
  owner: STAFF_TABS.map((t) => t.k),
  manager: STAFF_TABS.map((t) => t.k),
  staff: ['bar', 'caisse', 'clients'],
}

const ROLE_LABEL = {
  owner: 'Propriétaire',
  manager: 'Manager',
  staff: 'Équipe (accès bar)',
}

function tabsForRole(role) {
  const allowed = ROLE_TABS[role] || ROLE_TABS.staff
  return STAFF_TABS.filter((t) => allowed.includes(t.k))
}

function StaffApp({ session }) {
  const [venues, setVenues] = useState(null)
  const [venueId, setVenueId] = useState(LS.get('noti:venue', null))
  const [events, setEvents] = useState([])
  const [eventId, setEventId] = useState(LS.get('noti:event', null))
  const [tab, setTab] = useState('bar')
  const [switcher, setSwitcher] = useState(false)
  const [roles, setRoles] = useState({})
  const [toast, showToast] = useToast()

  const loadVenues = useCallback(async () => {
    // Une invitation adressée à cet e-mail devient une adhésion dès la première
    // connexion — c'est ce qui permet d'inviter quelqu'un qui n'a pas encore de
    // compte. À faire AVANT de lister les lieux, sinon l'invité tomberait sur
    // l'écran de création de lieu.
    if (!session.user.is_anonymous) {
      const { error } = await supabase.rpc('accept_my_staff_invites')
      if (error) console.warn('[Noti] invitations', error)
    }

    const { data: mine } = await supabase.from('venues').select('*').eq('owner_id', session.user.id)
    const { data: memberships } = await supabase
      .from('staff_members')
      .select('venue_id, role')
      .eq('user_id', session.user.id)

    const ids = (memberships || []).map((m) => m.venue_id)
    let all = mine || []
    if (ids.length) {
      const { data: extra } = await supabase.from('venues').select('*').in('id', ids)
      const seen = new Set(all.map((v) => v.id))
      all = [...all, ...(extra || []).filter((v) => !seen.has(v.id))]
    }
    all.sort((a, b) => a.name.localeCompare(b.name))

    // Le propriétaire l'emporte toujours sur une éventuelle ligne staff_members.
    const byVenue = Object.fromEntries((memberships || []).map((m) => [m.venue_id, m.role]))
    for (const v of mine || []) byVenue[v.id] = 'owner'

    setRoles(byVenue)
    setVenues(all)
    setVenueId((cur) => (all.find((v) => v.id === cur) ? cur : all[0]?.id ?? null))
  }, [session.user.id, session.user.is_anonymous])

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
  const role = roles[venue.id] || 'staff'
  const tabs = tabsForRole(role)
  // Un changement de lieu peut retirer l'accès à l'onglet courant.
  const activeTab = tabs.some((t) => t.k === tab) ? tab : tabs[0].k

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
            {activeTab === 'bar' && <BarTab event={event} venue={venue} onEventChange={loadEvents} showToast={showToast} />}
            {activeTab === 'caisse' && <CaisseTab event={event} venue={venue} showToast={showToast} />}
            {activeTab === 'orga' && <OrgaTab event={event} venue={venue} showToast={showToast} onEventChange={loadEvents} />}
            {activeTab === 'carte' && <CarteTab venue={venue} showToast={showToast} />}
            {activeTab === 'clients' && <ClientsTab event={event} showToast={showToast} />}
            {activeTab === 'qr' && <QrTab event={event} venue={venue} showToast={showToast} />}
            {activeTab === 'reglages' && (
              <ReglagesTab
                venue={venue}
                event={event}
                session={session}
                role={role}
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
        {tabs.map((t) => (
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
              color: activeTab === t.k ? C.terracotta : C.faint,
            }}
          >
            <div style={{ fontSize: 18, opacity: activeTab === t.k ? 1 : 0.6 }}>{t.e}</div>
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
        {tabs.some((t) => t.k === 'reglages') && (
          <button
            onClick={() => {
              setSwitcher(false)
              setTab('reglages')
            }}
            style={S.btnGhost}
          >
            + Nouvelle soirée / nouveau lieu
          </button>
        )}
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

        <div style={{ marginBottom: 14 }}>
          <Banner tone="info">
            Vous avez été <strong>invité à rejoindre une équipe</strong> ? Ne créez rien ici :
            demandez à l’organisateur de vous inviter à l’adresse <strong>{session.user.email}</strong>,
            puis rechargez cette page — vous serez rattaché automatiquement.
          </Banner>
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

/**
 * Signalements posables sur une commande, à n'importe quel stade. « Incident »
 * est le seul qui taggue aussi la fiche du client (côté serveur).
 */
const ORDER_FLAGS = [
  { k: 'info', label: 'Note', emoji: '💬', color: C.indigo },
  { k: 'attention', label: 'À surveiller', emoji: '⚠️', color: C.warn },
  { k: 'geste', label: 'Geste commercial', emoji: '🎁', color: C.ok },
  { k: 'incident', label: 'Incident', emoji: '🚨', color: C.danger },
]

const flagOf = (k) => ORDER_FLAGS.find((f) => f.k === k)

/** Pastille de signalement affichée sur la carte de commande. */
function FlagDot({ flag, count }) {
  const f = flagOf(flag)
  if (!f || !count) return null
  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 3,
        padding: '2px 7px',
        borderRadius: 999,
        fontSize: 10.5,
        fontWeight: 600,
        background: `${f.color}1f`,
        color: f.color,
      }}
    >
      {f.emoji} {count > 1 ? count : f.label}
    </span>
  )
}

/**
 * Commenter / signaler une commande en un clic — avant, pendant la préparation
 * ou après le service. L'historique alimente la fiche client.
 */
function OrderNotesSheet({ order, onClose, onSaved, showToast }) {
  const [notes, setNotes] = useState([])
  const [body, setBody] = useState('')
  const [flag, setFlag] = useState('info')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    if (!order) return
    const { data } = await supabase
      .from('order_notes')
      .select('*')
      .eq('order_id', order.id)
      .order('created_at', { ascending: false })
    setNotes(data || [])
    setLoading(false)
  }, [order])

  useEffect(() => {
    setBody('')
    setFlag('info')
    setLoading(true)
    load()
  }, [load])

  async function add() {
    if (!body.trim()) return showToast('Écrivez un commentaire.', 'error')
    setBusy(true)
    const { error } = await supabase.rpc('add_order_note', {
      p_order: order.id,
      p_body: body.trim(),
      p_flag: flag,
    })
    setBusy(false)
    if (error) return showToast(frError(error), 'error')
    setBody('')
    setFlag('info')
    showToast('Commentaire enregistré.', 'ok')
    load()
    onSaved?.()
  }

  async function remove(id) {
    const { error } = await supabase.from('order_notes').delete().eq('id', id)
    if (error) return showToast(frError(error), 'error')
    load()
    onSaved?.()
  }

  if (!order) return null

  return (
    <Sheet open={!!order} onClose={onClose} title={`Suivi · ${order.pickup_code}`}>
      <div style={{ fontSize: 13, color: C.dim, marginBottom: 14 }}>
        {order.customers?.first_name} {order.customers?.last_name} · {eur(order.total)} ·{' '}
        {ORDER_STATUS[order.status]?.label || order.status}
      </div>

      <Field label="Type">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {ORDER_FLAGS.map((f) => (
            <button
              key={f.k}
              onClick={() => setFlag(f.k)}
              style={{
                ...S.chip,
                flex: '1 0 46%',
                minHeight: 44,
                borderColor: flag === f.k ? f.color : C.lineHi,
                color: flag === f.k ? f.color : C.dim,
              }}
            >
              {f.emoji} {f.label}
            </button>
          ))}
        </div>
      </Field>

      <Field
        label="Commentaire"
        hint={
          flag === 'incident'
            ? 'Un incident est aussi ajouté aux tags de la fiche client.'
            : 'Visible par l’équipe uniquement — jamais par le client.'
        }
      >
        <textarea
          style={{ ...S.input, minHeight: 90, paddingTop: 12, resize: 'vertical' }}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          placeholder="Verre renversé, client mécontent, cadeau offert…"
        />
      </Field>

      <button disabled={busy || !body.trim()} onClick={add} style={{ ...S.btn, opacity: busy || !body.trim() ? 0.5 : 1 }}>
        {busy ? '…' : 'Enregistrer'}
      </button>

      <div style={{ marginTop: 20 }}>
        <div style={{ ...S.label, marginBottom: 8 }}>Historique</div>
        {loading ? (
          <Spinner label="Chargement…" />
        ) : notes.length === 0 ? (
          <div style={{ color: C.faint, fontSize: 12.5 }}>Aucun commentaire sur cette commande.</div>
        ) : (
          <div style={{ display: 'grid', gap: 8 }}>
            {notes.map((n) => {
              const f = flagOf(n.flag)
              return (
                <div
                  key={n.id}
                  style={{
                    padding: 11,
                    borderRadius: 12,
                    background: C.paper,
                    border: `1px solid ${C.line}`,
                    borderLeft: `3px solid ${f?.color || C.line}`,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontSize: 11.5, fontWeight: 600, color: f?.color || C.dim }}>
                      {f?.emoji} {f?.label || n.flag}
                    </span>
                    <span style={{ marginLeft: 'auto', fontSize: 10.5, color: C.faint }}>
                      {timeFR(n.created_at)}
                    </span>
                    <button
                      onClick={() => remove(n.id)}
                      title="Supprimer"
                      style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.faint, padding: 0, fontSize: 13 }}
                    >
                      ✕
                    </button>
                  </div>
                  <div style={{ fontSize: 13.5, marginTop: 5, whiteSpace: 'pre-wrap' }}>{n.body}</div>
                  {n.author_email && (
                    <div style={{ fontSize: 10.5, color: C.faint, marginTop: 4 }}>{n.author_email}</div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>
    </Sheet>
  )
}

/**
 * Détail des articles offerts sur une commande — ce que le bar doit servir
 * sans encaisser, et au titre de quel code.
 */
function GiftBanner({ orderId }) {
  const [rows, setRows] = useState(null)

  useEffect(() => {
    if (!orderId) return
    let dead = false
    supabase
      .from('gift_redemptions')
      .select('product_name, unit_price, covered, paid, redeemed_at, promo_codes ( code, label )')
      .eq('order_id', orderId)
      .order('redeemed_at')
      .then(({ data }) => {
        if (!dead) setRows(data || [])
      })
    return () => {
      dead = true
    }
  }, [orderId])

  if (!rows || rows.length === 0) return null

  return (
    <div
      style={{
        padding: 14,
        borderRadius: 14,
        background: `${C.gold}14`,
        border: `2px solid ${C.gold}`,
      }}
    >
      <div style={{ ...S.h1, fontSize: 16, color: C.goldDark, marginBottom: 8 }}>
        🎁 {rows.length} crédit{rows.length > 1 ? 's' : ''} — {rows.length > 1 ? 'articles' : 'article'} à offrir
      </div>
      <div style={{ display: 'grid', gap: 5 }}>
        {rows.map((r, i) => (
          <div key={i} style={{ fontSize: 13 }}>
            <strong>{r.product_name}</strong>
            <span style={{ color: C.dim }}>
              {' '}
              — {eur(r.covered)} offerts
              {Number(r.paid) > 0 ? `, ${eur(r.paid)} à encaisser` : ''}
            </span>
            {r.promo_codes?.code && (
              <span style={{ color: C.faint, fontSize: 11.5 }}>
                {' '}
                · {r.promo_codes.label || r.promo_codes.code}
              </span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

function BarTab({ event, venue, onEventChange, showToast }) {
  const [orders, setOrders] = useState([])
  const [loading, setLoading] = useState(true)
  const [prep, setPrep] = useState(event.default_prep_min ?? 1)
  const [detail, setDetail] = useState(null)
  const [notesFor, setNotesFor] = useState(null)
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
  const inPrep = orders.filter((o) => o.status === 'IN_PREP')
  const ready = orders.filter((o) => o.status === 'READY')
  const pickedUp = orders.filter((o) => o.status === 'PICKED_UP')

  // Retraits en retard : deux paliers, alignés sur l'affichage admin.
  //  · RELANCE_MIN  → la commande passe en alerte ici et côté organisation.
  //  · ESCALADE_MIN → l'organisateur prend le relais (contact du client).
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 15000)
    return () => clearInterval(id)
  }, [])
  const overdue = ready
    .map((o) => ({ o, min: waitingMin(o, now) }))
    .filter((x) => x.min >= RELANCE_MIN)

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

  // Relance de retrait : message urgent adressé au client, horodaté côté base
  // (voir nudge_pickup dans 0022).
  const [nudging, setNudging] = useState(null)
  async function nudge(order) {
    setNudging(order.id)
    const { error } = await supabase.rpc('nudge_pickup', { p_order: order.id, p_body: null })
    setNudging(null)
    if (error) return showToast(frError(error), 'error')
    showToast(`Relance envoyée pour ${order.pickup_code}.`, 'ok')
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

      {/* Retraits en retard — palier 15 min (relance) puis 20 min (escalade) */}
      {overdue.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <div
            style={{
              background: 'rgba(192,57,43,.09)',
              border: `2px solid ${C.danger}`,
              borderRadius: 16,
              padding: 16,
            }}
          >
            <div style={{ ...S.h1, fontSize: 18, color: C.danger, marginBottom: 8 }}>
              {overdue.length} commande{overdue.length > 1 ? 's' : ''} prête
              {overdue.length > 1 ? 's' : ''} non retirée{overdue.length > 1 ? 's' : ''}
            </div>
            <div style={{ display: 'grid', gap: 6 }}>
              {overdue.map(({ o, min }) => (
                <div key={o.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                  <strong style={{ fontFamily: FONT.label, letterSpacing: 1.5 }}>{o.pickup_code}</strong>
                  <span style={{ color: C.dim }}>
                    {o.customers?.first_name} {o.customers?.last_name}
                  </span>
                  <span
                    style={{
                      marginLeft: 'auto',
                      fontWeight: 700,
                      color: min >= ESCALADE_MIN ? C.danger : C.warn,
                    }}
                  >
                    {min} min
                  </span>
                  {/* Relance directe : le message part en rouge sur le téléphone
                      du client, sans passer par le micro. */}
                  <button
                    onClick={() => nudge(o)}
                    disabled={nudging === o.id}
                    style={{
                      ...S.chip,
                      minHeight: 32,
                      padding: '4px 10px',
                      fontSize: 11,
                      borderColor: C.danger,
                      color: C.danger,
                      opacity: nudging === o.id ? 0.5 : 1,
                    }}
                  >
                    {nudging === o.id ? '…' : 'Relancer'}
                  </button>
                </div>
              ))}
            </div>
            <div style={{ fontSize: 11.5, color: C.dim, marginTop: 10, lineHeight: 1.5 }}>
              « Relancer » envoie un message urgent au client. Appelez aussi le code au micro.
              Au-delà de {ESCALADE_MIN} min, l’organisateur prend le relais depuis l’onglet
              Organisation.
            </div>
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
          { title: 'Reçues', list: received, color: C.indigo, action: 'En préparation', next: 'IN_PREP' },
          { title: 'En préparation', list: inPrep, color: C.warn, action: 'Prête', next: 'READY' },
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
                      {o.notes_count > 0 && (
                        <div style={{ marginTop: 5 }}>
                          <FlagDot flag={o.flag} count={o.notes_count} />
                        </div>
                      )}
                      {o.gift_count > 0 && (
                        <div
                          style={{
                            marginTop: 6,
                            display: 'inline-flex',
                            alignItems: 'center',
                            gap: 4,
                            padding: '3px 9px',
                            borderRadius: 999,
                            fontSize: 11,
                            fontWeight: 700,
                            background: `${C.gold}22`,
                            color: C.goldDark,
                            border: `1px solid ${C.gold}66`,
                          }}
                        >
                          🎁 {o.gift_count} CRÉDIT{o.gift_count > 1 ? 'S' : ''} · {eur(o.gift_total)} offert{o.gift_count > 1 ? 's' : ''}
                        </div>
                      )}
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
                    <button
                      onClick={() => setNotesFor(o)}
                      title="Commenter / signaler cette commande"
                      style={{
                        ...stepBtn,
                        width: 44,
                        height: 44,
                        fontSize: 15,
                        borderColor: o.flag ? flagOf(o.flag)?.color : undefined,
                      }}
                    >
                      {o.flag ? flagOf(o.flag)?.emoji : '💬'}
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

      <OrderNotesSheet
        order={notesFor}
        onClose={() => setNotesFor(null)}
        onSaved={load}
        showToast={showToast}
      />

      <Sheet open={!!detail} onClose={() => setDetail(null)} title={detail ? `Commande ${detail.pickup_code}` : ''}>
        {detail && (
          <>
            {detail.gift_count > 0 && (
              <div style={{ marginBottom: 14 }}>
                <GiftBanner orderId={detail.id} />
              </div>
            )}
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
              <button
                onClick={() => {
                  const o = detail
                  setDetail(null)
                  setNotesFor(o)
                }}
                style={S.btnGhost}
              >
                💬 Commenter / signaler
                {detail.notes_count > 0 ? ` (${detail.notes_count})` : ''}
              </button>
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

/**
 * Jauge d'affluence : remplissage courant si une capacité est renseignée dans
 * les réglages, rythme d'arrivée sur la dernière heure, et courbe des arrivées
 * par tranche de 15 min — le tout alimenté par les scans QR.
 */
function AffluenceCard({ pulse, slots }) {
  const live = pulse
  const headcount = Number(live?.headcount ?? 0)
  const capacity = Number(live?.capacity ?? 0)
  const pct = capacity > 0 ? Math.min(100, Math.round((headcount / capacity) * 100)) : null
  const last15 = Number(live?.arrivals_15min ?? 0)
  const last60 = Number(live?.arrivals_60min ?? 0)
  const active = Number(live?.active_30min ?? 0)

  const tone = pct == null ? C.indigo : pct >= 90 ? C.danger : pct >= 70 ? C.warn : C.ok
  const toneLabel =
    pct == null ? null : pct >= 90 ? 'Salle pleine' : pct >= 70 ? 'Bien remplie' : 'De la place'

  // Douze dernières tranches de 15 min, y compris celles sans arrivée : sans
  // ça, une accalmie disparaîtrait de la courbe au lieu de s'y voir.
  const bars = useMemo(() => {
    const now = Date.now()
    const step = 15 * 60 * 1000
    const currentSlot = Math.floor(now / step) * step
    const bySlot = Object.fromEntries(
      (slots || []).map((s) => [Math.floor(new Date(s.slot).getTime() / step) * step, Number(s.people) || 0])
    )
    return Array.from({ length: 12 }, (_, i) => {
      const t = currentSlot - (11 - i) * step
      return { t, people: bySlot[t] || 0 }
    })
  }, [slots])

  const peak = Math.max(1, ...bars.map((b) => b.people))

  return (
    <div style={{ ...S.card, marginBottom: 14 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 12 }}>
        <div style={{ ...S.h2, marginBottom: 0 }}>Affluence</div>
        <div style={{ marginLeft: 'auto', fontSize: 11.5, color: C.dim }}>
          {active} actif{active > 1 ? 's' : ''} · 30 dernières min
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
        <div style={{ ...S.money, fontSize: 34, fontWeight: 600, color: tone }}>{headcount}</div>
        <div style={{ fontSize: 13, color: C.dim }}>
          {capacity > 0 ? `sur ${capacity} places` : 'personnes présentes'}
        </div>
        {toneLabel && (
          <div style={{ marginLeft: 'auto', fontSize: 11.5, fontWeight: 600, color: tone }}>
            {pct}% · {toneLabel}
          </div>
        )}
      </div>

      {capacity > 0 && (
        <div
          style={{
            height: 12,
            borderRadius: 999,
            background: 'rgba(28,42,74,.08)',
            overflow: 'hidden',
            marginBottom: 14,
          }}
        >
          <div
            style={{
              width: `${pct}%`,
              height: '100%',
              borderRadius: 999,
              background: tone,
              transition: 'width .6s ease',
            }}
          />
        </div>
      )}

      {capacity === 0 && (
        <div style={{ fontSize: 11.5, color: C.faint, marginBottom: 14, lineHeight: 1.5 }}>
          Renseignez la capacité de la salle dans les Réglages pour afficher le taux de remplissage.
        </div>
      )}

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <div style={{ flex: 1, padding: '10px 12px', borderRadius: 12, background: C.paper, border: `1px solid ${C.line}` }}>
          <div style={{ ...S.money, fontSize: 19, fontWeight: 600 }}>+{last15}</div>
          <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>15 dernières min</div>
        </div>
        <div style={{ flex: 1, padding: '10px 12px', borderRadius: 12, background: C.paper, border: `1px solid ${C.line}` }}>
          <div style={{ ...S.money, fontSize: 19, fontWeight: 600 }}>+{last60}</div>
          <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Dernière heure</div>
        </div>
        <div style={{ flex: 1, padding: '10px 12px', borderRadius: 12, background: C.paper, border: `1px solid ${C.line}` }}>
          <div style={{ ...S.money, fontSize: 19, fontWeight: 600 }}>
            {live?.last_arrival_at ? timeFR(live.last_arrival_at) : '—'}
          </div>
          <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Dernière arrivée</div>
        </div>
      </div>

      <div style={{ ...S.label, marginBottom: 8 }}>Arrivées · 3 dernières heures</div>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 4, height: 64 }}>
        {bars.map((b) => (
          <div key={b.t} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
            <div
              title={`${b.people} personne(s) à ${timeFR(new Date(b.t).toISOString())}`}
              style={{
                width: '100%',
                height: `${Math.max(3, (b.people / peak) * 48)}px`,
                borderRadius: 4,
                background: b.people > 0 ? C.indigo : 'rgba(28,42,74,.10)',
                transition: 'height .5s ease',
              }}
            />
            <div style={{ fontSize: 8.5, color: C.faint, whiteSpace: 'nowrap' }}>
              {new Date(b.t).getMinutes() === 0 ? timeFR(new Date(b.t).toISOString()) : ''}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function OrgaTab({ event, venue, showToast, onEventChange }) {
  const [live, setLive] = useState(null)
  const [board, setBoard] = useState([])
  const [messages, setMessages] = useState([])
  const [broadcastOpen, setBroadcastOpen] = useState(false)
  const [dmFor, setDmFor] = useState(null)
  const [report, setReport] = useState(null)
  const [busy, setBusy] = useState(false)
  const [promoCodes, setPromoCodes] = useState([])
  const [editingPromo, setEditingPromo] = useState(null)
  const [waiting, setWaiting] = useState([])
  const [slots, setSlots] = useState([])
  const [pulse, setPulse] = useState(null)
  const [now, setNow] = useState(Date.now())
  const [ficheFor, setFicheFor] = useState(null)

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 15000)
    return () => clearInterval(id)
  }, [])

  const load = useCallback(async () => {
    const [l, b, m, pc, w, af, pu] = await Promise.all([
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
      supabase
        .from('promo_codes')
        .select('*')
        .eq('event_id', event.id)
        .order('created_at', { ascending: false }),
      // Commandes prêtes mais toujours pas retirées : source des paliers
      // 15 min (relance) et 20 min (escalade organisateur).
      supabase
        .from('orders')
        .select('id, pickup_code, ready_at, created_at, total, customer_id, customers ( first_name, last_name, email, phone )')
        .eq('event_id', event.id)
        .eq('status', 'READY')
        .order('ready_at', { ascending: true }),
      supabase
        .from('v_event_affluence')
        .select('*')
        .eq('event_id', event.id)
        .order('slot', { ascending: true }),
      supabase.from('v_event_pulse').select('*').eq('event_id', event.id).maybeSingle(),
    ])
    setLive(l.data || null)
    setBoard(b.data || [])
    setMessages(m.data || [])
    setPromoCodes(pc.data || [])
    setWaiting(w.data || [])
    setSlots(af.data || [])
    setPulse(pu.data || null)
  }, [event.id])

  const overdue = waiting
    .map((o) => ({ o, min: waitingMin(o, now) }))
    .filter((x) => x.min >= RELANCE_MIN)

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

  async function exportCsv() {
    if (!board.length) return showToast('Rien à exporter.', 'error')
    setBusy(true)
    try {
      const ids = board.map((r) => r.customer_id)

      const [{ data: custs }, { data: att }, { data: ords }, { data: passes }] = await Promise.all([
        supabase.from('customers').select('id, email').in('id', ids),
        supabase
          .from('attendances')
          .select('customer_id, first_scan_at, scan_points ( label, kind )')
          .eq('event_id', event.id),
        supabase
          .from('orders')
          .select('customer_id, promo_code, order_items ( name_snapshot, quantity, variant_label )')
          .eq('event_id', event.id)
          .neq('status', 'CANCELLED'),
        // promo_redemptions garde une ligne par (code, client) : c'est la
        // source fiable de l'historique, y compris quand deux codes se cumulent.
        supabase
          .from('promo_redemptions')
          .select('customer_id, credits_granted, promo_codes ( code )')
          .eq('event_id', event.id),
      ])

      const emailById = Object.fromEntries((custs || []).map((c) => [c.id, c.email || '']))

      const scanLabel = (sp) =>
        sp?.label || (sp?.kind === 'entrance' ? 'Entrée' : sp?.kind === 'bar' ? 'Bar' : sp?.kind || '')
      const scanById = Object.fromEntries(
        (att || []).map((a) => [
          a.customer_id,
          { label: scanLabel(a.scan_points), at: a.first_scan_at ? `${dateFR(a.first_scan_at)} ${timeFR(a.first_scan_at)}` : '' },
        ])
      )

      const itemsById = {}
      for (const o of ords || []) {
        const counts = itemsById[o.customer_id] || (itemsById[o.customer_id] = {})
        for (const it of o.order_items || []) {
          const key = it.variant_label ? `${it.name_snapshot} (${it.variant_label})` : it.name_snapshot
          counts[key] = (counts[key] || 0) + it.quantity
        }
      }
      const itemsSummary = (customerId) => {
        const counts = itemsById[customerId] || {}
        return Object.entries(counts)
          .map(([name, qty]) => `${qty}× ${name}`)
          .join(', ')
      }

      // Historique des codes utilisés : les activations tracées dans
      // promo_redemptions (codes à crédit) + les codes % / montant réellement
      // appliqués sur les commandes, qui ne laissent de trace que là.
      const promoCodesById = {}
      const creditById = {}
      for (const o of ords || []) {
        if (!o.promo_code) continue
        const set = promoCodesById[o.customer_id] || (promoCodesById[o.customer_id] = new Set())
        set.add(o.promo_code)
      }
      for (const p of passes || []) {
        if (p.promo_codes?.code) {
          const set = promoCodesById[p.customer_id] || (promoCodesById[p.customer_id] = new Set())
          set.add(p.promo_codes.code)
        }
        creditById[p.customer_id] = (creditById[p.customer_id] || 0) + Number(p.credits_granted || 0)
      }
      const promoCodesSummary = (customerId) => [...(promoCodesById[customerId] || [])].join(', ')

      const head = [
        'Prénom',
        'Nom',
        'E-mail',
        'Point de scan',
        'Heure d’entrée',
        'Commande',
        'Tags',
        'Codes promo utilisés',
        'Crédits forfait reçus',
        'Commandes',
        'Total EUR',
        'Dernière commande',
      ]
      const rows = board.map((r) => [
        r.first_name ?? '',
        r.last_name ?? '',
        emailById[r.customer_id] ?? '',
        scanById[r.customer_id]?.label ?? '',
        scanById[r.customer_id]?.at ?? '',
        itemsSummary(r.customer_id),
        (r.tags || []).join('|'),
        promoCodesSummary(r.customer_id),
        creditById[r.customer_id] || 0,
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
    } catch (e) {
      showToast(frError(e), 'error')
    } finally {
      setBusy(false)
    }
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
        {stat('Scans QR', live?.present_count ?? 0, C.indigo)}
        {stat('Présents', live?.headcount ?? 0, C.indigo)}
        {stat('En prépa', live?.in_preparation ?? 0, C.navy)}
        {stat('À retirer', live?.awaiting_pickup ?? 0, C.terracotta)}
        {stat('Encaissé', eur(live?.revenue_paid ?? 0), C.ok)}
      </div>

      <AffluenceCard pulse={pulse} slots={slots} />

      {(live?.unpaid_count ?? 0) > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Banner tone="danger">
            <strong>{live.unpaid_count} commande(s) impayée(s)</strong> — tracées et rattachées à
            l’identité vérifiée du client (preuve horodatée).
          </Banner>
        </div>
      )}

      {/* Retraits en retard — mêmes seuils que l'écran Bar */}
      {overdue.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ ...S.h2, marginBottom: 8 }}>Retraits en retard</div>
          <div style={{ display: 'grid', gap: 8 }}>
            {overdue.map(({ o, min }) => {
              const escalate = min >= ESCALADE_MIN
              const who = `${o.customers?.first_name ?? ''} ${o.customers?.last_name ?? ''}`.trim()
              return (
                <div
                  key={o.id}
                  style={{
                    ...S.card,
                    padding: 12,
                    border: `1.5px solid ${escalate ? C.danger : C.warn}`,
                    background: escalate ? 'rgba(192,57,43,.06)' : 'rgba(201,130,31,.06)',
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1.6, fontSize: 16 }}>
                      {o.pickup_code}
                    </div>
                    <div style={{ fontSize: 13, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      {who || 'Client'}
                    </div>
                    <div
                      style={{
                        marginLeft: 'auto',
                        fontFamily: FONT.label,
                        fontWeight: 700,
                        color: escalate ? C.danger : C.warn,
                      }}
                    >
                      {min} min
                    </div>
                  </div>
                  <div style={{ fontSize: 11.5, color: C.dim, marginTop: 4 }}>
                    {escalate
                      ? `Au-delà de ${ESCALADE_MIN} min : contactez le client directement.`
                      : `Prête depuis ${min} min — le bar relance au micro.`}
                  </div>
                  <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                    <button
                      onClick={() => setDmFor({ customer_id: o.customer_id, first_name: who || 'Client' })}
                      style={{ ...S.btnGhost, minHeight: 40, fontSize: 12 }}
                    >
                      Message dans l’app
                    </button>
                    {escalate && o.customers?.phone && (
                      <a
                        href={`tel:${o.customers.phone}`}
                        style={{
                          ...S.btnGhost,
                          minHeight: 40,
                          fontSize: 12,
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          textDecoration: 'none',
                          borderColor: C.danger,
                          color: C.danger,
                        }}
                      >
                        Appeler
                      </a>
                    )}
                    {escalate && !o.customers?.phone && o.customers?.email && (
                      <a
                        href={`mailto:${o.customers.email}?subject=${encodeURIComponent(
                          `Votre commande ${o.pickup_code} vous attend`
                        )}`}
                        style={{
                          ...S.btnGhost,
                          minHeight: 40,
                          fontSize: 12,
                          display: 'flex',
                          alignItems: 'center',
                          justifyContent: 'center',
                          textDecoration: 'none',
                          borderColor: C.danger,
                          color: C.danger,
                        }}
                      >
                        E-mail
                      </a>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
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
          <button
            key={r.customer_id}
            onClick={() => setFicheFor(r.customer_id)}
            style={{ ...S.card, padding: 12, display: 'flex', gap: 12, alignItems: 'center', border: 'none', textAlign: 'left', cursor: 'pointer', color: C.text }}
          >
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
            <span
              onClick={(e) => {
                e.stopPropagation()
                setDmFor(r)
              }}
              title="Message individuel"
              style={{ ...stepBtn, width: 38, height: 38, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
            >
              ✉
            </span>
          </button>
        ))}
      </div>

      <ClientFicheSheet
        customerId={ficheFor}
        event={event}
        onClose={() => setFicheFor(null)}
        onChanged={load}
        onMessage={(target) => {
          setFicheFor(null)
          setDmFor(target)
        }}
        showToast={showToast}
      />

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
        <button disabled={busy} onClick={exportCsv} style={{ ...S.btnGhost, opacity: busy ? 0.6 : 1 }}>
          {busy ? '…' : 'Exporter les clients (CSV)'}
        </button>
      </div>

      {/* Codes promo */}
      <div style={{ ...S.h2, marginBottom: 10 }}>Codes promo</div>
      <div style={{ marginBottom: 10 }}>
        <button onClick={() => setEditingPromo(EMPTY_PROMO)} style={{ ...S.btn, minHeight: 46 }}>
          + Code promo
        </button>
      </div>
      {promoCodes.length === 0 && <Empty emoji="🏷️" title="Aucun code promo" />}
      <div style={{ display: 'grid', gap: 8, marginBottom: 18 }}>
        {promoCodes.map((p) => (
          <button
            key={p.id}
            onClick={() => setEditingPromo(p)}
            style={{
              ...S.card,
              padding: 12,
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              textAlign: 'left',
              border: 'none',
              cursor: 'pointer',
              color: C.text,
              opacity: p.active ? 1 : 0.55,
            }}
          >
            <div style={{ minWidth: 0 }}>
              <div style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1, fontSize: 14 }}>
                {p.code}
              </div>
              <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>
                {p.kind === 'gift'
                  ? `🎁 ${(p.gift_items || [])
                      .map((g) => giftLineLabel(g))
                      .join(' + ') || 'aucun article'}`
                  : p.kind === 'credits'
                    ? `🎟️ ${Math.round((p.credits_per_person || 0) / CREDITS_PAR_CONSO)} conso${
                        Math.round((p.credits_per_person || 0) / CREDITS_PAR_CONSO) > 1 ? 's' : ''
                      }${p.food_tokens_per_person > 0 ? ' + 1 plat' : ''} /pers`
                    : p.kind === 'percent'
                      ? `-${p.value}%`
                      : `-${eur(p.value)}`}
                {!['credits', 'gift'].includes(p.kind) && p.min_total > 0 ? ` · dès ${eur(p.min_total)}` : ''}
                {' · '}
                {p.uses_count}
                {p.max_uses ? `/${p.max_uses}` : ''}{' '}
                {['credits', 'gift'].includes(p.kind) ? 'personne' : 'utilisé'}
                {p.uses_count > 1 ? 's' : ''}
              </div>
            </div>
            <span
              style={{
                ...S.chip,
                flexShrink: 0,
                borderColor: p.active ? C.ok : C.lineHi,
                color: p.active ? C.ok : C.faint,
              }}
            >
              {p.active ? 'ACTIF' : 'INACTIF'}
            </span>
          </button>
        ))}
      </div>

      <PromoCodeSheet
        promo={editingPromo}
        event={event}
        venue={venue}
        onClose={() => setEditingPromo(null)}
        onSaved={() => {
          setEditingPromo(null)
          load()
        }}
        showToast={showToast}
      />

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
        onSent={(res) => {
          setBroadcastOpen(false)
          showToast(
            res.degraded
              ? `Message publié pour ${res.recipients} personne(s), visible dans leur onglet 💬. ` +
                  'Push et SMS non envoyés : la fonction notify n’est pas déployée.'
              : `Message diffusé à ${res.recipients} personne(s).`,
            res.degraded ? 'warn' : 'ok'
          )
          load()
        }}
        onChanged={load}
        showToast={showToast}
      />

      <DirectMessageSheet
        target={dmFor}
        event={event}
        onClose={() => setDmFor(null)}
        onSent={(res) => {
          setDmFor(null)
          showToast(
            res.degraded
              ? 'Message publié dans l’onglet 💬 du client. Push et SMS non envoyés : ' +
                  'la fonction notify n’est pas déployée.'
              : 'Message envoyé.',
            res.degraded ? 'warn' : 'ok'
          )
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
  'Forfaits : dernière ligne droite pour convertir votre jeton food en conso (crédits), fenêtre fermée à 22h — après quoi il reste un jeton food perdu s’il n’est pas utilisé.',
]

/**
 * Interrupteur « message urgent ». Le client le reçoit en rouge, avec un
 * bandeau distinct : sans ça, une relance de retrait se noyait dans les
 * annonces de la soirée.
 */
function UrgentToggle({ on, onChange }) {
  return (
    <button
      onClick={() => onChange(!on)}
      style={{
        ...S.chip,
        width: '100%',
        minHeight: 46,
        marginBottom: 14,
        justifyContent: 'flex-start',
        gap: 10,
        display: 'flex',
        alignItems: 'center',
        whiteSpace: 'normal',
        textAlign: 'left',
        borderColor: on ? C.danger : C.lineHi,
        background: on ? 'rgba(192,57,43,.08)' : 'transparent',
        color: on ? C.danger : C.dim,
        fontWeight: on ? 600 : 500,
      }}
    >
      <span style={{ fontSize: 16 }}>{on ? '⚠️' : '○'}</span>
      Message urgent — bandeau rouge côté client
    </button>
  )
}

function BroadcastSheet({ open, event, onClose, onSent, onChanged, showToast }) {
  const [body, setBody] = useState('')
  const [urgent, setUrgent] = useState(false)
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState([])
  const [loadingSent, setLoadingSent] = useState(false)

  // Historique des messages déjà partis, pour pouvoir en retirer un.
  const loadSent = useCallback(async () => {
    if (!open) return
    setLoadingSent(true)
    const { data } = await supabase
      .from('messages')
      .select('*, customers ( first_name, last_name )')
      .eq('event_id', event.id)
      .neq('kind', 'status')
      .order('created_at', { ascending: false })
      .limit(30)
    setSent(data || [])
    setLoadingSent(false)
  }, [open, event.id])

  useEffect(() => {
    loadSent()
  }, [loadSent])

  async function remove(id) {
    if (!confirm('Supprimer ce message ? Il disparaîtra aussi du canal des clients.')) return
    const { error } = await supabase.from('messages').delete().eq('id', id)
    if (error) return showToast(frError(error), 'error')
    showToast('Message supprimé.', 'ok')
    loadSent()
    onChanged?.()
  }

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

      <UrgentToggle on={urgent} onChange={setUrgent} />

      <button
        disabled={!body.trim() || busy}
        onClick={async () => {
          setBusy(true)
          const res = await notify({
            eventId: event.id,
            kind: 'broadcast',
            body: body.trim(),
            title: event.name,
            urgent,
          })
          setBusy(false)
          if (!res) return showToast('Envoi impossible : message non enregistré.', 'error')
          setBody('')
          setUrgent(false)
          loadSent()
          onSent(res)
        }}
        style={{ ...S.btn, opacity: !body.trim() || busy ? 0.5 : 1 }}
      >
        {busy ? 'Envoi…' : 'Diffuser'}
      </button>

      <div style={{ marginTop: 22 }}>
        <div style={{ ...S.label, marginBottom: 8 }}>Messages envoyés</div>
        {loadingSent ? (
          <Spinner label="Chargement…" />
        ) : sent.length === 0 ? (
          <div style={{ fontSize: 12.5, color: C.faint }}>Aucun message envoyé sur cette soirée.</div>
        ) : (
          <div style={{ display: 'grid', gap: 8 }}>
            {sent.map((m) => (
              <div
                key={m.id}
                style={{
                  padding: 11,
                  borderRadius: 12,
                  background: C.paper,
                  border: `1px solid ${C.line}`,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 10.5, fontWeight: 600, color: m.customer_id ? C.indigo : C.terracotta }}>
                    {m.customer_id
                      ? `À ${m.customers?.first_name || 'un client'} ${m.customers?.last_name || ''}`.trim()
                      : 'Diffusion générale'}
                  </span>
                  {m.urgent && (
                    <span style={{ fontSize: 10.5, fontWeight: 600, color: C.danger }}>⚠️ URGENT</span>
                  )}
                  <span style={{ marginLeft: 'auto', fontSize: 10.5, color: C.faint }}>
                    {dateFR(m.created_at)} {timeFR(m.created_at)}
                  </span>
                  <button
                    onClick={() => remove(m.id)}
                    title="Supprimer ce message"
                    style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.danger, padding: 0, fontSize: 13 }}
                  >
                    ✕
                  </button>
                </div>
                <div style={{ fontSize: 13, marginTop: 5, whiteSpace: 'pre-wrap' }}>{m.body}</div>
              </div>
            ))}
          </div>
        )}
        <div style={{ fontSize: 11, color: C.faint, marginTop: 10, lineHeight: 1.5 }}>
          Supprimer retire le message du canal 💬 des clients. Une notification push ou un SMS déjà
          reçu sur le téléphone, lui, ne peut pas être repris.
        </div>
      </div>
    </Sheet>
  )
}

/** Fiche client complète (staff) — tous les champs collectés, tous événements confondus. */
function ClientFicheSheet({ customerId, event, onClose, onMessage, onChanged, showToast }) {
  const [cust, setCust] = useState(null)
  const [promoCodesUsed, setPromoCodesUsed] = useState([])
  const [orders, setOrders] = useState([])
  const [giftsUsed, setGiftsUsed] = useState([])
  const [notes, setNotes] = useState([])
  const [attendance, setAttendance] = useState(null)
  const [wallet, setWallet] = useState(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!customerId) {
      setCust(null)
      return
    }
    let dead = false
    setLoading(true)
    ;(async () => {
      const [
        { data: c, error },
        { data: ords },
        { data: reds },
        { data: giftRows },
        { data: nts },
        { data: att },
        { data: wal },
      ] = await Promise.all([
        supabase.from('customers').select('*').eq('id', customerId).maybeSingle(),
        supabase
          .from('orders')
          .select('*, order_items ( name_snapshot, quantity, variant_label ), events ( name )')
          .eq('customer_id', customerId)
          .order('created_at', { ascending: false })
          .limit(40),
        supabase
          .from('promo_redemptions')
          .select('credits_granted, created_at, promo_codes ( code )')
          .eq('customer_id', customerId),
        supabase
          .from('gift_redemptions')
          .select('product_name, unit_price, covered, paid, redeemed_at, promo_codes ( code, label ), orders ( pickup_code )')
          .eq('customer_id', customerId)
          .order('redeemed_at', { ascending: false })
          .limit(50),
        supabase
          .from('order_notes')
          .select('*')
          .eq('customer_id', customerId)
          .order('created_at', { ascending: false })
          .limit(30),
        event
          ? supabase
              .from('attendances')
              .select('*, scan_points ( label, kind )')
              .eq('customer_id', customerId)
              .eq('event_id', event.id)
              .maybeSingle()
          : Promise.resolve({ data: null }),
        event
          ? supabase
              .from('event_passes')
              .select('credits_total, credits_remaining, food_token_total, food_token_available')
              .eq('customer_id', customerId)
              .eq('event_id', event.id)
              .maybeSingle()
          : Promise.resolve({ data: null }),
      ])
      if (dead) return
      if (error) showToast?.(frError(error), 'error')
      setCust(c || null)
      setOrders(ords || [])
      setGiftsUsed(giftRows || [])
      setNotes(nts || [])
      setAttendance(att || null)
      setWallet(wal || null)

      // promo_redemptions est la source fiable ; les codes % / montant ne
      // laissent de trace que sur la commande, on complète donc avec eux.
      const codes = new Set([
        ...(reds || []).map((r) => r.promo_codes?.code).filter(Boolean),
        ...(ords || []).map((o) => o.promo_code).filter(Boolean),
      ])
      setPromoCodesUsed([...codes])
      setLoading(false)
    })()
    return () => {
      dead = true
    }
  }, [customerId, event, showToast])

  // « Actif en live » : un scan ou une commande dans la dernière demi-heure.
  const lastSeen = attendance?.last_scan_at
  const liveNow = lastSeen && Date.now() - new Date(lastSeen).getTime() < 30 * 60 * 1000

  async function toggleTag(tag) {
    if (!cust) return
    const tags = cust.tags || []
    const next = tags.includes(tag) ? tags.filter((t) => t !== tag) : [...tags, tag]
    const { error } = await supabase.from('customers').update({ tags: next }).eq('id', cust.id)
    if (error) return showToast?.(frError(error), 'error')
    setCust({ ...cust, tags: next })
    onChanged?.()
  }

  return (
    <Sheet open={!!customerId} onClose={onClose} title="Fiche client">
      {loading || !cust ? (
        <Spinner />
      ) : (
        <div style={{ display: 'grid', gap: 14 }}>
          <div>
            <div style={{ ...S.h1, fontSize: 20 }}>
              {cust.first_name} {cust.last_name}
            </div>
            {(cust.tags || []).length > 0 && (
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 6 }}>
                {cust.tags.map((tg) => (
                  <span
                    key={tg}
                    style={{
                      ...S.chip,
                      padding: '3px 10px',
                      fontSize: 11,
                      color: tg === 'incident' ? C.danger : C.indigo,
                      borderColor: tg === 'incident' ? C.danger : C.indigo,
                    }}
                  >
                    {TAG_LABEL[tg] || tg}
                  </span>
                ))}
              </div>
            )}
          </div>

          {/* Présence sur la soirée en cours */}
          {attendance && (
            <div
              style={{
                ...S.card,
                padding: 14,
                border: `1.5px solid ${liveNow ? C.ok : C.line}`,
                background: liveNow ? 'rgba(46,125,90,.06)' : C.paper,
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
                <span
                  style={{
                    width: 8,
                    height: 8,
                    borderRadius: 4,
                    background: liveNow ? C.ok : C.faint,
                    animation: liveNow ? 'notipulse 1.6s infinite' : 'none',
                  }}
                />
                <span style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1, fontSize: 11.5, color: liveNow ? C.ok : C.dim }}>
                  {liveNow ? 'PRÉSENT MAINTENANT' : 'SUR CETTE SOIRÉE'}
                </span>
              </div>
              <div style={{ display: 'grid', gap: 4, fontSize: 13 }}>
                <div>
                  🚪 Arrivé à <strong>{timeFR(attendance.first_scan_at)}</strong>
                  {attendance.scan_points?.label ? ` · ${attendance.scan_points.label}` : ''}
                </div>
                <div>👥 Groupe de {attendance.group_size}</div>
                <div style={{ color: C.dim }}>
                  Dernière activité à {timeFR(attendance.last_scan_at)}
                </div>
                {wallet && Number(wallet.credits_total) > 0 && (
                  <div style={{ color: C.terracotta, fontWeight: 500 }}>
                    🎟️ Forfait : {wallet.credits_remaining}/{wallet.credits_total} crédits
                    {wallet.food_token_total > 0
                      ? ` · jeton food ${wallet.food_token_available ? 'dispo' : 'utilisé'}`
                      : ''}
                  </div>
                )}
              </div>
            </div>
          )}

          <div style={{ ...S.card, padding: 14, display: 'grid', gap: 8, fontSize: 14 }}>
            <div>📞 {phoneFR(cust.phone) || '—'}</div>
            <div>✉️ {cust.email || '—'}</div>
            <div>📷 {cust.instagram || '—'}</div>
            <div>📮 {cust.postal_code || '—'}</div>
            <div>🎂 {cust.birthdate ? new Date(cust.birthdate).toLocaleDateString('fr-FR') : '—'}</div>
          </div>

          {onMessage && (
            <button
              onClick={() =>
                onMessage({
                  customer_id: cust.id,
                  first_name: cust.first_name,
                  last_name: cust.last_name,
                })
              }
              style={S.btn}
            >
              ✉️ Envoyer un message à {cust.first_name || 'ce client'}
            </button>
          )}

          <div style={{ display: 'flex', gap: 8 }}>
            <div style={{ ...S.card, flex: 1, padding: 12, textAlign: 'center' }}>
              <div style={{ ...S.money, fontSize: 19, fontWeight: 600 }}>{cust.events_count}</div>
              <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Soirées</div>
            </div>
            <div style={{ ...S.card, flex: 1, padding: 12, textAlign: 'center' }}>
              <div style={{ ...S.money, fontSize: 19, fontWeight: 600 }}>{cust.orders_count}</div>
              <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Commandes</div>
            </div>
            <div style={{ ...S.card, flex: 1, padding: 12, textAlign: 'center' }}>
              <div style={{ ...S.money, fontSize: 19, fontWeight: 600, color: C.terracotta }}>{eur(cust.total_spent)}</div>
              <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Dépensé</div>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <div style={{ ...S.card, flex: 1, padding: 12, textAlign: 'center' }}>
              <div style={{ ...S.money, fontSize: 19, fontWeight: 600, color: (cust.unpaid_count || 0) > 0 ? C.danger : C.text }}>
                {cust.unpaid_count || 0}
              </div>
              <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Impayés</div>
            </div>
            <div style={{ ...S.card, flex: 1, padding: 12, textAlign: 'center' }}>
              <div style={{ ...S.money, fontSize: 13.5, fontWeight: 600 }}>
                {cust.first_seen_at ? dateFR(cust.first_seen_at) : '—'}
              </div>
              <div style={{ ...S.label, marginBottom: 0, marginTop: 2, fontSize: 9.5 }}>Première venue</div>
            </div>
          </div>

          {/* Segmentation — modifiable directement depuis la fiche */}
          <div>
            <div style={{ ...S.label, marginBottom: 6 }}>Segmentation</div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {ALL_TAGS.map((t) => {
                const on = (cust.tags || []).includes(t)
                return (
                  <button
                    key={t}
                    onClick={() => toggleTag(t)}
                    style={{
                      ...S.chip,
                      minHeight: 40,
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
          </div>

          {promoCodesUsed.length > 0 && (
            <div>
              <div style={{ ...S.label, marginBottom: 6 }}>Codes promo utilisés</div>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {promoCodesUsed.map((c) => (
                  <span key={c} style={{ ...S.chip, fontSize: 11.5, padding: '4px 10px' }}>
                    {c}
                  </span>
                ))}
              </div>
            </div>
          )}

          {cust.staff_note && (
            <div>
              <div style={{ ...S.label, marginBottom: 6 }}>Note</div>
              <div style={{ fontSize: 13.5, color: C.dim }}>{cust.staff_note}</div>
            </div>
          )}

          {/* Crédits consommés — l'article exact, l'heure exacte, le code */}
          {giftsUsed.length > 0 && (
            <div>
              <div style={{ ...S.label, marginBottom: 6 }}>
                💳 Crédits utilisés ({giftsUsed.length}) ·{' '}
                {eur(giftsUsed.reduce((s, g) => s + Number(g.covered || 0), 0))} offerts
              </div>
              <div style={{ display: 'grid', gap: 8 }}>
                {giftsUsed.map((g, i) => (
                  <div
                    key={i}
                    style={{
                      padding: 11,
                      borderRadius: 12,
                      background: `${C.gold}12`,
                      border: `1px solid ${C.gold}55`,
                    }}
                  >
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                      <strong style={{ fontSize: 13.5 }}>{g.product_name}</strong>
                      <span style={{ marginLeft: 'auto', ...S.money, fontWeight: 600, color: C.goldDark }}>
                        {eur(g.covered)}
                      </span>
                    </div>
                    <div style={{ fontSize: 11.5, color: C.dim, marginTop: 3 }}>
                      {dateFR(g.redeemed_at)} à <strong>{timeFR(g.redeemed_at)}</strong>
                      {g.orders?.pickup_code ? ` · commande ${g.orders.pickup_code}` : ''}
                      {Number(g.paid) > 0 ? ` · ${eur(g.paid)} réglés en plus` : ''}
                    </div>
                    {g.promo_codes?.code && (
                      <div style={{ fontSize: 11, color: C.faint, marginTop: 2 }}>
                        via {g.promo_codes.label || g.promo_codes.code} ({g.promo_codes.code})
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Signalements posés par l'équipe sur ses commandes */}
          {notes.length > 0 && (
            <div>
              <div style={{ ...S.label, marginBottom: 6 }}>Suivi de l’équipe ({notes.length})</div>
              <div style={{ display: 'grid', gap: 8 }}>
                {notes.map((n) => {
                  const f = flagOf(n.flag)
                  return (
                    <div
                      key={n.id}
                      style={{
                        padding: 11,
                        borderRadius: 12,
                        background: C.paper,
                        border: `1px solid ${C.line}`,
                        borderLeft: `3px solid ${f?.color || C.line}`,
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span style={{ fontSize: 11.5, fontWeight: 600, color: f?.color || C.dim }}>
                          {f?.emoji} {f?.label || n.flag}
                        </span>
                        <span style={{ marginLeft: 'auto', fontSize: 10.5, color: C.faint }}>
                          {dateFR(n.created_at)} {timeFR(n.created_at)}
                        </span>
                      </div>
                      <div style={{ fontSize: 13.5, marginTop: 5, whiteSpace: 'pre-wrap' }}>{n.body}</div>
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {/* Historique des commandes, toutes soirées confondues */}
          <div>
            <div style={{ ...S.label, marginBottom: 6 }}>
              Historique des commandes ({orders.length})
            </div>
            {orders.length === 0 ? (
              <div style={{ fontSize: 12.5, color: C.faint }}>Aucune commande enregistrée.</div>
            ) : (
              <div style={{ display: 'grid', gap: 8 }}>
                {orders.map((o) => {
                  const st = ORDER_STATUS[o.status]
                  return (
                    <div
                      key={o.id}
                      style={{
                        padding: 11,
                        borderRadius: 12,
                        background: C.paper,
                        border: `1px solid ${C.line}`,
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                        <span style={{ fontFamily: FONT.label, fontWeight: 600, letterSpacing: 1.4, fontSize: 13 }}>
                          {o.pickup_code}
                        </span>
                        <span style={{ fontSize: 11, color: C.faint }}>
                          {dateFR(o.created_at)} · {timeFR(o.created_at)}
                        </span>
                        <span style={{ marginLeft: 'auto', ...S.money, fontWeight: 600 }}>{eur(o.total)}</span>
                      </div>
                      <div style={{ fontSize: 12, color: C.dim, marginTop: 4 }}>
                        {(o.order_items || [])
                          .map((it) => `${it.quantity}× ${it.name_snapshot}${it.variant_label ? ` (${it.variant_label})` : ''}`)
                          .join(', ') || '—'}
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 6, alignItems: 'center' }}>
                        <span style={{ fontSize: 10.5, fontWeight: 600, color: st?.color || C.dim }}>
                          {st?.label || o.status}
                        </span>
                        {o.events?.name && (
                          <span style={{ fontSize: 10.5, color: C.faint }}>· {o.events.name}</span>
                        )}
                        {Number(o.credit_units_used) > 0 && (
                          <span style={{ fontSize: 10.5, color: C.terracotta }}>
                            · {o.credit_units_used} crédit{o.credit_units_used > 1 ? 's' : ''}
                          </span>
                        )}
                        {o.promo_code && (
                          <span style={{ fontSize: 10.5, color: C.indigo }}>· {o.promo_code}</span>
                        )}
                        {o.notes_count > 0 && <FlagDot flag={o.flag} count={o.notes_count} />}
                      </div>
                    </div>
                  )
                })}
              </div>
            )}
          </div>
        </div>
      )}
    </Sheet>
  )
}

function DirectMessageSheet({ target, event, onClose, onSent, showToast }) {
  const [body, setBody] = useState('')
  const [urgent, setUrgent] = useState(false)
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
      <UrgentToggle on={urgent} onChange={setUrgent} />
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
            urgent,
          })
          setBusy(false)
          if (!res) return showToast('Envoi impossible : message non enregistré.', 'error')
          onSent(res)
        }}
        style={{ ...S.btn, opacity: !body.trim() || busy ? 0.5 : 1 }}
      >
        {busy ? 'Envoi…' : 'Envoyer'}
      </button>
    </Sheet>
  )
}

// ------------------------------------------------------------- CODES PROMO
const EMPTY_PROMO = {
  code: '',
  label: '',
  kind: 'percent',
  value: 10,
  min_total: 0,
  max_uses: null,
  active: true,
  credits_per_person: 6,
  food_tokens_per_person: 1,
  gift_items: [],
}

/** Catégories offrables par un code cadeau, dans les mots de la carte. */
const GIFT_CATEGORIES = [
  { k: 'alcohol', label: 'Boisson alcoolisée', emoji: '🍸' },
  { k: 'soft', label: 'Soft', emoji: '🥤' },
  { k: 'food', label: 'Plat', emoji: '🍽️' },
  { k: 'bottle', label: 'Bouteille', emoji: '🍾' },
]

// Le staff lit ces libellés en français ; le client, dans sa langue (le
// dictionnaire porte les mêmes catégories sous catAlcohol / catSoft / …).
const GIFT_CAT_KEY = { alcohol: 'catAlcohol', soft: 'catSoft', food: 'catFood', bottle: 'catBottle' }
const giftCatLabel = (k, lang) =>
  (lang && lang !== 'fr' ? dict(lang)[GIFT_CAT_KEY[k]] : null) ||
  GIFT_CATEGORIES.find((c) => c.k === k)?.label ||
  k
const giftCatEmoji = (k) => GIFT_CATEGORIES.find((c) => c.k === k)?.emoji || '🎁'

/** Résumé en français d'une ligne de cadeau, tel que le staff et le client le lisent. */
function giftLineLabel(item, productName) {
  const q = Number(item.quantity) || 1
  if (item.mode === 'product') {
    return `${q} × ${productName || 'article de la carte'}`
  }
  const cat = giftCatLabel(item.category)
  const plafond = item.max_value ? ` jusqu’à ${eur(item.max_value)}` : ''
  return `${q} ${cat.toLowerCase()}${q > 1 ? 's' : ''} au choix${plafond}`
}

// Barème inchangé : 1 alcool éligible = 2 crédits, 1 soft = 1 crédit. Le staff
// raisonne en CONSOS (ce qu'il a vendu au groupe), l'app fait la conversion.
const CREDITS_PAR_CONSO = 2

/**
 * Configuration d'un forfait groupe.
 *
 * Le barème interne ne change pas (1 alcool = 2 crédits, 1 soft = 1 crédit),
 * mais le staff ne le manipule plus : il vend « 10 personnes × 3 consos », pas
 * « 6 crédits par personne ». Deux compteurs, un interrupteur, et un
 * récapitulatif en français — la conversion se fait ici.
 */
function ForfaitFields({ f, set }) {
  const consos = Math.max(0, Math.round((Number(f.credits_per_person) || 0) / CREDITS_PAR_CONSO))
  const personnes = f.max_uses === '' || f.max_uses == null ? null : Number(f.max_uses)
  const plat = Number(f.food_tokens_per_person) > 0

  const setConsos = (n) =>
    set('credits_per_person', Math.max(0, Math.min(30, n)) * CREDITS_PAR_CONSO)

  const Stepper = ({ label, hint, value, onChange, suffix }) => (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        padding: 14,
        borderRadius: 14,
        background: C.paper,
        border: `1px solid ${C.line}`,
        marginBottom: 10,
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 500 }}>{label}</div>
        <div style={{ fontSize: 11.5, color: C.faint, marginTop: 2 }}>{hint}</div>
      </div>
      <button onClick={() => onChange(value - 1)} style={stepBtn}>
        −
      </button>
      <div style={{ ...S.money, fontSize: 20, fontWeight: 600, minWidth: 42, textAlign: 'center' }}>
        {value}
        {suffix}
      </div>
      <button onClick={() => onChange(value + 1)} style={stepBtn}>
        +
      </button>
    </div>
  )

  return (
    <>
      <Stepper
        label="Personnes dans le groupe"
        hint="Autant d’activations du code"
        value={personnes ?? 0}
        onChange={(n) => set('max_uses', Math.max(1, Math.min(500, n)))}
      />

      <Stepper
        label="Consos par personne"
        hint="1 conso = 1 alcool, ou 2 softs"
        value={consos}
        onChange={setConsos}
      />

      <button
        onClick={() => set('food_tokens_per_person', plat ? 0 : 1)}
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          width: '100%',
          minHeight: 56,
          padding: '0 14px',
          borderRadius: 14,
          cursor: 'pointer',
          border: `1.5px solid ${plat ? C.terracotta : C.lineHi}`,
          background: plat ? 'rgba(185,106,76,.07)' : C.paper,
          color: C.text,
          marginBottom: 14,
          textAlign: 'left',
        }}
      >
        <span>
          <span style={{ fontSize: 14, fontWeight: 500 }}>Un plat inclus par personne</span>
          <span style={{ display: 'block', fontSize: 11.5, color: C.faint, marginTop: 2 }}>
            Convertible en 1 conso si la personne préfère boire
          </span>
        </span>
        <span style={{ fontFamily: FONT.label, fontWeight: 600, color: plat ? C.terracotta : C.faint }}>
          {plat ? 'OUI' : 'NON'}
        </span>
      </button>

      <div style={{ marginBottom: 16 }}>
        <Banner tone="info">
          <strong>
            {personnes ? `${personnes} personne${personnes > 1 ? 's' : ''}` : 'Groupe'} ·{' '}
            {consos} conso{consos > 1 ? 's' : ''} chacune{plat ? ' · 1 plat chacune' : ''}
          </strong>
          <br />
          Chaque personne saisit le code une fois et retrouve son forfait sur son écran. Une conso =
          1 alcool de la sélection forfait, ou 2 softs. Au-delà, elle règle au prix de la carte.
        </Banner>
      </div>
    </>
  )
}

/**
 * Éditeur des lignes d'un code cadeau.
 *
 * Chaque ligne dit ce qui est offert : soit une catégorie de la carte avec un
 * plafond facultatif (« 1 boisson alcoolisée au choix jusqu'à 15 € »), soit un
 * article précis (« 1 Spritz »). Un code peut en cumuler plusieurs.
 */
function GiftFields({ f, set, venueId, showToast }) {
  const [products, setProducts] = useState([])
  const items = Array.isArray(f.gift_items) ? f.gift_items : []

  useEffect(() => {
    if (!venueId) return
    let dead = false
    supabase
      .from('products')
      .select('id, name, price, universe, subcategory')
      .eq('venue_id', venueId)
      .eq('is_listed', true)
      .order('universe')
      .order('subcategory')
      .order('name')
      .then(({ data }) => {
        if (!dead) setProducts(data || [])
      })
    return () => {
      dead = true
    }
  }, [venueId])

  const nameOf = (id) => products.find((p) => p.id === id)?.name
  const update = (i, patch) => set('gift_items', items.map((it, k) => (k === i ? { ...it, ...patch } : it)))
  const remove = (i) => set('gift_items', items.filter((_, k) => k !== i))
  const add = (mode) =>
    set('gift_items', [
      ...items,
      mode === 'product'
        ? { mode: 'product', product_id: products[0]?.id || '', quantity: 1 }
        : { mode: 'category', category: 'alcohol', quantity: 1, max_value: 15 },
    ])

  return (
    <>
      <div style={{ marginBottom: 12 }}>
        <Banner tone="info">
          Chaque personne qui saisit ce code reçoit des <strong>crédits</strong> — un crédit par
          ligne ci-dessous, chacun donnant droit à un article de votre carte. À la commande, le
          crédit est utilisé automatiquement, et l’équipe voit apparaître dans la fiche du client
          <strong> l’heure exacte et l’article précis</strong> qu’il a pris.
        </Banner>
      </div>

      <div style={{ ...S.label, marginBottom: 8 }}>À quoi donne droit chaque crédit</div>

      {items.length === 0 && (
        <div style={{ fontSize: 12.5, color: C.faint, marginBottom: 10 }}>
          Aucun crédit pour l’instant — ajoutez ce à quoi ils donnent droit ci-dessous.
        </div>
      )}

      <div style={{ display: 'grid', gap: 10, marginBottom: 12 }}>
        {items.map((it, i) => (
          <div
            key={i}
            style={{
              padding: 12,
              borderRadius: 14,
              background: C.paper,
              border: `1.5px solid ${C.terracotta}44`,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
              <span style={{ fontSize: 13, fontWeight: 600, flex: 1 }}>
                🎁 {giftLineLabel(it, nameOf(it.product_id))}
              </span>
              <button
                onClick={() => remove(i)}
                title="Retirer cette ligne"
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: C.danger, fontSize: 14, padding: 0 }}
              >
                ✕
              </button>
            </div>

            {it.mode === 'category' ? (
              <>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 10 }}>
                  {GIFT_CATEGORIES.map((c) => (
                    <button
                      key={c.k}
                      onClick={() => update(i, { category: c.k })}
                      style={{
                        ...S.chip,
                        flex: '1 0 46%',
                        minHeight: 40,
                        fontSize: 11.5,
                        borderColor: it.category === c.k ? C.terracotta : C.lineHi,
                        color: it.category === c.k ? C.terracotta : C.dim,
                      }}
                    >
                      {c.emoji} {c.label}
                    </button>
                  ))}
                </div>
                <div style={{ display: 'flex', gap: 10 }}>
                  <div style={{ flex: 1 }}>
                    <Field label="Quantité">
                      <input
                        style={S.input}
                        type="number"
                        min="1"
                        value={it.quantity ?? 1}
                        onChange={(e) => update(i, { quantity: Math.max(1, Number(e.target.value) || 1) })}
                      />
                    </Field>
                  </div>
                  <div style={{ flex: 1 }}>
                    <Field label="Plafond (€)" hint="Vide = sans plafond">
                      <input
                        style={S.input}
                        type="number"
                        min="0"
                        step="0.5"
                        value={it.max_value ?? ''}
                        onChange={(e) =>
                          update(i, { max_value: e.target.value === '' ? null : Number(e.target.value) })
                        }
                        placeholder="ex. 15"
                      />
                    </Field>
                  </div>
                </div>
                <div style={{ fontSize: 11, color: C.faint, lineHeight: 1.5 }}>
                  Au-delà du plafond, le client règle la différence au bar.
                </div>
              </>
            ) : (
              <>
                <Field label="Article de la carte">
                  <select
                    style={S.input}
                    value={it.product_id || ''}
                    onChange={(e) => update(i, { product_id: e.target.value })}
                  >
                    <option value="">— choisir —</option>
                    {products.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.name} · {eur(p.price)}
                      </option>
                    ))}
                  </select>
                </Field>
                <Field label="Quantité">
                  <input
                    style={S.input}
                    type="number"
                    min="1"
                    value={it.quantity ?? 1}
                    onChange={(e) => update(i, { quantity: Math.max(1, Number(e.target.value) || 1) })}
                  />
                </Field>
              </>
            )}
          </div>
        ))}
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <button onClick={() => add('category')} style={{ ...S.btnGhost, minHeight: 44, fontSize: 12.5 }}>
          + Catégorie au choix
        </button>
        <button
          onClick={() => {
            if (!products.length) return showToast('Aucun article sur la carte de ce lieu.', 'error')
            add('product')
          }}
          style={{ ...S.btnGhost, minHeight: 44, fontSize: 12.5 }}
        >
          + Article précis
        </button>
      </div>

      <Field
        label="Nombre de personnes"
        hint="Combien de personnes peuvent activer ce code. Vide = illimité."
      >
        <input
          style={S.input}
          type="number"
          min="1"
          value={f.max_uses ?? ''}
          onChange={(e) => set('max_uses', e.target.value === '' ? null : Number(e.target.value))}
          placeholder="ex. 6 personnes"
        />
      </Field>
    </>
  )
}

function PromoCodeSheet({ promo, event, venue, onClose, onSaved, showToast }) {
  const [f, setF] = useState(EMPTY_PROMO)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (promo) setF({ ...EMPTY_PROMO, ...promo })
  }, [promo])

  if (!promo) return null
  const set = (k, v) => setF((p) => ({ ...p, [k]: v }))

  async function save() {
    if (!f.code.trim()) return showToast('Le code est obligatoire.', 'error')

    const gifts = Array.isArray(f.gift_items) ? f.gift_items : []
    if (f.kind === 'gift') {
      if (gifts.length === 0) return showToast('Ajoutez au moins un crédit.', 'error')
      if (gifts.some((g) => g.mode === 'product' && !g.product_id))
        return showToast('Choisissez l’article pour chaque crédit « article précis ».', 'error')
    }

    setBusy(true)
    const payload = {
      event_id: event.id,
      code: f.code.trim().toUpperCase(),
      label: f.label?.trim() || 'Promo',
      kind: f.kind,
      value: Number(f.value) || 0,
      min_total: Number(f.min_total) || 0,
      max_uses: f.max_uses === '' || f.max_uses == null ? null : Number(f.max_uses),
      active: !!f.active,
      credits_per_person: Number(f.credits_per_person) || 0,
      food_tokens_per_person: Number(f.food_tokens_per_person) || 0,
      gift_items: f.kind === 'gift' ? gifts : [],
    }
    const { error } = f.id
      ? await supabase.from('promo_codes').update(payload).eq('id', f.id)
      : await supabase.from('promo_codes').insert(payload)
    setBusy(false)
    if (error) return showToast(frError(error), 'error')
    onSaved()
  }

  async function remove() {
    setBusy(true)
    const { error } = await supabase.from('promo_codes').delete().eq('id', f.id)
    setBusy(false)
    if (error) return showToast(frError(error), 'error')
    onSaved()
  }

  return (
    <Sheet open={!!promo} onClose={onClose} title={f.id ? 'Modifier le code' : 'Nouveau code promo'}>
      <Field label="Code" hint="Ce que le client saisit dans son espace de commande">
        <input
          style={{ ...S.input, textTransform: 'uppercase', letterSpacing: 1.5, fontFamily: FONT.label }}
          value={f.code}
          onChange={(e) => set('code', e.target.value.toUpperCase())}
          placeholder="NOTI10"
        />
      </Field>

      <Field label="Nom du code" hint="Pour vous retrouver dans vos codes — non affiché au client">
        <input
          style={S.input}
          value={f.label || ''}
          onChange={(e) => set('label', e.target.value)}
          placeholder="Soirée Noti 1"
        />
      </Field>

      <Field label="Type de code">
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <button
            onClick={() => set('kind', 'percent')}
            style={{
              ...S.chip,
              flex: 1,
              minHeight: 44,
              borderColor: f.kind === 'percent' ? C.terracotta : C.lineHi,
              color: f.kind === 'percent' ? C.terracotta : C.dim,
            }}
          >
            Pourcentage %
          </button>
          <button
            onClick={() => set('kind', 'amount')}
            style={{
              ...S.chip,
              flex: 1,
              minHeight: 44,
              borderColor: f.kind === 'amount' ? C.terracotta : C.lineHi,
              color: f.kind === 'amount' ? C.terracotta : C.dim,
            }}
          >
            Montant fixe €
          </button>
          <button
            onClick={() => set('kind', 'credits')}
            style={{
              ...S.chip,
              flex: '1 0 100%',
              minHeight: 44,
              borderColor: f.kind === 'credits' ? C.terracotta : C.lineHi,
              color: f.kind === 'credits' ? C.terracotta : C.dim,
            }}
          >
            🎟️ Forfait groupe
          </button>
          <button
            onClick={() => set('kind', 'gift')}
            style={{
              ...S.chip,
              flex: '1 0 100%',
              minHeight: 44,
              borderColor: f.kind === 'gift' ? C.terracotta : C.lineHi,
              color: f.kind === 'gift' ? C.terracotta : C.dim,
            }}
          >
            🎁 Crédit offert
          </button>
        </div>
      </Field>

      {f.kind === 'gift' ? (
        <GiftFields f={f} set={set} venueId={venue?.id} showToast={showToast} />
      ) : f.kind === 'credits' ? (
        <ForfaitFields f={f} set={set} />
      ) : (
        <>
          <Field label={f.kind === 'percent' ? 'Valeur (%)' : 'Valeur (€)'}>
            <input
              style={S.input}
              type="number"
              min="0"
              step={f.kind === 'percent' ? 1 : 0.5}
              value={f.value}
              onChange={(e) => set('value', e.target.value)}
            />
          </Field>

          <Field label="Panier minimum" hint="0 = aucun minimum requis">
            <input style={S.input} type="number" min="0" step="0.5" value={f.min_total} onChange={(e) => set('min_total', e.target.value)} />
          </Field>

          <Field label="Nombre d'utilisations max" hint="Vide = illimité">
            <input
              style={S.input}
              type="number"
              min="1"
              value={f.max_uses ?? ''}
              onChange={(e) => set('max_uses', e.target.value)}
              placeholder="Illimité"
            />
          </Field>
        </>
      )}

      <button
        onClick={() => set('active', !f.active)}
        style={{
          ...S.btnGhost,
          marginBottom: 16,
          borderColor: f.active ? C.ok : C.lineHi,
          color: f.active ? C.ok : C.dim,
        }}
      >
        {f.active ? '✓ Actif' : 'Inactif'}
      </button>

      <button disabled={busy} onClick={save} style={{ ...S.btn, opacity: busy ? 0.6 : 1 }}>
        {busy ? '…' : 'Enregistrer'}
      </button>

      {f.id && (
        <button
          disabled={busy}
          onClick={() => {
            if (confirm('Supprimer ce code promo ?')) remove()
          }}
          style={{ ...S.btnGhost, marginTop: 10, borderColor: C.danger, color: C.danger }}
        >
          Supprimer
        </button>
      )}
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
  const [preview, setPreview] = useState(false)

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

  async function reloadNotiMenu() {
    if (
      !window.confirm(
        'Charger / mettre à jour la carte type Noti Club ? Les articles déjà présents (même nom, même univers) seront mis à jour — prix, description, formats — sans être dupliqués. Vos autres articles ne sont pas touchés, et le statut « épuisé »/« retiré » est conservé.'
      )
    )
      return
    setBusy('seed')
    try {
      const { data, error } = await supabase.rpc('seed_noti_menu', { p_venue: venue.id })
      if (error) throw error
      showToast(`Carte Noti Club chargée (${data} articles).`, 'ok')
      load()
    } catch (e) {
      showToast(frError(e), 'error')
    } finally {
      setBusy('')
    }
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
        <button
          disabled={busy === 'seed'}
          onClick={reloadNotiMenu}
          style={{ ...S.btnGhost, minHeight: 46, width: 'auto', padding: '0 16px', fontSize: 12 }}
          title="Charger ou mettre à jour la carte type Noti Club"
        >
          {busy === 'seed' ? '…' : '🍸 Carte Noti Club'}
        </button>
        <button
          onClick={() => setPreview(true)}
          style={{ ...S.btnGhost, minHeight: 46, width: 'auto', padding: '0 16px', fontSize: 12 }}
          title="Voir la carte telle qu'un client la voit"
        >
          👁️ Aperçu client
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

      <ClientMenuPreview products={products} open={preview} onClose={() => setPreview(false)} />
    </div>
  )
}

// --------------------------------------------------- Aperçu client (lecture seule)
// Rejoue exactement le rendu de la carte côté client (mêmes composants,
// même filtre is_listed), sans passer par un QR ni une identification.
function ClientMenuPreview({ products, open, onClose }) {
  const [lang, setLang] = useState('fr')
  const [universe, setUniverse] = useState('drinks')
  const [subcat, setSubcat] = useState(null)

  const listed = products.filter((p) => p.is_listed)

  const universesAvailable = UNIVERSES.filter((u) => listed.some((p) => p.universe === u.k))
  const subcats = [...new Set(listed.filter((p) => p.universe === universe).map((p) => p.subcategory))]

  useEffect(() => {
    if (!open) return
    if (universesAvailable.length && !universesAvailable.some((u) => u.k === universe)) {
      setUniverse(universesAvailable[0].k)
    }
  }, [open, universesAvailable, universe])

  useEffect(() => {
    setSubcat((s) => (subcats.includes(s) ? s : subcats[0] ?? null))
  }, [subcats])

  // Défilement continu, comme côté client : la puce active suit le scroll.
  const sectionRefs = useRef({})
  const chipRefs = useRef({})
  const scrollLock = useRef(0)

  useEffect(() => {
    if (!open) return
    const els = subcats.map((c) => sectionRefs.current[c]).filter(Boolean)
    if (!els.length) return
    const io = new IntersectionObserver(
      (entries) => {
        if (Date.now() < scrollLock.current) return
        const hit = entries.filter((e) => e.isIntersecting)
        if (hit.length) {
          const top = hit.reduce((a, b) => (a.boundingClientRect.top < b.boundingClientRect.top ? a : b))
          setSubcat(top.target.dataset.subcat)
        }
      },
      { rootMargin: '-8px 0px -75% 0px', threshold: 0 }
    )
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [subcats, open])

  useEffect(() => {
    if (!open || !subcat) return
    glideChipIntoView(chipRefs.current[subcat])
  }, [subcat, open])

  const chipsBarRef = useRef(null)

  function goToSubcat(c) {
    scrollLock.current = Date.now() + 1100
    setSubcat(c)
    glideIntoView(sectionRefs.current[c], (chipsBarRef.current?.offsetHeight || 52) + 10)
  }

  return (
    <Sheet open={open} onClose={onClose} title="Aperçu — vue client" maxHeight="92vh">
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        {['fr', 'en', 'es'].map((l) => (
          <button
            key={l}
            onClick={() => setLang(l)}
            style={{
              ...S.chip,
              borderColor: lang === l ? C.indigo : C.lineHi,
              color: lang === l ? C.indigo : C.dim,
            }}
          >
            {l.toUpperCase()}
          </button>
        ))}
      </div>

      {listed.length === 0 ? (
        <Empty emoji="📋" title="Aucun article publié" sub="Rien à afficher tant que la carte est vide ou entièrement retirée." />
      ) : (
        <>
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

          <ScrollHint sticky top={0} barRef={chipsBarRef} style={{ marginBottom: 14, background: C.creamSoft }}>
            {subcats.map((c) => (
              <button
                key={c}
                ref={(el) => {
                  chipRefs.current[c] = el
                }}
                onClick={() => goToSubcat(c)}
                style={{
                  ...S.chip,
                  flexShrink: 0,
                  borderColor: subcat === c ? C.indigo : C.lineHi,
                  color: subcat === c ? C.indigo : C.dim,
                  background: subcat === c ? 'rgba(106,95,214,.08)' : 'transparent',
                }}
              >
                {c}
              </button>
            ))}
          </ScrollHint>

          {subcats.map((c) => (
            <div
              key={c}
              ref={(el) => {
                sectionRefs.current[c] = el
              }}
              data-subcat={c}
              style={{ marginBottom: 22, scrollMarginTop: 8 }}
            >
              <div style={{ ...S.h2, marginBottom: 10, fontSize: 13 }}>{c}</div>
              <div style={{ display: 'grid', gap: 10 }}>
                {listed
                  .filter((p) => p.universe === universe && p.subcategory === c)
                  .map((p) => (
                    <ProductCard key={p.id} product={p} lang={lang} disabled onAdd={() => {}} />
                  ))}
              </div>
            </div>
          ))}
          {subcats.length === 0 && <Empty emoji="🍸" title="Rien dans cette sélection" />}
        </>
      )}

      <div style={{ textAlign: 'center', color: C.faint, fontSize: 11, marginTop: 18 }}>
        Aperçu en lecture seule — le bouton d’ajout est désactivé.
      </div>
    </Sheet>
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
  const [ficheFor, setFicheFor] = useState(null)
  const [dmFor, setDmFor] = useState(null)

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
            onClick={() => setFicheFor(r.id)}
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

      <ClientFicheSheet
        customerId={ficheFor}
        event={event}
        onClose={() => setFicheFor(null)}
        onChanged={load}
        onMessage={(target) => {
          setFicheFor(null)
          setDmFor(target)
        }}
        showToast={showToast}
      />

      <DirectMessageSheet
        target={dmFor}
        event={event}
        onClose={() => setDmFor(null)}
        onSent={(res) => {
          setDmFor(null)
          showToast(
            res.degraded
              ? 'Message publié dans l’onglet 💬 du client. Push et SMS non envoyés : ' +
                  'la fonction notify n’est pas déployée.'
              : 'Message envoyé.',
            res.degraded ? 'warn' : 'ok'
          )
        }}
        showToast={showToast}
      />
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

/**
 * Gestion de l'équipe — réservée au propriétaire du lieu.
 *
 * Une invitation est une simple ligne (lieu + e-mail + rôle) : la personne
 * invitée crée son compte avec cette adresse (ou se connecte si elle en a
 * déjà un) et se retrouve rattachée à l'équipe dès l'ouverture de l'espace,
 * sans qu'aucun e-mail ait besoin d'être envoyé.
 */
function TeamCard({ venue, session, showToast }) {
  const [members, setMembers] = useState([])
  const [invites, setInvites] = useState([])
  const [email, setEmail] = useState('')
  const [role, setRole] = useState('staff')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)

  const load = useCallback(async () => {
    const [{ data: m }, { data: i }] = await Promise.all([
      supabase.from('staff_members').select('*').eq('venue_id', venue.id).order('created_at'),
      supabase.from('staff_invites').select('*').eq('venue_id', venue.id).order('created_at', { ascending: false }),
    ])
    setMembers(m || [])
    setInvites(i || [])
    setLoading(false)
  }, [venue.id])

  useEffect(() => {
    load()
  }, [load])

  async function invite() {
    const mail = email.trim().toLowerCase()
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(mail)) return showToast('Adresse e-mail invalide.', 'error')
    setBusy(true)
    const { error } = await supabase
      .from('staff_invites')
      .upsert({ venue_id: venue.id, email: mail, role, invited_by: session.user.id }, { onConflict: 'venue_id,email' })
    setBusy(false)
    if (error) return showToast(frError(error), 'error')
    setEmail('')
    showToast(`${mail} fait maintenant partie de l’équipe dès sa première connexion.`, 'ok')
    load()
  }

  async function removeInvite(id) {
    const { error } = await supabase.from('staff_invites').delete().eq('id', id)
    if (error) return showToast(frError(error), 'error')
    load()
  }

  async function removeMember(m) {
    if (m.role === 'owner') return showToast('Le propriétaire ne peut pas être retiré.', 'error')
    if (!confirm('Retirer cette personne de l’équipe ?')) return
    const { error } = await supabase.from('staff_members').delete().eq('id', m.id)
    if (error) return showToast(frError(error), 'error')
    // L'invitation correspondante est supprimée aussi, sinon la personne serait
    // réintégrée automatiquement à sa prochaine connexion.
    const inv = invites.find((i) => i.accepted_by === m.user_id)
    if (inv) await supabase.from('staff_invites').delete().eq('id', inv.id)
    showToast('Personne retirée de l’équipe.', 'ok')
    load()
  }

  async function changeRole(m, next) {
    const { error } = await supabase.from('staff_members').update({ role: next }).eq('id', m.id)
    if (error) return showToast(frError(error), 'error')
    load()
  }

  const pending = invites.filter((i) => !i.accepted_at)
  const emailFor = (m) => invites.find((i) => i.accepted_by === m.user_id)?.email

  return (
    <div style={{ ...S.card, marginBottom: 14 }}>
      <div style={{ ...S.h2, marginBottom: 6 }}>Équipe</div>
      <div style={{ fontSize: 12, color: C.dim, marginBottom: 14, lineHeight: 1.55 }}>
        Invitez par e-mail. La personne crée son compte avec cette adresse depuis l’écran
        « Espace équipe » et rejoint automatiquement ce lieu — aucun code à transmettre.
      </div>

      {loading ? (
        <Spinner label="Chargement de l’équipe…" />
      ) : (
        <>
          <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
            {members.map((m) => {
              const isMe = m.user_id === session.user.id
              return (
                <div
                  key={m.id}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                    padding: 11,
                    borderRadius: 12,
                    background: C.paper,
                    border: `1px solid ${C.line}`,
                  }}
                >
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div style={{ fontSize: 13.5, fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      {isMe ? session.user.email : emailFor(m) || 'Membre de l’équipe'}
                      {isMe && <span style={{ color: C.faint, fontWeight: 400 }}> · vous</span>}
                    </div>
                    <div style={{ fontSize: 11, color: C.faint, marginTop: 2 }}>{ROLE_LABEL[m.role] || m.role}</div>
                  </div>
                  {m.role !== 'owner' && (
                    <>
                      <select
                        value={m.role}
                        onChange={(e) => changeRole(m, e.target.value)}
                        style={{ ...S.input, width: 'auto', minHeight: 38, padding: '0 8px', fontSize: 12 }}
                      >
                        <option value="staff">Équipe</option>
                        <option value="manager">Manager</option>
                      </select>
                      <button
                        onClick={() => removeMember(m)}
                        title="Retirer de l’équipe"
                        style={{ ...stepBtn, width: 38, height: 38, fontSize: 14, color: C.danger }}
                      >
                        ✕
                      </button>
                    </>
                  )}
                </div>
              )
            })}
          </div>

          {pending.length > 0 && (
            <>
              <div style={{ ...S.label, marginBottom: 6 }}>Invitations en attente</div>
              <div style={{ display: 'grid', gap: 8, marginBottom: 14 }}>
                {pending.map((i) => (
                  <div
                    key={i.id}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 10,
                      padding: 11,
                      borderRadius: 12,
                      background: 'rgba(201,130,31,.07)',
                      border: `1px dashed ${C.warn}66`,
                    }}
                  >
                    <div style={{ minWidth: 0, flex: 1 }}>
                      <div style={{ fontSize: 13.5, overflow: 'hidden', textOverflow: 'ellipsis' }}>{i.email}</div>
                      <div style={{ fontSize: 11, color: C.faint, marginTop: 2 }}>
                        {ROLE_LABEL[i.role] || i.role} · en attente de première connexion
                      </div>
                    </div>
                    <button
                      onClick={() => removeInvite(i.id)}
                      title="Annuler l’invitation"
                      style={{ ...stepBtn, width: 38, height: 38, fontSize: 14, color: C.danger }}
                    >
                      ✕
                    </button>
                  </div>
                ))}
              </div>
            </>
          )}

          <Field label="Inviter quelqu’un">
            <input
              style={S.input}
              type="email"
              inputMode="email"
              autoComplete="off"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="prenom@exemple.fr"
            />
          </Field>
          <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
            {[
              ['staff', 'Équipe', 'Bar, caisse, clients'],
              ['manager', 'Manager', 'Accès complet'],
            ].map(([k, label, hint]) => (
              <button
                key={k}
                onClick={() => setRole(k)}
                style={{
                  ...S.chip,
                  flex: 1,
                  minHeight: 52,
                  flexDirection: 'column',
                  gap: 2,
                  borderColor: role === k ? C.terracotta : C.lineHi,
                  color: role === k ? C.terracotta : C.dim,
                }}
              >
                <span style={{ fontWeight: 600 }}>{label}</span>
                <span style={{ fontSize: 9.5, opacity: 0.8 }}>{hint}</span>
              </button>
            ))}
          </div>
          <button disabled={busy || !email.trim()} onClick={invite} style={{ ...S.btnGhost, opacity: busy || !email.trim() ? 0.5 : 1 }}>
            {busy ? '…' : 'Envoyer l’invitation'}
          </button>
        </>
      )}
    </div>
  )
}

function ReglagesTab({ venue, event, session, role, onReload, showToast }) {
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
          capacity: e.capacity == null || e.capacity === '' ? null : Number(e.capacity),
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
        <Field
          label="Capacité de la salle"
          hint="Sert de repère à la jauge d'affluence dans l'onglet Orga. Vide = pas de jauge, juste le compte."
        >
          <input
            style={S.input}
            type="number"
            min="0"
            value={e.capacity ?? ''}
            onChange={(ev) => setE({ ...e, capacity: ev.target.value === '' ? null : Number(ev.target.value) })}
            placeholder="ex. 250"
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
        <Field
          label="Langues"
          hint="L'app est entièrement traduite. Les noms de vos produits suivent les traductions saisies dans la carte."
        >
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

      {role === 'owner' && <TeamCard venue={venue} session={session} showToast={showToast} />}

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
        {session.user.email} · {ROLE_LABEL[role] || role}
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


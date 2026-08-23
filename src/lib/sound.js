// Noti Calling — sons générés en WebAudio (aucun asset à charger).
//  · chime()  : sonnerie douce côté client ("commande prête").
//  · Alarm    : alarme agressive côté bar, qui ne s'arrête QUE sur "Accepter".

let ctx = null

function audioCtx() {
  if (typeof window === 'undefined') return null
  if (!ctx) {
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return null
    ctx = new AC()
  }
  if (ctx.state === 'suspended') ctx.resume().catch(() => {})
  return ctx
}

/** À appeler sur la première interaction utilisateur (déblocage iOS). */
export function unlockAudio() {
  const ac = audioCtx()
  if (!ac) return
  const o = ac.createOscillator()
  const g = ac.createGain()
  g.gain.value = 0.0001
  o.connect(g).connect(ac.destination)
  o.start()
  o.stop(ac.currentTime + 0.02)
}

function beep(freq, start, dur, gain = 0.16, type = 'sine') {
  const ac = audioCtx()
  if (!ac) return
  const o = ac.createOscillator()
  const g = ac.createGain()
  o.type = type
  o.frequency.setValueAtTime(freq, ac.currentTime + start)
  g.gain.setValueAtTime(0.0001, ac.currentTime + start)
  g.gain.exponentialRampToValueAtTime(gain, ac.currentTime + start + 0.02)
  g.gain.exponentialRampToValueAtTime(0.0001, ac.currentTime + start + dur)
  o.connect(g).connect(ac.destination)
  o.start(ac.currentTime + start)
  o.stop(ac.currentTime + start + dur + 0.05)
}

/** Sonnerie douce (client) — arpège montant. */
export function chime() {
  beep(880, 0, 0.28, 0.12)
  beep(1174.66, 0.16, 0.3, 0.12)
  beep(1567.98, 0.32, 0.45, 0.1)
}

/** Petit "tap" de confirmation. */
export function tick() {
  beep(660, 0, 0.09, 0.08, 'triangle')
}

/**
 * Sonneries d'alerte comptoir.
 *
 * Retour terrain : « la sonnerie actuelle est très agressive. C'est efficace
 * dans le bruit, mais selon la typologie d'établissement les attentes
 * diffèrent. » L'ancienne sonnerie reste disponible sous le nom « sirène » —
 * c'est encore le bon choix dans un club — mais elle n'est plus imposée.
 *
 * Chaque profil décrit une salve : les notes, l'écart entre deux salves, et le
 * motif de vibration. Rien à télécharger, tout est généré à la volée.
 */
export const RINGTONES = [
  {
    k: 'siren',
    label: 'Sirène',
    hint: 'Perce le bruit. Pour un club ou un bar bondé.',
    every: 1400,
    gain: 0.32,
    vibrate: [200, 100, 200, 100, 400],
    notes: [
      [1046, 0, 0.16, 'square'],
      [784, 0.18, 0.16, 'square'],
      [1046, 0.36, 0.16, 'square'],
      [784, 0.54, 0.22, 'square'],
    ],
  },
  {
    k: 'bell',
    label: 'Cloche',
    hint: 'Nette sans être stridente. Pour un bar à cocktails.',
    every: 2000,
    gain: 0.26,
    vibrate: [180, 120, 180],
    notes: [
      [1318.51, 0, 0.32, 'sine'],
      [1760, 0.14, 0.42, 'sine'],
    ],
  },
  {
    k: 'soft',
    label: 'Discrète',
    hint: 'Deux notes basses. Pour une salle calme ou un service en terrasse.',
    every: 2600,
    gain: 0.18,
    vibrate: [140],
    notes: [
      [587.33, 0, 0.3, 'triangle'],
      [880, 0.2, 0.36, 'triangle'],
    ],
  },
]

export const DEFAULT_RINGTONE = 'siren'

const ringtoneOf = (k) => RINGTONES.find((r) => r.k === k) || RINGTONES[0]

/** Joue une salve une seule fois — sert à l'écoute avant de choisir. */
export function previewRingtone(k) {
  const r = ringtoneOf(k)
  for (const [freq, at, dur, type] of r.notes) beep(freq, at, dur, r.gain, type)
}

/**
 * Alarme comptoir : boucle tant que stop() n'est pas appelé.
 * Volontairement insistante — c'est le but : personne ne rate une commande.
 */
export class Alarm {
  constructor(kind = DEFAULT_RINGTONE) {
    this.timer = null
    this.running = false
    this.kind = kind
  }

  /** Changer de sonnerie en cours de service prend effet à la salve suivante. */
  setKind(kind) {
    this.kind = kind
  }

  start() {
    if (this.running) return
    this.running = true
    const burst = () => {
      if (!this.running) return
      const r = ringtoneOf(this.kind)
      for (const [freq, at, dur, type] of r.notes) beep(freq, at, dur, r.gain, type)
      try {
        navigator.vibrate?.(r.vibrate)
      } catch (_) {}
      // L'écart dépend du profil : on replanifie à chaque salve plutôt que de
      // figer un intervalle au démarrage.
      if (this.running) this.timer = setTimeout(burst, r.every)
    }
    burst()
  }

  stop() {
    this.running = false
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    try {
      navigator.vibrate?.(0)
    } catch (_) {}
  }
}

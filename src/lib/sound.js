// TAPZ — sons générés en WebAudio (aucun asset à charger).
//  · chime()  : sonnerie douce côté client ("commande prête").
//  · Alarm    : alarme agressive côté comptoir, qui ne s'arrête QUE sur "Accepter".

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
 * Alarme comptoir : boucle sirène tant que stop() n'est pas appelé.
 * Volontairement pénible — c'est le but : personne ne rate une commande.
 */
export class Alarm {
  constructor() {
    this.timer = null
    this.running = false
  }

  start() {
    if (this.running) return
    this.running = true
    const burst = () => {
      if (!this.running) return
      beep(1046, 0, 0.16, 0.32, 'square')
      beep(784, 0.18, 0.16, 0.32, 'square')
      beep(1046, 0.36, 0.16, 0.32, 'square')
      beep(784, 0.54, 0.22, 0.32, 'square')
      try {
        navigator.vibrate?.([200, 100, 200, 100, 400])
      } catch (_) {}
    }
    burst()
    this.timer = setInterval(burst, 1400)
  }

  stop() {
    this.running = false
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    try {
      navigator.vibrate?.(0)
    } catch (_) {}
  }
}

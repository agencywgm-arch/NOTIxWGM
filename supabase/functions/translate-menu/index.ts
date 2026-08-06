// ============================================================
// TAPZ — Edge Function : translate-menu
// Traduction automatique de la carte via l'API Claude (JSON in / JSON out).
//
// Body attendu :
//   {
//     "targetLangs": ["en", "es"],          // codes ISO
//     "items": [{ "id": "...", "name": "...", "description": "..." }]
//   }
//
// Réponse :
//   { "translations": { "<item id>": { "en": {"name","description"}, ... } } }
//
// Secret requis : ANTHROPIC_API_KEY
// ============================================================

import Anthropic from 'npm:@anthropic-ai/sdk@0.68.0'
import { json, preflight } from '../_shared/cors.ts'

const LANG_NAMES: Record<string, string> = {
  en: 'anglais',
  es: 'espagnol',
  it: 'italien',
  de: 'allemand',
  pt: 'portugais',
  nl: 'néerlandais',
  ar: 'arabe',
  ja: 'japonais',
  zh: 'chinois simplifié',
  ru: 'russe',
}

const client = new Anthropic({ apiKey: Deno.env.get('ANTHROPIC_API_KEY') ?? '' })

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  if (!Deno.env.get('ANTHROPIC_API_KEY')) {
    return json({ error: 'ANTHROPIC_API_KEY non configurée' }, 500)
  }

  let payload: { targetLangs?: string[]; items?: Array<Record<string, string>> }
  try {
    payload = await req.json()
  } catch {
    return json({ error: 'JSON invalide' }, 400)
  }

  const langs = (payload.targetLangs ?? []).filter(Boolean).slice(0, 6)
  const items = (payload.items ?? []).slice(0, 120)

  if (!langs.length) return json({ error: 'targetLangs requis' }, 400)
  if (!items.length) return json({ translations: {} })

  // Schéma de sortie : un objet par article, une entrée par langue.
  const langSchema = {
    type: 'object',
    properties: Object.fromEntries(
      langs.map((l) => [
        l,
        {
          type: 'object',
          properties: {
            name: { type: 'string' },
            description: { type: 'string' },
          },
          required: ['name', 'description'],
          additionalProperties: false,
        },
      ])
    ),
    required: langs,
    additionalProperties: false,
  }

  const schema = {
    type: 'object',
    properties: {
      translations: {
        type: 'array',
        items: {
          type: 'object',
          properties: { id: { type: 'string' }, langs: langSchema },
          required: ['id', 'langs'],
          additionalProperties: false,
        },
      },
    },
    required: ['translations'],
    additionalProperties: false,
  }

  const system = [
    "Tu traduis la carte d'un bar / club (cocktails, spiritueux, shots, softs, snacks).",
    'Registre : court, commercial, lisible sur un téléphone dans un bar sombre.',
    'Conserve tels quels les noms propres, marques et noms de cocktails établis',
    "(Mojito, Negroni, Aperol Spritz…) : ne les traduis pas, ne les invente pas.",
    "N'ajoute aucun ingrédient ni allégation absente du texte source.",
    'Si la description source est vide, renvoie une chaîne vide.',
    `Langues cibles : ${langs.map((l) => `${l} (${LANG_NAMES[l] ?? l})`).join(', ')}.`,
  ].join(' ')

  const userPayload = items.map((i) => ({
    id: i.id,
    name: i.name ?? '',
    description: i.description ?? '',
  }))

  try {
    const response = await client.beta.messages.create({
      model: 'claude-opus-5',
      max_tokens: 16000,
      // Repli serveur automatique si un classifieur décline la requête.
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: {
        effort: 'low', // tâche routinière : on privilégie latence et coût
        format: { type: 'json_schema', schema },
      },
      system,
      messages: [
        {
          role: 'user',
          content:
            'Traduis chaque article. Renvoie exactement un objet par id fourni.\n\n' +
            JSON.stringify(userPayload, null, 2),
        },
      ],
    })

    // Un refus renvoie un HTTP 200 avec content vide : à tester avant de lire.
    if (response.stop_reason === 'refusal') {
      return json(
        { error: 'Requête déclinée par le modèle', category: response.stop_details?.category ?? null },
        422
      )
    }

    const text = response.content.find((b) => b.type === 'text')?.text ?? '{}'
    const parsed = JSON.parse(text) as {
      translations: Array<{ id: string; langs: Record<string, { name: string; description: string }> }>
    }

    const out: Record<string, Record<string, { name: string; description: string }>> = {}
    for (const row of parsed.translations ?? []) out[row.id] = row.langs

    return json({ translations: out })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})

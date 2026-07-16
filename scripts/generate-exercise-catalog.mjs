#!/usr/bin/env node
// Maps the Free Exercise DB (public domain, Unlicense) into Baseline's ExerciseDefinition schema.
//
// Output: Baseline/Resources/ExerciseCatalog/fedb-catalog.json — a plain array of ExerciseDefinition
// JSON objects (no curated built-ins; the app merges those in and drops any FEDB duplicate). Enum raw
// values here MUST match the Swift enums exactly (Muscle, Equipment, MovementPattern, Modality, Mechanic,
// ExerciseLevel, ExerciseTag, ActivityCategory, MetricType) — a wrong value fails the Swift decode, which
// the ExerciseCatalogSeedTests decode test guards against.
//
// Usage: node scripts/generate-exercise-catalog.mjs

import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const source = JSON.parse(readFileSync(join(root, 'scripts/data/free-exercise-db.json'), 'utf8'))
const outPath = join(root, 'Baseline/Resources/ExerciseCatalog/fedb-catalog.json')

// FEDB muscle → Baseline Muscle. FEDB never splits delts (only "shoulders") and has no hip flexors /
// obliques / upper-vs-front distinctions, so those Baseline muscles stay unpopulated from this source.
const MUSCLE = {
  abdominals: 'abdominals', abductors: 'abductors', adductors: 'adductors', biceps: 'biceps',
  calves: 'calves', chest: 'chest', forearms: 'forearms', glutes: 'glutes', hamstrings: 'hamstrings',
  lats: 'lats', 'lower back': 'lowerBack', 'middle back': 'upperBack', neck: 'neck',
  quadriceps: 'quadriceps', shoulders: 'frontDelts', traps: 'traps', triceps: 'triceps',
}

// FEDB equipment → Baseline Equipment. Gear Baseline has no case for (foam roller, stability ball) → other.
const EQUIPMENT = {
  barbell: 'barbell', dumbbell: 'dumbbell', kettlebells: 'kettlebell', cable: 'cable', machine: 'machine',
  'body only': 'bodyweight', bands: 'band', 'medicine ball': 'medicineBall', 'exercise ball': 'other',
  'e-z curl bar': 'ezBar', 'foam roll': 'other', other: 'other',
}

// FEDB category → { modality, tag, activityCategory (legacy) }.
const CATEGORY = {
  strength: { modality: 'resistance', tag: null, activity: 'strength' },
  powerlifting: { modality: 'resistance', tag: 'powerlifting', activity: 'strength' },
  'olympic weightlifting': { modality: 'resistance', tag: 'olympicWeightlifting', activity: 'strength' },
  strongman: { modality: 'resistance', tag: 'strongman', activity: 'strength' },
  plyometrics: { modality: 'resistance', tag: 'plyometric', activity: 'other' },
  cardio: { modality: 'cardio', tag: null, activity: 'other' },
  stretching: { modality: 'mobility', tag: 'mobility', activity: 'other' },
}

// Modality → the metrics an exercise supports + a sensible default selection.
const METRICS = {
  resistance: { supported: ['reps', 'load', 'rpe'], defaults: ['reps', 'load'] },
  cardio: { supported: ['duration', 'distance', 'calories', 'pace', 'rpe'], defaults: ['duration'] },
  mobility: { supported: ['duration', 'reps', 'rpe'], defaults: ['duration'] },
}

const LEVELS = new Set(['beginner', 'intermediate', 'expert'])

function slug(id, name) {
  const base = (id || name || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')
  return base || 'exercise'
}

// Movement pattern from FEDB `force` plus name keywords. Compound lower-body / locomotion patterns are
// listed before push/pull/hold so a thruster reads as [squat, push], and the list is capped at 2.
function patterns(force, name) {
  const n = name.toLowerCase()
  const named = []
  if (/\bsquat\b/.test(n)) named.push('squat')
  if (/\blunge\b/.test(n)) named.push('lunge')
  if (/deadlift|good ?morning|romanian|\brdl\b|hip hinge|kettlebell swing/.test(n)) named.push('hinge')
  if (/carry|farmer|yoke|suitcase/.test(n)) named.push('carry')
  if (/\brun\b|sprint|\bjog\b/.test(n)) named.push('gait')
  if (/twist|russian|wood ?chop|rotation/.test(n)) named.push('rotation')
  const forced = force === 'push' ? ['push'] : force === 'pull' ? ['pull'] : force === 'static' ? ['hold'] : []
  const ordered = [...named, ...forced.filter((p) => !named.includes(p))]
  return ordered.slice(0, 2)
}

const seenIDs = new Set()
const out = []
for (const ex of source) {
  if (!ex.name) continue
  const cat = CATEGORY[ex.category]
  if (!cat) throw new Error(`Unmapped category: ${ex.category}`)

  let id = slug(ex.id, ex.name)
  while (seenIDs.has(id)) id = `${id}_x`
  seenIDs.add(id)

  const primary = (ex.primaryMuscles || []).map((m) => MUSCLE[m]).filter(Boolean)
  const secondary = (ex.secondaryMuscles || []).map((m) => MUSCLE[m]).filter(Boolean)
  const equipment = ex.equipment && EQUIPMENT[ex.equipment] ? [EQUIPMENT[ex.equipment]] : []
  const pats = patterns(ex.force, ex.name)
  const activity = pats.includes('carry') ? 'carry' : cat.activity
  const level = LEVELS.has(ex.level) ? ex.level : 'intermediate'
  const metrics = METRICS[cat.modality]
  const tags = cat.tag ? [cat.tag] : []

  const def = {
    id,
    name: ex.name,
    category: activity,
    supported: metrics.supported,
    defaults: metrics.defaults,
    aliases: [],
    primaryMuscles: primary,
    secondaryMuscles: secondary,
    patterns: pats,
    equipment,
    modality: cat.modality,
    level,
    tags,
  }
  if (ex.mechanic === 'compound' || ex.mechanic === 'isolation') def.mechanic = ex.mechanic
  out.push(def)
}

const json = JSON.stringify(out, null, 2) + '\n'
writeFileSync(outPath, json)
const checksum = createHash('sha256').update(json).digest('hex')
console.log(`Wrote ${out.length} exercises → ${outPath}`)
console.log(`sha256(fedb-catalog.json) = ${checksum}`)

/**
 * The Baseline tool contract. These schemas are the ONLY things the model can request; the app
 * maps each returned `tool_use` (by name) to a validated `AgentTools.Call` and executes it locally,
 * where the state lives. Keep names + params in lock-step with Baseline/Shared/Services/AgentTools.swift
 * and ToolCallMapper.swift.
 */
export const TOOLS = [
  {
    name: "get_today",
    description: "Read today's current plan, readiness, band, certainty, main limiter, and any active constraints. Call this before answering questions about today.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "explain",
    description: "Get a plain-language explanation of why today's plan is what it is (limiter, reasons, what to avoid).",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "set_time_available",
    description: "Set how many minutes the athlete has to train today. Pass null to clear.",
    input_schema: {
      type: "object",
      properties: { minutes: { type: ["integer", "null"], description: "Minutes available, e.g. 30. null to clear." } },
      required: ["minutes"],
    },
  },
  {
    name: "set_equipment",
    description: "Set the equipment the athlete has access to today (e.g. ['gym','barbell'] or ['bodyweight']). Pass null to clear.",
    input_schema: {
      type: "object",
      properties: { equipment: { type: ["array", "null"], items: { type: "string" } } },
      required: ["equipment"],
    },
  },
  {
    name: "set_traveling",
    description: "Set whether the athlete is traveling today.",
    input_schema: {
      type: "object",
      properties: { traveling: { type: "boolean" } },
      required: ["traveling"],
    },
  },
  {
    name: "set_illness",
    description: "Set whether the athlete is sick/unwell today. When true, the plan drops to recovery.",
    input_schema: {
      type: "object",
      properties: { illness: { type: "boolean" } },
      required: ["illness"],
    },
  },
  {
    name: "set_sleep",
    description: "Record how long the athlete slept last night, in hours, when they tell you (e.g. 'four hours' -> 4, 'about seven and a half' -> 7.5). This DOES affect the plan. Pass null to clear.",
    input_schema: {
      type: "object",
      properties: { hours: { type: ["number", "null"], description: "Hours slept, e.g. 4 or 7.5. null to clear." } },
      required: ["hours"],
    },
  },
  {
    name: "set_checkin",
    description: "Record the athlete's subjective check-in from how they describe feeling. This DOES affect the plan (unlike set_note). Each field is 1-5 where 5 is best/most recovered. Include ONLY the fields they actually described; omit the rest so you don't overwrite earlier answers.",
    input_schema: {
      type: "object",
      properties: {
        energy: { type: ["number", "null"], description: "1 = exhausted/wiped, 5 = fully energized." },
        mood: { type: ["number", "null"], description: "1 = terrible, 5 = great." },
        stress: { type: ["number", "null"], description: "1 = extremely stressed, 5 = totally calm. High stress is a LOW number." },
        soreness: { type: ["number", "null"], description: "1 = very sore / bad DOMS, 5 = no soreness. Very sore is a LOW number." },
      },
    },
  },
  {
    name: "set_note",
    description: "Store a free-text note for today. Use ONLY for context that should NOT change the plan. For sleep or how they feel, use set_sleep / set_checkin instead.",
    input_schema: {
      type: "object",
      properties: { note: { type: "string" } },
      required: ["note"],
    },
  },
  {
    name: "upsert_constraint",
    description: "Log or update an injury or pain. Omit id to create; pass an existing id to update. Constraints persist across days until resolved and can gate the plan even when readiness is high.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Existing constraint id to update; omit to create." },
        kind: { type: "string", enum: ["injury", "pain"] },
        location: { type: "string", description: "Body location, e.g. 'right Achilles'." },
        severity: { type: "integer", minimum: 0, maximum: 3, description: "0 none, 1 mild, 2 moderate, 3 high." },
        affectsTraining: { type: "boolean", description: "Whether it actually limits training. If false it's just noted and won't change the plan." },
      },
      required: ["kind", "location", "severity", "affectsTraining"],
    },
  },
  {
    name: "resolve_constraint",
    description: "Mark a constraint resolved by its id.",
    input_schema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
    },
  },
  {
    name: "open_apple_health_setup",
    description: "Start the Apple Health connection flow on the athlete's device (presents the system permission sheet to import sleep, resting HR, and history). Call this when they want to connect Apple Health — don't just tell them where the button is. Only when the capability state says Apple Health is supported and not yet connected.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "get_sleep",
    description: "Retrieve the athlete's sleep from Apple Health for a recent night. ALWAYS call this to answer any question about their sleep (e.g. 'how did I sleep', 'my sleep yesterday') instead of saying you don't have it — the app queries HealthKit on the device and returns real data. Returns raw Apple Health stages/durations plus Baseline's own computed sleep score (keep those distinct — Apple does not provide a 'sleep score').",
    input_schema: {
      type: "object",
      properties: { nights_ago: { type: "integer", minimum: 0, description: "0 = last night, 1 = the night before, etc." } },
    },
  },
  {
    name: "get_hrv_readings",
    description: "Retrieve the athlete's recent HRV readings taken in Baseline (the morning scans), newest first with dates. ALWAYS call this to answer questions about their HRV or reading history instead of answering from memory.",
    input_schema: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 30, description: "How many recent readings to return (default 7)." } },
    },
  },
  {
    name: "get_resting_heart_rate",
    description: "Retrieve the athlete's resting heart rate trend from Apple Health (latest value + recent daily values + average). ALWAYS call this to answer questions about resting HR instead of guessing.",
    input_schema: {
      type: "object",
      properties: { days: { type: "integer", minimum: 1, maximum: 90, description: "How many days back to look (default 7)." } },
    },
  },
  {
    name: "get_current_workout",
    description: "Read the current structured workout (blocks → exercises → sets). Call before editing when you're unsure of the structure, or to answer what today's workout is.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "start_workout",
    description: "Begin the athlete's workout — activates a live logging session so sets can be checked off, and returns the active session id. Safe to call immediately when a workout exists and no session is already active. The workout must already exist (see the current-workout index in the state block); if none exists, offer to build one instead of calling this. Idempotent — calling it when already active just reports the running session.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "complete_workout",
    description: "Finalize the in-progress workout's performed log (the athlete is done). Only meaningful after start_workout; it never touches the planned workout. IMPORTANT: call it FIRST with confirm=false — if sets remain unlogged the tool returns a warning like 'You still have 4 unlogged sets…' and does NOT complete. Relay that to the athlete and only call again with confirm=true once they say to finish anyway. When nothing is unlogged it completes directly.",
    input_schema: {
      type: "object",
      properties: {
        confirm: { type: "boolean", description: "Set true ONLY after the athlete has confirmed finishing despite unlogged sets. Leave false/absent for the first call." },
      },
    },
  },
  {
    name: "get_week_plan",
    description: "Read the athlete's week-level training plan (each day's scheduled workouts + their status). Call this before moving/swapping/skipping workouts so you know what exists and can refer to them by name and day.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "move_workout",
    description: "Move a scheduled workout to another day of the current week. Refer to the workout by its title and the target day by weekday name (e.g. 'Thursday') or yyyy-MM-dd. If the name matches more than one workout this week, the tool asks which — relay that, don't guess.",
    input_schema: {
      type: "object",
      properties: { workout: { type: "string" }, to_day: { type: "string", description: "Weekday name or yyyy-MM-dd" } },
      required: ["workout", "to_day"],
    },
  },
  {
    name: "swap_workouts",
    description: "Swap the days of two scheduled workouts this week (each keeps its content, they trade dates). Refer to both by title.",
    input_schema: {
      type: "object",
      properties: { a: { type: "string" }, b: { type: "string" } },
      required: ["a", "b"],
    },
  },
  {
    name: "skip_workout",
    description: "Mark a scheduled workout as skipped (or un-skip it). Does not delete it.",
    input_schema: {
      type: "object",
      properties: { workout: { type: "string" }, skipped: { type: "boolean", description: "true to skip (default), false to un-skip" } },
      required: ["workout"],
    },
  },
  {
    name: "duplicate_workout",
    description: "Duplicate a scheduled workout (same content), optionally onto another day. The copy shares the original's content revision.",
    input_schema: {
      type: "object",
      properties: { workout: { type: "string" }, to_day: { type: "string", description: "Optional weekday name or yyyy-MM-dd" } },
      required: ["workout"],
    },
  },
  {
    name: "delete_workout",
    description: "Remove a scheduled workout from the plan. DESTRUCTIVE: call FIRST without proposal_id — the tool returns a warning and a proposal_id and deletes nothing. Relay the warning; only if the athlete confirms, call again with that proposal_id. (The athlete can also undo afterward.)",
    input_schema: {
      type: "object",
      properties: { workout: { type: "string" }, proposal_id: { type: "string", description: "Pass ONLY on the confirming second call, using the id from the first call's warning." } },
      required: ["workout"],
    },
  },
  {
    name: "explain_modification",
    description: "Explain why a scheduled workout is as it is (as-planned / modified today / skipped / completed / changed by you or the athlete). Rationale comes from the deterministic state and version history — report exactly what the tool returns; never invent a reason or a percentage.",
    input_schema: {
      type: "object",
      properties: { workout: { type: "string" } },
      required: ["workout"],
    },
  },
  {
    name: "update_logging_config",
    description: "THIS WORKOUT ONLY: choose which metrics an exercise logs and its display units. Does NOT change future defaults. Metrics: reps, load, duration, distance, calories, heartRate, cadence, power, pace, rpe. Unsupported metrics are rejected.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        enabled_metrics: { type: "array", items: { type: "string" }, description: "The full set of metrics to log for this exercise, e.g. ['duration','distance']." },
        distance_unit: { type: "string", description: "m | km | mi" },
        load_unit: { type: "string", description: "kg | lb" },
        duration_unit: { type: "string", description: "sec | min" },
      },
      required: ["exercise"],
    },
  },
  {
    name: "update_exercise_preference",
    description: "FUTURE DEFAULTS: save a preference for an exercise identity (or its whole category), applied to NEW instances only — e.g. 'use km for Stationary Bike from now on'. Never affects the current workout. Ask the athlete whether they mean just this exercise or all exercises in its category when unclear.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string", description: "Exercise name (resolved to a stable identity)." },
        scope: { type: "string", enum: ["exercise", "category"], description: "'exercise' = this movement's default; 'category' = all e.g. cycling." },
        enabled_metrics: { type: "array", items: { type: "string" } },
        distance_unit: { type: "string" },
        load_unit: { type: "string" },
        duration_unit: { type: "string" },
      },
      required: ["exercise", "scope"],
    },
  },
  {
    name: "set_metric_value",
    description: "Set one metric's value on a set of an exercise (value in the given unit; stored canonically). Adds the metric to what the exercise logs. Rejected if the exercise doesn't support the metric.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        set_number: { type: "integer", minimum: 1 },
        metric: { type: "string", description: "reps | load | duration | distance | calories | power | pace | heartRate | cadence | rpe" },
        value: { type: "number" },
        unit: { type: "string", description: "Unit of `value` (e.g. mi, km, kg, lb, min). Defaults to canonical." },
      },
      required: ["exercise", "set_number", "metric", "value"],
    },
  },
  {
    name: "remove_metric",
    description: "Stop logging a metric for an exercise this workout (unselect it and clear its values).",
    input_schema: {
      type: "object",
      properties: { exercise: { type: "string" }, metric: { type: "string" } },
      required: ["exercise", "metric"],
    },
  },
  {
    name: "create_workout",
    description: "Create today's workout as an empty shell, then add blocks and exercises. If a workout already exists this REPLACES it and discards the current one — the tool refuses unless replace_existing is true, so confirm with the athlete first, then call again with replace_existing: true.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        goal: { type: "string", description: "Optional overall goal." },
        replace_existing: { type: "boolean", description: "Set true ONLY after the athlete confirms replacing an existing workout." },
      },
      required: ["title"],
    },
  },
  {
    name: "add_block",
    description: "Add a semantic block to the workout (e.g. 'Warm-up', 'Strength', 'Metcon', 'Stations', 'Cooldown').",
    input_schema: {
      type: "object",
      properties: { name: { type: "string" }, intent: { type: "string", description: "Optional purpose, e.g. 'hypertrophy'." } },
      required: ["name"],
    },
  },
  {
    name: "add_exercise",
    description: "Add an exercise to a named block, optionally with a uniform set scheme. e.g. block 'Strength', name 'Bench press', sets 3, reps 8, load 60.",
    input_schema: {
      type: "object",
      properties: {
        block: { type: "string", description: "Name of an existing block." },
        name: { type: "string", description: "Exercise name." },
        sets: { type: "integer", minimum: 1, description: "How many sets (default 1)." },
        reps: { type: "integer" },
        load: { type: "number", description: "Resistance per set." },
        duration_seconds: { type: "integer", description: "For time-based work / holds." },
        distance_m: { type: "number", description: "Distance in METERS (e.g. 150 for a 150m carry, 1000 for a 1km row). Use this for distance work — never put the distance in the exercise name." },
      },
      required: ["block", "name"],
    },
  },
  {
    name: "move_exercise",
    description: "Move an exercise into another block (blocks are semantic groups, not fixed — exercises move freely).",
    input_schema: {
      type: "object",
      properties: { exercise: { type: "string" }, to_block: { type: "string" } },
      required: ["exercise", "to_block"],
    },
  },
  {
    name: "remove_exercise",
    description: "Remove an exercise from the workout by name.",
    input_schema: {
      type: "object",
      properties: { exercise: { type: "string" } },
      required: ["exercise"],
    },
  },
  {
    name: "update_set",
    description: "Change a single set of an exercise without rewriting the others. set_number is 1-based. Only the fields you pass change.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        set_number: { type: "integer", minimum: 1 },
        reps: { type: "integer" },
        load: { type: "number" },
        duration_seconds: { type: "integer" },
        distance_m: { type: "number", description: "Distance in METERS." },
        rpe: { type: "number" },
      },
      required: ["exercise", "set_number"],
    },
  },
];

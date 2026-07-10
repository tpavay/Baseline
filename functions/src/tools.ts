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
    name: "create_workout",
    description: "Create/replace today's workout as an empty shell. Then add blocks and exercises. Refer to blocks and exercises by name in later calls.",
    input_schema: {
      type: "object",
      properties: { title: { type: "string" }, goal: { type: "string", description: "Optional overall goal." } },
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
        rpe: { type: "number" },
      },
      required: ["exercise", "set_number"],
    },
  },
];

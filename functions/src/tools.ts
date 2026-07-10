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
];

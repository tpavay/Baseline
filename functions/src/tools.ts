/**
 * The Baseline tool contract. These schemas are the ONLY things the model can request; the app
 * maps each returned `tool_use` (by name) to a validated `AgentTools.Call` and executes it locally,
 * where the state lives. Keep names + params in lock-step with Baseline/Shared/Services/AgentTools.swift
 * and ToolCallMapper.swift.
 *
 * Workout target convention: *_id fields are stable instance IDs returned by get_current_workout.
 * Wave 5 structure tools require those IDs. The capability-gated legacy list retains the earlier
 * name fields only for installed clients that cannot map the Wave 5 contract.
 * Every workout-content mutation also requires the revision token returned by that same read.
 */
const expectedRevisionToken = {
  type: "string",
  description: "Exact revision_token from get_current_workout. The mutation is rejected as stale if the workout changed since that read.",
};

const expectedPerformedLogRevisionToken = {
  type: "string",
  description: "Exact performed_log_revision_token from get_active_session. The log mutation is rejected as stale if any performed state changed since that read.",
};

const expectedSessionMutationRevisionToken = {
  type: "string",
  description: "The after_revision_token from the exact session mutation receipt being undone.",
};

const performedMetricValue = {
  type: "object",
  properties: {
    metric: {
      type: "string",
      enum: ["reps", "load", "duration", "distance", "calories", "heartRate", "heartRateZoneTime", "cadence", "power", "pace", "rpe"],
    },
    value_text: {
      type: "string",
      minLength: 1,
      description: "The athlete's quantity wording with its unit, for example '185 lb' or '1:19 per 400 m'. Never send a bare dimensional number.",
    },
  },
  required: ["metric", "value_text"],
  additionalProperties: false,
};

const performedContextProperties = {
  group_id: {
    type: "string",
    description: "Repeated group ID from get_active_session. Supply together with iteration, or omit both for an ordinary set.",
  },
  iteration: {
    type: "integer",
    minimum: 1,
    description: "One-based round or interval from get_active_session. Supply together with group_id, or omit both.",
  },
};

const setMetricProperties = {
  reps: { type: "integer", minimum: 0, description: "Canonical repetition count." },
  load: { type: "number", minimum: 0, description: "Canonical kilograms." },
  duration: { type: "integer", minimum: 0, description: "Canonical seconds." },
  distance: { type: "number", minimum: 0, description: "Canonical meters." },
  calories: { type: "number", minimum: 0 },
  heartRate: { type: "integer", minimum: 0, description: "Beats per minute." },
  heartRateZoneTime: { type: "integer", minimum: 0, description: "Canonical seconds in zone." },
  cadence: { type: "integer", minimum: 0, description: "Revolutions per minute." },
  power: { type: "number", minimum: 0, description: "Watts." },
  pace: { type: "number", minimum: 0, description: "Canonical seconds per meter." },
  rpe: { type: "number", minimum: 0, maximum: 10 },
};

const nullableSetMetricProperties = Object.fromEntries(
  Object.entries(setMetricProperties).map(([metric, schema]) => [
    metric,
    { ...schema, type: [schema.type, "null"], description: `${"description" in schema ? schema.description : metric}. Pass null to clear.` },
  ])
);

const setRangeTarget = {
  type: "object",
  properties: {
    metric: { type: "string", enum: Object.keys(setMetricProperties) },
    lower: { type: "number", minimum: 0, description: "Canonical lower bound." },
    upper: { type: "number", minimum: 0, description: "Canonical upper bound, at least lower." },
  },
  required: ["metric", "lower", "upper"],
  additionalProperties: false,
};

const setEffortTarget = {
  type: "object",
  properties: {
    type: { type: "string", enum: ["rpe", "rir", "toFailure", "maxEffort"] },
    value: { type: "number", minimum: 0, maximum: 10, description: "Required for rpe or rir; omit for toFailure or maxEffort." },
  },
  required: ["type"],
  additionalProperties: false,
};

const setTargets = {
  type: "object",
  properties: {
    effort: setEffortTarget,
    ranges: { type: "array", items: setRangeTarget },
  },
  additionalProperties: false,
};

/** Wave 8: how a group's work repeats — once, N rounds, or a time cap. */
const groupRepetition = {
  type: "object",
  description: "How the group's work repeats. {type:'once'} runs it straight through, {type:'count',count:N} runs N rounds, {type:'until',duration_seconds:S} repeats for a time cap (AMRAP-style).",
  properties: {
    type: { type: "string", enum: ["once", "count", "until"] },
    count: { type: "integer", minimum: 1, description: "Rounds. Required when type is 'count'." },
    duration_seconds: { type: "integer", minimum: 1, description: "Time cap in seconds. Required when type is 'until'." },
  },
  required: ["type"],
  additionalProperties: false,
};

/** Wave 8: EMOM-style start cadence for a group. */
const groupCadence = {
  type: ["object", "null"],
  description: "Start cadence: scope 'child' starts the next child every interval (EMOM), 'cycle' restarts the whole sequence every interval. Pass null to clear.",
  properties: {
    interval_seconds: { type: "integer", minimum: 1 },
    scope: { type: "string", enum: ["child", "cycle"] },
  },
  required: ["interval_seconds", "scope"],
  additionalProperties: false,
};

/** Wave 8: a round-to-round metric adjustment on a group. */
const groupAdjustment = {
  type: "object",
  properties: {
    metric: { type: "string", enum: Object.keys(setMetricProperties) },
    step: { type: "number", description: "Canonical non-zero step per round; negative to decrease." },
    minimum: { type: "number", description: "Optional canonical floor." },
    maximum: { type: "number", description: "Optional canonical ceiling." },
  },
  required: ["metric", "step"],
  additionalProperties: false,
};

/** Wave 8: a per-set metric progression across sets/rounds/intervals. */
const setProgression = {
  type: "object",
  properties: {
    metric: { type: "string", enum: Object.keys(setMetricProperties) },
    delta: { type: "number", description: "Canonical non-zero change per step; negative to decrease." },
    every: { type: "integer", minimum: 1, description: "Apply the delta every N units. Defaults to 1." },
    unit: { type: "string", enum: ["set", "round", "interval", "cycle"] },
  },
  required: ["metric", "delta", "unit"],
  additionalProperties: false,
};

/** Wave 8: one typed exercise intensity target. Exactly the fields for its type. */
const intensityTarget = {
  type: "object",
  description: "One typed intensity target. heartRateZone uses zone; rpe/power/thresholdPercentage use lower and upper (lower ≤ upper); power is stated in watts; pace and descriptive use text; namedZone uses system and range.",
  properties: {
    type: { type: "string", enum: ["heartRateZone", "rpe", "pace", "power", "thresholdPercentage", "namedZone", "descriptive"] },
    zone: { type: "integer", minimum: 1, maximum: 5, description: "heartRateZone only: HR zone 1-5." },
    lower: { type: "number", minimum: 0, description: "Lower bound for rpe, power, or thresholdPercentage." },
    upper: { type: "number", minimum: 0, description: "Upper bound, at least lower." },
    unit: { type: "string", enum: ["watts"], description: "power only. Watts is the only power unit." },
    text: { type: "string", minLength: 1, description: "pace or descriptive wording, e.g. '5k pace'." },
    system: { type: "string", minLength: 1, description: "namedZone only, e.g. 'Coggan'." },
    range: { type: "string", minLength: 1, description: "namedZone only, e.g. 'Z2'." },
  },
  required: ["type"],
  additionalProperties: false,
};

/**
 * Explicit taxonomy selector shared by the Wave 7 bulk tools. Fields AND together. Instances without
 * catalog identity can never match a taxonomy field — the tool reports them instead of silently
 * skipping or including them, so a policy-sensitive phrase ("all runs") never decides itself.
 */
const exerciseSelector = {
  type: "object",
  minProperties: 1,
  description: "Explicit match over this workout's exercise instances. All supplied fields must match (AND). Prefer these explicit taxonomy fields over name guessing; the result always enumerates the exact matched instance IDs and names.",
  properties: {
    definition_id: { type: "string", description: "Exact catalog id from search_exercises / get_exercise, e.g. 'treadmill_run'. The most precise selector." },
    muscle: { type: "string", description: "Muscle trained (primary or secondary), e.g. quadriceps, hamstrings, chest." },
    equipment: { type: "string", description: "Gear needed, e.g. barbell, dumbbell, treadmill, rower." },
    modality: { type: "string", description: "resistance | cardio | hold | mobility" },
    pattern: { type: "string", description: "Movement pattern: squat | hinge | lunge | push | pull | carry | rotation | gait | hold" },
    tag: { type: "string", description: "Discipline: hyrox | olympicWeightlifting | powerlifting | calisthenics | plyometric | mobility | strongman" },
    level: { type: "string", description: "beginner | intermediate | expert" },
    block_id: { type: "string", description: "Restrict to one block by stable block ID from get_current_workout." },
  },
  additionalProperties: false,
};

/** The batch-eligible operations Wave 7 clients already understand. */
const waveSevenBatchOperationNames = [
  "update_workout_metadata", "update_block_metadata", "update_exercise_metadata",
  "add_block", "remove_block", "move_block", "duplicate_block",
  "add_exercise", "move_exercise", "replace_exercise", "remove_exercise",
  "reorder_exercise", "duplicate_exercise",
  "add_set", "update_set", "remove_set", "move_set", "duplicate_set",
  "set_metric_value", "remove_metric", "update_logging_config",
];

/** The single tools whose payloads may appear as one operation of an atomic apply_workout_edits batch. */
const batchOperationNames = [
  ...waveSevenBatchOperationNames,
  "update_group", "update_choice", "convert_choice_to_group", "update_rest", "add_rest",
  "move_node", "remove_node", "add_set_alternative", "update_set_alternative",
  "remove_set_alternative", "update_exercise_prescription",
];

export type ToolSchema = {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
};

export const TOOLS: ToolSchema[] = [
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
    name: "search_exercises",
    description: "Search Baseline's exercise catalog (~900 movements, always available offline). Call this to answer ANY question about which exercises exist ('what exercises do you have', 'do you have any hamstring movements') - Baseline HAS a full library, so never say it doesn't. Also call it BEFORE naming an exercise in a workout you're building, so you use a real catalog exercise instead of guessing a name. All params are optional and combine (AND); with none, returns a representative sample across the catalog. Returns up to 25 compact matches plus the true total, so say how many exist rather than implying the page is everything.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Free text matched against exercise names and aliases, e.g. 'bench', 'romanian deadlift', 'sled'." },
        muscle: { type: "string", description: "Muscle trained (primary or secondary), e.g. quadriceps, hamstrings, glutes, chest, lats, abdominals, biceps, triceps, calves, frontDelts." },
        equipment: { type: "string", description: "Gear needed, e.g. barbell, dumbbell, kettlebell, cable, machine, bodyweight, band, sled, box, bike, rower, skiErg, treadmill." },
        modality: { type: "string", description: "resistance | cardio | hold | mobility" },
        pattern: { type: "string", description: "Movement pattern: squat | hinge | lunge | push | pull | carry | rotation | gait | hold" },
        tag: { type: "string", description: "Discipline: hyrox | olympicWeightlifting | powerlifting | calisthenics | plyometric | mobility | strongman" },
        level: { type: "string", description: "beginner | intermediate | expert" },
      },
    },
  },
  {
    name: "get_exercise",
    description: "Get one exercise's full detail from the catalog by name or id - the muscles it trains, equipment, movement pattern, modality, mechanic, level, tags, and which metrics it logs. Use it to answer 'what does X work?' and to check what an exercise logs before setting metrics on it. Pass either name or id (name is fine - casual names and aliases resolve).",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Exercise name or alias, e.g. 'romanian deadlift', 'rdl'." },
        id: { type: "string", description: "Catalog id from search_exercises, e.g. 'bench_press'." },
      },
    },
  },
  {
    name: "get_current_workout",
    description: "Read the current structured workout, including its mutation scope, stable IDs for every block, exercise instance, and set — plus every group, choice, choice option, rest, and set alternative — and revision_token. Call before editing and pass the IDs plus revision_token to mutation tools. A stale token is rejected without writing.",
    input_schema: { type: "object", properties: {} },
  },
  {
    name: "undo_workout_mutation",
    description: "Undo exactly one workout edit using its mutation receipt. This succeeds only while that mutation is still the plan head and expected_revision_token still matches its after_revision_token. If any later edit or conflicting session intervened, it rejects as stale instead of reverting newer work.",
    input_schema: {
      type: "object",
      properties: {
        mutation_id: { type: "string", description: "mutation_id from the exact mutation receipt to undo." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["mutation_id", "expected_revision_token"],
    },
  },
  {
    name: "get_active_session",
    description: "Read the active performed-log session as structured JSON. Returns session, workout-log, exercise instance, planned-set, group, iteration, performed-set, outcome, and independent workout/log revision IDs. Call before every performed-log edit and target only IDs from this result.",
    input_schema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "upsert_performed_set",
    description: "Record or revise actual metric values for one planned set in the active session. This writes WorkoutLog only and never changes the planned set. Preserve the athlete's quantity wording in value_text so deterministic code can parse and convert explicit units. A bare dimensional number such as 185 for load is rejected rather than treated as kilograms.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Exercise instance ID from get_active_session." },
        planned_set_id: { type: "string", description: "Planned set ID from get_active_session." },
        ...performedContextProperties,
        values: { type: "array", minItems: 1, items: performedMetricValue },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["exercise_instance_id", "planned_set_id", "values", "expected_revision_token"],
      dependencies: { group_id: ["iteration"], iteration: ["group_id"] },
      additionalProperties: false,
    },
  },
  {
    name: "set_performed_set_outcome",
    description: "Set a performed row to pending, completed, or skipped. Use the planned target IDs to create or restore a planned-set actual, or use performed_set_id alone for an existing extra set. Pending restores a completed or skipped row without deleting its actual values.",
    input_schema: {
      type: "object",
      properties: {
        performed_set_id: { type: "string", description: "Existing extra performed-set ID from get_active_session. Use alone instead of planned target IDs." },
        exercise_instance_id: { type: "string", description: "Exercise instance ID for a planned-set target." },
        planned_set_id: { type: "string", description: "Planned set ID for a planned-set target." },
        ...performedContextProperties,
        outcome: { type: "string", enum: ["pending", "completed", "skipped"] },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["outcome", "expected_revision_token"],
      // Mirrors the iOS mapper: performed_set_id stands alone, and a planned target never carries
      // it. Anthropic rejects oneOf/allOf/anyOf at the top level of input_schema (every request
      // 400s before the model runs), so the exclusivity lives in schema-form `dependencies` plus
      // the description; the mapper still deterministically rejects any call that slips through.
      dependencies: {
        exercise_instance_id: {
          required: ["planned_set_id"],
          not: { required: ["performed_set_id"] },
        },
        planned_set_id: {
          required: ["exercise_instance_id"],
          not: { required: ["performed_set_id"] },
        },
        group_id: {
          required: ["iteration"],
          not: { required: ["performed_set_id"] },
        },
        iteration: {
          required: ["group_id"],
          not: { required: ["performed_set_id"] },
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "add_extra_performed_set",
    description: "Add actual work beyond the plan for one exercise, optionally in one repeated group iteration. Values use athlete-provided value_text with explicit units and are stored only in WorkoutLog.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Exercise instance ID from get_active_session." },
        ...performedContextProperties,
        values: { type: "array", minItems: 1, items: performedMetricValue },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["exercise_instance_id", "values", "expected_revision_token"],
      dependencies: { group_id: ["iteration"], iteration: ["group_id"] },
      additionalProperties: false,
    },
  },
  {
    name: "update_extra_performed_set",
    description: "Revise actual metric values on one extra performed set by performed-set ID. This never creates or changes a planned set.",
    input_schema: {
      type: "object",
      properties: {
        performed_set_id: { type: "string", description: "Extra performed-set ID from get_active_session." },
        values: { type: "array", minItems: 1, items: performedMetricValue },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["performed_set_id", "values", "expected_revision_token"],
      additionalProperties: false,
    },
  },
  {
    name: "delete_extra_performed_set",
    description: "Delete one extra performed set by its performed-set ID. Planned-set actuals cannot be deleted through this tool.",
    input_schema: {
      type: "object",
      properties: {
        performed_set_id: { type: "string", description: "Extra performed-set ID from get_active_session." },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["performed_set_id", "expected_revision_token"],
      additionalProperties: false,
    },
  },
  {
    name: "add_exercise_session_note",
    description: "Append an athlete note to one exercise's performed record in the active session. This is session history, not planned workout guidance.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Exercise instance ID from get_active_session." },
        note: { type: "string", minLength: 1 },
        expected_revision_token: expectedPerformedLogRevisionToken,
      },
      required: ["exercise_instance_id", "note", "expected_revision_token"],
      additionalProperties: false,
    },
  },
  {
    name: "undo_session_mutation",
    description: "Undo exactly one session mutation using its receipt. The stored before-snapshot is restored only while the session's current revision token still matches that receipt's after_revision_token. A later user or agent edit makes the request stale and nothing is changed.",
    input_schema: {
      type: "object",
      properties: {
        mutation_id: { type: "string", description: "mutation_id from the exact session mutation receipt." },
        expected_revision_token: expectedSessionMutationRevisionToken,
      },
      required: ["mutation_id", "expected_revision_token"],
      additionalProperties: false,
    },
  },
  {
    name: "update_workout_metadata",
    description: "Update the current workout's title or note. The note is the workout's single free-form text - there is no separate workout goal or workout-level coach guidance. Include only fields the athlete asked to change. For nullable fields, omit to preserve the current value and pass null to clear it.",
    input_schema: {
      type: "object",
      minProperties: 2,
      properties: {
        title: { type: "string", minLength: 1, description: "New workout title. Omit to leave unchanged." },
        note: { type: ["string", "null"], description: "The workout's one free-form note, null to clear, or omit to leave unchanged. Coach cues for a specific movement belong on that exercise (update_exercise_metadata), not here." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["expected_revision_token"],
    },
  },
  {
    name: "update_block_metadata",
    description: "Update one workout block's name, intent, or guidance by stable block ID. Include only fields the athlete asked to change. For nullable fields, omit to preserve the current value and pass null to clear it.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        block_id: { type: "string", description: "Stable block ID from get_current_workout." },
        name: { type: "string", minLength: 1, description: "New block name. Omit to leave unchanged." },
        intent: { type: ["string", "null"], description: "New block intent, null to clear, or omit to leave unchanged." },
        guidance: { type: ["string", "null"], description: "Coach guidance or notes for the block, null to clear, or omit to leave unchanged." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["block_id", "expected_revision_token"],
    },
  },
  {
    name: "update_exercise_metadata",
    description: "Update one exercise instance's workout-local display label or guidance by stable exercise instance ID. Include only fields the athlete asked to change. Omit a nullable field to preserve it and pass null to clear it.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        display_label: { type: ["string", "null"], description: "Workout-local label, null to return to the catalog exercise name, or omit to leave unchanged." },
        guidance: { type: ["string", "null"], description: "Coach guidance or notes for this instance, null to clear, or omit to leave unchanged." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "expected_revision_token"],
    },
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
    name: "save_as_template",
    description: "Save today's workout as a reusable template with a name. If a template with that name already exists the tool refuses and tells you — relay that and either use update_template to replace it or pick a different name (never overwrite silently).",
    input_schema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
  {
    name: "create_from_template",
    description: "Create a workout on a day from a saved template (by name). The new workout is an independent copy — later edits to it or the template don't affect each other. Day is a weekday name or yyyy-MM-dd. Asks which if the name matches more than one template.",
    input_schema: {
      type: "object",
      properties: { name: { type: "string" }, to_day: { type: "string", description: "Weekday name or yyyy-MM-dd" } },
      required: ["name", "to_day"],
    },
  },
  {
    name: "update_template",
    description: "Replace a saved template's content with today's workout (by template name). Creates a new template revision; workouts already scheduled from the template are NOT changed. Asks which if the name matches more than one.",
    input_schema: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
    },
  },
  {
    name: "update_logging_config",
    description: "THIS WORKOUT ONLY: choose which metrics an exercise instance logs and its display units. Does NOT change future defaults or canonical stored values. Metrics: reps, load, duration, distance, calories, heartRate, heartRateZoneTime, cadence, power, pace, rpe. Unsupported metrics and units are rejected.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        enabled_metrics: { type: "array", items: { type: "string" }, description: "The full set of metrics to log for this exercise, e.g. ['duration','distance']." },
        distance_unit: { type: "string", description: "m | km | mi" },
        load_unit: { type: "string", description: "kg | lb" },
        duration_unit: { type: "string", description: "sec | min" },
        pace_unit: { type: "string", description: "/km | /mi" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "expected_revision_token"],
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
    description: "Set one metric value on an ID-targeted planned set (value in the given unit; stored canonically). Adds the metric to what the exercise logs. Rejected if the set is not owned by the exercise instance or the exercise does not support the metric.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        metric: { type: "string", description: "reps | load | duration | distance | calories | power | pace | heartRate | heartRateZoneTime | cadence | rpe" },
        value: { type: "number" },
        unit: { type: "string", description: "Unit of `value` (e.g. mi, km, kg, lb, min). Defaults to canonical." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "set_id", "metric", "value", "expected_revision_token"],
    },
  },
  {
    name: "remove_metric",
    description: "Stop logging a metric for an exercise this workout (unselect it and clear its values).",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        metric: { type: "string" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "metric", "expected_revision_token"],
    },
  },
  {
    name: "create_workout",
    description: "Create today's workout as an empty shell, then add blocks and exercises. If a workout already exists this REPLACES it and discards the current one — the tool refuses unless replace_existing is true, so confirm with the athlete first, then call again with replace_existing: true.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        note: { type: "string", description: "Optional free-form note for the workout - its single note field, not a separate goal." },
        replace_existing: { type: "boolean", description: "Set true ONLY after the athlete confirms replacing an existing workout." },
        expected_revision_token: { ...expectedRevisionToken, description: "Required when replace_existing is true; use revision_token from get_current_workout. Omit only when no workout exists yet." },
      },
      required: ["title"],
    },
  },
  {
    name: "add_block",
    description: "Add a semantic block at an optional zero-based position. Omit at_index to append. Optional guidance uses the same plain coach-guidance convention as the metadata tools. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string" },
        intent: { type: "string", description: "Optional purpose, e.g. 'hypertrophy'." },
        guidance: { type: "string", description: "Optional coach guidance for performing this block." },
        at_index: { type: "integer", minimum: 0, description: "Optional zero-based insertion position. Omit to append." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["name", "expected_revision_token"],
    },
  },
  {
    name: "remove_block",
    description: "Remove one block by stable ID. In a live session every performed exercise, group, and choice record owned by the block is purged through the logged-work safeguard. Targeted undo restores the block and the exact purged performed content.",
    input_schema: {
      type: "object",
      properties: {
        block_id: { type: "string", description: "Stable block ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["block_id", "expected_revision_token"],
    },
  },
  {
    name: "move_block",
    description: "Move one block by stable ID to a zero-based final position. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        block_id: { type: "string", description: "Stable block ID from get_current_workout." },
        to_index: { type: "integer", minimum: 0, description: "Zero-based final position." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["block_id", "to_index", "expected_revision_token"],
    },
  },
  {
    name: "duplicate_block",
    description: "Deep-copy one block immediately after its source. The copy receives fresh block, node, exercise, set, and alternative IDs. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        block_id: { type: "string", description: "Stable block ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["block_id", "expected_revision_token"],
    },
  },
  {
    name: "add_exercise",
    description: "Add an exercise at an optional zero-based position, optionally with a uniform set scheme. Target EXACTLY ONE destination: block_id for a block's top level, or parent_id for a nested group (as a child) or choice (as a new option). Omit at_index to append.",
    input_schema: {
      type: "object",
      properties: {
        block_id: { type: "string", description: "Stable destination block ID from get_current_workout. Use this OR parent_id, never both." },
        parent_id: { type: "string", description: "Stable destination group or choice ID from get_current_workout for nested insertion. Use this OR block_id, never both." },
        name: { type: "string", description: "Exercise name." },
        at_index: { type: "integer", minimum: 0, description: "Optional zero-based insertion position among the destination container's nodes." },
        sets: { type: "integer", minimum: 1, description: "How many sets (default 1)." },
        reps: { type: "integer" },
        load: { type: "number", description: "Resistance per set." },
        duration_seconds: { type: "integer", description: "For time-based work / holds." },
        distance_m: { type: "number", description: "Distance in METERS (e.g. 150 for a 150m carry, 1000 for a 1km row). Use this for distance work — never put the distance in the exercise name." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["name", "expected_revision_token"],
      // Top-level oneOf is rejected by the Anthropic API; pairwise schema-form `dependencies`
      // keep block_id/parent_id mutually exclusive, and the iOS mapper enforces exactly-one.
      dependencies: {
        block_id: { not: { required: ["parent_id"] } },
        parent_id: { not: { required: ["block_id"] } },
      },
    },
  },
  {
    name: "move_exercise",
    description: "Move one exercise instance into an ID-targeted block at a zero-based final position. This tool targets the instance ID even when names are duplicated. Nested destination containers are not supported yet.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        to_block_id: { type: "string", description: "Stable destination block ID from get_current_workout." },
        to_index: { type: "integer", minimum: 0, description: "Zero-based final position among the destination block's top-level nodes." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "to_block_id", "to_index", "expected_revision_token"],
    },
  },
  {
    name: "replace_exercise",
    description: "Replace one ID-targeted exercise in place while preserving its instance ID, sets, targets, notes, and order. ALWAYS use this for replacements; never simulate replacement with add_exercise plus remove_exercise.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        replacement: { type: "string", description: "Replacement exercise from the catalog." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "replacement", "expected_revision_token"],
    },
  },
  {
    name: "remove_exercise",
    description: "Remove one exercise by stable instance ID. In a live session its performed record and any direct choice selection are purged through the logged-work safeguard. Targeted undo restores the exercise and the exact purged performed content.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "expected_revision_token"],
    },
  },
  {
    name: "reorder_exercise",
    description: "Reorder one exercise by stable instance ID within its current containing node list. to_index is the zero-based final position. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        to_index: { type: "integer", minimum: 0, description: "Zero-based final position in the current container." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "to_index", "expected_revision_token"],
    },
  },
  {
    name: "duplicate_exercise",
    description: "Deep-copy one exercise by stable instance ID immediately after its source. The copy receives fresh exercise, set, and alternative IDs. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "expected_revision_token"],
    },
  },
  {
    name: "require_all_options",
    description: "Convert one incorrectly inferred either/or choice into a required ordered group containing every existing option. Use when the athlete says both/all movements are required, such as 'Option B contains deadlifts AND lateral burpees.' Preserves the child exercises and their prescriptions.",
    input_schema: {
      type: "object",
      properties: {
        choice: { type: "string", description: "The current choice label, or an unambiguous part of it." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["choice", "expected_revision_token"],
    },
  },
  {
    name: "add_set",
    description: "Add one planned set to an exercise instance. Values and range bounds are canonical. after_set_id must belong to the same exercise; omit it to append. The mutation returns a receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        after_set_id: { type: "string", description: "Optional stable set ID in the same exercise. The new set is inserted immediately after it." },
        values: { type: "object", properties: setMetricProperties, additionalProperties: false },
        role: { type: "string", enum: ["warmup", "working", "top", "backoff", "drop"] },
        targets: setTargets,
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "values", "role", "targets", "expected_revision_token"],
    },
  },
  {
    name: "update_set",
    description: "Patch one planned set by stable ID. Omitted fields stay unchanged, values set fields, and null explicitly clears nullable values, targets, or progressions. A set role is required state and cannot be cleared.",
    input_schema: {
      type: "object",
      properties: {
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        patch: {
          type: "object",
          properties: {
            values: { type: ["object", "null"], properties: nullableSetMetricProperties, additionalProperties: false, description: "Pass null to clear every canonical metric value, or null for one metric to clear only that value." },
            role: { type: "string", enum: ["warmup", "working", "top", "backoff", "drop"] },
            targets: {
              type: ["object", "null"],
              properties: {
                effort: { ...setEffortTarget, type: ["object", "null"], description: "Pass null to clear the effort target." },
                ranges: { type: ["array", "null"], items: setRangeTarget, description: "Pass null to clear target ranges." },
              },
              additionalProperties: false,
              description: "Pass null to clear all effort and range targets.",
            },
            progressions: { type: ["array", "null"], items: setProgression, description: "Replaces the set's full progression list ('add 5 kg every round'). Pass null to clear all progressions." },
          },
          minProperties: 1,
          additionalProperties: false,
        },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["set_id", "patch", "expected_revision_token"],
    },
  },
  {
    name: "remove_set",
    description: "Remove one planned set by stable ID. In a live session the matching performed row is purged through the logged-actual safeguard so deleted work cannot survive invisibly. The mutation returns a receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["set_id", "expected_revision_token"],
    },
  },
  {
    name: "move_set",
    description: "Move one planned set within its owning exercise by stable ID. Supply exactly one destination: before_set_id in the same exercise, or a zero-based final to_index.",
    input_schema: {
      type: "object",
      properties: {
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        before_set_id: { type: "string", description: "Stable sibling set ID from get_current_workout." },
        to_index: { type: "integer", minimum: 0, description: "Zero-based final position in the owning exercise." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["set_id", "expected_revision_token"],
    },
  },
  {
    name: "duplicate_set",
    description: "Deep-copy one planned set by stable ID immediately after its source. The copy receives a fresh set ID and fresh IDs for every alternative. The mutation returns a receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["set_id", "expected_revision_token"],
    },
  },
  {
    name: "apply_workout_edits",
    description: "Apply an ORDERED list of workout edits as ONE atomic mutation. Use when one athlete request needs several edits ('rename the block, move rows after pull-ups, and add a set') so a later step can never leave the workout half-changed. Every operation is validated against the same snapshot: if ANY operation is invalid the whole batch is rejected, nothing is written, and the error names exactly which operation failed and why. Success returns ONE mutation receipt, and one undo_workout_mutation call reverts the entire batch. Each operation object is {\"op\": \"<single tool name>\", ...that tool's fields WITHOUT expected_revision_token} — the batch carries the token once.",
    input_schema: {
      type: "object",
      properties: {
        operations: {
          type: "array",
          minItems: 1,
          maxItems: 20,
          description: "Ordered operations. Later operations see earlier ones' effects (indexes and IDs shift as edits land), all inside the same atomic apply.",
          items: {
            type: "object",
            properties: {
              op: {
                type: "string",
                enum: batchOperationNames,
                description: "Which edit this is. The object's remaining fields are exactly the named tool's fields, minus expected_revision_token.",
              },
            },
            required: ["op"],
          },
        },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["operations", "expected_revision_token"],
    },
  },
  {
    name: "convert_workout_units",
    description: "Bulk-set DISPLAY units (distance, load, duration, pace) across every matched exercise instance in ONE atomic, undoable mutation. Display-only: canonical stored values never change. Omit selector to match every exercise in the workout that logs the metric — duplicates included. Include at least one unit field. The receipt enumerates exactly which instances changed. For a policy-sensitive phrase like 'all runs', pass a selector and dry_run true first, then confirm the enumerated matched instances against the athlete's intent before applying.",
    input_schema: {
      type: "object",
      minProperties: 2,
      properties: {
        distance_unit: { type: "string", description: "m | km | mi" },
        load_unit: { type: "string", description: "kg | lb" },
        duration_unit: { type: "string", description: "sec | min" },
        pace_unit: { type: "string", description: "/km | /mi" },
        selector: exerciseSelector,
        dry_run: { type: "boolean", description: "true = enumerate the exact matched instance IDs and names and change nothing. Defaults to false." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["expected_revision_token"],
    },
  },
  {
    name: "bulk_replace_exercises",
    description: "Replace EVERY exercise instance matched by an explicit taxonomy selector with one catalog exercise, atomically and undoably. Each instance keeps its ID, sets, targets, notes, and order (same semantics as replace_exercise). ALWAYS dry-run first: dry_run defaults to true and the result enumerates the exact matched instance IDs and names, plus any instances the selector could NOT classify. Read that list, confirm against the athlete's intent when the match set could surprise them ('all runs' — do treadmill or interval variants count?), and only then call again with dry_run explicitly false and the same expected_revision_token.",
    input_schema: {
      type: "object",
      properties: {
        selector: exerciseSelector,
        replacement_definition_id: { type: "string", description: "Exact catalog id of the replacement movement from search_exercises / get_exercise." },
        dry_run: { type: "boolean", description: "Omit or true = enumerate matches only, nothing changes. Only an explicit false applies the replacement." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["selector", "replacement_definition_id", "expected_revision_token"],
    },
  },
  {
    name: "update_group",
    description: "Patch one group by stable group ID: label, guidance, phase, dose layer, optional flag, repetition (once / N rounds / a time cap), start cadence, whole-group total targets, and round-to-round adjustments. Omit a field to leave it; pass null to clear a nullable field. Label and repetition are required group state and can't be cleared. Values are canonical (kg, meters, seconds).",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        group_id: { type: "string", description: "Stable group ID from get_current_workout." },
        label: { type: "string", minLength: 1, description: "New group label. Omit to leave unchanged." },
        guidance: { type: ["string", "null"], description: "Coach guidance for the group, null to clear, or omit to leave unchanged." },
        phase: { type: ["string", "null"], enum: ["warmup", "main", "cooldown", "transition", null], description: "Workout phase, null to clear." },
        dose: { type: ["string", "null"], enum: ["med", "hpl", "mdv", null], description: "Dose layer (MED / HPL / MDV), null to clear." },
        is_optional: { type: "boolean", description: "Whether the group is optional for the athlete." },
        repetition: groupRepetition,
        cadence: groupCadence,
        total_targets: { type: ["object", "null"], properties: nullableSetMetricProperties, additionalProperties: false, description: "Whole-group canonical totals (e.g. total calories for the block). null clears all; null for one metric clears only that metric." },
        adjustments: { type: ["array", "null"], items: groupAdjustment, description: "Replaces the full adjustment list; null clears it." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["group_id", "expected_revision_token"],
    },
  },
  {
    name: "update_choice",
    description: "Update one either/or choice by stable choice ID: rename its label or set how many options the athlete picks. selection_count must be between 1 and the choice's option count.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        choice_id: { type: "string", description: "Stable choice ID from get_current_workout." },
        label: { type: "string", minLength: 1, description: "New choice label. Omit to leave unchanged." },
        selection_count: { type: "integer", minimum: 1, description: "How many options the athlete performs." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["choice_id", "expected_revision_token"],
    },
  },
  {
    name: "convert_choice_to_group",
    description: "Convert one either/or choice into a required ordered group containing every existing option, by stable choice ID. Keeps the choice's ID, label, and child prescriptions, and one undo_workout_mutation call reverses it. Prefer this ID-targeted tool over require_all_options.",
    input_schema: {
      type: "object",
      properties: {
        choice_id: { type: "string", description: "Stable choice ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["choice_id", "expected_revision_token"],
    },
  },
  {
    name: "update_rest",
    description: "Patch one rest node by stable rest ID: label, placement, duration, or note. Omit a field to leave it; null clears duration or guidance. Label and placement are required rest state and can't be cleared.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        rest_id: { type: "string", description: "Stable rest ID from get_current_workout." },
        label: { type: "string", minLength: 1, description: "New rest label. Omit to leave unchanged." },
        placement: { type: "string", enum: ["inline", "betweenRepetitions", "afterEveryRepetition", "afterFinalRepetition"] },
        duration_seconds: { type: ["integer", "null"], minimum: 0, description: "Rest length in seconds, null to clear (unspecified duration)." },
        guidance: { type: ["string", "null"], description: "Rest note, null to clear." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["rest_id", "expected_revision_token"],
    },
  },
  {
    name: "add_rest",
    description: "Insert a rest node into a block or group at an optional zero-based position (omit at_index to append). A rest can't be a choice option. Returns a versioned receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        parent_id: { type: "string", description: "Stable destination block or group ID from get_current_workout." },
        at_index: { type: "integer", minimum: 0, description: "Optional zero-based insertion position. Omit to append." },
        duration_seconds: { type: "integer", minimum: 0, description: "Rest length in seconds. Omit for an unspecified duration." },
        placement: { type: "string", enum: ["inline", "betweenRepetitions", "afterEveryRepetition", "afterFinalRepetition"], description: "Defaults to inline." },
        label: { type: "string", description: "Defaults to 'Rest'." },
        guidance: { type: "string", description: "Optional rest note." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["parent_id", "expected_revision_token"],
    },
  },
  {
    name: "move_node",
    description: "Move or reorder ANY node — exercise, group, choice, or rest — by stable node ID into a destination container (block, group, or choice) at a zero-based final position. This is the general nesting tool: put an exercise inside a group, pull one out, reorder a choice's options, or reposition a whole group subtree. Everything validates against one snapshot before anything changes: the destination must exist, a node can never move into itself or its own subtree, a rest can't become a choice option, and a choice's only option can't be moved out. Returns a receipt and is undoable.",
    input_schema: {
      type: "object",
      properties: {
        node_id: { type: "string", description: "Stable ID of the node to move (exercise instance, group, choice, or rest) from get_current_workout." },
        to_parent_id: { type: "string", description: "Stable destination container ID: a block, group (children), or choice (options)." },
        to_index: { type: "integer", minimum: 0, description: "Zero-based final position inside the destination." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["node_id", "to_parent_id", "to_index", "expected_revision_token"],
    },
  },
  {
    name: "remove_node",
    description: "Remove ANY node by stable node ID, including a whole group or choice subtree. In a live session every performed exercise, group, and choice record owned by the removed subtree is purged through the logged-work safeguard, and targeted undo restores the node and the exact purged performed content. A choice's only option can't be removed — remove or convert the choice itself instead.",
    input_schema: {
      type: "object",
      properties: {
        node_id: { type: "string", description: "Stable node ID from get_current_workout (exercise instance, group, choice, or rest)." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["node_id", "expected_revision_token"],
    },
  },
  {
    name: "add_set_alternative",
    description: "Add an alternative prescription to one planned set by stable set ID (e.g. '20 cal row OR 15 cal ski'). Values and range bounds are canonical (kg, meters, seconds).",
    input_schema: {
      type: "object",
      properties: {
        set_id: { type: "string", description: "Stable set ID from get_current_workout." },
        label: { type: "string", minLength: 1, description: "What the alternative is, e.g. 'Ski erg'." },
        values: { type: "object", properties: setMetricProperties, additionalProperties: false },
        ranges: { type: "array", items: setRangeTarget },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["set_id", "label", "expected_revision_token"],
    },
  },
  {
    name: "update_set_alternative",
    description: "Patch one set alternative by stable alternative ID: label, canonical values (null clears one metric or the whole map), or ranges (null clears). The label is required state and can't be cleared.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        alternative_id: { type: "string", description: "Stable alternative ID from get_current_workout." },
        label: { type: "string", minLength: 1, description: "New alternative label. Omit to leave unchanged." },
        values: { type: ["object", "null"], properties: nullableSetMetricProperties, additionalProperties: false, description: "null clears every value; null for one metric clears only that value." },
        ranges: { type: ["array", "null"], items: setRangeTarget, description: "Replaces the full range list; null clears it." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["alternative_id", "expected_revision_token"],
    },
  },
  {
    name: "remove_set_alternative",
    description: "Remove one set alternative by stable alternative ID. The planned set itself is unchanged.",
    input_schema: {
      type: "object",
      properties: {
        alternative_id: { type: "string", description: "Stable alternative ID from get_current_workout." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["alternative_id", "expected_revision_token"],
    },
  },
  {
    name: "update_exercise_prescription",
    description: "Patch one exercise instance's prescription-level targets by stable exercise instance ID: rest between sets, tempo, training intent, target heart-rate zone (1-5), and typed intensity targets. Omit a field to leave it; pass null to clear it. intensity_targets replaces the whole list. Set-level values, roles, and ranges belong to update_set instead.",
    input_schema: {
      type: "object",
      minProperties: 3,
      properties: {
        exercise_instance_id: { type: "string", description: "Stable exercise instance ID from get_current_workout." },
        rest_seconds: { type: ["integer", "null"], minimum: 0, description: "Rest between sets in seconds, null to clear." },
        tempo: { type: ["string", "null"], description: "Tempo string such as '3-1-1-0', null to clear." },
        target_zone: { type: ["integer", "null"], minimum: 1, maximum: 5, description: "Target heart-rate zone 1-5, null to clear." },
        intent: { type: ["string", "null"], enum: ["easy", "threshold", "intervals", "vo2", "speed", "long", "race", "strength", "recovery", "mobility", null], description: "Training intent, null to clear." },
        intensity_targets: { type: ["array", "null"], items: intensityTarget, description: "Replaces the full intensity-target list; null clears it." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise_instance_id", "expected_revision_token"],
    },
  },
  {
    name: "create_custom_exercise",
    description: "Deliberately create a custom exercise definition for a movement Baseline's catalog doesn't have. Call search_exercises FIRST - if the movement (or a spelling of it) already exists, use the catalog entry instead of creating a duplicate. TWO-PHASE: call first WITHOUT proposal_id - nothing is created; the tool validates the classification, checks existing custom and catalog movements, and returns the exact definition it would commit (marking every derived or defaulted part) plus a proposal_id. Relay that full classification to the athlete and confirm every part they did not explicitly state - never silently commit a classification you inferred - then call again with the same fields plus that proposal_id to create it. The new exercise is immediately addable by name.",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string", minLength: 1, description: "The movement's name, e.g. 'Single-arm sled drag'." },
        equipment: {
          type: "array",
          minItems: 1,
          items: { type: "string", enum: ["bodyweight", "barbell", "barbellPlates", "ezBar", "trapBar", "dumbbell", "kettlebell", "medicineBall", "machine", "cable", "sled", "sandbag", "box", "bench", "band", "rope", "jumpRope", "pullUpBar", "exerciseBall", "bosuBall", "hangboard", "bike", "rower", "skiErg", "treadmill", "stairStepper", "elliptical", "other"] },
          description: "Gear the movement needs. Required, like the manual create form.",
        },
        primary_muscles: {
          type: "array",
          minItems: 1,
          items: { type: "string", enum: ["chest", "lats", "upperBack", "traps", "lowerBack", "frontDelts", "sideDelts", "rearDelts", "biceps", "triceps", "forearms", "abdominals", "obliques", "glutes", "quadriceps", "hamstrings", "adductors", "abductors", "calves", "hipFlexors", "neck", "fullBody"] },
          description: "What it mainly trains. Required, like the manual create form.",
        },
        secondary_muscles: {
          type: "array",
          items: { type: "string", enum: ["chest", "lats", "upperBack", "traps", "lowerBack", "frontDelts", "sideDelts", "rearDelts", "biceps", "triceps", "forearms", "abdominals", "obliques", "glutes", "quadriceps", "hamstrings", "adductors", "abductors", "calves", "hipFlexors", "neck", "fullBody"] },
        },
        metrics: {
          type: "array",
          minItems: 1,
          items: { type: "string", enum: ["reps", "load", "duration", "distance", "pace", "power", "calories", "cadence", "heartRate", "heartRateZoneTime", "rpe"] },
          description: "The metrics this movement can log (they also become its logging defaults, and its modality is derived from them).",
        },
        patterns: {
          type: "array",
          maxItems: 2,
          items: { type: "string", enum: ["squat", "hinge", "lunge", "push", "pull", "carry", "rotation", "gait", "hold"] },
          description: "Movement pattern(s), at most two.",
        },
        tags: {
          type: "array",
          items: { type: "string", enum: ["hyrox", "crossFit", "powerlifting", "olympicWeightlifting", "strongman", "calisthenics", "plyometric", "running", "cycling", "rowing", "conditioning", "warmUp", "coolDown", "mobility", "rehab", "unilateral"] },
        },
        level: { type: "string", enum: ["beginner", "intermediate", "expert"], description: "Defaults to intermediate when the athlete doesn't say." },
        distance_unit: { type: "string", enum: ["m", "km", "mi"], description: "Optional future display default for this movement's distance." },
        load_unit: { type: "string", enum: ["kg", "lb"], description: "Optional future display default for this movement's load." },
        duration_unit: { type: "string", enum: ["sec", "min"], description: "Optional future display default for this movement's duration." },
        pace_unit: { type: "string", enum: ["/km", "/mi"], description: "Optional future display default for this movement's pace." },
        proposal_id: { type: "string", description: "Pass ONLY on the confirming second call, using the id from the first call's proposal." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["name", "equipment", "primary_muscles", "metrics", "expected_revision_token"],
    },
  },
];

const legacyWaveFiveOverrides = new Map<string, ToolSchema>([
  ["add_block", {
    name: "add_block",
    description: "Add a semantic block to the workout.",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string" },
        intent: { type: "string", description: "Optional purpose." },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["name", "expected_revision_token"],
    },
  }],
  ["add_exercise", {
    name: "add_exercise",
    description: "Add an exercise to a named block, optionally with a uniform set scheme.",
    input_schema: {
      type: "object",
      properties: {
        block: { type: "string", description: "Name of an existing block." },
        name: { type: "string", description: "Exercise name." },
        sets: { type: "integer", minimum: 1 },
        reps: { type: "integer" },
        load: { type: "number" },
        duration_seconds: { type: "integer" },
        distance_m: { type: "number" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["block", "name", "expected_revision_token"],
    },
  }],
  ["move_exercise", {
    name: "move_exercise",
    description: "Move an exercise into another named block. Stable IDs take precedence when supplied.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        exercise_id: { type: "string" },
        to_block: { type: "string" },
        to_block_id: { type: "string" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise", "to_block", "expected_revision_token"],
    },
  }],
  ["replace_exercise", {
    name: "replace_exercise",
    description: "Replace an exercise in place. Stable IDs take precedence when supplied.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        exercise_id: { type: "string" },
        replacement: { type: "string" },
        block: { type: "string" },
        replace_all: { type: "boolean" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise", "replacement", "expected_revision_token"],
    },
  }],
  ["remove_exercise", {
    name: "remove_exercise",
    description: "Remove one exercise. Stable IDs take precedence when supplied.",
    input_schema: {
      type: "object",
      properties: {
        exercise: { type: "string" },
        exercise_id: { type: "string" },
        expected_revision_token: expectedRevisionToken,
      },
      required: ["exercise", "expected_revision_token"],
    },
  }],
]);

const waveFiveOnlyToolNames = new Set([
  "remove_block",
  "move_block",
  "duplicate_block",
  "reorder_exercise",
  "duplicate_exercise",
]);

const waveSixOnlyToolNames = new Set([
  "get_active_session",
  "upsert_performed_set",
  "set_performed_set_outcome",
  "add_extra_performed_set",
  "update_extra_performed_set",
  "delete_extra_performed_set",
  "add_exercise_session_note",
  "undo_session_mutation",
]);

const waveSevenOnlyToolNames = new Set([
  "apply_workout_edits",
  "convert_workout_units",
  "bulk_replace_exercises",
]);

const waveEightOnlyToolNames = new Set([
  "update_group",
  "update_choice",
  "convert_choice_to_group",
  "update_rest",
  "add_rest",
  "move_node",
  "remove_node",
  "add_set_alternative",
  "update_set_alternative",
  "remove_set_alternative",
  "update_exercise_prescription",
]);

const waveNineOnlyToolNames = new Set([
  "create_custom_exercise",
]);

function toolNamed(name: string): ToolSchema {
  const tool = TOOLS.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`missing tool schema: ${name}`);
  return tool;
}

function cloneSchema(schema: Record<string, unknown>): Record<string, unknown> {
  return JSON.parse(JSON.stringify(schema)) as Record<string, unknown>;
}

/**
 * Wave 8 upgraded three existing schemas (nested add_exercise targets, update_set progressions, and
 * the wider batch op enum). Installed Wave 7 and older clients cannot map those payloads, so their
 * served schemas must stay exactly what their mapper understands.
 */
const waveSevenOverrides = new Map<string, ToolSchema>([
  ["add_exercise", (() => {
    const base = toolNamed("add_exercise");
    const schema = cloneSchema(base.input_schema);
    delete (schema.properties as Record<string, unknown>).parent_id;
    delete schema.dependencies;
    schema.required = ["block_id", "name", "expected_revision_token"];
    return {
      ...base,
      description: "Add an exercise to an ID-targeted block at an optional zero-based position, optionally with a uniform set scheme. Omit at_index to append. Nested-parent insertion is not supported by this tool.",
      input_schema: schema,
    };
  })()],
  ["update_set", (() => {
    const base = toolNamed("update_set");
    const schema = cloneSchema(base.input_schema);
    const patch = (schema.properties as Record<string, Record<string, unknown>>).patch;
    delete (patch.properties as Record<string, unknown>).progressions;
    return {
      ...base,
      description: base.description.replace("nullable values, targets, or progressions", "nullable values or targets"),
      input_schema: schema,
    };
  })()],
  ["apply_workout_edits", (() => {
    const base = toolNamed("apply_workout_edits");
    const schema = cloneSchema(base.input_schema);
    const operations = (schema.properties as Record<string, Record<string, unknown>>).operations;
    const items = operations.items as Record<string, Record<string, Record<string, unknown>>>;
    items.properties.op.enum = [...waveSevenBatchOperationNames];
    return { ...base, input_schema: schema };
  })()],
]);

export const WAVE8_TOOLS: ToolSchema[] = TOOLS.filter(
  (tool) => !waveNineOnlyToolNames.has(tool.name),
);

export const WAVE7_TOOLS: ToolSchema[] = WAVE8_TOOLS
  .filter((tool) => !waveEightOnlyToolNames.has(tool.name))
  .map((tool) => waveSevenOverrides.get(tool.name) ?? tool);

export const WAVE6_TOOLS: ToolSchema[] = WAVE7_TOOLS.filter(
  (tool) => !waveSevenOnlyToolNames.has(tool.name),
);

export const WAVE5_TOOLS: ToolSchema[] = WAVE6_TOOLS.filter(
  (tool) => !waveSixOnlyToolNames.has(tool.name),
);

export const LEGACY_TOOLS: ToolSchema[] = WAVE5_TOOLS
  .filter((tool) => !waveFiveOnlyToolNames.has(tool.name))
  .map((tool) => legacyWaveFiveOverrides.get(tool.name) ?? tool);

export type ServedToolset = "wave9" | "wave8" | "wave7" | "wave6" | "wave5" | "legacy";

/**
 * Every toolset variant the runtime can serve, exactly as `toolsForClientSchema` serves it.
 * This is the single enumeration the schema-contract lint (`toolSchemaContract.ts`), the CI
 * real-provider preflight, and the conversation smoke test all iterate - a new variant added
 * here (the `Record` forces it when `ServedToolset` grows) is guarded automatically.
 */
export const SERVED_TOOLSETS: Record<ServedToolset, ToolSchema[]> = {
  wave9: TOOLS,
  wave8: WAVE8_TOOLS,
  wave7: WAVE7_TOOLS,
  wave6: WAVE6_TOOLS,
  wave5: WAVE5_TOOLS,
  legacy: LEGACY_TOOLS,
};

/**
 * Monotonic capability gate: Wave 9 clients receive deliberate custom exercise creation, Wave 8
 * clients keep advanced node and prescription editing, Wave 7 clients keep atomic composite/bulk
 * mutations, Wave 6 clients keep performed logging, Wave 5 clients keep their ID-targeted
 * structure schema, and older clients keep the name-based legacy schema.
 */
export function servedToolsetForClientSchema(version: unknown): ServedToolset {
  if (typeof version !== "string" || !/^\d+$/.test(version)) return "legacy";
  if (Number(version) >= 9) return "wave9";
  if (Number(version) >= 8) return "wave8";
  if (Number(version) >= 7) return "wave7";
  if (Number(version) >= 6) return "wave6";
  return Number(version) >= 5 ? "wave5" : "legacy";
}

export function toolsForClientSchema(version: unknown): ToolSchema[] {
  return SERVED_TOOLSETS[servedToolsetForClientSchema(version)];
}

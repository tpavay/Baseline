const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  buildWorkoutImportProviderRequest,
  createWorkoutImportProviderAliasBoundary,
  parseWorkoutImportPayload,
  createWorkoutImportProviderClient,
  assembleWorkoutImportIR,
  orchestrateWorkoutDocumentParse,
  orchestrateWorkoutSectionParse,
  assembleWorkoutImportSectionDocuments,
  reconcileParsedWorkoutCatalogIdentities,
  workoutImportTokenBudget,
  validateParsedWorkoutDocument,
  WorkoutDocumentValidationError,
  workoutImportValidationLogFields,
  WORKOUT_IMPORT_PROVIDER_OPTIONS,
  WORKOUT_IMPORT_IR_VERSION,
  WORKOUT_IMPORT_SYSTEM,
  WORKOUT_IMPORT_TIMEOUT_SECONDS,
  WORKOUT_IMPORT_TOOL,
} = require("../lib/workoutImport");
const {
  mapWithConcurrency,
  parseStartWorkoutImportJobPayload,
  workoutImportOperationalLog,
} = require("../lib/workoutImportJobs");
const {
  DISPATCH_RECOVERY_MS,
  SECTION_LEASE_MS,
  WORKER_LEASE_MS,
} = require("../lib/workoutImportFirestoreStore");

function assertValidation(action, code, path) {
  assert.throws(action, (error) => {
    assert.ok(error instanceof WorkoutDocumentValidationError);
    assert.equal(error.diagnostic.code, code);
    if (path !== undefined) assert.equal(error.diagnostic.path, path);
    return true;
  });
}

function observation(id, text = "Run", sourceImageIndex = 0) {
  return {
    id, text, sourceImageIndex, confidence: 0.9,
    boundingBox: { x: 0, y: 0, width: 1, height: 0.1 },
  };
}

function validWorkout() {
  return {
    title: "Wrapped workout",
    notes: ["Keep this at conversational effort."],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: ["a"],
      nodes: [{ type: "exercise", exercise: {
        name: "Run", sets: [], notes: [], intensityTargets: [], sourceObservationIDs: ["a"],
      } }],
    }],
  };
}

function validPayload() {
  return { observations: [observation("a")], catalogHints: ["Run"] };
}

function record(id, kind, parentID, order, attributes = {}, sourceObservationIDs = ["a"]) {
  return {
    id, kind, parentID, order,
    attributes: Object.entries(attributes).map(([key, value]) => ({ key, value: `${value}` })),
    sourceObservationIDs,
  };
}

function validIR(records = [
  record("block", "block", "", 0, { name: "Main" }),
  record("run", "exercise", "block", 0, { name: "Run" }),
]) {
  return {
    schemaVersion: WORKOUT_IMPORT_IR_VERSION,
    title: "Wrapped workout",
    goal: "",
    ignoredObservationIDs: [],
    records,
  };
}

function providerIR(value = validIR()) {
  const result = structuredClone(value);
  result.ignoredObservationIDs = result.ignoredObservationIDs.map((id) => id === "a" ? "o1" : id);
  result.records.forEach((item) => {
    item.sourceObservationIDs = item.sourceObservationIDs.map((id) => id === "a" ? "o1" : id);
  });
  return result;
}

function groupIR(attributes, children = []) {
  return validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("group", "group", "block", 0, { label: "Circuit", ...attributes }),
    record("run", "exercise", "group", 0, { name: "Run" }),
    ...children,
  ]);
}

function exerciseIR(attributes, children = []) {
  return validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run", ...attributes }),
    ...children,
  ]);
}

function setIR(setAttributes = {}, metricAttributes = { type: "reps", value: "10" }) {
  return exerciseIR({}, [
    record("set", "set", "run", 0, setAttributes),
    record("metric", "metric", "set", 0, metricAttributes),
  ]);
}

const EXPECTED_PARENT_MATRIX = Object.freeze({
  block: ["root"],
  group: ["block", "group", "choice"],
  choice: ["block", "group", "choice"],
  rest: ["block", "group", "choice"],
  exercise: ["block", "group", "choice"],
  set: ["exercise"],
  setAlternative: ["set"],
  metric: ["set", "setAlternative"],
  intensity: ["exercise"],
  adjustment: ["group"],
  note: ["root", "block", "group", "exercise"],
});

function relationshipTarget(kind, parentID) {
  switch (kind) {
  case "block": return [record("target", kind, parentID, 50, { name: "Target block" })];
  case "group": return [record("target", kind, parentID, 50, { label: "Target group" })];
  case "choice": return [
    record("target", kind, parentID, 50, { label: "Target choice", selectionCount: "1" }),
    record("target-choice-a", "exercise", "target", 0, { name: "Run" }),
    record("target-choice-b", "exercise", "target", 1, { name: "Run" }),
  ];
  case "rest": return [record("target", kind, parentID, 50, { label: "Rest", placement: "inline" })];
  case "exercise": return [record("target", kind, parentID, 50, { name: "Run" })];
  case "set": return [record("target", kind, parentID, 50)];
  case "setAlternative": return [record("target", kind, parentID, 50, { label: "Alternative" })];
  case "metric": return [record("target", kind, parentID, 50, { type: "reps", value: "1" })];
  case "intensity": return [record("target", kind, parentID, 50, { type: "descriptive", value: "Easy" })];
  case "adjustment": return [record("target", kind, parentID, 50, { metric: "duration", step: "60" })];
  case "note": return [record("target", kind, parentID, 50, { text: "Target note" })];
  default: throw new Error(`Unknown relationship target ${kind}`);
  }
}

function relationshipIR(childKind, parentKind) {
  const anchors = [
    record("anchor-block", "block", "", 0, { name: "Main" }),
    record("anchor-group", "group", "anchor-block", 0, { label: "Circuit" }),
    record("anchor-choice", "choice", "anchor-group", 0, { label: "Choose", selectionCount: "1" }),
    record("anchor-choice-a", "exercise", "anchor-choice", 0, { name: "Run" }),
    record("anchor-choice-b", "exercise", "anchor-choice", 1, { name: "Run" }),
    record("anchor-rest", "rest", "anchor-group", 1, { label: "Rest", placement: "inline" }),
    record("anchor-exercise", "exercise", "anchor-group", 2, { name: "Run" }),
    record("anchor-set", "set", "anchor-exercise", 0),
    record("anchor-setAlternative", "setAlternative", "anchor-set", 0, { label: "Alternative" }),
    record("anchor-metric", "metric", "anchor-set", 1, { type: "reps", value: "1" }),
    record("anchor-intensity", "intensity", "anchor-exercise", 1, { type: "descriptive", value: "Easy" }),
    record("anchor-adjustment", "adjustment", "anchor-group", 2, { metric: "duration", step: "60" }),
    record("anchor-note", "note", "anchor-group", 3, { text: "Anchor note" }),
  ];
  const parentID = parentKind === "root" ? "" : `anchor-${parentKind}`;
  return validIR([...anchors, ...relationshipTarget(childKind, parentID)]);
}

function canonicalIR() {
  const metrics = [
    ["reps", "12", "count", { upperValue: "15", progressionDelta: "1", progressionEvery: "2", progressionUnit: "round" }],
    ["load", "20", "kg"],
    ["load", "10", "lb"],
    ["duration", "30", "seconds"],
    ["duration", "2", "minutes"],
    ["distance", "100", "m"],
    ["distance", "1", "km"],
    ["distance", "1", "mi"],
    ["calories", "15", "kcal"],
    ["heartRate", "150", "bpm"],
    ["heartRateZoneTime", "30", "seconds"],
    ["heartRateZoneTime", "2", "minutes"],
    ["cadence", "90", "rpm"],
    ["power", "250", "watts"],
    ["pace", "0.3", "secondsPerMeter"],
    ["rpe", "7", "rpe"],
  ];
  const records = [
    record("workout-note", "note", "", 0, { text: "Workout note" }, ["o-root"]),
    record("block", "block", "", 1, { name: "Main", intent: "strength" }, ["o-root"]),
    record("block-note", "note", "block", 0, { text: "Block note" }, ["o-root"]),
    record("group", "group", "block", 1, {
      label: "Structured circuit", phase: "main", repeatCount: "2", cadenceSeconds: "60",
      cadenceScope: "cycle", scoring: "total", scoreMetric: "power", doseLayer: "med",
      isOptional: "true", ambiguity: "Confirm the circuit order.",
    }, ["o-group"]),
    record("group-note", "note", "group", 0, { text: "Group note" }, ["o-group"]),
    record("adjustment", "adjustment", "group", 0, {
      metric: "duration", step: "600", minimum: "3600", maximum: "4800",
    }, ["o-group"]),
    record("exercise", "exercise", "group", 0, { name: "Run", restSeconds: "90", intent: "easy" }, ["o-exercise"]),
    record("exercise-note", "note", "exercise", 0, { text: "Exercise note" }, ["o-exercise"]),
    record("power-target", "intensity", "exercise", 1, {
      type: "power", lower: "200", upper: "300", unit: "W",
    }, ["o-exercise"]),
    record("alternative", "setAlternative", "set-0", 0, { label: "Scaled" }, ["o-exercise"]),
    record("alternative-metric", "metric", "alternative", 0, {
      type: "distance", value: "50", unit: "meters",
    }, ["o-exercise"]),
    record("choice", "choice", "group", 1, {
      label: "Choose modality", selectionCount: "1", ambiguity: "Choose one option.",
    }, ["o-choice"]),
    record("choice-a", "exercise", "choice", 0, { name: "Run" }, ["o-choice"]),
    record("choice-b", "exercise", "choice", 1, { name: "Run" }, ["o-choice"]),
    record("rest", "rest", "group", 2, {
      label: "Rest between rounds", durationSeconds: "90", placement: "betweenRepetitions",
      guidance: "Recover fully.",
    }, ["o-rest"]),
  ];
  metrics.forEach(([type, value, unit, extra = {}], index) => {
    records.push(record(`set-${index}`, "set", "exercise", index,
      index === 0 ? { role: "working", effortType: "rpe", effortValue: "7" } : {}, ["o-exercise"]));
    records.push(record(`metric-${index}`, "metric", `set-${index}`, 0,
      { type, value, unit, ...extra }, ["o-exercise"]));
  });
  return {
    schemaVersion: 1,
    title: "Canonical import",
    goal: "Metric compatibility",
    ignoredObservationIDs: [],
    records,
  };
}

test("accepts a bounded OCR payload", () => {
  const payload = parseWorkoutImportPayload(JSON.stringify({
    observations: [{ id: "a", text: "3 x 10 Back Squat", confidence: 0.9, boundingBox: { x: 0, y: 0, width: 1, height: 0.1 } }],
    catalogHints: ["Barbell Back Squat"],
  }));
  assert.equal(payload.observations.length, 1);
  assert.equal(payload.observations[0].sourceImageIndex, 0);
});

test("legacy document validator still unwraps only bounded known envelopes", () => {
  const workout = validWorkout();

  for (const wrapped of [
    { document: workout },
    { workout },
    { workoutDocument: workout },
    { result: { document: workout } },
  ]) {
    assert.equal(validateParsedWorkoutDocument(wrapped, new Set(["a"])).title, "Wrapped workout");
  }
  assertValidation(
    () => validateParsedWorkoutDocument({ document: workout, workout }, new Set(["a"])),
    "document.shape", "document",
  );
  assertValidation(
    () => validateParsedWorkoutDocument({ result: { document: workout, workout } }, new Set(["a"])),
    "document.shape", "document",
  );
  assertValidation(
    () => validateParsedWorkoutDocument({ result: { document: { workout } } }, new Set(["a"])),
    "document.shape", "document",
  );
});

test("valid flat IR makes exactly one provider call and assembles the existing document contract", async () => {
  let calls = 0;
  let providerPayload;
  const parsed = await orchestrateWorkoutDocumentParse(validPayload(), async (content) => {
    calls += 1;
    providerPayload = JSON.parse(content);
    return providerIR();
  });
  assert.equal(parsed.document.title, "Wrapped workout");
  assert.equal(parsed.document.blocks[0].nodes[0].exercise.name, "Run");
  assert.equal(calls, 1);
  assert.equal(providerPayload.observations[0].id, "o1");
});

test("provider aliases compact SHA-256 observation and fragment IDs then expand provenance", async () => {
  const firstID = "a".repeat(64);
  const secondID = "b".repeat(64);
  const scopeID = "c".repeat(64);
  const payload = {
    observations: [observation(firstID, "Main"), observation(secondID, "Run 400 m")],
    catalogHints: ["Run"],
    sourcePlan: { startFragmentPath: [scopeID], endFragmentPath: [scopeID] },
  };
  let content = "";
  const result = await orchestrateWorkoutDocumentParse(payload, async (request) => {
    content = request;
    return validIR([
      record("block", "block", "", 0, { name: "Main" }, ["o1"]),
      record("run", "exercise", "block", 0, { name: "Run" }, ["o2"]),
    ]);
  });

  const sent = JSON.parse(content);
  assert.deepEqual(sent.observations.map((item) => item.id), ["o1", "o2"]);
  assert.deepEqual(sent.sourcePlan, { startFragmentPath: ["f1"], endFragmentPath: ["f1"] });
  assert.equal(content.includes(firstID), false);
  assert.equal(content.includes(secondID), false);
  assert.equal(content.includes(scopeID), false);
  assert.deepEqual(result.document.blocks[0].sourceObservationIDs, [firstID]);
  assert.deepEqual(result.document.blocks[0].nodes[0].exercise.sourceObservationIDs, [secondID]);
});

test("provenance diagnostics target missing opaque aliases without adding them to logs", () => {
  const firstID = "a".repeat(64);
  const secondID = "b".repeat(64);
  const observations = [
    observation(firstID, "Main"),
    observation(secondID, "12 Burpees"),
  ];
  const payload = { observations, catalogHints: ["Burpee"] };
  const boundary = createWorkoutImportProviderAliasBoundary(payload);
  let diagnostic;

  try {
    assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [firstID]),
    ]), new Set([firstID, secondID]), {
      allowEmptyExercises: true,
      fallbackObservations: observations,
      fallbackScope: "workout",
      catalogHints: ["Burpee"],
    });
  } catch (error) {
    assert.ok(error instanceof WorkoutDocumentValidationError);
    diagnostic = error.diagnostic;
  }

  assert.deepEqual(diagnostic.unaccountedObservationIDs, [secondID]);
  const compact = boundary.compactDiagnostic(diagnostic);
  assert.deepEqual(compact.unaccountedObservationIDs, ["o2"]);
  const fields = workoutImportValidationLogFields("initial", diagnostic);
  assert.equal(Object.hasOwn(fields, "unaccountedObservationIDs"), false);
  assert.equal(JSON.stringify(fields).includes(secondID), false);
});

test("relationship repair identifies the exact source rule without exposing durable IDs to logs", async () => {
  const durableID = "e".repeat(64);
  const payload = {
    observations: [observation(
      durableID,
      "B. 12 Deadlifts @ Bodyweight + 12 lateral burpees over barbell.",
    )],
    catalogHints: ["Deadlift", "Lateral Burpee Over Barbell"],
  };
  const initial = validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1"]),
    record("deadlift", "exercise", "block", 0, { name: "Deadlift" }, ["o1"]),
  ]);
  const repaired = validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1"]),
    record("station-b", "group", "block", 0, { label: "B" }, ["o1"]),
    record("deadlift", "exercise", "station-b", 0, { name: "Deadlift" }, ["o1"]),
    record("burpee", "exercise", "station-b", 1, {
      name: "Lateral Burpee Over Barbell",
    }, ["o1"]),
  ]);
  const requests = [];
  const failures = [];

  const result = await orchestrateWorkoutSectionParse(payload, async (content) => {
    requests.push(JSON.parse(content));
    return requests.length === 1 ? initial : repaired;
  }, {
    onValidationFailure: (attempt, diagnostic) => failures.push({ attempt, diagnostic }),
  });

  assert.equal(result.repaired, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].diagnostic.relationshipRule, "source_required_movements");
  assert.deepEqual(requests[1].diagnostic.relatedObservationIDs, ["o1"]);
  assert.equal(requests[1].diagnostic.expectedExerciseCount, 2);
  assert.match(requests[1].relationshipRepair, /separate required sibling exercises/);
  assert.equal(JSON.stringify(requests[1]).includes(durableID), false);
  assert.equal(failures[0].attempt, "initial");
  assert.deepEqual(failures[0].diagnostic.relatedObservationIDs, [durableID]);
  const logFields = workoutImportValidationLogFields("initial", failures[0].diagnostic);
  assert.equal(logFields.relationshipRule, "source_required_movements");
  assert.equal(logFields.expectedExerciseCount, 2);
  assert.equal(Object.hasOwn(logFields, "relatedObservationIDs"), false);
  assert.equal(JSON.stringify(logFields).includes(durableID), false);
  assert.deepEqual(result.document.blocks[0].nodes[0].group.children.map(
    (node) => node.exercise.name,
  ), ["Deadlift", "Lateral Burpee Over Barbell"]);
});

test("allowed-parent repair identifies the record kind and accepted parent kinds", () => {
  const input = validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("set", "set", "block", 0),
  ]);

  assert.throws(
    () => assembleWorkoutImportIR(input, new Set(["a"])),
    (error) => {
      assert.ok(error instanceof WorkoutDocumentValidationError);
      assert.equal(error.diagnostic.relationshipRule, "allowed_parent");
      assert.equal(error.diagnostic.recordKind, "set");
      assert.deepEqual(error.diagnostic.expectedParentKinds, ["exercise"]);
      return true;
    },
  );
});

test("unknown and duplicate provider aliases fail closed and an unknown alias receives one repair", async () => {
  const originalID = "d".repeat(64);
  const payload = { observations: [observation(originalID)], catalogHints: ["Run"] };
  const invalid = validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o999"]),
    record("run", "exercise", "block", 0, { name: "Run" }, ["o999"]),
  ]);
  const requests = [];
  const repaired = await orchestrateWorkoutSectionParse(payload, async (content) => {
    requests.push(JSON.parse(content));
    return requests.length === 1 ? invalid : validIR([
      record("block", "block", "", 0, { name: "Main" }, ["o1"]),
      record("run", "exercise", "block", 0, { name: "Run" }, ["o1"]),
    ]);
  });
  assert.equal(repaired.repaired, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].diagnostic.code, "ir.provenance");
  assert.deepEqual(requests[1].invalidIR.records[0].sourceObservationIDs,
    [null]);
  assert.deepEqual(repaired.document.blocks[0].sourceObservationIDs, [originalID]);

  const boundary = createWorkoutImportProviderAliasBoundary(payload);
  const duplicate = boundary.expandIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1", "o1"]),
    record("run", "exercise", "block", 0, { name: "Run" }, ["o1"]),
  ]));
  assertValidation(
    () => assembleWorkoutImportIR(duplicate, new Set([originalID])),
    "ir.provenance",
    "ir.records[0].sourceObservationIDs",
  );
  assert.throws(() => parseWorkoutImportPayload({
    observations: [observation(originalID), observation(originalID)],
    catalogHints: [],
  }), /observation identifiers must be unique/);
});

test("unknown aliases cannot collide with a valid legacy observation identifier", () => {
  const legacyID = "invalid-provider-observation-alias";
  const payload = { observations: [observation(legacyID)], catalogHints: ["Run"] };
  const boundary = createWorkoutImportProviderAliasBoundary(payload);
  const valid = boundary.expandIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1"]),
    record("run", "exercise", "block", 0, { name: "Run" }, ["o1"]),
  ]));
  assert.doesNotThrow(() => assembleWorkoutImportIR(valid, new Set([legacyID])));

  const unknown = boundary.expandIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o999"]),
    record("run", "exercise", "block", 0, { name: "Run" }, ["o999"]),
  ]));
  assert.deepEqual(unknown.records[0].sourceObservationIDs, [null]);
  assertValidation(
    () => assembleWorkoutImportIR(unknown, new Set([legacyID])),
    "ir.provenance",
    "ir.records[0].sourceObservationIDs",
  );
});

test("raw provider numeric and boolean attribute scalars normalize without regeneration", async () => {
  const rawIR = {
    schemaVersion: WORKOUT_IMPORT_IR_VERSION,
    title: "EMOM",
    goal: "",
    ignoredObservationIDs: [],
    records: [
      {
        id: "block", kind: "block", parentID: "", order: 0,
        attributes: [{ key: "name", value: "Main" }], sourceObservationIDs: ["a"],
      },
      {
        id: "group", kind: "group", parentID: "block", order: 0,
        attributes: [
          { key: "label", value: "EMOM" },
          { key: "cadenceSeconds", value: 60 },
          { key: "cadenceScope", value: "child" },
          { key: "isOptional", value: true },
        ],
        sourceObservationIDs: ["a"],
      },
      {
        id: "run", kind: "exercise", parentID: "group", order: 0,
        attributes: [{ key: "name", value: "Run" }], sourceObservationIDs: ["a"],
      },
    ],
  };
  let calls = 0;
  const parsed = await orchestrateWorkoutDocumentParse(validPayload(), async () => {
    calls += 1;
    return providerIR(rawIR);
  });

  const group = parsed.document.blocks[0].nodes[0].group;
  assert.equal(calls, 1);
  assert.equal(group.cadenceSeconds, 60);
  assert.equal(group.cadenceScope, "child");
  assert.equal(group.isOptional, true);
});

test("raw provider scalar normalization remains schema-aware and fails closed", () => {
  const numericText = validIR();
  numericText.records[0].attributes[0].value = 42;

  const booleanNumeric = groupIR({ cadenceSeconds: "60", cadenceScope: "child" });
  booleanNumeric.records[1].attributes[1].value = true;

  const numericEnum = groupIR({ cadenceSeconds: "60", cadenceScope: "child" });
  numericEnum.records[1].attributes[2].value = 1;

  const numericBoolean = groupIR({ isOptional: "true" });
  numericBoolean.records[1].attributes[1].value = 1;

  const nonfiniteNumeric = groupIR({ cadenceSeconds: "60", cadenceScope: "child" });
  nonfiniteNumeric.records[1].attributes[1].value = Number.POSITIVE_INFINITY;

  const cases = [
    [numericText, "ir.records[0].attributes[0].value", "number"],
    [booleanNumeric, "ir.records[1].attributes[1].value", "boolean"],
    [numericEnum, "ir.records[1].attributes[2].value", "number"],
    [numericBoolean, "ir.records[1].attributes[1].value", "number"],
    [nonfiniteNumeric, "ir.records[1].attributes[1].value", "nonfinite"],
  ];

  for (const [ir, expectedPath, expectedKind] of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(ir, new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError &&
        error.diagnostic.code === "ir.attribute" &&
        error.diagnostic.path === expectedPath &&
        error.diagnostic.actualKind === expectedKind,
    );
  }
});

test("invalid IR fails after one provider call without whole-document regeneration", async () => {
  let calls = 0;
  const diagnostics = [];
  await assert.rejects(
    orchestrateWorkoutDocumentParse(validPayload(), async () => {
      calls += 1;
      return { invalid: true };
    }, {
      onValidationFailure: (attempt, diagnostic) =>
        diagnostics.push([attempt, diagnostic.boundary, diagnostic.code]),
    }),
    (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === "ir.shape",
  );
  assert.equal(calls, 1);
  assert.deepEqual(diagnostics, [["initial", "ir", "ir.shape"]]);
});

test("strict provider tool uses a small non-recursive all-required IR schema", () => {
  assert.equal(WORKOUT_IMPORT_TOOL.strict, true);
  assert.equal(WORKOUT_IMPORT_TOOL.name, "submit_workout_import_ir");
  const seen = new Set();
  let propertyCount = 0;
  let optionalPropertyCount = 0;
  let maximumDepth = 0;
  let hasReference = false;
  const forbiddenKeywords = new Set([
    "pattern", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems",
  ]);
  const foundForbiddenKeywords = new Set();

  function inspect(value, depth) {
    if (!value || typeof value !== "object" || seen.has(value)) return;
    seen.add(value);
    maximumDepth = Math.max(maximumDepth, depth);
    if (Object.hasOwn(value, "$ref")) hasReference = true;
    if (value.properties) {
      const keys = Object.keys(value.properties);
      const required = new Set(value.required ?? []);
      propertyCount += keys.length;
      optionalPropertyCount += keys.filter((key) => !required.has(key)).length;
      for (const child of Object.values(value.properties)) inspect(child, depth + 1);
    }
    if (value.items) inspect(value.items, depth + 1);
  }

  function collectForbidden(value) {
    if (!value || typeof value !== "object") return;
    for (const [key, child] of Object.entries(value)) {
      if (forbiddenKeywords.has(key)) foundForbiddenKeywords.add(key);
      collectForbidden(child);
    }
  }

  inspect(WORKOUT_IMPORT_TOOL.input_schema, 0);
  collectForbidden(WORKOUT_IMPORT_TOOL.input_schema);
  assert.equal(hasReference, false);
  assert.deepEqual([...foundForbiddenKeywords], []);
  assert.equal(optionalPropertyCount, 0);
  assert.ok(propertyCount <= 24, `strict schema has ${propertyCount} properties`);
  assert.ok(maximumDepth <= 8, `strict schema depth is ${maximumDepth}`);
  assert.deepEqual(
    WORKOUT_IMPORT_TOOL.input_schema.required,
    ["schemaVersion", "title", "goal", "ignoredObservationIDs", "records"],
  );
});

test("provider request builder pins the strict import contract and forced matching tool", () => {
  const request = buildWorkoutImportProviderRequest("test-model", "serialized OCR");
  assert.equal(request.model, "test-model");
  assert.equal(request.max_tokens, 4_096);
  assert.equal(request.temperature, 0);
  assert.equal(request.system, WORKOUT_IMPORT_SYSTEM);
  assert.deepEqual(request.tools, [WORKOUT_IMPORT_TOOL]);
  assert.deepEqual(request.tool_choice, { type: "tool", name: WORKOUT_IMPORT_TOOL.name });
  assert.deepEqual(request.messages, [{ role: "user", content: "serialized OCR" }]);
});

test("section token budgets are proportional and remain within the fixed clamp", () => {
  assert.equal(workoutImportTokenBudget(validPayload()), 4_096);
  const large = {
    observations: Array.from({ length: 121 }, (_, index) => observation(`line-${index}`, "Run")),
    catalogHints: [],
  };
  assert.equal(workoutImportTokenBudget(large), 6_144);
  assert.equal(buildWorkoutImportProviderRequest("model", "payload", 99_999).max_tokens, 8_192);
  assert.equal(buildWorkoutImportProviderRequest("model", "payload", 1).max_tokens, 2_048);
});

test("one invalid section receives exactly one isolated repair", async () => {
  const durableID = "9".repeat(64);
  const payload = { observations: [observation(durableID)], catalogHints: ["Run"] };
  const invalid = validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1"]),
    record("run", "exercise", "missing", 0, { name: "Run" }, ["o1"]),
  ]);
  const responses = [invalid, validIR([
    record("block", "block", "", 0, { name: "Main" }, ["o1"]),
    record("run", "exercise", "block", 0, { name: "Run" }, ["o1"]),
  ])];
  const requests = [];
  const result = await orchestrateWorkoutSectionParse(payload, async (content, maxTokens) => {
    requests.push({ content: JSON.parse(content), maxTokens });
    return responses.shift();
  });
  assert.equal(result.repaired, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[0].maxTokens, 4_096);
  assert.equal(requests[1].content.task, "repair_one_workout_section");
  assert.deepEqual(requests[1].content.section, {
    ...payload,
    observations: [{ ...payload.observations[0], id: "o1" }],
  });
  assert.deepEqual(
    requests[1].content.invalidIR.records.flatMap((item) => item.sourceObservationIDs),
    ["o1", "o1"],
  );
  assert.equal(JSON.stringify(requests[1].content).includes(durableID), false);
  assert.equal(requests[1].content.diagnostic.code, "assembly.parent_missing");
  assert.deepEqual(result.document.blocks[0].sourceObservationIDs, [durableID]);
});

test("missing required attribute gives one fixed repair hint and privacy-safe operational field", async () => {
  const invalid = providerIR(validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("note", "note", "block", 0),
  ]));
  const repaired = providerIR(validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("note", "note", "block", 0, { text: "Keep the effort controlled." }),
  ]));
  const requests = [];

  const result = await orchestrateWorkoutSectionParse(validPayload(), async (content) => {
    requests.push(JSON.parse(content));
    return requests.length === 1 ? invalid : repaired;
  });

  assert.equal(result.repaired, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].diagnostic.code, "ir.attribute");
  assert.equal(requests[1].diagnostic.path, "ir.records[1].attributes");
  assert.equal(requests[1].diagnostic.expectedAttribute, "text");
  assert.match(requests[1].requirement, /diagnostic\.expectedAttribute/);
  assert.equal(
    Object.hasOwn(workoutImportValidationLogFields("initial", requests[1].diagnostic), "expectedAttribute"),
    true,
  );
  assert.equal(
    workoutImportValidationLogFields("initial", requests[1].diagnostic).expectedAttribute,
    "text",
  );
  assert.deepEqual(result.document.blocks[0].notes, ["Keep the effort controlled."]);
});

test("operational diagnostics reject a provider-controlled expected attribute", () => {
  const sentinel = "PRIVATE-WORKOUT-ATTRIBUTE-9f2d";
  const fields = workoutImportValidationLogFields("repair", {
    version: 1,
    boundary: "ir",
    code: "ir.attribute",
    path: "ir.records[1].attributes",
    actualKind: "missing",
    expectedAttribute: sentinel,
  });

  assert.equal(Object.hasOwn(fields, "expectedAttribute"), false);
  assert.equal(JSON.stringify(fields).includes(sentinel), false);
});

test("a malformed provider record receives the bounded record-shape repair", async () => {
  const invalid = { ...providerIR(validIR()), records: [null] };
  const repaired = providerIR(validIR());
  const requests = [];

  const result = await orchestrateWorkoutSectionParse(validPayload(), async (content) => {
    requests.push(JSON.parse(content));
    return requests.length === 1 ? invalid : repaired;
  });

  assert.equal(result.repaired, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[1].diagnostic.code, "ir.record_shape");
  assert.equal(requests[1].diagnostic.path, "ir.records[0]");
  assert.equal(result.document.title, "Wrapped workout");
});

test("set synthesis preserves the repair index of a later malformed record", async () => {
  const line = observation("a", "2:00-minute run at threshold effort");
  const invalid = providerIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [line.id]),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }, [line.id]),
    record("note", "note", "run", 0, {}, [line.id]),
  ]));
  const repaired = providerIR(validIR());
  const requests = [];

  await orchestrateWorkoutSectionParse(
    { observations: [line], catalogHints: ["Run"] },
    async (content) => {
      requests.push(JSON.parse(content));
      return requests.length === 1 ? invalid : repaired;
    },
  );

  assert.equal(requests.length, 2);
  assert.equal(requests[1].diagnostic.code, "ir.attribute");
  assert.equal(requests[1].diagnostic.path, "ir.records[3].attributes");
  assert.equal(requests[1].invalidIR.records.length, 4);
});

test("a failed repair stops after two section-only provider calls", async () => {
  const invalid = providerIR(validIR([record("run", "exercise", "missing", 0, { name: "Run" })]));
  let calls = 0;
  const attempts = [];
  await assert.rejects(
    orchestrateWorkoutSectionParse(
      validPayload(),
      async () => { calls += 1; return invalid; },
      { onValidationFailure: (attempt) => attempts.push(attempt) },
    ),
    WorkoutDocumentValidationError,
  );
  assert.equal(calls, 2);
  assert.deepEqual(attempts, ["initial", "repair"]);
});

test("section documents assemble locally in source order without a provider call", () => {
  const first = assembleWorkoutImportIR(validIR(), new Set(["a"]));
  const secondIR = validIR([
    record("block-b", "block", "", 0, { name: "Main" }, ["b"]),
    record("bike", "exercise", "block-b", 0, { name: "Echo Bike" }, ["b"]),
  ]);
  const second = assembleWorkoutImportIR(secondIR, new Set(["b"]));
  const firstSectionID = "a".repeat(64);
  const secondSectionID = "b".repeat(64);
  const assembled = assembleWorkoutImportSectionDocuments([
    { sectionID: firstSectionID, startScopeID: firstSectionID, endScopeID: firstSectionID, document: first },
    { sectionID: secondSectionID, startScopeID: secondSectionID, endScopeID: secondSectionID, document: second },
  ], new Set(["a", "b"]));
  assert.equal(assembled.blocks.length, 2);
  assert.deepEqual(
    assembled.blocks.flatMap((block) => block.nodes.map((node) => node.exercise.name)),
    ["Run", "Echo Bike"],
  );
});

test("continued AMRAP fragments recursively merge into one block and one parent group", () => {
  const exercise = (name, id) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [id],
  } });
  const group = (children, ids) => ({ type: "group", group: {
    label: "70-minute AMRAP",
    durationSeconds: 4_200,
    adjustments: [{ metric: "duration", step: 600 }],
    children,
    notes: [],
    isOptional: false,
    sourceObservationIDs: ids,
  } });
  const firstSectionID = "a".repeat(64);
  const secondSectionID = "b".repeat(64);
  const parentScopeID = "c".repeat(64);
  const amrapFragmentID = "d".repeat(64);
  const assembled = assembleWorkoutImportSectionDocuments([
    {
      sectionID: firstSectionID,
      startScopeID: parentScopeID,
      endScopeID: parentScopeID,
      startFragmentPath: [parentScopeID, amrapFragmentID],
      endFragmentPath: [parentScopeID, amrapFragmentID],
      document: {
        title: "Aerobic capacity",
        notes: [],
        blocks: [{
          name: "Minimum Effective Dose",
          notes: [],
          nodes: [group([exercise("Echo Bike", "bike")], ["bike"])],
          sourceObservationIDs: ["bike"],
        }],
      },
    },
    {
      sectionID: secondSectionID,
      startScopeID: parentScopeID,
      endScopeID: parentScopeID,
      startFragmentPath: [parentScopeID, amrapFragmentID],
      endFragmentPath: [parentScopeID, amrapFragmentID],
      continuationFromSectionID: firstSectionID,
      document: {
        title: "Aerobic capacity",
        notes: [],
        blocks: [{
          name: "Minimum Effective Dose",
          notes: [],
          nodes: [group([
            { type: "choice", choice: {
              label: "Alternate A and B",
              selectionCount: 1,
              options: [exercise("Sled Pull", "sled"), exercise("Deadlift", "deadlift")],
              sourceObservationIDs: ["sled", "deadlift"],
            } },
            exercise("Lateral Burpee Over Barbell", "burpee"),
          ], ["sled", "deadlift", "burpee"])],
          sourceObservationIDs: ["sled", "deadlift", "burpee"],
        }],
      },
    },
  ], new Set(["bike", "sled", "deadlift", "burpee"]));

  assert.equal(assembled.blocks.length, 1);
  assert.equal(assembled.blocks[0].nodes.length, 1);
  const amrap = assembled.blocks[0].nodes[0].group;
  assert.equal(amrap.label, "70-minute AMRAP");
  assert.equal(amrap.children.length, 3);
  assert.equal(amrap.children[1].choice.options.length, 2);
  assert.deepEqual(amrap.sourceObservationIDs, ["bike", "sled", "deadlift", "burpee"]);
});

test("boundary anchors merge a repeated child fragment inside a repeated outer wrapper", () => {
  const exercise = (name, id) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [id],
  } });
  const group = (label, children, ids, metadata = {}) => ({ type: "group", group: {
    label, adjustments: [], children, notes: [], isOptional: false,
    sourceObservationIDs: ids, ...metadata,
  } });
  const firstSectionID = "a".repeat(64);
  const secondSectionID = "b".repeat(64);
  const scopeID = "c".repeat(64);
  const fragmentID = "d".repeat(64);
  const assembled = assembleWorkoutImportSectionDocuments([
    {
      sectionID: firstSectionID,
      startScopeID: scopeID,
      endScopeID: scopeID,
      startFragmentPath: [scopeID, fragmentID],
      endFragmentPath: [scopeID, fragmentID],
      endObservationIDs: ["interval-heading"],
      document: {
        title: "Workout", notes: [],
        blocks: [{
          name: "MED", notes: [],
          nodes: [group("70 minute AMRAP", [
            group("Aerobic Intervals", [], ["interval-heading"], {
              repeatCount: 6,
              notes: ["C2 Bike / Echo Bike"],
            }),
          ], ["amrap", "interval-heading"], { durationSeconds: 4_200 })],
          sourceObservationIDs: ["amrap", "interval-heading"],
        }],
      },
    },
    {
      sectionID: secondSectionID,
      startScopeID: scopeID,
      endScopeID: scopeID,
      startFragmentPath: [scopeID, fragmentID],
      endFragmentPath: [scopeID, fragmentID],
      startObservationIDs: ["interval-work"],
      continuationFromSectionID: firstSectionID,
      document: {
        title: "Workout", notes: [],
        blocks: [{
          name: "MED", notes: [],
          nodes: [group("70-minute AMRAP", [
            group("Aerobic Intervals", [exercise("Echo Bike", "interval-work")], ["interval-work"], {
              repeatCount: 6,
            }),
          ], ["interval-work"], { durationSeconds: 4_200 })],
          sourceObservationIDs: ["interval-work"],
        }],
      },
    },
  ], new Set(["amrap", "interval-heading", "interval-work"]));

  const amrap = assembled.blocks[0].nodes[0].group;
  assert.equal(amrap.children.length, 1);
  const intervals = amrap.children[0].group;
  assert.equal(intervals.repeatCount, 6);
  assert.deepEqual(intervals.notes, ["C2 Bike / Echo Bike"]);
  assert.deepEqual(intervals.sourceObservationIDs, ["interval-heading", "interval-work"]);
  assert.equal(intervals.children[0].exercise.name, "Echo Bike");
});

test("source anchors merge around trailing blocks, unwrapped children, and rest siblings", () => {
  const exercise = (name, id) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [id],
  } });
  const group = (label, children, ids, metadata = {}) => ({ type: "group", group: {
    label, adjustments: [], children, notes: [], isOptional: false,
    sourceObservationIDs: ids, ...metadata,
  } });
  const section0 = "a".repeat(64);
  const section1 = "b".repeat(64);
  const section2 = "c".repeat(64);
  const medScope = "d".repeat(64);
  const amrapFragment = "e".repeat(64);
  const mdvScope = "f".repeat(64);
  const skiFragment = "1".repeat(64);
  const assembled = assembleWorkoutImportSectionDocuments([
    {
      sectionID: section0,
      startScopeID: medScope,
      endScopeID: medScope,
      startFragmentPath: [medScope],
      endFragmentPath: [medScope, amrapFragment],
      endObservationIDs: ["interval-heading", "amrap"],
      document: {
        title: "Aerobic capacity",
        notes: [],
        blocks: [
          {
            name: "Minimum Effective Dose",
            notes: [],
            nodes: [group("70 minute AMRAP", [], ["amrap"], { durationSeconds: 4_200 })],
            sourceObservationIDs: ["med"],
          },
          { name: "Daily Summary", notes: ["Summary"], nodes: [], sourceObservationIDs: ["summary"] },
        ],
      },
    },
    {
      sectionID: section1,
      startScopeID: medScope,
      endScopeID: mdvScope,
      startFragmentPath: [medScope, amrapFragment],
      endFragmentPath: [mdvScope, skiFragment],
      startObservationIDs: ["work"],
      endObservationIDs: ["rest", "plank"],
      continuationFromSectionID: section0,
      document: {
        title: "Aerobic capacity",
        notes: [],
        blocks: [
          {
            name: "AMRAP continuation",
            notes: [],
            nodes: [
              group("Aerobic Intervals", [exercise("Echo Bike", "work")], ["work"], { repeatCount: 6 }),
              group("A", [exercise("Sled Pull", "sled")], ["sled"]),
            ],
            sourceObservationIDs: ["work"],
          },
          { name: "Performance Layer", notes: [], nodes: [], sourceObservationIDs: ["performance"] },
          {
            name: "Maximum Daily Volume",
            notes: [],
            nodes: [
              group("4 Rounds", [exercise("Plank", "plank")], ["plank"], { repeatCount: 4 }),
              { type: "rest", rest: {
                label: "Rest", placement: "betweenRepetitions", durationSeconds: 90,
                sourceObservationIDs: ["rest"],
              } },
            ],
            sourceObservationIDs: ["mdv"],
          },
        ],
      },
    },
    {
      sectionID: section2,
      startScopeID: mdvScope,
      endScopeID: mdvScope,
      startFragmentPath: [mdvScope, skiFragment],
      endFragmentPath: [mdvScope],
      startObservationIDs: ["continued-note"],
      continuationFromSectionID: section1,
      document: {
        title: "Aerobic capacity",
        notes: [],
        blocks: [
          {
            name: "Continued workout",
            notes: [],
            nodes: [group("Continued section", [], ["continued-note"], { notes: ["Keep this easy."] })],
            sourceObservationIDs: ["continued-note"],
          },
          { name: "Coach's Note", notes: ["Finish calm."], nodes: [], sourceObservationIDs: ["coach"] },
        ],
      },
    },
  ], new Set([
    "amrap", "med", "summary", "work", "sled", "performance", "plank", "rest", "mdv",
    "continued-note", "coach",
  ]));

  assert.equal(assembled.blocks.length, 5);
  const med = assembled.blocks.find((block) => block.name === "Minimum Effective Dose");
  assert.equal(med.nodes[0].group.children[0].group.label, "Aerobic Intervals");
  assert.equal(med.nodes[0].group.children[1].group.label, "A");
  const mdv = assembled.blocks.find((block) => block.name === "Maximum Daily Volume");
  assert.deepEqual(mdv.nodes[0].group.notes, ["Keep this easy."]);
  assert.equal(mdv.nodes[1].type, "rest");
});

test("conflicting continuation wrappers fail closed instead of multiplying prescriptions", () => {
  const exercise = (id) => ({ type: "exercise", exercise: {
    name: "Run", sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [id],
  } });
  const group = (metadata = {}) => ({ type: "group", group: {
    label: "Rounds", adjustments: [], children: [exercise("run")], notes: [],
    isOptional: false, sourceObservationIDs: ["run"], ...metadata,
  } });
  const choice = (selectionCount) => ({ type: "choice", choice: {
    label: "Choose", selectionCount,
    options: [exercise("run"), exercise("bike")],
    sourceObservationIDs: ["run", "bike"],
  } });
  const scope = "a".repeat(64);
  const fragment = "b".repeat(64);
  const firstSection = "c".repeat(64);
  const secondSection = "d".repeat(64);
  const assemble = (targetNode, incomingNode) => assembleWorkoutImportSectionDocuments([
    {
      sectionID: firstSection, startScopeID: scope, endScopeID: scope,
      startFragmentPath: [scope, fragment], endFragmentPath: [scope, fragment],
      document: {
        title: "Workout", notes: [],
        blocks: [{ name: "Main", notes: [], nodes: [targetNode], sourceObservationIDs: ["run"] }],
      },
    },
    {
      sectionID: secondSection, startScopeID: scope, endScopeID: scope,
      startFragmentPath: [scope, fragment], endFragmentPath: [scope, fragment],
      continuationFromSectionID: firstSection,
      document: {
        title: "Workout", notes: [],
        blocks: [{ name: "Main", notes: [], nodes: [incomingNode], sourceObservationIDs: ["bike"] }],
      },
    },
  ], new Set(["run", "bike"]));

  for (const [target, incoming] of [
    [group({ repeatCount: 4 }), group({ repeatCount: 5 })],
    [group({ durationSeconds: 60 }), group({ durationSeconds: 90 })],
    [group(), group({ isOptional: true })],
    [choice(1), choice(2)],
  ]) {
    assert.throws(() => assemble(target, incoming), /cross_section_assembly/);
  }
});

test("continuation containers sharing only generic label words remain distinct", () => {
  const exercise = (name, id) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [id],
  } });
  const group = (label, id, metadata = {}) => ({ type: "group", group: {
    label, adjustments: [], children: [exercise("Run", id)], notes: [], isOptional: false,
    sourceObservationIDs: [id], ...metadata,
  } });
  const choice = (label, id) => ({ type: "choice", choice: {
    label, selectionCount: 1,
    options: [exercise("Run", id), exercise("Bike", `${id}-bike`)],
    sourceObservationIDs: [id, `${id}-bike`],
  } });
  const scope = "2".repeat(64);
  const fragment = "3".repeat(64);
  const firstSection = "4".repeat(64);
  const secondSection = "5".repeat(64);
  const assemble = (targetNode, incomingNode, validIDs) => assembleWorkoutImportSectionDocuments([
    {
      sectionID: firstSection, startScopeID: scope, endScopeID: scope,
      startFragmentPath: [scope, fragment], endFragmentPath: [scope, fragment],
      document: {
        title: "Workout", notes: [],
        blocks: [{ name: "Main", notes: [], nodes: [targetNode], sourceObservationIDs: [validIDs[0]] }],
      },
    },
    {
      sectionID: secondSection, startScopeID: scope, endScopeID: scope,
      startFragmentPath: [scope, fragment], endFragmentPath: [scope, fragment],
      continuationFromSectionID: firstSection,
      document: {
        title: "Workout", notes: [],
        blocks: [{ name: "Main", notes: [], nodes: [incomingNode], sourceObservationIDs: [validIDs[1]] }],
      },
    },
  ], new Set(validIDs));

  const grouped = assemble(
    group("Circuit One", "one"), group("Circuit Two", "two"), ["one", "two"],
  );
  assert.equal(grouped.blocks[0].nodes[0].group.label, "Circuit One");
  assert.equal(grouped.blocks[0].nodes[0].group.children[1].group.label, "Circuit Two");

  const repeated = assemble(
    group("4 Rounds", "repeat-one", { repeatCount: 4 }),
    group("Four Rounds", "repeat-two", { repeatCount: 4 }),
    ["repeat-one", "repeat-two"],
  );
  assert.equal(repeated.blocks[0].nodes[0].group.children.length, 2);
  assert.ok(repeated.blocks[0].nodes[0].group.children.every((node) => node.type === "exercise"));

  const timed = assemble(
    group("70 Minutes", "time-one", { durationSeconds: 4_200 }),
    group("Seventy Minutes", "time-two", { durationSeconds: 4_200 }),
    ["time-one", "time-two"],
  );
  assert.equal(timed.blocks[0].nodes[0].group.children.length, 2);
  assert.ok(timed.blocks[0].nodes[0].group.children.every((node) => node.type === "exercise"));

  const chosen = assemble(
    choice("Choose modality", "modality"), choice("Choose load", "load"),
    ["modality", "modality-bike", "load", "load-bike"],
  );
  assert.equal(chosen.blocks[0].nodes[0].choice.label, "Choose modality");
  assert.equal(chosen.blocks[0].nodes[0].choice.options[2].choice.label, "Choose load");
});

test("stable continuation path ignores label variation and accepts an unwrapped child", () => {
  const firstSectionID = "a".repeat(64);
  const secondSectionID = "b".repeat(64);
  const scopeID = "c".repeat(64);
  const fragmentID = "d".repeat(64);
  const base = {
    title: "Workout",
    notes: [],
    blocks: [{
      name: "MED",
      notes: [],
      nodes: [{ type: "group", group: {
        label: "70 minute AMRAP",
        adjustments: [],
        children: [],
        notes: [],
        isOptional: false,
        sourceObservationIDs: ["a"],
      } }],
      sourceObservationIDs: ["a"],
    }],
  };
  const continuation = {
    title: "Workout",
    notes: [],
    blocks: [{
      name: "MED",
      notes: [],
      nodes: [{ type: "group", group: {
        label: "AMRAP - seventy minutes",
        adjustments: [],
        children: [{ type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [], sourceObservationIDs: ["b"],
        } }],
        notes: [],
        isOptional: false,
        sourceObservationIDs: ["b"],
      } }],
      sourceObservationIDs: ["b"],
    }],
  };
  const metadata = (sectionID, document, continuationFromSectionID) => ({
    sectionID,
    startScopeID: scopeID,
    endScopeID: scopeID,
    startFragmentPath: [scopeID, fragmentID],
    endFragmentPath: [scopeID, fragmentID],
    ...(continuationFromSectionID ? { continuationFromSectionID } : {}),
    document,
  });
  const assembled = assembleWorkoutImportSectionDocuments([
    metadata(firstSectionID, base),
    metadata(secondSectionID, continuation, firstSectionID),
  ], new Set(["a", "b"]));
  assert.equal(assembled.blocks[0].nodes.length, 1);
  assert.equal(assembled.blocks[0].nodes[0].group.children[0].exercise.name, "Echo Bike");

  const unwrapped = structuredClone(continuation);
  unwrapped.blocks[0].nodes[0] = unwrapped.blocks[0].nodes[0].group.children[0];
  const assembledUnwrapped = assembleWorkoutImportSectionDocuments([
    metadata(firstSectionID, base),
    metadata(secondSectionID, unwrapped, firstSectionID),
  ], new Set(["a", "b"]));
  assert.equal(
    assembledUnwrapped.blocks[0].nodes[0].group.children[0].exercise.name,
    "Echo Bike",
  );
});

test("a note-only continuation section validates locally but the final workout still requires exercise content", () => {
  const noteOnly = validIR([
    record("notes", "block", "", 0, { name: "Coach Notes" }),
    record("note", "note", "notes", 0, { text: "Preserve this long coaching note." }),
  ]);
  assert.throws(() => assembleWorkoutImportIR(noteOnly, new Set(["a"])), WorkoutDocumentValidationError);
  const fragment = assembleWorkoutImportIR(noteOnly, new Set(["a"]), { allowEmptyExercises: true });
  assert.equal(fragment.blocks[0].nodes.length, 0);
  assert.throws(
    () => assembleWorkoutImportSectionDocuments([{
      sectionID: "a".repeat(64),
      startScopeID: "b".repeat(64),
      endScopeID: "b".repeat(64),
      document: fragment,
    }], new Set(["a"])),
    /cross_section_assembly/,
  );
});

test("note-only overflow drops ungrounded context inventions and preserves every OCR line", () => {
  const note = observation("overflow-note", "Overflow coaching detail");
  const header = observation("coach-header", "Coach's Note");
  const raw = validIR([
    record("invented-block", "block", "", 0, { name: "Invented" }, []),
    record("invented-group", "group", "invented-block", 0, { label: "Invented circuit" }, []),
    record("invented-exercise", "exercise", "invented-group", 0, { name: "Run" }, []),
    record("invented-rest", "rest", "invented-group", 1, { restSeconds: 90 }, []),
    record("overflow", "note", "", 1, { text: note.text }, [note.id]),
  ]);

  const document = assembleWorkoutImportIR(raw, new Set([note.id, header.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [note, header],
    continuationDepth: 1,
    fallbackScope: "continuation",
  });

  assert.equal(document.blocks.length, 1);
  assert.equal(document.blocks[0].nodes.length, 1);
  assert.equal(document.blocks[0].nodes[0].type, "group");
  assert.deepEqual(document.blocks[0].nodes[0].group.children, []);
  assert.deepEqual(document.blocks[0].nodes[0].group.notes, [note.text, header.text]);
  assert.deepEqual(
    new Set(document.blocks[0].nodes[0].group.sourceObservationIDs),
    new Set([note.id, header.id]),
  );
});

test("continuation fallback chunks many omitted OCR lines within note and provenance limits", () => {
  const observations = Array.from({ length: 40 }, (_, index) =>
    observation(`overflow-${index}`, `Coaching line ${index}`));
  const document = assembleWorkoutImportIR(
    validIR([]),
    new Set(observations.map((item) => item.id)),
    {
      allowEmptyExercises: true,
      fallbackObservations: observations,
      continuationDepth: 1,
      fallbackScope: "continuation",
    },
  );
  const group = document.blocks[0].nodes[0].group;

  assert.equal(group.notes.length, 1);
  assert.match(group.notes[0], /Coaching line 0/);
  assert.match(group.notes[0], /Coaching line 39/);
  assert.deepEqual(new Set(group.sourceObservationIDs), new Set(observations.map((item) => item.id)));
});

test("grounding keeps required ancestors but drops ungrounded siblings under a valid block", () => {
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }, []),
    record("run", "exercise", "block", 0, { name: "Run" }, ["a"]),
    record("invented-rest", "rest", "block", 1, { restSeconds: 90 }, []),
  ]);
  const document = assembleWorkoutImportIR(raw, new Set(["a"]), { allowEmptyExercises: true });

  assert.equal(document.blocks[0].nodes.length, 1);
  assert.equal(document.blocks[0].nodes[0].type, "exercise");
});

test("mixed-scope continuation preserves omissions in a separate review block", () => {
  const continuation = observation("continued-note", "Continue the prior circuit conservatively");
  const heading = observation("new-heading", "Coach's Note");
  const raw = validIR([
    record("continued", "note", "", 0, { text: continuation.text }, [continuation.id]),
  ]);
  const document = assembleWorkoutImportIR(raw, new Set([continuation.id, heading.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [continuation, heading],
    continuationDepth: 1,
    fallbackScope: "separateBlock",
  });

  assert.equal(document.blocks.length, 2);
  assert.equal(document.blocks[0].nodes[0].type, "group");
  assert.deepEqual(document.blocks[0].nodes[0].group.notes, [continuation.text]);
  assert.equal(document.blocks[1].name, heading.text);
  assert.deepEqual(document.blocks[1].notes, []);
  assert.deepEqual(document.blocks[1].sourceObservationIDs, [heading.id]);
});

test("container depth without a continuation cannot activate OCR fallback", () => {
  const line = observation("not-a-continuation", "Run 400 m");
  assertValidation(() => assembleWorkoutImportIR(validIR([]), new Set([line.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [line],
    continuationDepth: 1,
  }), "ir.provenance");
});

test("continuation fallback refuses to turn omitted programming into prose", () => {
  const note = observation("note", "Continue calmly");
  const exercise = observation("exercise", "12 Deadlifts at bodyweight");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [note.id]),
  ]), new Set([note.id, exercise.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [note, exercise],
    continuationDepth: 1,
    fallbackScope: "continuation",
  }), "ir.provenance");
});

test("provenance repair is modality agnostic for uncatalogued movements", () => {
  const heading = observation("heading", "Main");
  const movement = observation("movement", "Back Squats");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]), new Set([heading.id, movement.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, movement],
    fallbackScope: "workout",
  }), "ir.provenance");
});

test("catalog movements with prose-like prescriptions cannot silently become notes", () => {
  const heading = observation("heading", "Main");
  const movement = observation(
    "movement",
    "Perform a controlled set of back squats before the conditioning begins.",
  );
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]), new Set([heading.id, movement.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, movement],
    fallbackScope: "workout",
    catalogHints: ["Barbell Back Squat"],
  }), "ir.provenance");
});

test("provenance completeness ignores deterministic screen chrome", () => {
  const heading = observation("heading", "Main");
  const network = observation("network", "5G UW");
  const history = observation("history", "HISTORY");
  const publisher = observation("publisher", "THE BAYENS METHOD");
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]);
  raw.ignoredObservationIDs = [publisher.id];
  const document = assembleWorkoutImportIR(raw, new Set([heading.id, network.id, history.id, publisher.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, network, history, publisher],
    fallbackScope: "workout",
  });

  assert.equal(document.blocks.length, 1);
  assert.deepEqual(document.notes, []);
});

test("provider IR can consolidate repeated screenshot text without losing either source", () => {
  const first = observation("sled-first", "25 m Sled Push", 0);
  const second = observation("sled-second", "25 m Sled Push", 1);
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [first.id, second.id]),
    record("sled", "exercise", "block", 0, { name: "Sled Push" }, [first.id, second.id]),
  ]), new Set([first.id, second.id]), {
    fallbackObservations: [first, second],
    catalogHints: ["Sled Push"],
  });

  assert.equal(document.blocks[0].nodes.length, 1);
  assert.deepEqual(document.blocks[0].nodes[0].exercise.sourceObservationIDs, [
    first.id, second.id,
  ]);
});

test("varying status-bar clocks and percentages remain reviewable despite clustered layout", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.96, width: 0.12, height: 0.03 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const observations = [
    status("clock-0", "8:13 0", 0, 0.05),
    status("battery-0", "89%", 0, 0.84),
    heading,
    status("clock-1", "8:14 0", 1, 0.05),
    status("battery-1", "88%", 1, 0.84),
    run,
  ];
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  });

  const serialized = JSON.stringify(document);
  for (const id of ["clock-0", "battery-0", "clock-1", "battery-1"]) {
    assert.equal(serialized.includes(id), true, `${id} should remain in provenance`);
  }
  assert.equal(document.blocks[0].nodes[0].exercise.name, "Run");
});

test("repeated status anchors cannot delete narrow top-edge programming", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.96, width: 0.12, height: 0.03 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const reps = {
    ...observation("reps", "12 Reps", 0),
    boundingBox: { x: 0.35, y: 0.96, width: 0.12, height: 0.03 },
  };
  const observations = [
    status("clock-0", "8:13 0", 0, 0.05),
    status("battery-0", "89", 0, 0.84),
    reps,
    heading,
    status("clock-1", "8:14 0", 1, 0.05),
    status("battery-1", "88", 1, 0.84),
    run,
  ];

  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  }), "ir.provenance", "ir.records");
});

test("one apparent status cluster cannot activate layout-based deletion", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.96, width: 0.12, height: 0.03 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const observations = [
    status("clock-0", "8:13 0", 0, 0.05),
    status("battery-0", "89", 0, 0.84),
    heading,
    run,
  ];

  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  }), "ir.provenance", "ir.records");
});

test("two cropped timer and numeric-target layouts remain reviewable instead of becoming chrome", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.96, width: 0.12, height: 0.03 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const observations = [
    status("timer-0", "12:30", 0, 0.05),
    status("target-0", "90", 0, 0.84),
    heading,
    status("timer-1", "10:00", 1, 0.05),
    status("target-1", "80", 1, 0.84),
    run,
  ];
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  });
  const serialized = JSON.stringify(document);

  for (const id of ["timer-0", "target-0", "timer-1", "target-1"]) {
    assert.equal(serialized.includes(id), true, `${id} should remain in provenance`);
  }
});

test("two cropped timer and percentage-target layouts remain reviewable instead of becoming chrome", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.96, width: 0.12, height: 0.03 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const observations = [
    status("timer-0", "12:30", 0, 0.05),
    status("target-0", "90%", 0, 0.84),
    heading,
    status("timer-1", "10:00", 1, 0.05),
    status("target-1", "80%", 1, 0.84),
    run,
  ];
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  });
  const serialized = JSON.stringify(document);

  for (const id of ["timer-0", "target-0", "timer-1", "target-1"]) {
    assert.equal(serialized.includes(id), true, `${id} should remain in provenance`);
  }
});

test("decorated battery pills and slightly inset clipped fragments remain reviewable", () => {
  const status = (id, text, sourceImageIndex, x) => ({
    ...observation(id, text, sourceImageIndex),
    boundingBox: { x, y: 0.953, width: 0.12, height: 0.02 },
  });
  const heading = observation("heading", "Main", 0);
  const run = observation("run", "Run 400 m", 1);
  const clipped = {
    ...observation("clipped", "ui", 1),
    boundingBox: { x: 0.86, y: 0.052, width: 0.05, height: 0.02 },
  };
  const observations = [
    status("clock-0", "8:13 ◻", 0, 0.05),
    status("battery-0", "89)", 0, 0.84),
    heading,
    status("clock-1", "8:14 ◻", 1, 0.05),
    status("battery-1", "88)", 1, 0.84),
    run,
    clipped,
  ];
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set(observations.map((item) => item.id)), {
    fallbackObservations: observations,
    fallbackScope: "workout",
    catalogHints: ["Run"],
  });
  const serialized = JSON.stringify(document);

  for (const id of ["clock-0", "battery-0", "clock-1", "battery-1", "clipped"]) {
    assert.equal(serialized.includes(id), true, `${id} should remain in provenance`);
  }
});

test("an unknown clipped edge fragment is preserved for review instead of discarded", () => {
  const heading = observation("heading", "Main");
  const run = observation("run", "Run 400 m");
  const clipped = {
    ...observation("clipped", "Clipped"),
    boundingBox: { x: 0.05, y: 0.01, width: 0.12, height: 0.02 },
  };
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [run.id]),
  ]), new Set([heading.id, run.id, clipped.id]), {
    fallbackObservations: [heading, run, clipped],
    fallbackScope: "workout",
    catalogHints: ["Run"],
  });

  assert.equal(document.blocks[1].name, clipped.text);
  assert.deepEqual(document.blocks[1].sourceObservationIDs, [clipped.id]);
});

test("explicit metadata accounting cannot discard a legitimate workout heading", () => {
  const heading = observation("heading", "Main");
  const training = observation("training", "STRENGTH TRAINING");
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]);
  raw.ignoredObservationIDs = [training.id];
  assertValidation(() => assembleWorkoutImportIR(raw, new Set([heading.id, training.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, training],
    fallbackScope: "workout",
  }), "ir.provenance");
});

test("explicit metadata accounting fails closed for unknown all-caps headings", () => {
  const heading = observation("heading", "Main");
  const aerobic = observation("aerobic", "AEROBIC CAPACITY");
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]);
  raw.ignoredObservationIDs = [aerobic.id];
  assertValidation(() => assembleWorkoutImportIR(raw, new Set([heading.id, aerobic.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, aerobic],
    fallbackScope: "workout",
  }), "ir.provenance");
});

test("an ignored heading immediately before a sourced block is recovered deterministically", () => {
  const heading = observation("heading", "Performance Layer");
  const exercise = observation("exercise", "StairMaster - 70 minutes");
  const raw = validIR([
    record("block", "block", "", 0, { name: "StairMaster" }, [exercise.id]),
    record("stairs", "exercise", "block", 0, { name: "StairMaster" }, [exercise.id]),
  ]);
  raw.ignoredObservationIDs = [heading.id];
  const document = assembleWorkoutImportIR(raw, new Set([heading.id, exercise.id]), {
    fallbackObservations: [heading, exercise],
    fallbackScope: "workout",
    catalogHints: ["StairMaster"],
  });

  assert.equal(document.blocks[0].name, heading.text);
  assert.deepEqual(new Set(document.blocks[0].sourceObservationIDs), new Set([heading.id, exercise.id]));
});

test("ignored prescriptions and movements cannot be promoted to block headings", () => {
  for (const ignoredText of [
    "4 Rounds", "Four Rounds", "70 minutes", "AMRAP 20", "AMRAP Twenty", "EMOM 10",
    "Sets: 4", "Reps: 12", "StairMaster", "Recovery should remain easy",
    "Keep strength work controlled",
  ]) {
    const ignored = observation(`ignored-${ignoredText}`, ignoredText);
    const exercise = observation(`exercise-${ignoredText}`, "StairMaster - 70 minutes");
    const raw = validIR([
      record("block", "block", "", 0, { name: "StairMaster" }, [exercise.id]),
      record("stairs", "exercise", "block", 0, { name: "StairMaster" }, [exercise.id]),
    ]);
    raw.ignoredObservationIDs = [ignored.id];

    assertValidation(() => assembleWorkoutImportIR(
      raw,
      new Set([ignored.id, exercise.id]),
      {
        fallbackObservations: [ignored, exercise],
        fallbackScope: "workout",
        catalogHints: ["StairMaster"],
      },
    ), "ir.provenance", "ir.records");
  }
});

test("an unambiguous rest duration wrapper normalizes without another model call", () => {
  const line = observation("rest", "90 seconds rest between rounds");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("group", "group", "block", 0, { label: "Circuit" }, [line.id]),
    record("rest", "rest", "group", 0, { placement: "betweenRepetitions" }, [line.id]),
    record("set", "set", "rest", 0, {}, [line.id]),
    record("duration", "metric", "set", 0, { type: "duration", value: "90", unit: "s" }, [line.id]),
  ]), new Set([line.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [line],
  });

  const rest = document.blocks[0].nodes[0].group.children[0].rest;
  assert.equal(rest.label, "Rest");
  assert.equal(rest.durationSeconds, 90);
  assert.equal(rest.placement, "betweenRepetitions");
});

test("cited container labels and explicit rest placement normalize without repair", () => {
  const heading = observation("heading", "Main");
  const groupLine = observation("group-line", "Tempo Block");
  const betweenLine = observation("between-line", "90 seconds standing rest between intervals");
  const everyLine = observation("every-line", "Rest after every round");
  const finalLine = observation(
    "final-line",
    "Transition Rest\nAfter the final tempo interval: additional 90 seconds standing rest",
  );
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("group", "group", "block", 0, { repeatCount: "3" }, [groupLine.id]),
    record("between-rest", "rest", "group", 0, {
      label: "Standing rest", durationSeconds: "90",
    }, [betweenLine.id]),
    record("every-rest", "rest", "group", 1, {
      label: "Round rest", durationSeconds: "60",
    }, [everyLine.id]),
    record("final-rest", "rest", "group", 2, {
      label: "Transition rest", durationSeconds: "90",
    }, [finalLine.id]),
  ]), new Set([heading.id, groupLine.id, betweenLine.id, everyLine.id, finalLine.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, groupLine, betweenLine, everyLine, finalLine],
  });

  const group = document.blocks[0].nodes[0].group;
  assert.equal(group.label, groupLine.text);
  assert.equal(group.children[0].rest.placement, "betweenRepetitions");
  assert.equal(group.children[0].rest.durationSeconds, 90);
  assert.equal(group.children[1].rest.placement, "afterEveryRepetition");
  assert.equal(group.children[2].rest.placement, "afterFinalRepetition");
});

test("a missing ambiguous rest placement remains on the repair path", () => {
  for (const [index, text] of [
    "90 seconds standing rest",
    "Do not rest between rounds",
    "Rest after every two rounds",
    "Rest between rounds if needed",
    "Rest between rounds as needed",
    "Optional rest between rounds",
    "Recovery after every round when needed",
    "Rest between rounds as tolerated",
    "Athletes may rest between rounds",
    "Rest between rounds at the athlete's discretion",
    "Rest between rounds when possible",
    "Rest between rounds where needed",
    "Rest between rounds whenever necessary",
    "Rest between rounds on request",
  ].entries()) {
    const heading = observation(`heading-${index}`, "Main");
    const restLine = observation(`rest-line-${index}`, text);

    assertValidation(() => assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [heading.id]),
      record("rest", "rest", "block", 0, {
        label: "Standing rest", durationSeconds: "90",
      }, [restLine.id]),
    ]), new Set([heading.id, restLine.id]), {
      allowEmptyExercises: true,
      fallbackObservations: [heading, restLine],
    }), "ir.attribute", "ir.records[1].attributes");
  }
});

test("a prose-only adjustment record becomes a grounded group note", () => {
  const heading = observation("heading", "Main");
  const groupLine = observation("group-line", "EMOM x 14");
  const coaching = observation("coaching", "Scale the repetitions based on fitness.");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("group", "group", "block", 0, { label: "EMOM x 14" }, [groupLine.id]),
    record("coaching-note", "adjustment", "group", 0, {
      text: coaching.text,
    }, [coaching.id]),
  ]), new Set([heading.id, groupLine.id, coaching.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, groupLine, coaching],
  });

  assert.deepEqual(document.blocks[0].nodes[0].group.notes, [coaching.text]);
});

test("a non-text adjustment remains structured and fails when its step is missing", () => {
  const heading = observation("heading", "Main");
  const groupLine = observation("group-line", "AMRAP 20");
  const adjustment = observation("adjustment", "Adjust duration as needed");

  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
    record("group", "group", "block", 0, { label: "AMRAP 20" }, [groupLine.id]),
    record("adjustment", "adjustment", "group", 0, {
      metric: "duration",
    }, [adjustment.id]),
  ]), new Set([heading.id, groupLine.id, adjustment.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, groupLine, adjustment],
  }), "ir.attribute", "ir.records[2].attributes");
});

test("an immediately grounded orphan metric receives its unambiguous missing set", () => {
  const line = observation("run", "2:00-minute run at threshold effort");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [line.id]),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
  });

  const exercise = document.blocks[0].nodes[0].exercise;
  assert.deepEqual(exercise.sets, [{
    metrics: [{ type: "duration", value: 120, unit: "seconds" }],
    alternatives: [],
  }]);
});

test("an immediately grounded metric parented directly to its exercise receives a set wrapper", () => {
  const line = observation("run-direct", "2:00-minute run at threshold effort");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [line.id]),
    record("duration", "metric", "run", 0, {
      type: "duration", value: "120", unit: "seconds",
    }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
  });

  assert.deepEqual(document.blocks[0].nodes[0].exercise.sets, [{
    metrics: [{ type: "duration", value: 120, unit: "seconds" }],
    alternatives: [],
  }]);
});

test("catalog aliases reconcile a related but unsupported exercise identity", () => {
  const line = observation("bike", "C2 Bike/ECHO Bike");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, {
      label: "C2 Bike or Echo Bike", selectionCount: "1",
    }, [line.id]),
    record("wrong-bike", "exercise", "choice", 0, { name: "Stationary Bike" }, [line.id]),
    record("echo", "exercise", "choice", 1, { name: "Echo Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.deepEqual(document.blocks[0].nodes[0].choice.options.map((node) => node.exercise.name), [
    "BikeErg", "Echo Bike",
  ]);
});

test("catalog reconciliation preserves a source-supported stationary bike", () => {
  const line = observation("bike", "20 minutes Stationary Bike");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("bike", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "Stationary Bike");
});

test("catalog reconciliation does not treat a negated catalog mention as an exercise identity", () => {
  const line = observation("custom", "Avoid Echo Bike if unavailable");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("custom", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "Avoid Echo Bike if unavailable");
});

test("catalog reconciliation rejects positional exclusions but preserves postfix guidance", () => {
  const catalogHints = [
    "Stationary Bike | aliases: spin bike; indoor bike",
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  const importedName = (text) => {
    const line = observation("bike", text);
    return assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("bike", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
    ]), new Set([line.id]), { fallbackObservations: [line], catalogHints })
      .blocks[0].nodes[0].exercise.name;
  };

  for (const text of [
    "Without Echo Bike",
    "Instead of Echo Bike",
    "Rather than Echo Bike",
    "Do not use Echo Bike",
    "No Echo Bike",
  ]) {
    assert.equal(importedName(text), text);
  }
  assert.equal(importedName("Use BikeErg instead of Echo Bike"), "BikeErg");
  assert.equal(importedName("Echo Bike without arms"), "Echo Bike");
});

test("catalog reconciliation prefers a complete specific identity over a contained generic alias", () => {
  const line = observation("bench", "12 Dumbbell Bench Press");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("bench", "exercise", "block", 0, { name: "Barbell Bench Press" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Barbell Bench Press | aliases: bench press; barbell bench",
      "Dumbbell Bench Press | aliases: dumbbell bench press; db bench press",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "Dumbbell Bench Press");
});

test("catalog reconciliation leaves an unknown custom movement unchanged", () => {
  const line = observation("custom", "20 Sandbag Bear Hug Marches");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("custom", "exercise", "block", 0, { name: "Sandbag Bear Hug March" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "Sandbag Bear Hug March");
});

test("catalog reconciliation never resolves a longer custom name by substring", () => {
  const line = observation("custom", "20 minutes Echo Bike Simulator");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("custom", "exercise", "block", 0, { name: "Echo Bike Simulator" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: ["Echo Bike | aliases: echo bike; assault bike"],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "Echo Bike Simulator");
});

test("catalog reconciliation cannot replace a custom movement cited by a wrong known identity", () => {
  const line = observation("custom", "20 minutes Echo Bike Simulator");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("custom", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "20 minutes Echo Bike Simulator");
});

test("catalog reconciliation preserves an unaccounted explicit source alternative", () => {
  const line = observation("bike", "C2 Bike/ECHO Bike");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("bike", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "BikeErg / Echo Bike");
});

test("catalog reconciliation preserves two source alternatives instead of an unsupported identity", () => {
  const line = observation("bike", "C2 Bike/ECHO Bike");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("bike", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.equal(document.blocks[0].nodes[0].exercise.name, "BikeErg / Echo Bike");
});

test("catalog reconciliation keeps non-alternative multi-identity sources on the repair path", () => {
  const catalogHints = [
    "Stationary Bike | aliases: spin bike; indoor bike",
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  for (const separator of ["+", "&", "and", "then", "followed by", ",", "\n"]) {
    const line = observation("bike", `10 cal Echo Bike ${separator} 500 m C2 Bike`);
    assertValidation(() => assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("bike", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    ]), new Set([line.id]), {
      fallbackObservations: [line],
      catalogHints,
    }), "assembly.relationship");
  }
});

test("raw reconciliation rejects laundering a standalone custom movement through another exercise", () => {
  const echo = observation("echo", "10 cal Echo Bike");
  for (const [id, text] of [
    ["numbered-burpee", "12 Burpees"],
    ["unnumbered-march", "Zercher Sandbag March"],
    ["unnumbered-burpee", "Burpees"],
    ["unnumbered-plank", "Max plank hold."],
    ["stairmaster-guidance", "StairMaster - 70 minutes - ideally with a weight vest or ruck."],
  ]) {
    const movement = observation(id, text);
    assertValidation(() => assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [echo.id, movement.id]),
      record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [echo.id, movement.id]),
    ]), new Set([echo.id, movement.id]), {
      fallbackObservations: [echo, movement],
      catalogHints: ["Echo Bike | aliases: echo bike; assault bike"],
    }), "assembly.relationship");
  }
});

test("raw reconciliation requires repeat groups and structured timed work prescriptions", () => {
  const repeat = observation("intervals", "6 Sets - Aerobic Intervals");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [repeat.id]),
    record("intervals", "group", "block", 0, { label: "Aerobic Intervals" }, [repeat.id]),
  ]), new Set([repeat.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [repeat],
  }), "assembly.relationship");

  const work = observation("work", "50 seconds work at 6-8 RPE");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [work.id]),
    record("work", "exercise", "block", 0, { name: "Echo Bike" }, [work.id]),
    record("set", "set", "work", 0, {}, [work.id]),
    record("duration", "metric", "set", 0, {
      type: "duration", value: "50", unit: "seconds",
    }, [work.id]),
  ]), new Set([work.id]), {
    fallbackObservations: [work],
  }), "assembly.relationship");

  const adjacentContextID = "context";
  const groundedThroughExercise = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [work.id]),
    record("work", "exercise", "block", 0, { name: "Echo Bike" }, [work.id]),
    record("set", "set", "work", 0, {}, [adjacentContextID]),
    record("duration", "metric", "set", 0, {
      type: "duration", value: "50", unit: "seconds",
    }, [adjacentContextID]),
    record("rpe", "metric", "set", 1, {
      type: "rpe", value: "6", upperValue: "8",
    }, [adjacentContextID]),
  ]), new Set([work.id, adjacentContextID]), {
    fallbackObservations: [work],
  });
  assert.deepEqual(groundedThroughExercise.blocks[0].nodes[0].exercise.sets[0].metrics, [
    { type: "duration", value: 50, unit: "seconds" },
    { type: "rpe", value: 6, upperValue: 8 },
  ]);
  assert.deepEqual(groundedThroughExercise.blocks[0].nodes[0].exercise.intensityTargets, []);

  const intensityRepresentation = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [work.id]),
    record("work", "exercise", "block", 0, { name: "Echo Bike" }, [work.id]),
    record("set", "set", "work", 0, {}, [work.id]),
    record("duration", "metric", "set", 0, {
      type: "duration", value: "50", unit: "seconds",
    }, [work.id]),
    record("rpe", "intensity", "work", 1, {
      type: "rpe", lower: "6", upper: "8",
    }, [work.id]),
  ]), new Set([work.id]), {
    fallbackObservations: [work],
  });
  assert.deepEqual(intensityRepresentation.blocks[0].nodes[0].exercise.intensityTargets, [
    { type: "rpe", lower: 6, upper: 8 },
  ]);

  const splitSetRecords = [
    record("block", "block", "", 0, { name: "Main" }, [work.id]),
    record("work", "exercise", "block", 0, { name: "Echo Bike" }, [work.id]),
    record("duration-set", "set", "work", 0, {}, [work.id]),
    record("duration", "metric", "duration-set", 0, {
      type: "duration", value: "50", unit: "seconds",
    }, [work.id]),
    record("rpe-set", "set", "work", 1, {}, [work.id]),
    record("rpe", "metric", "rpe-set", 0, {
      type: "rpe", value: "6", upperValue: "8",
    }, [work.id]),
  ];
  assertValidation(() => assembleWorkoutImportIR(
    validIR(splitSetRecords),
    new Set([work.id]),
    { fallbackObservations: [work] },
  ), "assembly.relationship");

  const duplicateRPERecords = [
    ...splitSetRecords.slice(0, 4),
    record("rpe", "metric", "duration-set", 1, {
      type: "rpe", value: "6", upperValue: "8",
    }, [work.id]),
    record("rpe-intensity", "intensity", "work", 2, {
      type: "rpe", lower: "6", upper: "8",
    }, [work.id]),
  ];
  assertValidation(() => assembleWorkoutImportIR(
    validIR(duplicateRPERecords),
    new Set([work.id]),
    { fallbackObservations: [work] },
  ), "assembly.relationship");
});

test("catalog reconciliation scopes alternative grammar to identity-bearing clauses", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  for (const text of [
    "Choose a challenging load, then 10 cal Echo Bike and 500 m C2 Bike",
    "10 cal Echo Bike + 500 m C2 Bike / 3 rounds",
    "10 cal Echo Bike and 500 m C2 Bike for time or until cutoff",
    "10 cal Echo Bike w/ arms and 500 m C2 Bike",
  ]) {
    const line = observation("bike", text);
    assertValidation(() => assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("bike", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    ]), new Set([line.id]), {
      fallbackObservations: [line],
      catalogHints,
    }), "assembly.relationship");
  }
});

test("catalog reconciliation accepts separate required siblings for a conjunction", () => {
  const line = observation("bike", "10 cal Echo Bike + 500 m C2 Bike");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "block", 1, { name: "BikeErg" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  });

  assert.deepEqual(document.blocks[0].nodes.map((node) => node.exercise.name), [
    "Echo Bike", "BikeErg",
  ]);

  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "block", 1, { name: "BikeErg" }, [line.id]),
    record("run", "exercise", "block", 2, { name: "Run" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
      "Run | aliases: running",
    ],
  }), "assembly.relationship");
});

test("catalog reconciliation preserves required uncatalogued movement clauses", () => {
  const line = observation("custom-pair", "10 cal Echo Bike + 20 Zercher Sandbag Marches");
  const catalogHints = ["Echo Bike | aliases: echo bike; assault bike"];
  const validRecords = [
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    record("march", "exercise", "block", 1, { name: "Zercher Sandbag March" }, [line.id]),
  ];
  const document = assembleWorkoutImportIR(validIR(validRecords), new Set([line.id]), {
    fallbackObservations: [line], catalogHints,
  });
  assert.deepEqual(document.blocks[0].nodes.map((node) => node.exercise.name), [
    "Echo Bike", "Zercher Sandbag March",
  ]);

  assertValidation(() => assembleWorkoutImportIR(validIR(validRecords.slice(0, 2)),
    new Set([line.id]), { fallbackObservations: [line], catalogHints }), "assembly.relationship");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    ...validRecords.slice(0, 2),
    record("wrong", "exercise", "block", 1, { name: "Run" }, [line.id]),
  ]), new Set([line.id]), { fallbackObservations: [line], catalogHints }), "assembly.relationship");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    ...validRecords.slice(0, 2),
    record("shortened", "exercise", "block", 1, { name: "Sandbag March" }, [line.id]),
  ]), new Set([line.id]), { fallbackObservations: [line], catalogHints }), "assembly.relationship");

  const unnumbered = observation("custom-unnumbered", "10 cal Echo Bike + Zercher Sandbag Marches");
  const unnumberedRecords = [
    record("block", "block", "", 0, { name: "Main" }, [unnumbered.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [unnumbered.id]),
    record("march", "exercise", "block", 1, { name: "Zercher Sandbag March" }, [unnumbered.id]),
  ];
  const unnumberedDocument = assembleWorkoutImportIR(validIR(unnumberedRecords),
    new Set([unnumbered.id]), { fallbackObservations: [unnumbered], catalogHints });
  assert.equal(unnumberedDocument.blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR(unnumberedRecords.slice(0, 2)),
    new Set([unnumbered.id]), { fallbackObservations: [unnumbered], catalogHints }),
  "assembly.relationship");

  const oneWord = observation("custom-one-word", "10 cal Echo Bike + Burpees");
  const oneWordRecords = [
    record("block", "block", "", 0, { name: "Main" }, [oneWord.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [oneWord.id]),
    record("burpees", "exercise", "block", 1, { name: "Burpee" }, [oneWord.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(oneWordRecords), new Set([oneWord.id]), {
    fallbackObservations: [oneWord], catalogHints,
  }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR(oneWordRecords.slice(0, 2)),
    new Set([oneWord.id]), { fallbackObservations: [oneWord], catalogHints }),
  "assembly.relationship");

  const contextualWord = observation("custom-sprint", "10 cal Echo Bike + 100 m Sprint");
  const contextualRecords = [
    record("block", "block", "", 0, { name: "Main" }, [contextualWord.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [contextualWord.id]),
    record("sprint", "exercise", "block", 1, { name: "Sprint" }, [contextualWord.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(contextualRecords), new Set([contextualWord.id]), {
    fallbackObservations: [contextualWord], catalogHints,
  }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR(contextualRecords.slice(0, 2)),
    new Set([contextualWord.id]), { fallbackObservations: [contextualWord], catalogHints }),
  "assembly.relationship");

  const qualified = observation("custom-qualified", "10 cal Echo Bike + 12 Y Raises");
  const qualifiedRecords = [
    record("block", "block", "", 0, { name: "Main" }, [qualified.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [qualified.id]),
    record("raise", "exercise", "block", 1, { name: "Y Raise" }, [qualified.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(qualifiedRecords), new Set([qualified.id]), {
    fallbackObservations: [qualified], catalogHints,
  }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR([
    ...qualifiedRecords.slice(0, 2),
    record("generic-raise", "exercise", "block", 1, { name: "Raise" }, [qualified.id]),
  ]), new Set([qualified.id]), { fallbackObservations: [qualified], catalogHints }),
  "assembly.relationship");

  const letterQualified = observation(
    "custom-letter-qualified",
    "10 cal Echo Bike + 30 second L-Sit",
  );
  const letterQualifiedRecords = [
    record("block", "block", "", 0, { name: "Main" }, [letterQualified.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [letterQualified.id]),
    record("l-sit", "exercise", "block", 1, { name: "L-Sit" }, [letterQualified.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(letterQualifiedRecords),
    new Set([letterQualified.id]), {
      fallbackObservations: [letterQualified], catalogHints,
    }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR([
    ...letterQualifiedRecords.slice(0, 2),
    record("generic-sit", "exercise", "block", 1, { name: "Sit" }, [letterQualified.id]),
  ]), new Set([letterQualified.id]), {
    fallbackObservations: [letterQualified], catalogHints,
  }), "assembly.relationship");

  const stationLetter = observation("custom-a-skip", "10 cal Echo Bike + 20 m A-Skip");
  const stationLetterRecords = [
    record("block", "block", "", 0, { name: "Main" }, [stationLetter.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [stationLetter.id]),
    record("a-skip", "exercise", "block", 1, { name: "A-Skip" }, [stationLetter.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(stationLetterRecords),
    new Set([stationLetter.id]), {
      fallbackObservations: [stationLetter], catalogHints,
    }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR([
    ...stationLetterRecords.slice(0, 2),
    record("generic-skip", "exercise", "block", 1, { name: "Skip" }, [stationLetter.id]),
  ]), new Set([stationLetter.id]), {
    fallbackObservations: [stationLetter], catalogHints,
  }), "assembly.relationship");
  for (const [index, [text, name]] of [
    ["10 cal Echo Bike + 20 m A Skips", "A Skip"],
    ["10 cal Echo Bike + 20 m A–Skips", "A–Skip"],
  ].entries()) {
    const variant = observation(`custom-a-skip-${index}`, text);
    const base = [
      record("block", "block", "", 0, { name: "Main" }, [variant.id]),
      record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [variant.id]),
    ];
    assert.equal(assembleWorkoutImportIR(validIR([
      ...base, record("a-skip", "exercise", "block", 1, { name }, [variant.id]),
    ]), new Set([variant.id]), { fallbackObservations: [variant], catalogHints })
      .blocks[0].nodes.length, 2);
    assertValidation(() => assembleWorkoutImportIR(validIR([
      ...base, record("skip", "exercise", "block", 1, { name: "Skip" }, [variant.id]),
    ]), new Set([variant.id]), { fallbackObservations: [variant], catalogHints }),
    "assembly.relationship");
  }

  const allCustom = observation("all-custom", "Bear Crawl + Zercher Sandbag Marches");
  const allCustomRecords = [
    record("block", "block", "", 0, { name: "Main" }, [allCustom.id]),
    record("crawl", "exercise", "block", 0, { name: "Bear Crawl" }, [allCustom.id]),
    record("march", "exercise", "block", 1, { name: "Zercher Sandbag March" }, [allCustom.id]),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(allCustomRecords), new Set([allCustom.id]), {
    fallbackObservations: [allCustom],
  }).blocks[0].nodes.length, 2);
  assertValidation(() => assembleWorkoutImportIR(validIR(allCustomRecords.slice(0, 2)),
    new Set([allCustom.id]), { fallbackObservations: [allCustom] }), "assembly.relationship");

  const sharedBase = observation(
    "shared-base",
    "20 Burpee Box Jump Overs + 10 Burpee Broad Jumps",
  );
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [sharedBase.id]),
    record("jump-1", "exercise", "block", 0, { name: "Burpee Jump" }, [sharedBase.id]),
    record("jump-2", "exercise", "block", 1, { name: "Burpee Jump" }, [sharedBase.id]),
  ]), new Set([sharedBase.id]), { fallbackObservations: [sharedBase] }), "assembly.relationship");
});

test("catalog reconciliation joins identities only for explicit alternative grammar", () => {
  const catalogHints = [
    "Stationary Bike | aliases: spin bike; indoor bike",
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  for (const text of [
    "C2 Bike/Echo Bike",
    "C2 Bike or Echo Bike",
    "10 cal Echo Bike or 500m C2 Bike",
    "Choose C2 Bike, Echo Bike",
    "Choose between C2 Bike and Echo Bike",
    "Either C2 Bike or Echo Bike",
  ]) {
    const line = observation("bike", text);
    const document = assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("bike", "exercise", "block", 0, { name: "Stationary Bike" }, [line.id]),
    ]), new Set([line.id]), { fallbackObservations: [line], catalogHints });
    assert.equal(document.blocks[0].nodes[0].exercise.name, "BikeErg / Echo Bike", text);
  }
});

test("catalog reconciliation requires a single selection for a pure alternative", () => {
  const line = observation("bike", "10 cal Echo Bike or 500 m C2 Bike");
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
    "Run | aliases: running",
  ];
  const validate = (records) => assembleWorkoutImportIR(validIR(records), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints,
  });
  const choiceRecords = (selectionCount, names) => [
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount }, [line.id]),
    ...names.map((name, index) =>
      record(`option-${index}`, "exercise", "choice", index, { name }, [line.id])),
  ];

  assertValidation(() => validate(choiceRecords("2", ["Echo Bike", "BikeErg"])),
    "assembly.relationship", "ir.records[2].parentID");
  assertValidation(() => validate(choiceRecords("1", ["Echo Bike", "Echo Bike"])),
    "assembly.relationship", "ir.records[2].parentID");
  assertValidation(() => validate(choiceRecords("1", ["Echo Bike"])),
    "assembly.relationship", "ir.records[2].parentID");
  assertValidation(() => validate(choiceRecords("1", ["Echo Bike", "BikeErg", "Run"])),
    "assembly.relationship", "ir.records[2].parentID");
  assertValidation(() => validate(choiceRecords("1", ["Stationary Bike", "Run"])),
    "assembly.relationship", "ir.records[2].parentID");
  assertValidation(() => validate([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "block", 1, { name: "BikeErg" }, [line.id]),
  ]), "assembly.relationship");
  assertValidation(() => validate([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("cardio", "exercise", "block", 0, { name: "Cardio" }, [line.id]),
  ]), "assembly.relationship");
  assertValidation(() => validate([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "2" }, [line.id]),
    record("echo-group", "group", "choice", 0, { label: "Echo" }, [line.id]),
    record("echo", "exercise", "echo-group", 0, { name: "Echo Bike" }, [line.id]),
    record("erg-group", "group", "choice", 1, { label: "Erg" }, [line.id]),
    record("erg", "exercise", "erg-group", 0, { name: "BikeErg" }, [line.id]),
  ]), "assembly.relationship");
});

test("catalog reconciliation preserves chained explicit alternatives", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
  ];
  for (const text of [
    "C2 Bike or Echo Bike or Stationary Bike",
    "C2 Bike/Echo Bike/Stationary Bike",
  ]) {
    const line = observation("bike", text);
    const document = assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("bike", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    ]), new Set([line.id]), { fallbackObservations: [line], catalogHints });
    assert.equal(
      document.blocks[0].nodes[0].exercise.name,
      "BikeErg / Echo Bike / Stationary Bike",
      text,
    );
  }
});

test("catalog reconciliation repairs only the missing option in a three-way choice", () => {
  const line = observation("bike", "Echo Bike or C2 Bike or Stationary Bike");
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
    "Recumbent Bike | aliases: recumbent cycle",
  ];
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
    record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
    record("recumbent", "exercise", "choice", 2, { name: "Recumbent Bike" }, [line.id]),
  ]), new Set([line.id]), { fallbackObservations: [line], catalogHints });

  assert.deepEqual(document.blocks[0].nodes[0].choice.options.map(
    (node) => node.exercise.name,
  ), ["Echo Bike", "BikeErg", "Stationary Bike"]);
});

test("catalog reconciliation preserves a mixed choice plus required sibling structure", () => {
  const line = observation("mixed", "10 cal Echo Bike or 500 m C2 Bike, then 400 m Run");
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Run | aliases: running",
  ];
  const flatRecords = [
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("echo", "exercise", "block", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "block", 1, { name: "BikeErg" }, [line.id]),
    record("run", "exercise", "block", 2, { name: "Run" }, [line.id]),
  ];
  assertValidation(() => assembleWorkoutImportIR(validIR(flatRecords), new Set([line.id]), {
    fallbackObservations: [line], catalogHints,
  }), "assembly.relationship");

  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "2" }, [line.id]),
    record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
    record("run", "exercise", "block", 1, { name: "Run" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line], catalogHints,
  }), "assembly.relationship");

  for (const invalidRecords of [
    [
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
      record("echo-1", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
      record("echo-2", "exercise", "choice", 1, { name: "Echo Bike" }, [line.id]),
      record("erg", "exercise", "choice", 2, { name: "BikeErg" }, [line.id]),
      record("run", "exercise", "block", 1, { name: "Run" }, [line.id]),
    ],
    [
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
      record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
      record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
      record("run-1", "exercise", "block", 1, { name: "Run" }, [line.id]),
      record("run-2", "exercise", "block", 2, { name: "Run" }, [line.id]),
    ],
  ]) {
    assertValidation(() => assembleWorkoutImportIR(validIR(invalidRecords), new Set([line.id]), {
      fallbackObservations: [line], catalogHints,
    }), "assembly.relationship");
  }

  const structured = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
    record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
    record("run", "exercise", "block", 1, { name: "Run" }, [line.id]),
  ]), new Set([line.id]), { fallbackObservations: [line], catalogHints });

  assert.equal(structured.blocks[0].nodes[0].type, "choice");
  assert.equal(structured.blocks[0].nodes[1].exercise.name, "Run");
});

test("catalog reconciliation scopes choose-between before a required transition", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
    "Run | aliases: running",
  ];
  for (const [index, text] of [
    "Choose between Echo Bike and C2 Bike, then 400 m Run",
    "Choose between Echo Bike and C2 Bike, 400 m Run",
  ].entries()) {
    const line = observation(`mixed-${index}`, text);
    const structured = assembleWorkoutImportIR(validIR([
      record("block", "block", "", 0, { name: "Main" }, [line.id]),
      record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
      record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
      record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
      record("run", "exercise", "block", 1, { name: "Run" }, [line.id]),
    ]), new Set([line.id]), { fallbackObservations: [line], catalogHints });

    assert.equal(structured.blocks[0].nodes[0].type, "choice", text);
    assert.equal(structured.blocks[0].nodes[1].exercise.name, "Run", text);
  }
});

test("catalog reconciliation rejects choice options for a required conjunction", () => {
  const line = observation("bike", "10 cal Echo Bike + 500 m C2 Bike");
  assertValidation(() => assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("choice", "choice", "block", 0, { label: "Bike", selectionCount: "1" }, [line.id]),
    record("echo", "exercise", "choice", 0, { name: "Echo Bike" }, [line.id]),
    record("erg", "exercise", "choice", 1, { name: "BikeErg" }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
    catalogHints: [
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  }), "assembly.relationship", "ir.records[2].parentID");
});

test("final catalog reconciliation preserves an unaccounted explicit source alternative", () => {
  const ambiguous = observation("ambiguous", "C2 Bike/ECHO Bike", 2);
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [ambiguous.id],
      nodes: [{ type: "exercise", exercise: {
        name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
        sourceObservationIDs: [ambiguous.id],
      } }],
    }],
  };

  const reconciled = reconcileParsedWorkoutCatalogIdentities(document, [ambiguous], [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ]);

  assert.equal(reconciled.blocks[0].nodes[0].exercise.name, "BikeErg / Echo Bike");
});

test("final catalog reconciliation preserves bounded choose and chained alternatives", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
  ];
  for (const [text, expected] of [
    ["10 cal Echo Bike or 500m C2 Bike", "BikeErg / Echo Bike"],
    ["Choose between C2 Bike and Echo Bike", "BikeErg / Echo Bike"],
    ["C2 Bike or Echo Bike or Stationary Bike", "BikeErg / Echo Bike / Stationary Bike"],
    ["C2 Bike/Echo Bike/Stationary Bike", "BikeErg / Echo Bike / Stationary Bike"],
  ]) {
    const line = observation("bike", text, 2);
    const document = {
      title: "Imported workout",
      notes: [],
      blocks: [{
        name: "Main", notes: [], sourceObservationIDs: [line.id],
        nodes: [{ type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [line.id],
        } }],
      }],
    };
    const reconciled = reconcileParsedWorkoutCatalogIdentities(document, [line], catalogHints);
    assert.equal(reconciled.blocks[0].nodes[0].exercise.name, expected, text);
  }
});

test("final catalog reconciliation repairs only the missing option in a three-way choice", () => {
  const line = observation("bike", "Echo Bike or C2 Bike or Stationary Bike", 2);
  const exercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [line.id],
  } });
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [line.id],
      nodes: [{ type: "choice", choice: {
        label: "Bike", selectionCount: 1,
        options: [exercise("Echo Bike"), exercise("BikeErg"), exercise("Recumbent Bike")],
        sourceObservationIDs: [line.id],
      } }],
    }],
  };
  const reconciled = reconcileParsedWorkoutCatalogIdentities(document, [line], [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Stationary Bike | aliases: spin bike; indoor bike",
    "Recumbent Bike | aliases: recumbent cycle",
  ]);

  assert.deepEqual(reconciled.blocks[0].nodes[0].choice.options.map(
    (node) => node.exercise.name,
  ), ["Echo Bike", "BikeErg", "Stationary Bike"]);
});

test("final catalog reconciliation requires a single selection for a pure alternative", () => {
  const line = observation("bike", "10 cal Echo Bike or 500 m C2 Bike", 2);
  const exercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [line.id],
  } });
  const document = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [line.id],
      nodes,
    }],
  });
  const choice = (selectionCount, names) => ({ type: "choice", choice: {
    label: "Bike", selectionCount,
    options: names.map(exercise),
    sourceObservationIDs: [line.id],
  } });
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Run | aliases: running",
  ];
  for (const node of [
    choice(2, ["Echo Bike", "BikeErg"]),
    choice(1, ["Echo Bike", "Echo Bike"]),
    choice(1, ["Echo Bike"]),
    choice(1, ["Echo Bike", "BikeErg", "Run"]),
    choice(1, ["Stationary Bike", "Run"]),
  ]) {
    assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([node]), [line], catalogHints),
      "assembly.relationship", "document.blocks");
  }
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Echo Bike"), exercise("BikeErg"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Cardio"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");
  const wrapped = (label, child) => ({ type: "group", group: {
    label, children: [child], adjustments: [], notes: [], isOptional: false,
    sourceObservationIDs: [line.id],
  } });
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    { type: "choice", choice: {
      label: "Bike", selectionCount: 2,
      options: [wrapped("Echo", exercise("Echo Bike")), wrapped("Erg", exercise("BikeErg"))],
      sourceObservationIDs: [line.id],
    } },
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");
});

test("final catalog reconciliation preserves a mixed choice plus required sibling structure", () => {
  const line = observation("mixed", "10 cal Echo Bike or 500 m C2 Bike, then 400 m Run", 2);
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Run | aliases: running",
  ];
  const exercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [line.id],
  } });
  const base = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [line.id], nodes }],
  });
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(base([
    exercise("Echo Bike"), exercise("BikeErg"), exercise("Run"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");

  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(base([
    { type: "choice", choice: {
      label: "Bike", selectionCount: 2,
      options: [exercise("Echo Bike"), exercise("BikeErg")],
      sourceObservationIDs: [line.id],
    } },
    exercise("Run"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");

  for (const nodes of [
    [
      { type: "choice", choice: {
        label: "Bike", selectionCount: 1,
        options: [exercise("Echo Bike"), exercise("Echo Bike"), exercise("BikeErg")],
        sourceObservationIDs: [line.id],
      } },
      exercise("Run"),
    ],
    [
      { type: "choice", choice: {
        label: "Bike", selectionCount: 1,
        options: [exercise("Echo Bike"), exercise("BikeErg")],
        sourceObservationIDs: [line.id],
      } },
      exercise("Run"),
      exercise("Run"),
    ],
  ]) {
    assertValidation(() => reconcileParsedWorkoutCatalogIdentities(base(nodes), [line], catalogHints),
      "assembly.relationship", "document.blocks");
  }

  const structured = reconcileParsedWorkoutCatalogIdentities(base([
    { type: "choice", choice: {
      label: "Bike", selectionCount: 1,
      options: [exercise("Echo Bike"), exercise("BikeErg")],
      sourceObservationIDs: [line.id],
    } },
    exercise("Run"),
  ]), [line], catalogHints);
  assert.equal(structured.blocks[0].nodes[0].type, "choice");
  assert.equal(structured.blocks[0].nodes[1].exercise.name, "Run");

  const chooseLine = observation(
    "choose-mixed",
    "Choose between Echo Bike and C2 Bike, then 400 m Run",
    2,
  );
  const chooseExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [chooseLine.id],
  } });
  const chooseDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [chooseLine.id],
      nodes: [{ type: "choice", choice: {
        label: "Bike", selectionCount: 1,
        options: [chooseExercise("Echo Bike"), chooseExercise("BikeErg")],
        sourceObservationIDs: [chooseLine.id],
      } }, chooseExercise("Run")],
    }],
  };
  const chooseStructured = reconcileParsedWorkoutCatalogIdentities(
    chooseDocument, [chooseLine], catalogHints,
  );
  assert.equal(chooseStructured.blocks[0].nodes[0].type, "choice");
  assert.equal(chooseStructured.blocks[0].nodes[1].exercise.name, "Run");

  const commaLine = observation(
    "choose-comma-mixed",
    "Choose between Echo Bike and C2 Bike, 400 m Run",
    2,
  );
  const commaExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [commaLine.id],
  } });
  const commaDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [commaLine.id],
      nodes: [{ type: "choice", choice: {
        label: "Bike", selectionCount: 1,
        options: [commaExercise("Echo Bike"), commaExercise("BikeErg")],
        sourceObservationIDs: [commaLine.id],
      } }, commaExercise("Run")],
    }],
  };
  const commaStructured = reconcileParsedWorkoutCatalogIdentities(
    commaDocument, [commaLine], catalogHints,
  );
  assert.equal(commaStructured.blocks[0].nodes[0].type, "choice");
  assert.equal(commaStructured.blocks[0].nodes[1].exercise.name, "Run");
});

test("final catalog reconciliation rejects unaccounted required identities", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
    "Run | aliases: running",
  ];
  for (const separator of ["+", "&", "and", "then", "followed by", ",", "\n"]) {
    const line = observation("bike", `10 cal Echo Bike ${separator} 500 m C2 Bike`, 2);
    const document = {
      title: "Imported workout",
      notes: [],
      blocks: [{
        name: "Main",
        notes: [],
        sourceObservationIDs: [line.id],
        nodes: [{ type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [line.id],
        } }],
      }],
    };

    assertValidation(
      () => reconcileParsedWorkoutCatalogIdentities(document, [line], catalogHints),
      "assembly.relationship",
      "document.blocks",
    );
  }

  const extraLine = observation("bike-extra", "10 cal Echo Bike + 500 m C2 Bike", 2);
  const extraExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [extraLine.id],
  } });
  const extraDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [extraLine.id],
      nodes: [extraExercise("Echo Bike"), extraExercise("BikeErg"), extraExercise("Run")],
    }],
  };
  assertValidation(
    () => reconcileParsedWorkoutCatalogIdentities(extraDocument, [extraLine], catalogHints),
    "assembly.relationship",
    "document.blocks",
  );
});

test("final catalog reconciliation preserves required uncatalogued movement clauses", () => {
  const line = observation("custom-pair", "10 cal Echo Bike + 20 Zercher Sandbag Marches", 2);
  const exercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [line.id],
  } });
  const document = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [line.id], nodes }],
  });
  const catalogHints = ["Echo Bike | aliases: echo bike; assault bike"];
  const reconciled = reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Echo Bike"), exercise("Zercher Sandbag March"),
  ]), [line], catalogHints);
  assert.deepEqual(reconciled.blocks[0].nodes.map((node) => node.exercise.name), [
    "Echo Bike", "Zercher Sandbag March",
  ]);

  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Echo Bike"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Echo Bike"), exercise("Run"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
    exercise("Echo Bike"), exercise("Sandbag March"),
  ]), [line], catalogHints), "assembly.relationship", "document.blocks");

  const unnumbered = observation(
    "custom-unnumbered",
    "10 cal Echo Bike + Zercher Sandbag Marches",
    2,
  );
  const unnumberedExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [unnumbered.id],
  } });
  const unnumberedDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [unnumbered.id], nodes }],
  });
  const unnumberedResult = reconcileParsedWorkoutCatalogIdentities(unnumberedDocument([
    unnumberedExercise("Echo Bike"), unnumberedExercise("Zercher Sandbag March"),
  ]), [unnumbered], catalogHints);
  assert.equal(unnumberedResult.blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(unnumberedDocument([
    unnumberedExercise("Echo Bike"),
  ]), [unnumbered], catalogHints), "assembly.relationship", "document.blocks");

  const oneWord = observation("custom-one-word", "10 cal Echo Bike + Burpees", 2);
  const oneWordExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [oneWord.id],
  } });
  const oneWordDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [oneWord.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(oneWordDocument([
    oneWordExercise("Echo Bike"), oneWordExercise("Burpee"),
  ]), [oneWord], catalogHints).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(oneWordDocument([
    oneWordExercise("Echo Bike"),
  ]), [oneWord], catalogHints), "assembly.relationship", "document.blocks");

  const contextualWord = observation("custom-sprint", "10 cal Echo Bike + 100 m Sprint", 2);
  const contextualExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [contextualWord.id],
  } });
  const contextualDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [contextualWord.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(contextualDocument([
    contextualExercise("Echo Bike"), contextualExercise("Sprint"),
  ]), [contextualWord], catalogHints).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(contextualDocument([
    contextualExercise("Echo Bike"),
  ]), [contextualWord], catalogHints), "assembly.relationship", "document.blocks");

  const qualified = observation("custom-qualified", "10 cal Echo Bike + 12 Y Raises", 2);
  const qualifiedExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [qualified.id],
  } });
  const qualifiedDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [qualified.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(qualifiedDocument([
    qualifiedExercise("Echo Bike"), qualifiedExercise("Y Raise"),
  ]), [qualified], catalogHints).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(qualifiedDocument([
    qualifiedExercise("Echo Bike"), qualifiedExercise("Raise"),
  ]), [qualified], catalogHints), "assembly.relationship", "document.blocks");

  const letterQualified = observation(
    "custom-letter-qualified",
    "10 cal Echo Bike + 30 second L-Sit",
    2,
  );
  const letterExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [letterQualified.id],
  } });
  const letterDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [letterQualified.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(letterDocument([
    letterExercise("Echo Bike"), letterExercise("L-Sit"),
  ]), [letterQualified], catalogHints).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(letterDocument([
    letterExercise("Echo Bike"), letterExercise("Sit"),
  ]), [letterQualified], catalogHints), "assembly.relationship", "document.blocks");

  const stationLetter = observation("custom-a-skip", "10 cal Echo Bike + 20 m A-Skip", 2);
  const stationExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [stationLetter.id],
  } });
  const stationDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [stationLetter.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(stationDocument([
    stationExercise("Echo Bike"), stationExercise("A-Skip"),
  ]), [stationLetter], catalogHints).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(stationDocument([
    stationExercise("Echo Bike"), stationExercise("Skip"),
  ]), [stationLetter], catalogHints), "assembly.relationship", "document.blocks");
  for (const [index, [text, name]] of [
    ["10 cal Echo Bike + 20 m A Skips", "A Skip"],
    ["10 cal Echo Bike + 20 m A–Skips", "A–Skip"],
  ].entries()) {
    const variant = observation(`custom-a-skip-${index}`, text, 2);
    const exercise = (exerciseName) => ({ type: "exercise", exercise: {
      name: exerciseName, sets: [], notes: [], intensityTargets: [],
      sourceObservationIDs: [variant.id],
    } });
    const document = (nodes) => ({
      title: "Imported workout", notes: [],
      blocks: [{ name: "Main", notes: [], sourceObservationIDs: [variant.id], nodes }],
    });
    assert.equal(reconcileParsedWorkoutCatalogIdentities(document([
      exercise("Echo Bike"), exercise(name),
    ]), [variant], catalogHints).blocks[0].nodes.length, 2);
    assertValidation(() => reconcileParsedWorkoutCatalogIdentities(document([
      exercise("Echo Bike"), exercise("Skip"),
    ]), [variant], catalogHints), "assembly.relationship", "document.blocks");
  }

  const allCustom = observation("all-custom", "Bear Crawl + Zercher Sandbag Marches", 2);
  const allCustomExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [allCustom.id],
  } });
  const allCustomDocument = (nodes) => ({
    title: "Imported workout",
    notes: [],
    blocks: [{ name: "Main", notes: [], sourceObservationIDs: [allCustom.id], nodes }],
  });
  assert.equal(reconcileParsedWorkoutCatalogIdentities(allCustomDocument([
    allCustomExercise("Bear Crawl"), allCustomExercise("Zercher Sandbag March"),
  ]), [allCustom], []).blocks[0].nodes.length, 2);
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(allCustomDocument([
    allCustomExercise("Bear Crawl"),
  ]), [allCustom], []), "assembly.relationship", "document.blocks");

  const sharedBase = observation(
    "shared-base",
    "20 Burpee Box Jump Overs + 10 Burpee Broad Jumps",
    2,
  );
  const sharedExercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [sharedBase.id],
  } });
  const sharedDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [sharedBase.id],
      nodes: [sharedExercise("Burpee Jump"), sharedExercise("Burpee Jump")],
    }],
  };
  assertValidation(
    () => reconcileParsedWorkoutCatalogIdentities(sharedDocument, [sharedBase], []),
    "assembly.relationship",
    "document.blocks",
  );
});

test("final catalog reconciliation scopes alternative grammar to identity-bearing clauses", () => {
  const catalogHints = [
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  for (const text of [
    "Choose a challenging load, then 10 cal Echo Bike and 500 m C2 Bike",
    "10 cal Echo Bike + 500 m C2 Bike / 3 rounds",
    "10 cal Echo Bike and 500 m C2 Bike for time or until cutoff",
    "10 cal Echo Bike w/ arms and 500 m C2 Bike",
  ]) {
    const line = observation("bike", text, 2);
    const document = {
      title: "Imported workout",
      notes: [],
      blocks: [{
        name: "Main",
        notes: [],
        sourceObservationIDs: [line.id],
        nodes: [{ type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [line.id],
        } }],
      }],
    };
    assertValidation(
      () => reconcileParsedWorkoutCatalogIdentities(document, [line], catalogHints),
      "assembly.relationship",
      "document.blocks",
    );
  }
});

test("final catalog reconciliation rejects choice options for a required conjunction", () => {
  const line = observation("bike", "10 cal Echo Bike + 500 m C2 Bike", 2);
  const exercise = (name) => ({ type: "exercise", exercise: {
    name, sets: [], notes: [], intensityTargets: [], sourceObservationIDs: [line.id],
  } });
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [line.id],
      nodes: [{ type: "choice", choice: {
        label: "Bike",
        selectionCount: 1,
        options: [exercise("Echo Bike"), exercise("BikeErg")],
        sourceObservationIDs: [line.id],
      } }],
    }],
  };

  assertValidation(
    () => reconcileParsedWorkoutCatalogIdentities(document, [line], [
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ]),
    "assembly.relationship",
    "document.blocks",
  );
});

test("final catalog reconciliation does not use an unrelated peer from the same photo", () => {
  const ambiguous = observation("ambiguous", "C2 Bike/ECHO Bike", 2);
  const echoPeer = observation("echo-peer", "20 seconds ECHO Bike arms only", 2);
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [ambiguous.id, echoPeer.id],
      nodes: [
        { type: "exercise", exercise: {
          name: "Stationary Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [ambiguous.id],
        } },
        { type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [echoPeer.id],
        } },
      ],
    }],
  };
  const result = reconcileParsedWorkoutCatalogIdentities(
    document,
    [ambiguous, echoPeer],
    [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  );

  assert.deepEqual(result.blocks[0].nodes.map((node) => node.exercise.name), [
    "BikeErg / Echo Bike", "Echo Bike",
  ]);
  assert.equal(document.blocks[0].nodes[0].exercise.name, "Stationary Bike");
});

test("final catalog reconciliation uses a source-supported peer in the same explicit choice", () => {
  const ambiguous = observation("ambiguous", "C2 Bike/ECHO Bike", 2);
  const echoPeer = observation("echo-peer", "20 seconds ECHO Bike arms only", 3);
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [ambiguous.id, echoPeer.id],
      nodes: [{ type: "choice", choice: {
        label: "Choose a bike",
        selectionCount: 1,
        ambiguity: "Imported across two sections",
        sourceObservationIDs: [ambiguous.id, echoPeer.id],
        options: [
          { type: "exercise", exercise: {
            name: "Stationary Bike", sets: [], notes: [], intensityTargets: [],
            sourceObservationIDs: [ambiguous.id],
          } },
          { type: "exercise", exercise: {
            name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
            sourceObservationIDs: [echoPeer.id],
          } },
        ],
      } }],
    }],
  };
  const result = reconcileParsedWorkoutCatalogIdentities(
    document,
    [ambiguous, echoPeer],
    [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  );

  assert.deepEqual(result.blocks[0].nodes[0].choice.options.map(
    (node) => node.exercise.name,
  ), ["BikeErg", "Echo Bike"]);
  assert.equal(
    document.blocks[0].nodes[0].choice.options[0].exercise.name,
    "Stationary Bike",
  );
});

test("final catalog reconciliation does not treat exercises in separate choice groups as direct alternatives", () => {
  const ambiguous = observation("ambiguous", "C2 Bike/ECHO Bike", 2);
  const echoPeer = observation("echo-peer", "10 calories Echo Bike cooldown", 2);
  const exerciseNode = (name, sourceObservationID) => ({
    type: "exercise",
    exercise: {
      name, sets: [], notes: [], intensityTargets: [],
      sourceObservationIDs: [sourceObservationID],
    },
  });
  const groupNode = (label, child, sourceObservationID) => ({
    type: "group",
    group: {
      label,
      adjustments: [],
      children: [child],
      notes: [],
      isOptional: false,
      sourceObservationIDs: [sourceObservationID],
    },
  });
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [ambiguous.id, echoPeer.id],
      nodes: [{ type: "choice", choice: {
        label: "Choose a session",
        selectionCount: 1,
        sourceObservationIDs: [ambiguous.id, echoPeer.id],
        options: [
          groupNode("Option A", exerciseNode("Stationary Bike", ambiguous.id), ambiguous.id),
          groupNode("Option B", exerciseNode("Echo Bike", echoPeer.id), echoPeer.id),
        ],
      } }],
    }],
  };
  const result = reconcileParsedWorkoutCatalogIdentities(
    document,
    [ambiguous, echoPeer],
    [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  );

  assert.deepEqual(result.blocks[0].nodes[0].choice.options.map(
    (option) => option.group.children[0].exercise.name,
  ), ["BikeErg / Echo Bike", "Echo Bike"]);
});

test("final reconciliation rejects laundering a standalone custom movement through another exercise", () => {
  const echo = observation("echo", "10 cal Echo Bike");
  for (const [id, text] of [
    ["numbered-burpee", "12 Burpees"],
    ["unnumbered-march", "Zercher Sandbag March"],
    ["unnumbered-burpee", "Burpees"],
    ["unnumbered-plank", "Max plank hold."],
    ["stairmaster-guidance", "StairMaster - 70 minutes - ideally with a weight vest or ruck."],
  ]) {
    const movement = observation(id, text);
    const document = {
      title: "Imported workout",
      notes: [],
      blocks: [{
        name: "Main",
        notes: [],
        sourceObservationIDs: [echo.id, movement.id],
        nodes: [{ type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [echo.id, movement.id],
        } }],
      }],
    };

    assertValidation(() => reconcileParsedWorkoutCatalogIdentities(
      document,
      [echo, movement],
      ["Echo Bike | aliases: echo bike; assault bike"],
    ), "assembly.relationship");
  }
});

test("final reconciliation requires repeat groups and structured timed work prescriptions", () => {
  const repeat = observation("intervals", "6 Sets - Aerobic Intervals");
  const repeatDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [repeat.id],
      nodes: [{ type: "group", group: {
        label: "Aerobic Intervals", children: [], adjustments: [], notes: [],
        isOptional: false, sourceObservationIDs: [repeat.id],
      } }],
    }],
  };
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(
    repeatDocument,
    [repeat],
    [],
  ), "assembly.relationship");

  const work = observation("work", "50 seconds work at 6-8 RPE");
  const workDocument = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main", notes: [], sourceObservationIDs: [work.id],
      nodes: [{ type: "exercise", exercise: {
        name: "Echo Bike",
        sets: [{ metrics: [{ type: "duration", value: 50, unit: "seconds" }], alternatives: [] }],
        notes: [], intensityTargets: [], sourceObservationIDs: [work.id],
      } }],
    }],
  };
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(
    workDocument,
    [work],
    [],
  ), "assembly.relationship");

  const rpeMetricDocument = structuredClone(workDocument);
  rpeMetricDocument.blocks[0].nodes[0].exercise.sets[0].metrics.push({
    type: "rpe", value: 6, upperValue: 8,
  });
  assert.doesNotThrow(() => reconcileParsedWorkoutCatalogIdentities(
    rpeMetricDocument,
    [work],
    [],
  ));

  const rpeIntensityDocument = structuredClone(workDocument);
  rpeIntensityDocument.blocks[0].nodes[0].exercise.intensityTargets.push({
    type: "rpe", lower: 6, upper: 8,
  });
  assert.doesNotThrow(() => reconcileParsedWorkoutCatalogIdentities(
    rpeIntensityDocument,
    [work],
    [],
  ));

  const splitSetDocument = structuredClone(workDocument);
  splitSetDocument.blocks[0].nodes[0].exercise.sets.push({
    metrics: [{ type: "rpe", value: 6, upperValue: 8 }], alternatives: [],
  });
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(
    splitSetDocument,
    [work],
    [],
  ), "assembly.relationship");

  const duplicateRPERepresentation = structuredClone(rpeMetricDocument);
  duplicateRPERepresentation.blocks[0].nodes[0].exercise.intensityTargets.push({
    type: "rpe", lower: 6, upper: 8,
  });
  assertValidation(() => reconcileParsedWorkoutCatalogIdentities(
    duplicateRPERepresentation,
    [work],
    [],
  ), "assembly.relationship");
});

test("final catalog reconciliation does not use peer evidence from a different photo", () => {
  const ambiguous = observation("ambiguous", "C2 Bike/ECHO Bike", 2);
  const echoPeer = observation("echo-peer", "20 seconds ECHO Bike arms only", 3);
  const document = {
    title: "Imported workout",
    notes: [],
    blocks: [{
      name: "Main",
      notes: [],
      sourceObservationIDs: [ambiguous.id, echoPeer.id],
      nodes: [
        { type: "exercise", exercise: {
          name: "Stationary Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [ambiguous.id],
        } },
        { type: "exercise", exercise: {
          name: "Echo Bike", sets: [], notes: [], intensityTargets: [],
          sourceObservationIDs: [echoPeer.id],
        } },
      ],
    }],
  };
  const result = reconcileParsedWorkoutCatalogIdentities(
    document,
    [ambiguous, echoPeer],
    [
      "Stationary Bike | aliases: spin bike; indoor bike",
      "BikeErg | aliases: concept2 bike; c2 bike",
      "Echo Bike | aliases: echo bike; assault bike",
    ],
  );

  assert.equal(result.blocks[0].nodes[0].exercise.name, "BikeErg / Echo Bike");
});

test("an adjacent orphan metric with different source evidence remains a relationship failure", () => {
  const exerciseLine = observation("exercise-line", "Run at threshold effort");
  const metricLine = observation("metric-line", "2:00 minutes");
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }, [exerciseLine.id]),
    record("run", "exercise", "block", 0, { name: "Run" }, [exerciseLine.id]),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }, [metricLine.id]),
  ]);

  assertValidation(
    () => assembleWorkoutImportIR(raw, new Set([exerciseLine.id, metricLine.id])),
    "assembly.parent_missing",
    "ir.records[2].parentID",
  );
});

test("an orphan metric cannot synthesize a second set for its exercise", () => {
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }),
    record("existing-set", "set", "run", 0),
  ]);

  assertValidation(
    () => assembleWorkoutImportIR(raw, new Set(["a"])),
    "assembly.parent_missing",
    "ir.records[2].parentID",
  );
});

test("an orphan metric separated from an exercise remains a relationship failure", () => {
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("note", "note", "run", 0, { text: "Stay controlled." }),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }),
  ]);

  assertValidation(
    () => assembleWorkoutImportIR(raw, new Set(["a"])),
    "assembly.parent_missing",
    "ir.records[3].parentID",
  );
});

test("grounding cannot create false adjacency for an orphan metric", () => {
  const raw = validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("ungrounded-note", "note", "run", 0, { text: "Invented model note." }, []),
    record("duration", "metric", "omitted-set", 0, {
      type: "duration", value: "120", unit: "seconds",
    }),
  ]);

  assertValidation(
    () => assembleWorkoutImportIR(raw, new Set(["a"])),
    "assembly.parent_missing",
    "ir.records[2].parentID",
  );
});

test("a note nested under a set moves to the owning exercise", () => {
  const line = observation("deadlift", "12 Deadlifts at bodyweight");
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [line.id]),
    record("deadlift", "exercise", "block", 0, { name: "Deadlift" }, [line.id]),
    record("set", "set", "deadlift", 0, {}, [line.id]),
    record("note", "note", "set", 0, { text: "Load the bar to bodyweight." }, [line.id]),
  ]), new Set([line.id]), {
    fallbackObservations: [line],
  });

  assert.deepEqual(document.blocks[0].nodes[0].exercise.notes, ["Load the bar to bodyweight."]);
});

test("root title provenance is satisfied by the preserved IR title", () => {
  const title = observation("title", "Aerobic Capacity");
  const heading = observation("heading", "Main");
  const document = assembleWorkoutImportIR({
    ...validIR([record("block", "block", "", 0, { name: "Main" }, [heading.id])]),
    title: title.text,
  }, new Set([title.id, heading.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [title, heading],
    fallbackScope: "workout",
  });

  assert.equal(document.title, title.text);
  assert.deepEqual(document.notes, []);
});

test("omitted long coaching prose is preserved deterministically at workout scope", () => {
  const heading = observation("heading", "Main");
  const coaching = observation(
    "coaching",
    "This session should remain intentionally controlled so the athlete can preserve the quality of the surrounding intensity days and leave ready to train again. ".repeat(2).trim(),
  );
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]), new Set([heading.id, coaching.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, coaching],
    fallbackScope: "workout",
  });

  assert.deepEqual(document.notes, []);
  assert.deepEqual(document.blocks[0].notes, [coaching.text]);
});

test("first-section heading fallback preserves scope without polluting note text", () => {
  const heading = observation("heading", "Main");
  const coachHeading = observation("coach-heading", "Coach's Note");
  const coaching = observation(
    "coaching",
    "Keep this session intentionally controlled so the athlete leaves ready to train again. ".repeat(3).trim(),
  );
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }, [heading.id]),
  ]), new Set([heading.id, coachHeading.id, coaching.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [heading, coachHeading, coaching],
    fallbackScope: "workout",
  });

  assert.equal(document.blocks[1].name, coachHeading.text);
  assert.deepEqual(document.blocks[1].notes, [coaching.text]);
  assert.equal(document.blocks[1].notes.some((note) => note.includes(coachHeading.text)), false);
});

test("first-section prose fallback attaches to the retained preceding block", () => {
  const coachHeading = observation("coach-heading", "Coach's Note");
  const coaching = observation(
    "coaching",
    "This session should remain intentionally controlled so the athlete can preserve the surrounding intensity days and leave ready to train again. ".repeat(2).trim(),
  );
  const document = assembleWorkoutImportIR(validIR([
    record("coach", "block", "", 0, { name: coachHeading.text }, [coachHeading.id]),
  ]), new Set([coachHeading.id, coaching.id]), {
    allowEmptyExercises: true,
    fallbackObservations: [coachHeading, coaching],
    fallbackScope: "workout",
  });

  assert.deepEqual(document.notes, []);
  assert.deepEqual(document.blocks[0].notes, [coaching.text]);
});

test("job payload parsing bounds sections and concurrency never exceeds two", async () => {
  const digest = "a".repeat(64);
  const parsed = parseStartWorkoutImportJobPayload({
    schemaVersion: 1,
    clientJobID: "11111111-1111-4111-8111-111111111111",
    requestID: "22222222-2222-4222-8222-222222222222",
    jobHash: "b".repeat(64),
    catalogHints: ["Run"],
    sections: [{ id: digest, order: 0, observations: [observation("a")], contextBefore: ["Main"] }],
  });
  assert.equal(parsed.sections.length, 1);
  assert.deepEqual(parsed.sections[0].contextBefore, ["Main"]);

  let active = 0;
  let highWater = 0;
  const results = await mapWithConcurrency([1, 2, 3, 4], 2, async (value) => {
    active += 1;
    highWater = Math.max(highWater, active);
    await Promise.resolve();
    active -= 1;
    return value * 2;
  });
  assert.equal(highWater, 2);
  assert.deepEqual(results, [2, 4, 6, 8]);
});

test("operational logs drop privacy canaries outside the allowlist", () => {
  const fields = workoutImportOperationalLog({
    jobID: "job",
    stage: "processing",
    model: "model",
    sourceText: "private workout" ,
    filename: "photo.jpg",
  });
  assert.deepEqual(fields, { jobID: "job", stage: "processing", model: "model" });
  assert.equal(JSON.stringify(fields).includes("private workout"), false);
});

test("IR graph validation rejects duplicate, orphaned, cyclic, and invalid relationships", () => {
  const cases = [
    {
      expected: "assembly.duplicate_id",
      ir: validIR([
        record("same", "block", "", 0, { name: "Main" }),
        record("same", "exercise", "same", 0, { name: "Run" }),
      ]),
    },
    {
      expected: "assembly.parent_missing",
      ir: validIR([record("run", "exercise", "missing", 0, { name: "Run" })]),
    },
    {
      expected: "assembly.relationship",
      ir: validIR([
        record("block", "block", "", 0, { name: "Main" }),
        record("metric", "metric", "block", 0, { type: "reps", value: "12" }),
      ]),
    },
    {
      expected: "assembly.cycle",
      ir: validIR([
        record("block", "block", "", 0, { name: "Main" }),
        record("g1", "group", "g2", 0, { label: "One" }),
        record("g2", "group", "g1", 0, { label: "Two" }),
      ]),
    },
  ];

  for (const item of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(item.ir, new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === item.expected,
    );
  }
});

test("independent parent matrix accepts allowed pairs and only the explicit recoverable edge", () => {
  const childKinds = Object.keys(EXPECTED_PARENT_MATRIX);
  const parentKinds = ["root", ...childKinds];
  let allowedCount = 0;
  let recoveredCount = 0;
  let rejectedCount = 0;

  for (const childKind of childKinds) {
    for (const parentKind of parentKinds) {
      const ir = relationshipIR(childKind, parentKind);
      if (EXPECTED_PARENT_MATRIX[childKind].includes(parentKind)) {
        assert.doesNotThrow(
          () => assembleWorkoutImportIR(ir, new Set(["a"])),
          `${childKind} should accept parent ${parentKind}`,
        );
        allowedCount += 1;
      } else if (childKind === "note" && parentKind === "set") {
        assert.doesNotThrow(
          () => assembleWorkoutImportIR(ir, new Set(["a"])),
          "a set note should recover to the owning exercise",
        );
        recoveredCount += 1;
      } else {
        assert.throws(
          () => assembleWorkoutImportIR(ir, new Set(["a"])),
          (error) => error instanceof WorkoutDocumentValidationError &&
            error.diagnostic.code === "assembly.relationship",
          `${childKind} should reject parent ${parentKind}`,
        );
        rejectedCount += 1;
      }
    }
  }

  assert.equal(allowedCount, 23);
  assert.equal(recoveredCount, 1);
  assert.equal(rejectedCount, 108);
});

test("all flat record kinds and metadata assemble to the canonical cross-runtime fixture", () => {
  const fixturePath = path.resolve(
    __dirname,
    "../../fixtures/workout-import/canonical-assembled-document.json",
  );
  const expected = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
  const validObservationIDs = new Set(["o-root", "o-group", "o-exercise", "o-choice", "o-rest"]);
  const assembled = assembleWorkoutImportIR(canonicalIR(), validObservationIDs);

  assert.deepEqual(assembled, expected);
  assert.deepEqual(assembled.blocks[0].sourceObservationIDs, ["o-root"]);
  const group = assembled.blocks[0].nodes[0].group;
  assert.equal(group.phase, "main");
  assert.equal(group.cadenceScope, "cycle");
  assert.equal(group.doseLayer, "med");
  assert.equal(group.isOptional, true);
  assert.equal(group.ambiguity, "Confirm the circuit order.");
  assert.deepEqual(group.adjustments[0], {
    metric: "duration", step: 600, minimum: 3_600, maximum: 4_800,
  });
  const exercise = group.children[0].exercise;
  assert.equal(exercise.sets[0].alternatives[0].label, "Scaled");
  assert.deepEqual(exercise.notes, ["Exercise note"]);
  assert.deepEqual(exercise.sourceObservationIDs, ["o-exercise"]);
});

test("IR normalization accepts bounded string numbers and known unit aliases but rejects unsupported units", () => {
  const ir = validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("sled", "exercise", "block", 0, { name: "Sled Pull", restSeconds: "90" }),
    record("set", "set", "sled", 0),
    record("distance", "metric", "set", 0, { type: "distance", value: "25", unit: "meters" }),
  ]);
  ir.schemaVersion = "1";
  ir.records[0].order = "0";
  const exercise = assembleWorkoutImportIR(ir, new Set(["a"]))
    .blocks[0].nodes[0].exercise;
  assert.equal(exercise.restSeconds, 90);
  assert.deepEqual(exercise.sets[0].metrics, [{ type: "distance", value: 25, unit: "m" }]);

  ir.records[3].attributes.find((attribute) => attribute.key === "unit").value = "yards";
  assert.throws(
    () => assembleWorkoutImportIR(ir, new Set(["a"])),
    (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === "ir.unit",
  );
});

test("IR rejects unitless dimensional metrics instead of inventing canonical units", () => {
  const requiredUnits = [
    "load", "duration", "distance", "heartRateZoneTime", "cadence", "power", "pace",
  ];

  for (const type of requiredUnits) {
    assert.throws(
      () => assembleWorkoutImportIR(setIR({}, { type, value: "10" }), new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError &&
        error.diagnostic.code === "ir.unit" &&
        error.diagnostic.path === "ir.records[3].attributes",
      `Expected ${type} without a unit to fail closed`,
    );
  }
});

test("IR preserves unitless natural metrics and types that explicitly encode a unit", () => {
  const cases = [
    [{ type: "reps", value: "12" }, { type: "reps", value: 12 }],
    [{ type: "calories", value: "20" }, { type: "calories", value: 20 }],
    [{ type: "heartRate", value: "150" }, { type: "heartRate", value: 150 }],
    [{ type: "rpe", value: "7" }, { type: "rpe", value: 7 }],
    [{ type: "seconds", value: "30" }, { type: "duration", value: 30, unit: "seconds" }],
    [{ type: "meters", value: "400" }, { type: "distance", value: 400, unit: "m" }],
    [{ type: "rpm", value: "90" }, { type: "cadence", value: 90, unit: "rpm" }],
    [{ type: "watts", value: "250" }, { type: "power", value: 250, unit: "watts" }],
  ];

  for (const [attributes, expected] of cases) {
    const metric = assembleWorkoutImportIR(setIR({}, attributes), new Set(["a"]))
      .blocks[0].nodes[0].exercise.sets[0].metrics[0];
    assert.deepEqual(metric, expected);
  }
});

test("IR rejects explicit units that contradict unit-encoded metric types", () => {
  const cases = [
    { type: "seconds", value: "30", unit: "minutes" },
    { type: "meters", value: "400", unit: "mi" },
  ];

  for (const attributes of cases) {
    assertValidation(
      () => assembleWorkoutImportIR(setIR({}, attributes), new Set(["a"])),
      "ir.unit", "ir.records[3].attributes[2].value",
    );
  }

  const matching = assembleWorkoutImportIR(
    setIR({}, { type: "seconds", value: "30", unit: "seconds" }),
    new Set(["a"]),
  ).blocks[0].nodes[0].exercise.sets[0].metrics[0];
  assert.deepEqual(matching, { type: "duration", value: 30, unit: "seconds" });
});

test("IR adjustments reject unit-encoded aliases and normalize unitless metric aliases", () => {
  const adjustment = (metric) => groupIR({}, [
    record("adjustment-extra", "adjustment", "group", 1, { metric, step: "10" }),
  ]);

  assertValidation(
    () => assembleWorkoutImportIR(adjustment("minutes"), new Set(["a"])),
    "ir.attribute", "ir.records[3].attributes[0].value",
  );

  const group = assembleWorkoutImportIR(adjustment("time"), new Set(["a"]))
    .blocks[0].nodes[0].group;
  assert.deepEqual(group.adjustments, [{ metric: "duration", step: 10 }]);
});

test("IR attributes, enums, booleans, numerics, and relationships fail closed", () => {
  const invalidDuplicateAttribute = record("run", "exercise", "block", 0, { name: "Run" });
  invalidDuplicateAttribute.attributes.push({ key: "name", value: "Bike" });
  const cases = [
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("run", "exercise", "block", 0, { name: "Run", bogus: "value" }),
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }), invalidDuplicateAttribute,
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("group", "group", "block", 0, { label: "Circuit", isOptional: "sometimes" }),
      record("run", "exercise", "group", 0, { name: "Run" }),
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("group", "group", "block", 0, { label: "Circuit", cadenceScope: "exercise" }),
      record("run", "exercise", "group", 0, { name: "Run" }),
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("rest", "rest", "block", 0, { label: "Rest", placement: "whenever" }),
      record("run", "exercise", "block", 1, { name: "Run" }),
    ])],
    ["ir.record_shape", validIR([
      record("block", "block", "", "-1", { name: "Main" }),
      record("run", "exercise", "block", 0, { name: "Run" }),
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("group", "group", "block", 0, { label: "Circuit", repeatCount: "0" }),
      record("run", "exercise", "group", 0, { name: "Run" }),
    ])],
    ["ir.attribute", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("run", "exercise", "block", 0, { name: "Run" }),
      record("set", "set", "run", 0),
      record("metric", "metric", "set", 0, { type: "reps", value: "-1" }),
    ])],
    ["assembly.relationship", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("set", "set", "block", 0),
    ])],
    ["assembly.relationship", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      record("run", "exercise", "block", 0, { name: "Run" }),
      record("adjustment", "adjustment", "run", 0, { metric: "duration", step: "60" }),
    ])],
  ];

  for (const [expectedCode, ir] of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(ir, new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === expectedCode,
    );
  }
});

test("downstream domain aliases normalize to the exact Swift vocabulary", () => {
  const freeTextBlockIntent = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main", intent: "Aerobic foundation" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
  ]), new Set(["a"]));
  assert.equal(freeTextBlockIntent.blocks[0].intent, "Aerobic foundation");

  const phaseCases = [
    ["warm-up", "warmup"], ["main", "main"], ["cool down", "cooldown"], ["transition", "transition"],
  ];
  for (const [input, expected] of phaseCases) {
    const group = assembleWorkoutImportIR(groupIR({ phase: input }), new Set(["a"]))
      .blocks[0].nodes[0].group;
    assert.equal(group.phase, expected);
  }

  for (const expected of ["med", "hpl", "mdv"]) {
    const group = assembleWorkoutImportIR(groupIR({ doseLayer: expected.toUpperCase() }), new Set(["a"]))
      .blocks[0].nodes[0].group;
    assert.equal(group.doseLayer, expected);
  }

  const scoringCases = [
    ["completion", "completion"],
    ["elapsedTime", "elapsedTime"],
    ["for time", "elapsedTime"],
    ["roundsAndReps", "roundsAndReps"],
    ["AMRAP", "roundsAndReps"],
  ];
  for (const [input, expected] of scoringCases) {
    const group = assembleWorkoutImportIR(groupIR({ scoring: input }), new Set(["a"]))
      .blocks[0].nodes[0].group;
    assert.equal(group.scoring, expected);
    assert.equal(group.scoreMetric, undefined);
  }
  const total = assembleWorkoutImportIR(
    groupIR({ scoring: "TOTAL", scoreMetric: "heart rate zone time" }),
    new Set(["a"]),
  ).blocks[0].nodes[0].group;
  assert.equal(total.scoring, "total");
  assert.equal(total.scoreMetric, "heartRateZoneTime");

  for (const intent of [
    "easy", "threshold", "intervals", "vo2", "speed", "long", "race", "strength", "recovery", "mobility",
  ]) {
    const exercise = assembleWorkoutImportIR(exerciseIR(intent === "vo2" ? { intent: "VO2" } : { intent }), new Set(["a"]))
      .blocks[0].nodes[0].exercise;
    assert.equal(exercise.intent, intent);
  }

  const roleCases = [
    ["warm-up", "warmup"], ["working", "working"], ["top", "top"], ["back-off", "backoff"], ["drop", "drop"],
  ];
  for (const [input, expected] of roleCases) {
    const set = assembleWorkoutImportIR(setIR({ role: input }), new Set(["a"]))
      .blocks[0].nodes[0].exercise.sets[0];
    assert.equal(set.role, expected);
  }

  const effortCases = [
    [{ effortType: "rpe", effortValue: "0" }, { type: "rpe", value: 0 }],
    [{ effortType: "rir", effortValue: "10" }, { type: "rir", value: 10 }],
    [{ effortType: "failure" }, { type: "toFailure" }],
    [{ effortType: "to failure" }, { type: "toFailure" }],
    [{ effortType: "max" }, { type: "maxEffort" }],
    [{ effortType: "max effort" }, { type: "maxEffort" }],
  ];
  for (const [attributes, expected] of effortCases) {
    const set = assembleWorkoutImportIR(setIR(attributes), new Set(["a"]))
      .blocks[0].nodes[0].exercise.sets[0];
    assert.deepEqual(set.effort, expected);
  }

  for (const unit of ["set", "round", "interval", "cycle"]) {
    const metric = assembleWorkoutImportIR(setIR({}, {
      type: "reps", value: "10", progressionDelta: "1", progressionEvery: "1",
      progressionUnit: unit.toUpperCase(),
    }), new Set(["a"])).blocks[0].nodes[0].exercise.sets[0].metrics[0];
    assert.equal(metric.progressionUnit, unit);
  }

  for (const scope of ["child", "cycle"]) {
    const group = assembleWorkoutImportIR(groupIR({ cadenceSeconds: "60", cadenceScope: scope }), new Set(["a"]))
      .blocks[0].nodes[0].group;
    assert.equal(group.cadenceSeconds, 60);
    assert.equal(group.cadenceScope, scope);
  }
});

test("every downstream semantic family rejects invalid or incoherent model values", () => {
  const adjustmentIR = (attributes) => groupIR({}, [
    record("adjustment", "adjustment", "group", 0, attributes),
  ]);
  const intensityIR = (attributes) => exerciseIR({}, [
    record("target", "intensity", "run", 0, attributes),
  ]);
  const alternativeProgressionIR = exerciseIR({}, [
    record("set", "set", "run", 0),
    record("alternative", "setAlternative", "set", 0, { label: "Scaled" }),
    record("alternative-metric", "metric", "alternative", 0, {
      type: "reps", value: "10", progressionDelta: "1", progressionEvery: "1", progressionUnit: "round",
    }),
  ]);
  const cases = [
    ["phase banana probe", groupIR({ phase: "bananas" })],
    ["dose layer", groupIR({ doseLayer: "bananas" })],
    ["scoring", groupIR({ scoring: "bananas" })],
    ["total missing metric", groupIR({ scoring: "total" })],
    ["score metric outside total", groupIR({ scoring: "completion", scoreMetric: "reps" })],
    ["unsupported total metric", groupIR({ scoring: "total", scoreMetric: "bananas" })],
    ["exercise intent", exerciseIR({ intent: "bananas" })],
    ["set role", setIR({ role: "bananas" })],
    ["effort type", setIR({ effortType: "bananas", effortValue: "7" })],
    ["orphan effort value", setIR({ effortValue: "7" })],
    ["rpe missing value", setIR({ effortType: "rpe" })],
    ["rpe range", setIR({ effortType: "rpe", effortValue: "11" })],
    ["rir finite", setIR({ effortType: "rir", effortValue: "NaN" })],
    ["value on failure effort", setIR({ effortType: "failure", effortValue: "7" })],
    ["value on max effort", setIR({ effortType: "max", effortValue: "7" })],
    ["orphan progression delta", setIR({}, { type: "reps", value: "10", progressionDelta: "1" })],
    ["orphan progression every", setIR({}, { type: "reps", value: "10", progressionEvery: "1" })],
    ["orphan progression unit", setIR({}, { type: "reps", value: "10", progressionUnit: "round" })],
    ["progression every", setIR({}, {
      type: "reps", value: "10", progressionDelta: "1", progressionEvery: "0", progressionUnit: "round",
    })],
    ["progression finite", setIR({}, {
      type: "reps", value: "10", progressionDelta: "NaN", progressionEvery: "1", progressionUnit: "round",
    })],
    ["progression unit", setIR({}, {
      type: "reps", value: "10", progressionDelta: "1", progressionEvery: "1", progressionUnit: "bananas",
    })],
    ["alternative progression", alternativeProgressionIR],
    ["upper value order", setIR({}, { type: "reps", value: "10", upperValue: "9" })],
    ["cadence missing scope", groupIR({ cadenceSeconds: "60" })],
    ["cadence missing seconds", groupIR({ cadenceScope: "child" })],
    ["cadence scope", groupIR({ cadenceSeconds: "60", cadenceScope: "bananas" })],
    ["adjustment metric", adjustmentIR({ metric: "bananas", step: "1" })],
    ["adjustment zero step", adjustmentIR({ metric: "duration", step: "0" })],
    ["adjustment negative step", adjustmentIR({ metric: "duration", step: "-1" })],
    ["adjustment finite step", adjustmentIR({ metric: "duration", step: "NaN" })],
    ["adjustment negative minimum", adjustmentIR({ metric: "duration", step: "1", minimum: "-1" })],
    ["adjustment incoherent bounds", adjustmentIR({
      metric: "duration", step: "1", minimum: "10", maximum: "9",
    })],
    ["named zone system", intensityIR({ type: "namedZone", value: "Zone 2" })],
    ["morpheus system", intensityIR({ type: "morpheus", value: "Blue", system: "Garmin" })],
  ];

  for (const [label, ir] of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(ir, new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === "ir.attribute",
      label,
    );
  }
});

test("configured IR limits accept their exact practical boundary", () => {
  const tenAttributeGroup = assembleWorkoutImportIR(groupIR({
    phase: "main",
    repeatCount: "2",
    cadenceSeconds: "60",
    cadenceScope: "cycle",
    scoring: "total",
    scoreMetric: "power",
    doseLayer: "med",
    isOptional: "true",
    ambiguity: "Confirm order.",
  }), new Set(["a"])).blocks[0].nodes[0].group;
  assert.equal(tenAttributeGroup.phase, "main");
  assert.equal(tenAttributeGroup.scoreMetric, "power");

  const sourceIDs = Array.from({ length: 100 }, (_, index) => `source-${index}`);
  const sourceBoundary = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }, sourceIDs),
  ]), new Set(["a", ...sourceIDs]));
  assert.equal(sourceBoundary.blocks[0].nodes[0].exercise.sourceObservationIDs.length, 100);

  const blockRecords = Array.from({ length: 50 }, (_, index) =>
    record(`block-${index}`, "block", "", index, { name: `Block ${index}` }));
  blockRecords.push(record("run", "exercise", "block-0", 0, { name: "Run" }));
  assert.equal(assembleWorkoutImportIR(validIR(blockRecords), new Set(["a"])).blocks.length, 50);

  const nodeRecords = [];
  for (let blockIndex = 0; blockIndex < 5; blockIndex += 1) {
    const blockID = `node-block-${blockIndex}`;
    nodeRecords.push(record(blockID, "block", "", blockIndex, { name: `Block ${blockIndex}` }));
    if (blockIndex === 0) {
      nodeRecords.push(record("run", "exercise", blockID, 0, { name: "Run" }));
    }
    const restCount = blockIndex === 0 ? 99 : 100;
    for (let restIndex = 0; restIndex < restCount; restIndex += 1) {
      nodeRecords.push(record(`rest-${blockIndex}-${restIndex}`, "rest", blockID, restIndex + 1, {
        label: "Rest", placement: "inline",
      }));
    }
  }
  const nodeBoundary = assembleWorkoutImportIR(validIR(nodeRecords), new Set(["a"]));
  assert.equal(nodeBoundary.blocks.reduce((sum, block) => sum + block.nodes.length, 0), 500);

  const depthRecords = [record("block", "block", "", 0, { name: "Main" })];
  let depthParent = "block";
  for (let index = 0; index < 8; index += 1) {
    depthRecords.push(record(`group-${index}`, "group", depthParent, 0, { label: `Group ${index}` }));
    depthParent = `group-${index}`;
  }
  depthRecords.push(record("deep-run", "exercise", depthParent, 0, { name: "Run" }));
  assert.doesNotThrow(() => assembleWorkoutImportIR(validIR(depthRecords), new Set(["a"])));

  const exerciseRecords = [
    record("exercise-block-0", "block", "", 0, { name: "First" }),
    record("exercise-block-1", "block", "", 1, { name: "Second" }),
    ...Array.from({ length: 200 }, (_, index) =>
      record(`run-${index}`, "exercise", `exercise-block-${Math.floor(index / 100)}`, index % 100, { name: "Run" })),
  ];
  const exerciseBoundary = assembleWorkoutImportIR(validIR(exerciseRecords), new Set(["a"]));
  assert.equal(exerciseBoundary.blocks.reduce((sum, block) => sum + block.nodes.length, 0), 200);

  const choiceRecords = [
    record("block", "block", "", 0, { name: "Main" }),
    record("choice", "choice", "block", 0, { label: "Choose", selectionCount: "1" }),
    ...Array.from({ length: 20 }, (_, index) =>
      record(`option-${index}`, "exercise", "choice", index, { name: "Run" })),
  ];
  assert.equal(assembleWorkoutImportIR(validIR(choiceRecords), new Set(["a"]))
    .blocks[0].nodes[0].choice.options.length, 20);

  const recordBoundary = [
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    ...Array.from({ length: 1_498 }, (_, index) =>
      record(`note-${index}`, "note", "", index, { text: "Note" })),
  ];
  assert.doesNotThrow(() => assembleWorkoutImportIR(validIR(recordBoundary), new Set(["a"])));
});

test("IR configured attribute, source, block, node, depth, exercise, and choice limits fail closed", () => {
  const tooManyAttributes = record("run", "exercise", "block", 0, { name: "Run" });
  tooManyAttributes.attributes = Array.from({ length: 11 }, () => ({ key: "name", value: "Run" }));
  const tooManySources = record("run", "exercise", "block", 0, { name: "Run" });
  tooManySources.sourceObservationIDs = Array.from({ length: 101 }, (_, index) => `source-${index}`);

  const nestedRecords = [record("block", "block", "", 0, { name: "Main" })];
  let parentID = "block";
  for (let index = 0; index < 10; index += 1) {
    nestedRecords.push(record(`group-${index}`, "group", parentID, 0, { label: `Group ${index}` }));
    parentID = `group-${index}`;
  }
  nestedRecords.push(record("deep-run", "exercise", parentID, 0, { name: "Run" }));

  const choiceWith = (count) => [
    record("block", "block", "", 0, { name: "Main" }),
    record("choice", "choice", "block", 0, { label: "Choose", selectionCount: "1" }),
    ...Array.from({ length: count }, (_, index) =>
      record(`option-${index}`, "exercise", "choice", index, { name: "Run" })),
  ];
  const cases = [
    ["ir.attribute_limit", validIR([
      record("block", "block", "", 0, { name: "Main" }), tooManyAttributes,
    ])],
    ["ir.record_shape", validIR([
      record("block", "block", "", 0, { name: "Main" }), tooManySources,
    ])],
    ["assembly.block_limit", validIR(Array.from({ length: 51 }, (_, index) =>
      record(`block-${index}`, "block", "", index, { name: `Block ${index}` })))],
    ["assembly.node_limit", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      ...Array.from({ length: 501 }, (_, index) => record(`rest-${index}`, "rest", "block", index, {
        label: "Rest", placement: "inline",
      })),
    ])],
    ["assembly.node_limit", validIR(nestedRecords)],
    ["assembly.exercise_count", validIR([
      record("block", "block", "", 0, { name: "Main" }),
      ...Array.from({ length: 201 }, (_, index) =>
        record(`run-${index}`, "exercise", "block", index, { name: "Run" })),
    ])],
    ["assembly.relationship", validIR(choiceWith(1))],
    ["assembly.relationship", validIR(choiceWith(21))],
  ];

  for (const [expectedCode, ir] of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(ir, new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === expectedCode,
    );
  }
});

test("IR qualitative load and unresolved non-load text remain editable without invented numbers", () => {
  const document = assembleWorkoutImportIR(validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("set", "set", "run", 0),
    record("load", "metric", "set", 0, { type: "load", value: "body weight" }),
    record("duration", "metric", "set", 1, { type: "duration", value: "until recovered" }),
  ]), new Set(["a"]));
  const exercise = document.blocks[0].nodes[0].exercise;

  assert.deepEqual(exercise.sets[0].metrics, []);
  assert.deepEqual(exercise.intensityTargets, [
    { type: "descriptive", value: "Load target: Bodyweight" },
  ]);
  assert.deepEqual(exercise.notes, ["duration: until recovered"]);
});

test("IR intensity types normalize only supported semantics and compatible units", () => {
  const records = [
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("hr-zone", "intensity", "run", 0, { type: "hr zone", lower: "2" }),
    record("named", "intensity", "run", 1, { type: "morpheus", value: "Blue" }),
    record("custom-zone", "intensity", "run", 2, {
      type: "namedZone", value: "Zone 2", system: "Custom zones",
    }),
    record("rpe", "intensity", "run", 3, { type: "rpe", lower: "6", upper: "8", unit: "RPE" }),
    record("pace", "intensity", "run", 4, { type: "pace", value: "Tempo pace" }),
    record("power", "intensity", "run", 5, { type: "power", lower: "200", upper: "300", unit: "watt" }),
    record("threshold", "intensity", "run", 6, {
      type: "percent threshold", lower: "90", upper: "105", unit: "percent",
    }),
    record("description", "intensity", "run", 7, { type: "effort", value: "Conversational" }),
  ];
  const exercise = assembleWorkoutImportIR(validIR(records), new Set(["a"]))
    .blocks[0].nodes[0].exercise;

  assert.deepEqual(exercise.intensityTargets, [
    { type: "heartRateZone", lower: 2 },
    { type: "namedZone", value: "Blue", system: "Morpheus" },
    { type: "namedZone", value: "Zone 2", system: "Custom zones" },
    { type: "rpe", lower: 6, upper: 8, unit: "rpe" },
    { type: "pace", value: "Tempo pace" },
    { type: "power", lower: 200, upper: 300, unit: "watts" },
    { type: "thresholdPercentage", lower: 90, upper: 105, unit: "%" },
    { type: "descriptive", value: "Conversational" },
  ]);
});

test("IR intensity semantics reject missing values, invalid ranges, unknown types, and bad units", () => {
  const intensityIR = (attributes) => validIR([
    record("block", "block", "", 0, { name: "Main" }),
    record("run", "exercise", "block", 0, { name: "Run" }),
    record("target", "intensity", "run", 0, attributes),
  ]);
  const cases = [
    ["ir.unit", { type: "power", lower: "200", unit: "bananas" }],
    ["ir.unit", { type: "power", lower: "200" }],
    ["ir.attribute", { type: "power", unit: "watts" }],
    ["ir.attribute", { type: "rpe", lower: "11" }],
    ["ir.attribute", { type: "rpe", lower: "8", upper: "6" }],
    ["ir.attribute", { type: "heartRateZone", lower: "2.5" }],
    ["ir.attribute", { type: "namedZone" }],
    ["ir.attribute", { type: "namedZone", value: "Blue" }],
    ["ir.attribute", { type: "morpheus", value: "Blue", system: "Garmin" }],
    ["ir.attribute", { type: "pace", value: "Tempo", unit: "secondsPerMeter" }],
    ["ir.unit", { type: "thresholdPercentage", lower: "95", unit: "bananas" }],
    ["ir.attribute", { type: "mystery", value: "Hard" }],
    ["ir.attribute", { type: "descriptive" }],
  ];

  for (const [expectedCode, attributes] of cases) {
    assert.throws(
      () => assembleWorkoutImportIR(intensityIR(attributes), new Set(["a"])),
      (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === expectedCode,
    );
  }
});

test("IR assembly fails closed for an empty workout and configured record limit", () => {
  assert.throws(
    () => assembleWorkoutImportIR(validIR([]), new Set(["a"])),
    (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === "assembly.empty",
  );
  const records = Array.from({ length: 1_501 }, (_, index) =>
    record(`note-${index}`, "note", "", index, { text: "Note" }));
  assert.throws(
    () => assembleWorkoutImportIR(validIR(records), new Set(["a"])),
    (error) => error instanceof WorkoutDocumentValidationError && error.diagnostic.code === "ir.record_limit",
  );
});

test("representative five-image workout preserves semantics without fabricated loads", () => {
  const longWorkoutNote = "This session protects the quality of the surrounding hard days. ".repeat(30).trim();
  const longBlockNote = "Use this day to consolidate, not chase stimulus. ".repeat(20).trim();
  const records = [
    record("workout-note", "note", "", 0, { text: longWorkoutNote }, ["p1"]),
    record("med", "block", "", 0, { name: "Minimum Effective Dose (MED)" }, ["p2"]),
    record("med-note", "note", "med", 0, { text: longBlockNote }, ["p2"]),
    record("amrap", "group", "med", 1, {
      label: "70 minute AMRAP", durationSeconds: "4200", scoring: "roundsAndReps",
    }, ["p2"]),
    record("duration-adjustment", "adjustment", "amrap", 0, { metric: "duration", step: "600" }, ["p2"]),
    record("bike-choice", "choice", "amrap", 0, { label: "C2 Bike or Echo Bike", selectionCount: "1" }, ["p2"]),
    record("c2", "exercise", "bike-choice", 0, { name: "Concept2 Bike" }, ["p2"]),
    record("echo", "exercise", "bike-choice", 1, { name: "Echo Bike" }, ["p2"]),
    record("station-a", "group", "amrap", 1, { label: "A" }, ["p3"]),
    record("sled", "exercise", "station-a", 0, { name: "Sled Pull" }, ["p3"]),
    record("sled-set", "set", "sled", 0, {}, ["p3"]),
    record("sled-distance", "metric", "sled-set", 0, { type: "distance", value: "25", unit: "meters" }, ["p3"]),
    record("sled-load", "intensity", "sled", 1, { type: "descriptive", value: "Load target: Race weight" }, ["p3"]),
    record("station-b", "group", "amrap", 2, { label: "B" }, ["p3"]),
    record("deadlift", "exercise", "station-b", 0, { name: "Deadlift" }, ["p3"]),
    record("deadlift-set", "set", "deadlift", 0, {}, ["p3"]),
    record("deadlift-reps", "metric", "deadlift-set", 0, { type: "reps", value: "12" }, ["p3"]),
    record("deadlift-load", "intensity", "deadlift", 1, { type: "descriptive", value: "Load target: Bodyweight" }, ["p3"]),
    record("burpee", "exercise", "station-b", 1, { name: "Lateral Burpee Over Barbell" }, ["p3"]),
    record("burpee-set", "set", "burpee", 0, {}, ["p3"]),
    record("burpee-reps", "metric", "burpee-set", 0, { type: "reps", value: "12" }, ["p3"]),
    record("performance", "block", "", 1, { name: "Performance Layer" }, ["p4"]),
    record("push-press", "exercise", "performance", 0, { name: "Dual Dumbbell Push Press" }, ["p4"]),
    record("push-set", "set", "push-press", 0, {}, ["p4"]),
    record("push-reps", "metric", "push-set", 0, { type: "reps", value: "12" }, ["p4"]),
    record("mdv", "block", "", 2, { name: "Maximum Daily Volume (MDV)" }, ["p5"]),
    record("core", "group", "mdv", 0, { label: "Ski + Core", repeatCount: "4" }, ["p5"]),
    record("ski", "exercise", "core", 0, { name: "SkiErg" }, ["p5"]),
    record("rest", "rest", "core", 1, {
      label: "Rest between rounds", durationSeconds: "90", placement: "betweenRepetitions",
    }, ["p5"]),
  ];
  const document = assembleWorkoutImportIR(
    { schemaVersion: 1, title: "Aerobic Capacity", goal: "", ignoredObservationIDs: [], records },
    new Set(["p1", "p2", "p3", "p4", "p5"]),
  );

  assert.equal(document.notes[0], longWorkoutNote);
  assert.equal(document.blocks[0].notes[0], longBlockNote);
  assert.deepEqual(document.blocks.map((block) => block.name), [
    "Minimum Effective Dose (MED)", "Performance Layer", "Maximum Daily Volume (MDV)",
  ]);
  const amrap = document.blocks[0].nodes[0].group;
  assert.equal(amrap.durationSeconds, 4_200);
  assert.deepEqual(amrap.adjustments, [{ metric: "duration", step: 600 }]);
  assert.deepEqual(amrap.children[0].choice.options.map((node) => node.exercise.name), [
    "Concept2 Bike", "Echo Bike",
  ]);
  assert.deepEqual(amrap.children.slice(1).map((node) => node.group.label), ["A", "B"]);
  const sled = amrap.children[1].group.children[0].exercise;
  assert.deepEqual(sled.sets[0].metrics, [{ type: "distance", value: 25, unit: "m" }]);
  assert.deepEqual(sled.intensityTargets, [{ type: "descriptive", value: "Load target: Race weight" }]);
  const stationB = amrap.children[2].group;
  assert.deepEqual(stationB.children.map((node) => node.exercise.name), [
    "Deadlift", "Lateral Burpee Over Barbell",
  ]);
  const deadlift = stationB.children[0].exercise;
  assert.deepEqual(deadlift.sets[0].metrics, [{ type: "reps", value: 12 }]);
  assert.deepEqual(deadlift.intensityTargets, [{ type: "descriptive", value: "Load target: Bodyweight" }]);
  assert.equal(deadlift.sets[0].metrics.some((metric) => metric.type === "load"), false);
  assert.equal(document.blocks[1].nodes[0].exercise.name, "Dual Dumbbell Push Press");
  assert.equal(document.blocks[2].nodes[0].group.children[1].rest.durationSeconds, 90);
});

test("validation diagnostics expose only fixed codes and schema-index paths", () => {
  const sentinel = "PRIVATE-WORKOUT-CONTENT-9f2d";
  const document = validWorkout();
  document.title = sentinel;
  document.notes = [sentinel];
  document.blocks[0].name = sentinel;
  document.blocks[0].nodes[0].exercise.name = sentinel;
  document.blocks[0].nodes[0].exercise.sets = [{
    metrics: [{ type: "load", value: null, privateUnknownKey: sentinel }], alternatives: [],
  }];

  let diagnostic;
  try {
    validateParsedWorkoutDocument(document, new Set(["a"]));
    assert.fail("Expected malformed qualitative metric to be rejected");
  } catch (error) {
    assert.ok(error instanceof WorkoutDocumentValidationError);
    diagnostic = error.diagnostic;
  }

  assert.equal(diagnostic.code, "metric.shape");
  assert.equal(diagnostic.path, "blocks[0].nodes[0].exercise.sets[0].metrics[0]");
  assert.equal(diagnostic.actualKind, "null");
  const serialized = JSON.stringify(workoutImportValidationLogFields("initial", diagnostic));
  assert.ok(serialized.length < 1_000);
  assert.doesNotMatch(serialized, new RegExp(sentinel));
  assert.deepEqual(Object.keys(JSON.parse(serialized)).sort(), [
    "actualKind", "attempt", "boundary", "validationCode", "validationPath", "validatorVersion",
  ]);
});

test("IR diagnostics do not expose source IDs, record IDs, attribute keys, or values", () => {
  const sentinel = "PRIVATE-WORKOUT-CONTENT-9f2d";
  const ir = validIR([
    record("block", "block", "", 0, { name: sentinel }, [sentinel]),
    record("run", "exercise", "block", 0, { name: sentinel }, [sentinel]),
    record("set", "set", "run", 0, {}, [sentinel]),
    record("metric", "metric", "set", 0, { type: "distance", value: "25", unit: sentinel }, [sentinel]),
  ]);
  let diagnostic;
  try {
    assembleWorkoutImportIR(ir, new Set([sentinel]));
    assert.fail("Expected unsupported unit to fail");
  } catch (error) {
    assert.ok(error instanceof WorkoutDocumentValidationError);
    diagnostic = error.diagnostic;
  }
  const fields = workoutImportValidationLogFields("initial", diagnostic);
  const serialized = JSON.stringify(fields);
  assert.equal(fields.boundary, "ir");
  assert.equal(fields.validationCode, "ir.unit");
  assert.equal(fields.validationPath, "ir.records[3].attributes[2].value");
  assert.doesNotMatch(serialized, new RegExp(sentinel));
  assert.ok(serialized.length < 1_000);
});

test("validator keeps duration and surfaces ambiguity when a group also contains repeat count", () => {
  const document = validWorkout();
  document.blocks[0].nodes = [{ type: "group", group: {
    label: "PRIVATE GROUP LABEL", repeatCount: 6, durationSeconds: 4_200,
    adjustments: [], notes: [], isOptional: false, sourceObservationIDs: ["a"], ambiguity: "x".repeat(500),
    children: [document.blocks[0].nodes[0]],
  } }];

  const parsed = validateParsedWorkoutDocument(document, new Set(["a"]));
  const group = parsed.blocks[0].nodes[0].group;
  assert.equal(group.durationSeconds, 4_200);
  assert.equal(group.repeatCount, undefined);
  assert.match(group.ambiguity, /kept the duration/i);
});

test("validator preserves qualitative loads as structured targets without inventing numbers", () => {
  const document = validWorkout();
  document.blocks[0].nodes[0].exercise.notes = Array.from({ length: 20 }, (_, index) => `Existing note ${index}`);
  document.blocks[0].nodes[0].exercise.sets = [{
    metrics: [
      { type: "load", value: "bodyweight" },
      { type: "duration", value: "max" },
      { type: "reps", value: "12" },
    ],
    alternatives: [],
  }];

  const exercise = validateParsedWorkoutDocument(document, new Set(["a"]))
    .blocks[0].nodes[0].exercise;
  assert.deepEqual(exercise.sets[0].metrics, [{ type: "reps", value: 12 }]);
  assert.deepEqual(exercise.intensityTargets, [
    { type: "descriptive", value: "Load target: bodyweight" },
  ]);
  assert.ok(!exercise.notes.includes("load: bodyweight"));
  assert.ok(exercise.notes.includes("duration: max"));
});

test("validator preserves race-weight sled load as a blank structured target", () => {
  const document = validWorkout();
  document.blocks[0].nodes[0].exercise.name = "Sled Pull";
  document.blocks[0].nodes[0].exercise.sets = [{
    metrics: [
      { type: "distance", value: "25", unit: "m" },
      { type: "load", value: "race weight" },
    ],
    alternatives: [],
  }];

  const exercise = validateParsedWorkoutDocument(document, new Set(["a"]))
    .blocks[0].nodes[0].exercise;
  assert.deepEqual(exercise.sets[0].metrics, [
    { type: "distance", value: 25, unit: "m" },
  ]);
  assert.deepEqual(exercise.intensityTargets, [
    { type: "descriptive", value: "Load target: race weight" },
  ]);
});

test("validator recovers one unambiguous tagged-node payload mismatch", () => {
  const document = validWorkout();
  const exercise = document.blocks[0].nodes[0].exercise;
  document.blocks[0].nodes = [{ type: "group", exercise }];

  const node = validateParsedWorkoutDocument(document, new Set(["a"]))
    .blocks[0].nodes[0];
  assert.equal(node.type, "exercise");
  assert.equal(node.exercise.name, "Run");
});

test("validator rejects a flattened declared payload mixed with another nested branch", () => {
  const document = validWorkout();
  const ambiguousNodes = [
    {
      type: "exercise", name: "Run", sets: [],
      group: { label: "Do not discard", children: [] },
    },
    {
      type: "group", label: "Circuit", children: [],
      exercise: { name: "Do not discard", sets: [] },
    },
    {
      type: "exercise", name: "Run", sets: [],
      exercise: { name: "Bike", sets: [] },
    },
    {
      type: "rest", durationSeconds: "60",
      exercise: { name: "Run", sets: [] },
    },
    {
      name: "Run", sets: [],
      group: { label: "Circuit", children: [] },
    },
  ];

  for (const node of ambiguousNodes) {
    document.blocks[0].nodes = [node];
    assertValidation(
      () => validateParsedWorkoutDocument(document, new Set(["a"])),
      "node.shape", "blocks[0].nodes[0]",
    );
  }
});

test("validator normalizes exact numeric strings for every optional numeric prescription", () => {
  const document = validWorkout();
  document.blocks[0].nodes = [{ type: "group", group: {
    label: "Timed circuit", durationSeconds: "4200", cadenceSeconds: "60",
    adjustments: [{ metric: "duration", step: "600", minimum: "3600", maximum: "4800" }],
    notes: [], isOptional: false, sourceObservationIDs: ["a"],
    children: [{ type: "exercise", exercise: {
      name: "Run", restSeconds: "90", notes: [], sourceObservationIDs: ["a"],
      intensityTargets: [{ type: "rpe", lower: "6", upper: "8" }],
      sets: [{ effort: { type: "rpe", value: "7" }, alternatives: [], metrics: [{
        type: "reps", value: "12", upperValue: "15", progressionDelta: "1", progressionEvery: "2",
      }] }],
    } }],
  } }];

  const group = validateParsedWorkoutDocument(document, new Set(["a"]))
    .blocks[0].nodes[0].group;
  const exercise = group.children[0].exercise;
  const metric = exercise.sets[0].metrics[0];
  assert.equal(group.durationSeconds, 4_200);
  assert.equal(group.cadenceSeconds, 60);
  assert.deepEqual(group.adjustments[0], { metric: "duration", step: 600, minimum: 3_600, maximum: 4_800 });
  assert.equal(exercise.restSeconds, 90);
  assert.deepEqual(exercise.intensityTargets[0], { type: "rpe", lower: 6, upper: 8 });
  assert.deepEqual(exercise.sets[0].effort, { type: "rpe", value: 7 });
  assert.deepEqual(metric, {
    type: "reps", value: 12, upperValue: 15, progressionDelta: 1, progressionEvery: 2,
  });
});

test("validator rejects nonnumeric strings in optional numeric fields instead of dropping them", () => {
  const document = validWorkout();
  document.blocks[0].nodes[0].exercise.restSeconds = "after breathing settles";
  assertValidation(
    () => validateParsedWorkoutDocument(document, new Set(["a"])),
    "exercise.shape", "blocks[0].nodes[0].exercise.restSeconds",
  );
});

test("validator rejects a negative required metric string instead of preserving it as prose", () => {
  const document = validWorkout();
  document.blocks[0].nodes[0].exercise.sets = [{
    metrics: [{ type: "reps", value: "-1" }], alternatives: [],
  }];
  assertValidation(
    () => validateParsedWorkoutDocument(document, new Set(["a"])),
    "metric.shape", "blocks[0].nodes[0].exercise.sets[0].metrics[0]",
  );
});

test("document validator rejects unitless dimensional metrics and accepts explicit type units", () => {
  const requiredUnits = [
    "load", "duration", "distance", "heartRateZoneTime", "cadence", "power", "pace",
  ];
  for (const type of requiredUnits) {
    const document = validWorkout();
    document.blocks[0].nodes[0].exercise.sets = [{
      metrics: [{ type, value: "10" }], alternatives: [],
    }];
    assertValidation(
      () => validateParsedWorkoutDocument(document, new Set(["a"])),
      "metric.shape", "blocks[0].nodes[0].exercise.sets[0].metrics[0].unit",
    );
  }

  const encoded = validWorkout();
  encoded.blocks[0].nodes[0].exercise.sets = [{
    metrics: [{ type: "seconds", value: "30" }], alternatives: [],
  }];
  const metric = validateParsedWorkoutDocument(encoded, new Set(["a"]))
    .blocks[0].nodes[0].exercise.sets[0].metrics[0];
  assert.deepEqual(metric, { type: "duration", value: 30, unit: "seconds" });

  for (const contradictory of [
    { type: "seconds", value: "30", unit: "minutes" },
    { type: "meters", value: "400", unit: "mi" },
  ]) {
    const document = validWorkout();
    document.blocks[0].nodes[0].exercise.sets = [{ metrics: [contradictory], alternatives: [] }];
    assertValidation(
      () => validateParsedWorkoutDocument(document, new Set(["a"])),
      "metric.shape", "blocks[0].nodes[0].exercise.sets[0].metrics[0].unit",
    );
  }
});

test("document adjustments reject unit-encoded aliases and normalize unitless metric aliases", () => {
  const withAdjustment = (metric) => ({
    title: "Adjustable workout",
    blocks: [{
      name: "Main",
      sourceObservationIDs: ["a"],
      nodes: [{ type: "group", group: {
        label: "AMRAP",
        adjustments: [{ metric, step: 10 }],
        notes: [],
        sourceObservationIDs: ["a"],
        children: [validWorkout().blocks[0].nodes[0]],
      } }],
    }],
  });

  assertValidation(
    () => validateParsedWorkoutDocument(withAdjustment("minutes"), new Set(["a"])),
    "adjustment.shape", "blocks[0].nodes[0].group.adjustments[0].metric",
  );
  const group = validateParsedWorkoutDocument(withAdjustment("time"), new Set(["a"]))
    .blocks[0].nodes[0].group;
  assert.deepEqual(group.adjustments, [{ metric: "duration", step: 10 }]);
});

test("choice diagnostics distinguish minimum from maximum cardinality", () => {
  const document = validWorkout();
  document.blocks[0].nodes = [{ type: "choice", choice: {
    label: "Pick one", selectionCount: 1, options: [document.blocks[0].nodes[0]],
    sourceObservationIDs: ["a"],
  } }];

  assert.throws(
    () => validateParsedWorkoutDocument(document, new Set(["a"])),
    (error) => {
      assert.ok(error instanceof WorkoutDocumentValidationError);
      assert.equal(error.diagnostic.code, "choice.limit");
      assert.equal(error.diagnostic.observedCount, 1);
      assert.equal(error.diagnostic.minimum, 2);
      assert.equal(error.diagnostic.limit, undefined);
      return true;
    },
  );
});

test("provider construction binds the bounded timeout and disables hidden retries", () => {
  let received;
  class CapturingProvider {
    constructor(options) { received = options; }
  }

  const client = createWorkoutImportProviderClient(CapturingProvider, "test-key");

  assert.ok(client instanceof CapturingProvider);
  assert.deepEqual(received, { apiKey: "test-key", timeout: 120_000, maxRetries: 0 });
});

test("callable and provider deadline constants leave bounded completion headroom", () => {
  assert.equal(WORKOUT_IMPORT_TIMEOUT_SECONDS, 180);
  assert.deepEqual(WORKOUT_IMPORT_PROVIDER_OPTIONS, { timeout: 120_000, maxRetries: 0 });
  assert.ok(WORKOUT_IMPORT_PROVIDER_OPTIONS.timeout < WORKOUT_IMPORT_TIMEOUT_SECONDS * 1_000);
  assert.ok(WORKOUT_IMPORT_PROVIDER_OPTIONS.timeout < WORKER_LEASE_MS);
  assert.ok(WORKOUT_IMPORT_PROVIDER_OPTIONS.timeout < SECTION_LEASE_MS);
  assert.ok(WORKER_LEASE_MS < DISPATCH_RECOVERY_MS);
  const { parseWorkoutImport } = require("../lib/index");
  assert.equal(parseWorkoutImport.__endpoint.timeoutSeconds, WORKOUT_IMPORT_TIMEOUT_SECONDS);
});

test("durable import endpoints return promptly and worker retries exponentially", () => {
  const endpoints = require("../lib/index");
  for (const name of [
    "startWorkoutImportJob",
    "getWorkoutImportJobStatus",
    "retryWorkoutImportJob",
    "cancelWorkoutImportJob",
  ]) {
    assert.equal(endpoints[name].__endpoint.timeoutSeconds, 45);
    assert.deepEqual(endpoints[name].__endpoint.region, ["us-central1"]);
  }
  const worker = endpoints.processWorkoutImportJob.__endpoint;
  assert.equal(worker.timeoutSeconds, 540);
  assert.deepEqual(worker.taskQueueTrigger.retryConfig, {
    maxAttempts: 12,
    maxDoublings: 3,
    maxBackoffSeconds: 120,
    maxRetrySeconds: worker.taskQueueTrigger.retryConfig.maxRetrySeconds,
    minBackoffSeconds: 10,
  });
  assert.equal(worker.taskQueueTrigger.rateLimits.maxConcurrentDispatches, 10);
  const dispatcher = endpoints.dispatchWorkoutImportJob.__endpoint;
  assert.deepEqual(dispatcher.region, ["us-central1"]);
  assert.equal(dispatcher.eventTrigger.retry, true);
  assert.equal(
    dispatcher.eventTrigger.eventFilterPathPatterns.document,
    "workoutImportJobs/{jobID}",
  );
});

test("durable import endpoints require authentication and use environment App Check policy", () => {
  const source = fs.readFileSync(path.join(__dirname, "..", "src", "index.ts"), "utf8");
  const endpointNames = [
    "startWorkoutImportJob",
    "getWorkoutImportJobStatus",
    "retryWorkoutImportJob",
    "cancelWorkoutImportJob",
  ];
  for (let index = 0; index < endpointNames.length; index += 1) {
    const start = source.indexOf(`export const ${endpointNames[index]} = onCall`);
    const endName = endpointNames[index + 1] ?? "processWorkoutImportJob";
    const end = source.indexOf(`export const ${endName}`, start + 1);
    const endpoint = source.slice(start, end);
    assert.ok(start >= 0, `${endpointNames[index]} must be declared`);
    assert.match(endpoint, /enforceAppCheck: ENFORCE_IMPORT_APP_CHECK/);
    assert.match(endpoint, /if \(!req\.auth\) throw new HttpsError\("unauthenticated"/);
  }
});

test("Photos intake is file-backed only and has no unbounded data transfer fallback", () => {
  const source = fs.readFileSync(path.join(
    __dirname, "..", "..", "Baseline", "Features", "WorkoutImport", "WorkoutImportView.swift",
  ), "utf8");
  assert.match(source, /FileRepresentation\(importedContentType: \.image\)/);
  assert.doesNotMatch(source, /DataRepresentation\(importedContentType: \.image\)/);
  assert.match(source, /WorkoutImageTransferFiles\.copyProtectedFile/);
});

test("Firestore rules deny direct import access and TTL covers roots, sections, and cancellation tombstones", () => {
  const projectRoot = path.join(__dirname, "..", "..");
  const rules = fs.readFileSync(path.join(projectRoot, "firestore.rules"), "utf8");
  const indexes = fs.readFileSync(path.join(projectRoot, "firestore.indexes.json"), "utf8");

  for (const collection of [
    "workoutImportJobs", "workoutImportJobSections", "workoutImportJobCancellations",
  ]) {
    assert.match(rules, new RegExp(`match \\/${collection}\\/\\{[^}]+\\} \\{\\s+allow read, write: if false;`));
    assert.match(
      indexes,
      new RegExp(`"collectionGroup": "${collection}"[\\s\\S]+?"fieldPath": "expiresAt"[\\s\\S]+?"ttl": true`),
    );
  }
});

test("preserves ordered source image indexes and rejects reordered pages", () => {
  const parsed = parseWorkoutImportPayload({
    observations: [observation("a", "page 0", 0), observation("b", "page 1", 1), observation("c", "page 1", 1)],
    catalogHints: [],
  });
  assert.deepEqual(parsed.observations.map((item) => item.sourceImageIndex), [0, 1, 1]);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [observation("b", "page 1", 1), observation("a", "page 0", 0)], catalogHints: [],
  }), /source image order/);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [observation("x", "page 10", 10)], catalogHints: [],
  }), /source image index/);
});

test("enforces observation, character, image, confidence, box, and catalog boundaries", () => {
  const maximumObservations = Array.from({ length: 2_000 }, (_, index) => observation(`${index}`, "x"));
  assert.equal(parseWorkoutImportPayload({ observations: maximumObservations, catalogHints: [] }).observations.length, 2_000);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [...maximumObservations, observation("overflow", "x")], catalogHints: [],
  }), /observation count/);

  const maximumCharacters = Array.from({ length: 20 }, (_, index) => observation(`${index}`, "x".repeat(2_000)));
  assert.equal(parseWorkoutImportPayload({ observations: maximumCharacters, catalogHints: [] })
    .observations.reduce((sum, item) => sum + item.text.length, 0), 40_000);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [...maximumCharacters, observation("overflow", "x")], catalogHints: [],
  }), /OCR text is too long/);

  assert.deepEqual(parseWorkoutImportPayload({
    observations: [observation("first", "x", 0), observation("last", "x", 9)], catalogHints: [],
  }).observations.map((item) => item.sourceImageIndex), [0, 9]);
  assert.throws(() => parseWorkoutImportPayload({ observations: [observation("x", "x", 10)], catalogHints: [] }), /source image index/);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [{ ...observation("x"), confidence: Number.NaN }], catalogHints: [],
  }), /confidence/);
  assert.throws(() => parseWorkoutImportPayload({
    observations: [{ ...observation("x"), boundingBox: { x: 0.5, y: 0, width: 0.6, height: 0.1 } }], catalogHints: [],
  }), /outside the source image/);

  const catalogHints = Array.from({ length: 501 }, (_, index) => `${index}-${"a".repeat(200)}`);
  const parsed = parseWorkoutImportPayload({ observations: [observation("x")], catalogHints });
  assert.equal(parsed.catalogHints.length, 500);
  assert.equal(parsed.catalogHints[0].length, 120);
});

test("rejects non-finite or negative parsed metrics", () => {
  const base = { title: "Strength", blocks: [{ name: "Main", sourceObservationIDs: ["a"], exercises: [{
    name: "Back Squat", notes: [], sourceObservationIDs: ["a"], sets: [{ metrics: [{ type: "reps", value: -1 }] }],
  }] }] };
  assert.throws(() => validateParsedWorkoutDocument(base, new Set(["a"])), /metric/);
});

test("drops evidence IDs that were not present in the OCR request", () => {
  const document = validateParsedWorkoutDocument({ title: "Run", blocks: [{ name: "", sourceObservationIDs: ["fake"], exercises: [{
    name: "Run", notes: [], sourceObservationIDs: ["real", "fake"], sets: [{ metrics: [{ type: "distance", value: 5, unit: "km" }] }],
  }] }] }, new Set(["real"]));
  assert.deepEqual(document.blocks[0].nodes[0].exercise.sourceObservationIDs, ["real"]);
});

test("preserves nested AMRAP progression, choices, and duration adjustments", () => {
  const document = validateParsedWorkoutDocument({ title: "Progressive AMRAP", blocks: [{
    name: "Main", sourceObservationIDs: ["a"], nodes: [{ type: "group", group: {
      label: "70-minute AMRAP", durationSeconds: 4200, scoring: "roundsAndReps",
      adjustments: [{ metric: "duration", step: 600 }], notes: [], isOptional: false,
      sourceObservationIDs: ["a"], children: [
        { type: "exercise", exercise: { name: "SkiErg", notes: [], intensityTargets: [], sourceObservationIDs: ["a"], sets: [{
          metrics: [{ type: "calories", value: 10, progressionDelta: 1, progressionEvery: 1, progressionUnit: "round" }], alternatives: [],
        }] } },
        { type: "choice", choice: { label: "Bike", selectionCount: 1, sourceObservationIDs: ["a"], options: [
          { type: "exercise", exercise: { name: "Concept2 Bike", notes: [], intensityTargets: [], sourceObservationIDs: ["a"], sets: [{ metrics: [{ type: "duration", value: 360, unit: "seconds" }], alternatives: [] }] } },
          { type: "exercise", exercise: { name: "Echo Bike", notes: [], intensityTargets: [], sourceObservationIDs: ["a"], sets: [{ metrics: [{ type: "duration", value: 360, unit: "seconds" }], alternatives: [] }] } },
        ] } },
      ],
    } }],
  }] }, new Set(["a"]));
  const group = document.blocks[0].nodes[0].group;
  assert.equal(group.durationSeconds, 4200);
  assert.equal(group.adjustments[0].step, 600);
  assert.equal(group.children[0].exercise.sets[0].metrics[0].progressionDelta, 1);
  assert.equal(group.children[1].choice.options.length, 2);
});

test("accepts flattened exercise nodes and missing sets as an editable empty prescription", () => {
  const document = validateParsedWorkoutDocument({ title: "Warm-up", blocks: [{
    name: "Main", sourceObservationIDs: ["a"], nodes: [{
      type: "exercise", name: "Run", notes: [], intensityTargets: [], sourceObservationIDs: ["a"],
    }],
  }] }, new Set(["a"]));
  const exercise = document.blocks[0].nodes[0].exercise;
  assert.equal(exercise.name, "Run");
  assert.deepEqual(exercise.sets, []);
});

test("accepts children as a block node collection and infers an untagged exercise", () => {
  const document = validateParsedWorkoutDocument({ title: "Run", blocks: [{
    name: "Main", sourceObservationIDs: ["a"], children: [{
      name: "Run", notes: [], intensityTargets: [], sourceObservationIDs: ["a"], sets: [],
    }],
  }] }, new Set(["a"]));
  assert.equal(document.blocks[0].nodes[0].type, "exercise");
  assert.equal(document.blocks[0].nodes[0].exercise.name, "Run");
});

test("accepts a single block node object and safely truncates display labels", () => {
  const document = validateParsedWorkoutDocument({ title: "T".repeat(250), blocks: [{
    name: "M".repeat(150), nodes: {
      type: "exercise", exercise: { name: "Run", notes: [], intensityTargets: [], sourceObservationIDs: [], sets: [] },
    },
  }] }, new Set());
  assert.equal(document.title.length, 200);
  assert.equal(document.blocks[0].name.length, 120);
  assert.equal(document.blocks[0].nodes.length, 1);
});

test("preserves bounded long workout and block notes without creating exercises", () => {
  const longNote = "Coach detail ".repeat(500);
  const document = validateParsedWorkoutDocument({
    title: "Long notes",
    notes: [longNote],
    blocks: [{
      name: "Main",
      notes: [longNote],
      nodes: [{ type: "exercise", exercise: {
        name: "Run", notes: ["Relax the shoulders."], intensityTargets: [], sourceObservationIDs: ["a"], sets: [],
      } }],
      sourceObservationIDs: ["a"],
    }],
  }, new Set(["a"]));

  assert.equal(document.notes.length, 1);
  assert.equal(document.notes[0].length, 4000);
  assert.equal(document.blocks[0].notes[0].length, 4000);
  assert.equal(document.blocks[0].nodes.length, 1);
});

test("preserves and bounds notes at workout, block, group, and exercise scopes", () => {
  const note = `  ${"Coach detail ".repeat(500)}  `;
  const notes = (count) => Array.from({ length: count }, () => note);
  const document = validateParsedWorkoutDocument({
    title: "All note scopes",
    notes: notes(51),
    blocks: [{
      name: "Main",
      notes: notes(51),
      sourceObservationIDs: ["a"],
      nodes: [{ type: "group", group: {
        label: "Circuit", adjustments: [], notes: notes(31), isOptional: false,
        sourceObservationIDs: ["a"],
        children: [{ type: "exercise", exercise: {
          name: "Run", notes: notes(21), intensityTargets: [], sourceObservationIDs: ["a"], sets: [],
        } }],
      } }],
    }],
  }, new Set(["a"]));

  const group = document.blocks[0].nodes[0].group;
  const exercise = group.children[0].exercise;
  assert.equal(document.notes.length, 50);
  assert.equal(document.blocks[0].notes.length, 50);
  assert.equal(group.notes.length, 30);
  assert.equal(exercise.notes.length, 20);
  for (const scopedNotes of [document.notes, document.blocks[0].notes, group.notes, exercise.notes]) {
    assert.equal(scopedNotes[0].length, 4_000);
  }
  assert.equal(document.blocks[0].nodes.length, 1);
  assert.equal(group.children.length, 1);
});

test("parser contract explicitly separates movement identity, compound movements, and active recovery", () => {
  assert.match(WORKOUT_IMPORT_SYSTEM, /small, flat WorkoutImportIR/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Never return nested workout nodes/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Exercise names are identities/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /25 Air Squats \+ 15 Jump Squats/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /40-50 seconds very easy jog/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /publisher metadata/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /sourceImageIndex/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Classify prose by scope instead of inventing exercises/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /workout-level notes/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /block notes/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Alternate A & B.*both stations are required/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Only explicit "or", "choose", or "either" wording creates a choice/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Load target: Bodyweight/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Dumbbell Bench Press for Dual Dumbbell Push Press/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Stationary Bike for Echo Bike/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /Catalog hints use "Canonical Name \| aliases:/);
  assert.match(WORKOUT_IMPORT_SYSTEM, /vocabulary, not evidence/);
});

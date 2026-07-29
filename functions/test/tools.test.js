const test = require("node:test");
const assert = require("node:assert/strict");
const {
  LEGACY_TOOLS,
  SERVED_TOOLSETS,
  TOOLS,
  WAVE5_TOOLS,
  WAVE6_TOOLS,
  WAVE7_TOOLS,
  WAVE8_TOOLS,
  servedToolsetForClientSchema,
  toolsForClientSchema,
} = require("../lib/tools");

test("replace_exercise is an atomic duplicate-safe tool", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "replace_exercise");

  assert.ok(tool);
  assert.deepEqual(tool.input_schema.required, [
    "exercise_instance_id", "replacement", "expected_revision_token",
  ]);
  assert.equal(tool.input_schema.properties.exercise_instance_id.type, "string");
  assert.equal(tool.input_schema.properties.replace_all, undefined);
  assert.match(tool.description, /never simulate replacement/i);
});

test("workout tools expose stable ID targeting", () => {
  const currentWorkout = TOOLS.find((candidate) => candidate.name === "get_current_workout");
  assert.ok(currentWorkout);
  assert.match(currentWorkout.description, /stable ids/i);
  assert.match(currentWorkout.description, /block, exercise instance, and set/i);

  const targetFields = {
    move_exercise: ["exercise_instance_id", "to_block_id"],
    replace_exercise: ["exercise_instance_id"],
    remove_exercise: ["exercise_instance_id"],
    reorder_exercise: ["exercise_instance_id"],
    duplicate_exercise: ["exercise_instance_id"],
  };

  for (const [name, fields] of Object.entries(targetFields)) {
    const tool = TOOLS.find((candidate) => candidate.name === name);
    assert.ok(tool, `${name} should exist`);
    for (const field of fields) {
      assert.equal(tool.input_schema.properties[field].type, "string", `${name}.${field}`);
      assert.match(tool.input_schema.properties[field].description, /get_current_workout/i);
      assert.equal(tool.input_schema.required.includes(field), true, `${name}.${field} is required`);
    }
  }

  const addExercise = TOOLS.find((candidate) => candidate.name === "add_exercise");
  assert.equal(addExercise.input_schema.properties.block_id.type, "string");
  assert.equal(addExercise.input_schema.properties.parent_id.type, "string");
  assert.match(addExercise.input_schema.properties.block_id.description, /get_current_workout/i);
  assert.match(addExercise.input_schema.properties.parent_id.description, /get_current_workout/i);
  assert.deepEqual(
    TOOLS.find((candidate) => candidate.name === "remove_exercise").input_schema.required,
    ["exercise_instance_id", "expected_revision_token"]
  );
  assert.deepEqual(
    TOOLS.find((candidate) => candidate.name === "update_logging_config").input_schema.required,
    ["exercise_instance_id", "expected_revision_token"]
  );
  assert.deepEqual(
    TOOLS.find((candidate) => candidate.name === "set_metric_value").input_schema.required,
    ["exercise_instance_id", "set_id", "metric", "value", "expected_revision_token"]
  );
  assert.deepEqual(
    TOOLS.find((candidate) => candidate.name === "remove_metric").input_schema.required,
    ["exercise_instance_id", "metric", "expected_revision_token"]
  );
});

test("Wave 5 structure schemas are ID-only, positioned, purge-aware, and undoable", () => {
  const addBlock = TOOLS.find((candidate) => candidate.name === "add_block");
  const removeBlock = TOOLS.find((candidate) => candidate.name === "remove_block");
  const moveBlock = TOOLS.find((candidate) => candidate.name === "move_block");
  const duplicateBlock = TOOLS.find((candidate) => candidate.name === "duplicate_block");
  const addExercise = TOOLS.find((candidate) => candidate.name === "add_exercise");
  const moveExercise = TOOLS.find((candidate) => candidate.name === "move_exercise");
  const reorderExercise = TOOLS.find((candidate) => candidate.name === "reorder_exercise");
  const duplicateExercise = TOOLS.find((candidate) => candidate.name === "duplicate_exercise");

  for (const tool of [
    addBlock, removeBlock, moveBlock, duplicateBlock,
    addExercise, moveExercise, reorderExercise, duplicateExercise,
  ]) {
    assert.ok(tool);
    assert.ok(tool.input_schema.required.includes("expected_revision_token"));
  }
  assert.equal(addBlock.input_schema.properties.guidance.type, "string");
  assert.equal(addBlock.input_schema.properties.at_index.minimum, 0);
  assert.deepEqual(removeBlock.input_schema.required, ["block_id", "expected_revision_token"]);
  assert.deepEqual(moveBlock.input_schema.required, ["block_id", "to_index", "expected_revision_token"]);
  assert.deepEqual(duplicateBlock.input_schema.required, ["block_id", "expected_revision_token"]);
  assert.deepEqual(addExercise.input_schema.required, ["name", "expected_revision_token"]);
  // Mutual exclusion is expressed as schema-form dependencies, never a top-level oneOf — the
  // Anthropic API rejects top-level combinators in input_schema with a 400.
  assert.deepEqual(addExercise.input_schema.dependencies, {
    block_id: { not: { required: ["parent_id"] } },
    parent_id: { not: { required: ["block_id"] } },
  });
  assert.deepEqual(moveExercise.input_schema.required, [
    "exercise_instance_id", "to_block_id", "to_index", "expected_revision_token",
  ]);
  assert.match(removeBlock.description, /performed exercise, group, and choice record/i);
  assert.match(removeBlock.description, /undo restores/i);
  assert.match(
    TOOLS.find((candidate) => candidate.name === "remove_exercise").description,
    /exact purged performed content/i
  );
  assert.match(duplicateBlock.description, /fresh block, node, exercise, set, and alternative IDs/i);
  assert.match(duplicateExercise.description, /fresh exercise, set, and alternative IDs/i);
});

test("Wave 5 schemas are capability-gated for installed clients", () => {
  assert.equal(toolsForClientSchema("5"), WAVE5_TOOLS);
  assert.equal(toolsForClientSchema(undefined), LEGACY_TOOLS);

  // The gate is monotonic: a future client version bump keeps the current schema, while malformed
  // or pre-Wave-5 versions fall back to the legacy schema.
  assert.equal(toolsForClientSchema("6"), WAVE6_TOOLS);
  assert.equal(toolsForClientSchema("7"), WAVE7_TOOLS);
  assert.equal(toolsForClientSchema("8"), WAVE8_TOOLS);
  assert.equal(toolsForClientSchema("9"), TOOLS);
  assert.equal(toolsForClientSchema("12"), TOOLS);
  assert.equal(toolsForClientSchema("4"), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema("0"), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema(""), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema("5.1"), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema("banana"), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema(5), LEGACY_TOOLS);
  assert.equal(toolsForClientSchema(null), LEGACY_TOOLS);

  assert.equal(servedToolsetForClientSchema("5"), "wave5");
  assert.equal(servedToolsetForClientSchema("6"), "wave6");
  assert.equal(servedToolsetForClientSchema("7"), "wave7");
  assert.equal(servedToolsetForClientSchema("8"), "wave8");
  assert.equal(servedToolsetForClientSchema("9"), "wave9");
  assert.equal(servedToolsetForClientSchema("12"), "wave9");
  assert.equal(servedToolsetForClientSchema("4"), "legacy");
  assert.equal(servedToolsetForClientSchema(undefined), "legacy");

  const legacyNames = new Set(LEGACY_TOOLS.map((tool) => tool.name));
  for (const name of ["remove_block", "move_block", "duplicate_block", "reorder_exercise", "duplicate_exercise"]) {
    assert.equal(legacyNames.has(name), false);
  }
  assert.deepEqual(
    LEGACY_TOOLS.find((tool) => tool.name === "add_exercise").input_schema.required,
    ["block", "name", "expected_revision_token"]
  );
  assert.deepEqual(
    LEGACY_TOOLS.find((tool) => tool.name === "remove_exercise").input_schema.required,
    ["exercise", "expected_revision_token"]
  );
});

test("Wave 6 performed logging is distinct, unit-safe, and capability-gated", () => {
  const performedNames = [
    "get_active_session",
    "upsert_performed_set",
    "set_performed_set_outcome",
    "add_extra_performed_set",
    "update_extra_performed_set",
    "delete_extra_performed_set",
    "add_exercise_session_note",
    "undo_session_mutation",
  ];
  const wave6Names = new Set(TOOLS.map((tool) => tool.name));
  const wave5Names = new Set(WAVE5_TOOLS.map((tool) => tool.name));

  for (const name of performedNames) {
    assert.equal(wave6Names.has(name), true, `${name} should be served to Wave 6 clients`);
    assert.equal(wave5Names.has(name), false, `${name} should not leak to Wave 5 clients`);
  }

  for (const name of ["upsert_performed_set", "add_extra_performed_set", "update_extra_performed_set"]) {
    const tool = TOOLS.find((candidate) => candidate.name === name);
    const valueText = tool.input_schema.properties.values.items.properties.value_text;
    assert.equal(valueText.type, "string");
    assert.match(valueText.description, /athlete's quantity wording/i);
    assert.match(valueText.description, /unit/i);
  }

  const outcome = TOOLS.find((tool) => tool.name === "set_performed_set_outcome");
  assert.deepEqual(outcome.input_schema.properties.outcome.enum, ["pending", "completed", "skipped"]);
  assert.ok(outcome.input_schema.properties.planned_set_id);
  assert.ok(outcome.input_schema.properties.performed_set_id);

  // The schema mirrors what the iOS mapper rejects: performed_set_id combined with any
  // planned-target field, split targets, and group_id or iteration supplied alone. It is
  // expressed as schema-form dependencies because the Anthropic API 400s on top-level
  // oneOf/allOf/anyOf; "at least one target" is unexpressible without those, so the mapper
  // remains the deterministic backstop for a call with no target at all.
  assert.deepEqual(outcome.input_schema.dependencies, {
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
  });
  const pairing = { group_id: ["iteration"], iteration: ["group_id"] };
  for (const name of ["upsert_performed_set", "add_extra_performed_set"]) {
    const tool = TOOLS.find((candidate) => candidate.name === name);
    assert.deepEqual(tool.input_schema.dependencies, pairing, `${name} should pair group_id with iteration`);
  }

  assert.equal(toolsForClientSchema("6"), WAVE6_TOOLS);
  assert.equal(servedToolsetForClientSchema("6"), "wave6");
});

test("Wave 7 composite and bulk mutations are atomic, dry-runnable, and capability-gated", () => {
  const wave7Names = ["apply_workout_edits", "convert_workout_units", "bulk_replace_exercises"];
  const allNames = new Set(TOOLS.map((tool) => tool.name));
  const wave6Names = new Set(WAVE6_TOOLS.map((tool) => tool.name));
  const wave5Names = new Set(WAVE5_TOOLS.map((tool) => tool.name));

  for (const name of wave7Names) {
    assert.equal(allNames.has(name), true, `${name} should be served to Wave 7 clients`);
    assert.equal(wave6Names.has(name), false, `${name} should not leak to Wave 6 clients`);
    assert.equal(wave5Names.has(name), false, `${name} should not leak to Wave 5 clients`);
  }

  const batch = TOOLS.find((tool) => tool.name === "apply_workout_edits");
  assert.deepEqual(batch.input_schema.required, ["operations", "expected_revision_token"]);
  assert.equal(batch.input_schema.properties.operations.minItems, 1);
  assert.equal(batch.input_schema.properties.operations.maxItems, 20);
  assert.deepEqual(batch.input_schema.properties.operations.items.required, ["op"]);
  assert.match(batch.description, /atomic/i);
  assert.match(batch.description, /whole batch is rejected/i);
  assert.match(batch.description, /which operation failed/i);
  assert.match(batch.description, /one undo_workout_mutation call reverts the entire batch/i);
  // Every batch-eligible op is a real served single tool with the same name.
  const opNames = batch.input_schema.properties.operations.items.properties.op.enum;
  assert.equal(new Set(opNames).size, opNames.length);
  for (const opName of opNames) {
    assert.equal(allNames.has(opName), true, `batch op ${opName} should be a served tool`);
  }
  for (const excluded of ["create_workout", "require_all_options", "undo_workout_mutation", "upsert_performed_set"]) {
    assert.equal(opNames.includes(excluded), false, `${excluded} must not be batchable`);
  }

  const convert = TOOLS.find((tool) => tool.name === "convert_workout_units");
  assert.deepEqual(convert.input_schema.required, ["expected_revision_token"]);
  assert.equal(convert.input_schema.minProperties, 2);   // at least one unit besides the token
  for (const unitField of ["distance_unit", "load_unit", "duration_unit", "pace_unit"]) {
    assert.equal(convert.input_schema.properties[unitField].type, "string");
  }
  assert.match(convert.description, /display/i);
  assert.match(convert.description, /canonical stored values never change/i);
  assert.match(convert.description, /duplicates included/i);
  assert.match(convert.input_schema.properties.dry_run.description, /defaults to false/i);

  const replace = TOOLS.find((tool) => tool.name === "bulk_replace_exercises");
  assert.deepEqual(replace.input_schema.required, [
    "selector", "replacement_definition_id", "expected_revision_token",
  ]);
  assert.match(replace.description, /dry[-_]?run/i);
  assert.match(replace.description, /exact matched instance IDs and names/i);
  assert.match(replace.input_schema.properties.dry_run.description, /explicit false/i);

  // Both bulk tools share one explicit-taxonomy selector; no fuzzy name field exists.
  for (const tool of [convert, replace]) {
    const selector = tool.input_schema.properties.selector;
    assert.equal(selector.minProperties, 1);
    assert.equal(selector.additionalProperties, false);
    assert.deepEqual(Object.keys(selector.properties).sort(), [
      "block_id", "definition_id", "equipment", "level", "modality", "muscle", "pattern", "tag",
    ]);
    assert.equal(selector.properties.name, undefined);
    assert.equal(selector.properties.query, undefined);
  }
});

test("Wave 4 planned-set schemas are ID-only and explicit about clearing", () => {
  const add = TOOLS.find((candidate) => candidate.name === "add_set");
  const update = TOOLS.find((candidate) => candidate.name === "update_set");
  const remove = TOOLS.find((candidate) => candidate.name === "remove_set");
  const move = TOOLS.find((candidate) => candidate.name === "move_set");
  const duplicate = TOOLS.find((candidate) => candidate.name === "duplicate_set");

  assert.ok(add);
  assert.ok(update);
  assert.ok(remove);
  assert.ok(move);
  assert.ok(duplicate);
  assert.deepEqual(add.input_schema.required, [
    "exercise_instance_id", "values", "role", "targets", "expected_revision_token",
  ]);
  assert.deepEqual(update.input_schema.required, ["set_id", "patch", "expected_revision_token"]);
  assert.deepEqual(remove.input_schema.required, ["set_id", "expected_revision_token"]);
  assert.deepEqual(move.input_schema.required, ["set_id", "expected_revision_token"]);
  assert.deepEqual(duplicate.input_schema.required, ["set_id", "expected_revision_token"]);
  assert.deepEqual(update.input_schema.properties.patch.properties.values.type, ["object", "null"]);
  assert.deepEqual(update.input_schema.properties.patch.properties.targets.type, ["object", "null"]);
  assert.match(update.description, /omitted/i);
  assert.match(update.description, /null/i);
  assert.match(remove.description, /logged-actual safeguard/i);
  assert.match(duplicate.description, /fresh set ID/i);
});

test("Wave 4 metric schemas expose pace units and heart-rate zone time", () => {
  const logging = TOOLS.find((candidate) => candidate.name === "update_logging_config");
  const metricValue = TOOLS.find((candidate) => candidate.name === "set_metric_value");
  const convertUnits = TOOLS.find((candidate) => candidate.name === "convert_workout_units");
  const customExercise = TOOLS.find((candidate) => candidate.name === "create_custom_exercise");

  assert.ok(logging.input_schema.properties.pace_unit);
  assert.match(logging.input_schema.properties.pace_unit.description, /\/km/);
  // Every unit the athlete can pick in the app has to be offerable by the model too: an option that
  // exists in the picker but not in the served schema is a setting the coach can never apply.
  for (const spelling of ["/km", "/mi", "/500m"]) {
    assert.ok(logging.input_schema.properties.pace_unit.description.includes(spelling),
      `update_logging_config pace_unit must offer ${spelling}`);
    assert.ok(convertUnits.input_schema.properties.pace_unit.description.includes(spelling),
      `convert_workout_units pace_unit must offer ${spelling}`);
    assert.ok(customExercise.input_schema.properties.pace_unit.enum.includes(spelling),
      `create_custom_exercise pace_unit enum must offer ${spelling}`);
  }
  assert.match(logging.description, /heartRateZoneTime/);
  assert.match(metricValue.input_schema.properties.metric.description, /heartRateZoneTime/);
  assert.match(logging.description, /canonical stored values/i);
});

test("require_all_options preserves an imported choice's children", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "require_all_options");

  assert.ok(tool);
  assert.deepEqual(tool.input_schema.required, ["choice", "expected_revision_token"]);
  assert.match(tool.description, /required ordered group/i);
  assert.match(tool.description, /preserves the child exercises/i);
});

test("workout mutations require revision tokens and expose targeted undo", () => {
  const mutationNames = [
    "update_workout_metadata",
    "update_block_metadata",
    "update_exercise_metadata",
    "add_block",
    "remove_block",
    "move_block",
    "duplicate_block",
    "add_exercise",
    "move_exercise",
    "replace_exercise",
    "remove_exercise",
    "reorder_exercise",
    "duplicate_exercise",
    "require_all_options",
    "add_set",
    "update_set",
    "remove_set",
    "move_set",
    "duplicate_set",
    "update_logging_config",
    "set_metric_value",
    "remove_metric",
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
  ];

  for (const name of mutationNames) {
    const tool = TOOLS.find((candidate) => candidate.name === name);
    assert.ok(tool, `${name} should exist`);
    assert.ok(tool.input_schema.required.includes("expected_revision_token"));
  }

  const undo = TOOLS.find((candidate) => candidate.name === "undo_workout_mutation");
  assert.ok(undo);
  assert.deepEqual(undo.input_schema.required, ["mutation_id", "expected_revision_token"]);
  assert.match(undo.description, /still the plan head/i);
  assert.match(undo.description, /rejects as stale/i);
});

test("metadata tools expose orthogonal patches with nullable clear semantics", () => {
  const workout = TOOLS.find((candidate) => candidate.name === "update_workout_metadata");
  const block = TOOLS.find((candidate) => candidate.name === "update_block_metadata");
  const exercise = TOOLS.find((candidate) => candidate.name === "update_exercise_metadata");

  assert.ok(workout);
  assert.ok(block);
  assert.ok(exercise);
  assert.deepEqual(workout.input_schema.required, ["expected_revision_token"]);
  assert.deepEqual(block.input_schema.required, ["block_id", "expected_revision_token"]);
  assert.deepEqual(exercise.input_schema.required, ["exercise_instance_id", "expected_revision_token"]);
  assert.equal(workout.input_schema.minProperties, 2);
  assert.equal(block.input_schema.minProperties, 3);
  assert.equal(exercise.input_schema.minProperties, 3);
  // The workout level has exactly one free-form text, the athlete's note. A separate goal or a
  // workout-level guidance field would let the model write text no surface ever shows.
  assert.deepEqual(Object.keys(workout.input_schema.properties).sort(), [
    "expected_revision_token", "note", "title",
  ]);
  assert.deepEqual(Object.keys(block.input_schema.properties).sort(), [
    "block_id", "expected_revision_token", "guidance", "intent", "name",
  ]);
  assert.deepEqual(Object.keys(exercise.input_schema.properties).sort(), [
    "display_label", "exercise_instance_id", "expected_revision_token", "guidance",
  ]);
  assert.equal(workout.input_schema.properties.title.type, "string");
  assert.equal(block.input_schema.properties.name.type, "string");
  for (const field of [
    workout.input_schema.properties.note,
    block.input_schema.properties.intent,
    block.input_schema.properties.guidance,
    exercise.input_schema.properties.display_label,
    exercise.input_schema.properties.guidance,
  ]) {
    assert.deepEqual(field.type, ["string", "null"]);
    assert.match(field.description, /clear|return to the catalog/i);
  }
  assert.match(block.input_schema.properties.block_id.description, /get_current_workout/i);
  assert.match(exercise.input_schema.properties.exercise_instance_id.description, /get_current_workout/i);
});

test("search_exercises retrieves from the catalog with every filter optional", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "search_exercises");

  assert.ok(tool);
  // No required params: an empty call is a valid "what do you have?" browse.
  assert.equal(tool.input_schema.required, undefined);
  for (const param of ["query", "muscle", "equipment", "modality", "pattern", "tag", "level"]) {
    assert.equal(tool.input_schema.properties[param].type, "string");
  }
  // The catalog must never be inlined into the prompt, so the tool itself has to tell the model
  // the library exists and that a page is not the whole of it.
  assert.match(tool.description, /never say it doesn't/i);
  assert.match(tool.description, /total/i);
});

test("get_exercise looks one movement up by name or id", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "get_exercise");

  assert.ok(tool);
  assert.equal(tool.input_schema.required, undefined);   // either name or id; enforced on-device
  assert.equal(tool.input_schema.properties.name.type, "string");
  assert.equal(tool.input_schema.properties.id.type, "string");
  assert.match(tool.description, /muscles/i);
});

// The workout carries one free-form text and no CoachGuidance of its own. Every served toolset is a
// filtered view of the same array, so a workout-level `guidance` or `goal` field reintroduced in one
// place would reach every client at once - and let the model write text no surface can ever show.
test("no served toolset lets the model write workout-level guidance or a separate goal", () => {
  for (const [toolsetName, tools] of Object.entries(SERVED_TOOLSETS)) {
    for (const name of ["update_workout_metadata", "create_workout"]) {
      const tool = tools.find((candidate) => candidate.name === name);
      assert.ok(tool, `${toolsetName}: ${name} is not served`);
      const fields = Object.keys(tool.input_schema.properties ?? {});
      assert.ok(!fields.includes("guidance"), `${toolsetName}: ${name} still advertises guidance`);
      assert.ok(!fields.includes("goal"), `${toolsetName}: ${name} still advertises a goal`);
      assert.ok(fields.includes("note"), `${toolsetName}: ${name} must expose the workout's one note`);
    }
  }
});

test("tool names are unique and map to the on-device executor", () => {
  const names = TOOLS.map((tool) => tool.name);
  assert.equal(new Set(names).size, names.length);
  assert.ok(names.includes("search_exercises"));
  assert.ok(names.includes("get_exercise"));
  assert.ok(names.includes("update_workout_metadata"));
  assert.ok(names.includes("update_block_metadata"));
  assert.ok(names.includes("update_exercise_metadata"));
});

test("Wave 8 advanced node and prescription schemas are ID-only, typed, and capability-gated", () => {
  const wave8Names = [
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
  ];
  const wave8ServedNames = new Set(WAVE8_TOOLS.map((tool) => tool.name));
  const wave7Names = new Set(WAVE7_TOOLS.map((tool) => tool.name));

  for (const name of wave8Names) {
    assert.equal(wave8ServedNames.has(name), true, `${name} should be served to Wave 8 clients`);
    assert.equal(wave7Names.has(name), false, `${name} should not leak to Wave 7 clients`);
  }

  const group = TOOLS.find((tool) => tool.name === "update_group");
  assert.deepEqual(group.input_schema.required, ["group_id", "expected_revision_token"]);
  assert.deepEqual(group.input_schema.properties.repetition.properties.type.enum, ["once", "count", "until"]);
  assert.deepEqual(group.input_schema.properties.cadence.properties.scope.enum, ["child", "cycle"]);
  assert.deepEqual(group.input_schema.properties.phase.enum, ["warmup", "main", "cooldown", "transition", null]);
  assert.deepEqual(group.input_schema.properties.dose.enum, ["med", "hpl", "mdv", null]);
  assert.deepEqual(group.input_schema.properties.total_targets.type, ["object", "null"]);
  assert.deepEqual(group.input_schema.properties.adjustments.type, ["array", "null"]);
  assert.match(group.description, /can't be cleared/i);

  const choice = TOOLS.find((tool) => tool.name === "update_choice");
  assert.deepEqual(choice.input_schema.required, ["choice_id", "expected_revision_token"]);
  assert.equal(choice.input_schema.properties.selection_count.minimum, 1);
  assert.match(choice.description, /1 and the choice's option count/i);

  const convert = TOOLS.find((tool) => tool.name === "convert_choice_to_group");
  assert.deepEqual(convert.input_schema.required, ["choice_id", "expected_revision_token"]);
  assert.match(convert.description, /required ordered group/i);
  assert.match(convert.description, /undo_workout_mutation/i);

  const rest = TOOLS.find((tool) => tool.name === "update_rest");
  assert.deepEqual(rest.input_schema.required, ["rest_id", "expected_revision_token"]);
  assert.deepEqual(rest.input_schema.properties.placement.enum, [
    "inline", "betweenRepetitions", "afterEveryRepetition", "afterFinalRepetition",
  ]);
  assert.deepEqual(rest.input_schema.properties.duration_seconds.type, ["integer", "null"]);

  const addRest = TOOLS.find((tool) => tool.name === "add_rest");
  assert.deepEqual(addRest.input_schema.required, ["parent_id", "expected_revision_token"]);
  assert.match(addRest.description, /can't be a choice option/i);

  const moveNode = TOOLS.find((tool) => tool.name === "move_node");
  assert.deepEqual(moveNode.input_schema.required, [
    "node_id", "to_parent_id", "to_index", "expected_revision_token",
  ]);
  assert.match(moveNode.description, /never move into itself or its own subtree/i);
  assert.match(moveNode.description, /rest can't become a choice option/i);
  assert.match(moveNode.description, /only option can't be moved out/i);

  const removeNode = TOOLS.find((tool) => tool.name === "remove_node");
  assert.deepEqual(removeNode.input_schema.required, ["node_id", "expected_revision_token"]);
  assert.match(removeNode.description, /purged through the logged-work safeguard/i);
  assert.match(removeNode.description, /undo restores/i);

  const addAlternative = TOOLS.find((tool) => tool.name === "add_set_alternative");
  assert.deepEqual(addAlternative.input_schema.required, ["set_id", "label", "expected_revision_token"]);
  const updateAlternative = TOOLS.find((tool) => tool.name === "update_set_alternative");
  assert.deepEqual(updateAlternative.input_schema.required, ["alternative_id", "expected_revision_token"]);
  assert.deepEqual(updateAlternative.input_schema.properties.values.type, ["object", "null"]);
  const removeAlternative = TOOLS.find((tool) => tool.name === "remove_set_alternative");
  assert.deepEqual(removeAlternative.input_schema.required, ["alternative_id", "expected_revision_token"]);

  const prescription = TOOLS.find((tool) => tool.name === "update_exercise_prescription");
  assert.deepEqual(prescription.input_schema.required, ["exercise_instance_id", "expected_revision_token"]);
  assert.deepEqual(prescription.input_schema.properties.target_zone.type, ["integer", "null"]);
  assert.equal(prescription.input_schema.properties.target_zone.maximum, 5);
  const targetTypes = prescription.input_schema.properties.intensity_targets.items.properties.type.enum;
  assert.deepEqual(targetTypes, [
    "heartRateZone", "rpe", "pace", "power", "thresholdPercentage", "namedZone", "descriptive",
  ]);
  assert.deepEqual(
    prescription.input_schema.properties.intensity_targets.items.properties.unit.enum,
    ["watts"]
  );

  // update_set gained progressions in Wave 8.
  const updateSet = TOOLS.find((tool) => tool.name === "update_set");
  const progressions = updateSet.input_schema.properties.patch.properties.progressions;
  assert.deepEqual(progressions.type, ["array", "null"]);
  assert.deepEqual(progressions.items.properties.unit.enum, ["set", "round", "interval", "cycle"]);

  // The batch accepts every Wave 8 op for Wave 8 clients.
  const batch = TOOLS.find((tool) => tool.name === "apply_workout_edits");
  const opNames = batch.input_schema.properties.operations.items.properties.op.enum;
  for (const name of wave8Names) {
    assert.equal(opNames.includes(name), true, `${name} should be batch-eligible`);
  }

  assert.equal(toolsForClientSchema("8"), WAVE8_TOOLS);
  assert.equal(servedToolsetForClientSchema("8"), "wave8");
});

test("Wave 9 custom exercise creation is two-phase, taxonomy-complete, and capability-gated", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "create_custom_exercise");

  assert.ok(tool);
  // The manual create form's required set: name, equipment, primary muscle, at least one metric.
  assert.deepEqual(tool.input_schema.required, [
    "name", "equipment", "primary_muscles", "metrics", "expected_revision_token",
  ]);
  assert.equal(tool.input_schema.properties.equipment.minItems, 1);
  assert.equal(tool.input_schema.properties.primary_muscles.minItems, 1);
  assert.equal(tool.input_schema.properties.metrics.minItems, 1);
  assert.equal(tool.input_schema.properties.patterns.maxItems, 2);
  assert.ok(tool.input_schema.properties.proposal_id);
  // Taxonomy axes are closed enums so the model cannot invent classification values.
  for (const axis of ["equipment", "primary_muscles", "secondary_muscles", "metrics", "patterns", "tags"]) {
    assert.ok(Array.isArray(tool.input_schema.properties[axis].items.enum), `${axis} must be a closed enum`);
  }
  assert.deepEqual(tool.input_schema.properties.equipment.items.enum, [
    "bodyweight", "barbell", "barbellPlates", "ezBar", "trapBar", "dumbbell", "kettlebell",
    "medicineBall", "machine", "cable", "sled", "sandbag", "box", "bench", "band", "rope",
    "jumpRope", "pullUpBar", "exerciseBall", "bosuBall", "hangboard", "bike", "rower",
    "skiErg", "treadmill", "stairStepper", "elliptical", "other",
  ]);
  const expectedMuscles = [
    "chest", "lats", "upperBack", "traps", "lowerBack", "frontDelts", "sideDelts",
    "rearDelts", "biceps", "triceps", "forearms", "abdominals", "obliques", "glutes",
    "quadriceps", "hamstrings", "adductors", "abductors", "calves", "hipFlexors", "neck",
    "fullBody",
  ];
  assert.deepEqual(tool.input_schema.properties.primary_muscles.items.enum, expectedMuscles);
  assert.deepEqual(tool.input_schema.properties.secondary_muscles.items.enum, expectedMuscles);
  assert.deepEqual(tool.input_schema.properties.metrics.items.enum, [
    "reps", "load", "duration", "distance", "pace", "power", "calories", "cadence",
    "heartRate", "heartRateZoneTime", "rpe",
  ]);
  assert.deepEqual(tool.input_schema.properties.patterns.items.enum, [
    "squat", "hinge", "lunge", "push", "pull", "carry", "rotation", "gait", "hold",
  ]);
  assert.deepEqual(tool.input_schema.properties.tags.items.enum, [
    "hyrox", "crossFit", "powerlifting", "olympicWeightlifting", "strongman", "calisthenics",
    "plyometric", "running", "cycling", "rowing", "conditioning", "warmUp", "coolDown",
    "mobility", "rehab", "unilateral",
  ]);
  assert.deepEqual(tool.input_schema.properties.level.enum, ["beginner", "intermediate", "expert"]);
  // Units-bearing future defaults reuse the display-unit vocabulary.
  assert.deepEqual(tool.input_schema.properties.distance_unit.enum, ["m", "km", "mi"]);
  assert.deepEqual(tool.input_schema.properties.load_unit.enum, ["kg", "lb"]);
  // The two-phase confirmation contract is spelled out.
  assert.match(tool.description, /TWO-PHASE/);
  assert.match(tool.description, /nothing is created/i);
  assert.match(tool.description, /never silently commit a classification you inferred/i);
  assert.match(tool.description, /search_exercises FIRST/);

  // Gating: Wave 9 clients only. No older toolset may serve it, and it is not batch-eligible.
  for (const [label, toolset] of [
    ["wave8", WAVE8_TOOLS], ["wave7", WAVE7_TOOLS], ["wave6", WAVE6_TOOLS],
    ["wave5", WAVE5_TOOLS], ["legacy", LEGACY_TOOLS],
  ]) {
    assert.equal(
      toolset.some((candidate) => candidate.name === "create_custom_exercise"),
      false,
      `create_custom_exercise should not leak to ${label} clients`
    );
  }
  const batchOps = TOOLS.find((candidate) => candidate.name === "apply_workout_edits")
    .input_schema.properties.operations.items.properties.op.enum;
  assert.equal(batchOps.includes("create_custom_exercise"), false);

  assert.equal(toolsForClientSchema("9"), TOOLS);
  assert.equal(servedToolsetForClientSchema("9"), "wave9");
});

test("Wave 7 and older clients keep exactly the schemas their mappers understand", () => {
  // add_exercise: no nested parent target before Wave 8.
  const wave7AddExercise = WAVE7_TOOLS.find((tool) => tool.name === "add_exercise");
  assert.deepEqual(wave7AddExercise.input_schema.required, ["block_id", "name", "expected_revision_token"]);
  assert.equal(wave7AddExercise.input_schema.properties.parent_id, undefined);
  assert.equal(wave7AddExercise.input_schema.oneOf, undefined);

  // update_set: no progressions before Wave 8.
  const wave7UpdateSet = WAVE7_TOOLS.find((tool) => tool.name === "update_set");
  assert.equal(wave7UpdateSet.input_schema.properties.patch.properties.progressions, undefined);
  const wave6UpdateSet = WAVE6_TOOLS.find((tool) => tool.name === "update_set");
  assert.equal(wave6UpdateSet.input_schema.properties.patch.properties.progressions, undefined);

  // apply_workout_edits: the op enum stays the Wave 7 list.
  const wave7Batch = WAVE7_TOOLS.find((tool) => tool.name === "apply_workout_edits");
  const wave7Ops = wave7Batch.input_schema.properties.operations.items.properties.op.enum;
  assert.equal(wave7Ops.includes("update_group"), false);
  assert.equal(wave7Ops.includes("move_node"), false);
  assert.equal(wave7Ops.includes("update_set"), true);

  // The Wave 8 upgrades never mutate the shared base schemas.
  const wave8AddExercise = TOOLS.find((tool) => tool.name === "add_exercise");
  assert.ok(wave8AddExercise.input_schema.properties.parent_id);
  const wave8Batch = TOOLS.find((tool) => tool.name === "apply_workout_edits");
  assert.equal(
    wave8Batch.input_schema.properties.operations.items.properties.op.enum.includes("update_group"),
    true
  );
});

// The PR #59 regression test ("no served toolset carries a top-level schema combinator the
// Anthropic API rejects") moved into test/toolSchemaContract.test.js, whose enforced-profile
// lint covers top-level combinators plus the rest of the documented safe subset across every
// served toolset variant. See docs/tool-schema-contract.md.

const test = require("node:test");
const assert = require("node:assert/strict");
const { TOOLS } = require("../lib/tools");

test("replace_exercise is an atomic duplicate-safe tool", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "replace_exercise");

  assert.ok(tool);
  assert.deepEqual(tool.input_schema.required, ["exercise", "replacement", "expected_revision_token"]);
  assert.equal(tool.input_schema.properties.replace_all.type, "boolean");
  assert.equal(tool.input_schema.properties.block.type, "string");
  assert.match(tool.description, /never simulate replacement/i);
});

test("workout tools expose stable ID targeting", () => {
  const currentWorkout = TOOLS.find((candidate) => candidate.name === "get_current_workout");
  assert.ok(currentWorkout);
  assert.match(currentWorkout.description, /stable ids/i);
  assert.match(currentWorkout.description, /block, exercise instance, and set/i);

  const legacyTargetFields = {
    move_exercise: ["exercise_id", "to_block_id"],
    replace_exercise: ["exercise_id"],
    remove_exercise: ["exercise_id"],
  };

  for (const [name, fields] of Object.entries(legacyTargetFields)) {
    const tool = TOOLS.find((candidate) => candidate.name === name);
    assert.ok(tool, `${name} should exist`);
    for (const field of fields) {
      assert.equal(tool.input_schema.properties[field].type, "string", `${name}.${field}`);
      assert.match(tool.input_schema.properties[field].description, /get_current_workout/i);
      assert.match(tool.input_schema.properties[field].description, /takes precedence/i);
      assert.equal(tool.input_schema.required.includes(field), false, `${name}.${field} stays optional`);
    }
  }

  assert.deepEqual(
    TOOLS.find((candidate) => candidate.name === "remove_exercise").input_schema.required,
    ["exercise", "expected_revision_token"]
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

  assert.ok(logging.input_schema.properties.pace_unit);
  assert.match(logging.input_schema.properties.pace_unit.description, /\/km/);
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
    "add_exercise",
    "move_exercise",
    "replace_exercise",
    "remove_exercise",
    "require_all_options",
    "add_set",
    "update_set",
    "remove_set",
    "move_set",
    "duplicate_set",
    "update_logging_config",
    "set_metric_value",
    "remove_metric",
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
  assert.deepEqual(Object.keys(workout.input_schema.properties).sort(), [
    "expected_revision_token", "goal", "guidance", "title",
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
    workout.input_schema.properties.goal,
    workout.input_schema.properties.guidance,
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

test("tool names are unique and map to the on-device executor", () => {
  const names = TOOLS.map((tool) => tool.name);
  assert.equal(new Set(names).size, names.length);
  assert.ok(names.includes("search_exercises"));
  assert.ok(names.includes("get_exercise"));
  assert.ok(names.includes("update_workout_metadata"));
  assert.ok(names.includes("update_block_metadata"));
  assert.ok(names.includes("update_exercise_metadata"));
});

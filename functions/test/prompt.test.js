const test = require("node:test");
const assert = require("node:assert/strict");
const { buildSystem, buildSystemBlocks } = require("../lib/prompt");
const {
  LEGACY_TOOLS,
  TOOLS,
  WAVE5_TOOLS,
  WAVE6_TOOLS,
  WAVE7_TOOLS,
  WAVE8_TOOLS,
  WAVE9_TOOLS,
} = require("../lib/tools");

const SERVED_PAIRS = [
  ["wave10", TOOLS],
  ["wave9", WAVE9_TOOLS],
  ["wave8", WAVE8_TOOLS],
  ["wave7", WAVE7_TOOLS],
  ["wave6", WAVE6_TOOLS],
  ["wave5", WAVE5_TOOLS],
  ["legacy", LEGACY_TOOLS],
];

test("each prompt variant names only tools its served schema actually contains", () => {
  const anyToolName = new Set([...TOOLS, ...LEGACY_TOOLS].map((tool) => tool.name));

  for (const [toolset, tools] of SERVED_PAIRS) {
    const prompt = buildSystem(toolset);
    const servedNames = new Set(tools.map((tool) => tool.name));
    const mentioned = prompt.match(/[a-z][a-z0-9]*(?:_[a-z0-9]+)+/g) ?? [];

    assert.doesNotMatch(prompt, /\{\{/, `${toolset} prompt has an unresolved slot`);
    for (const token of mentioned) {
      if (!anyToolName.has(token)) continue;   // field name, not a tool
      assert.equal(servedNames.has(token), true, `${toolset} prompt names unserved tool ${token}`);
    }
  }
});

test("Wave 5 prompt teaches the ID-targeted structure contract", () => {
  const prompt = buildSystem("wave5");

  for (const name of ["remove_block", "move_block", "duplicate_block", "reorder_exercise", "duplicate_exercise"]) {
    assert.match(prompt, new RegExp(name), `wave5 prompt must list ${name}`);
  }
  assert.match(prompt, /add_exercise always requires a block_id/);
  assert.match(prompt, /replace_exercise with the target's exercise_instance_id/);
  assert.match(prompt, /call replace_exercise once per instance/);
  assert.doesNotMatch(prompt, /replace_all/);
  assert.doesNotMatch(prompt, /human-readable fallback/);
  assert.doesNotMatch(prompt, /any block name goes there/);
});

test("Wave 6 prompt teaches performed logging without rewriting the plan", () => {
  const prompt = buildSystem("wave6");

  for (const name of [
    "get_active_session",
    "upsert_performed_set",
    "set_performed_set_outcome",
    "add_extra_performed_set",
    "update_extra_performed_set",
    "delete_extra_performed_set",
    "add_exercise_session_note",
    "undo_session_mutation",
  ]) {
    assert.match(prompt, new RegExp(name), `wave6 prompt must list ${name}`);
  }
  assert.match(prompt, /actual work/i);
  assert.match(prompt, /performed log/i);
  assert.match(prompt, /never call update_set/i);
  assert.match(prompt, /value_text/i);
  assert.match(prompt, /185 lb/i);
  assert.match(prompt, /1:19 per 400 m/i);

  for (const toolset of ["wave5", "legacy"]) {
    assert.doesNotMatch(buildSystem(toolset), /upsert_performed_set/);
  }
});

test("Wave 7 prompt teaches the atomic batch and dry-run-then-apply bulk contract", () => {
  const prompt = buildSystem("wave7");

  for (const name of ["apply_workout_edits", "convert_workout_units", "bulk_replace_exercises"]) {
    assert.match(prompt, new RegExp(name), `wave7 prompt must list ${name}`);
  }
  assert.match(prompt, /all-or-nothing/i);
  assert.match(prompt, /NOTHING changed/);
  assert.match(prompt, /ONE receipt \(one undo\)/);
  assert.match(prompt, /\{"op": "<single tool name>"/);
  assert.match(prompt, /canonical stored values never change/i);
  assert.match(prompt, /duplicates included/i);
  assert.match(prompt, /dry_run true first/);
  assert.match(prompt, /"all runs" NEVER decides itself/);
  assert.match(prompt, /confirm with the athlete/i);
  assert.match(prompt, /without catalog identity never match/i);
  // The performed-log contract survives alongside the batch guidance.
  assert.match(prompt, /upsert_performed_set/);

  for (const toolset of ["wave6", "wave5", "legacy"]) {
    const older = buildSystem(toolset);
    assert.doesNotMatch(older, /apply_workout_edits/, `${toolset} must not advertise the batch tool`);
    assert.doesNotMatch(older, /convert_workout_units/);
    assert.doesNotMatch(older, /bulk_replace_exercises/);
  }
});

test("legacy prompt matches the capability-gated name-based schema", () => {
  const prompt = buildSystem("legacy");

  assert.match(prompt, /replace_all=true and omit exercise_id/);
  assert.match(prompt, /any block name goes there/);
  assert.match(prompt, /human-readable fallback/);
  assert.doesNotMatch(prompt, /add_exercise always requires a block_id/);
});

test("shared guidance and the state block survive in both variants", () => {
  for (const [toolset] of SERVED_PAIRS) {
    const prompt = buildSystem(toolset, "  athlete state here  ");
    assert.match(prompt, /You are Baseline/);
    assert.match(prompt, /expected_revision_token/);
    assert.match(prompt, /MUTATION RECEIPT/);
    assert.match(prompt, /Today's current state \(from the engine\):\nathlete state here$/);
    assert.equal(buildSystem(toolset).includes("Today's current state (from the engine):"), false);
  }
});

// The block split is what prompt caching hangs on: the persona is identical across requests for a
// toolset (cacheable), the athlete state changes between rounds (never cacheable). Marking the
// state block cacheable would invalidate the whole cached prefix on every state change.
test("system blocks separate the cacheable persona from the volatile athlete state", () => {
  for (const [toolset] of SERVED_PAIRS) {
    const blocks = buildSystemBlocks(toolset, "  athlete state here  ");
    assert.equal(blocks.length, 2);
    assert.equal(blocks[0].cacheable, true);
    assert.match(blocks[0].text, /^You are Baseline/);
    assert.equal(blocks[1].cacheable, false);
    assert.equal(blocks[1].text, "Today's current state (from the engine):\nathlete state here");

    const withoutContext = buildSystemBlocks(toolset);
    assert.equal(withoutContext.length, 1);
    assert.equal(withoutContext[0].cacheable, true);

    // buildSystem stays the joined view of the same blocks, so scripts and the token fixture
    // measure exactly what the runtime sends.
    assert.equal(buildSystem(toolset, "  athlete state here  "), blocks.map((b) => b.text).join("\n\n"));
  }
});

test("Wave 8 prompt teaches advanced node editing and canonical prescription units", () => {
  const prompt = buildSystem("wave8");

  for (const name of [
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
  ]) {
    assert.match(prompt, new RegExp(name), `wave8 prompt must list ${name}`);
  }
  assert.match(prompt, /move_node is the ONE tool for restructuring/);
  assert.match(prompt, /never move into its own subtree/i);
  assert.match(prompt, /only option can neither move out nor be removed/i);
  assert.match(prompt, /rest can never be a choice option/i);
  assert.match(prompt, /CANONICAL values \(kg, meters, seconds\)/);
  assert.match(prompt, /progressions/);
  assert.match(prompt, /selection_count/);
  // The batch and performed-log contracts survive alongside the node guidance.
  assert.match(prompt, /apply_workout_edits/);
  assert.match(prompt, /upsert_performed_set/);

  for (const toolset of ["wave7", "wave6", "wave5", "legacy"]) {
    const older = buildSystem(toolset);
    assert.doesNotMatch(older, /move_node/, `${toolset} must not advertise move_node`);
    assert.doesNotMatch(older, /update_group/);
    assert.doesNotMatch(older, /update_exercise_prescription/);
    assert.doesNotMatch(older, /add_set_alternative/);
  }
});

test("Wave 9 and 10 prompts teach identical deliberate two-phase custom exercise creation", () => {
  const prompt = buildSystem("wave9");
  assert.equal(buildSystem("wave10"), prompt);

  assert.match(prompt, /create_custom_exercise/);
  assert.match(prompt, /TWO-PHASE/);
  assert.match(prompt, /proposal_id/);
  assert.match(prompt, /creates nothing/i);
  assert.match(prompt, /never silently commit a guessed classification/i);
  assert.match(prompt, /anything YOU inferred counts as unstated/);
  assert.match(prompt, /Search first/i);
  assert.match(prompt, /immediately addable by its exact name/);
  // The units-bearing future defaults ride the same display-unit vocabulary.
  assert.match(prompt, /distance_unit \/ load_unit \/ duration_unit \/ pace_unit/);
  // The full Wave 8 editing surface survives alongside the creation guidance.
  assert.match(prompt, /move_node is the ONE tool for restructuring/);
  assert.match(prompt, /apply_workout_edits/);
  assert.match(prompt, /upsert_performed_set/);

  for (const toolset of ["wave8", "wave7", "wave6", "wave5", "legacy"]) {
    assert.doesNotMatch(
      buildSystem(toolset),
      /create_custom_exercise/,
      `${toolset} must not advertise create_custom_exercise`
    );
  }
});

const test = require("node:test");
const assert = require("node:assert/strict");
const { buildSystem } = require("../lib/prompt");
const { LEGACY_TOOLS, TOOLS, WAVE5_TOOLS } = require("../lib/tools");

const SERVED_PAIRS = [
  ["wave6", TOOLS],
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

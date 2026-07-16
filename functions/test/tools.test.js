const test = require("node:test");
const assert = require("node:assert/strict");
const { TOOLS } = require("../lib/tools");

test("replace_exercise is an atomic duplicate-safe tool", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "replace_exercise");

  assert.ok(tool);
  assert.deepEqual(tool.input_schema.required, ["exercise", "replacement"]);
  assert.equal(tool.input_schema.properties.replace_all.type, "boolean");
  assert.equal(tool.input_schema.properties.block.type, "string");
  assert.match(tool.description, /never simulate replacement/i);
});

test("require_all_options preserves an imported choice's children", () => {
  const tool = TOOLS.find((candidate) => candidate.name === "require_all_options");

  assert.ok(tool);
  assert.deepEqual(tool.input_schema.required, ["choice"]);
  assert.match(tool.description, /required ordered group/i);
  assert.match(tool.description, /preserves the child exercises/i);
});

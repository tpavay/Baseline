const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
  INPUT_FORMAT_VERSION,
  buildMeasurementInputs,
  diffFixtures,
  measureInputs,
  validateMeasurementInputs,
} = require("../scripts/measure-tool-schema-tokens");
const { SERVED_TOOLSETS } = require("../lib/tools");

test("feature-branch measurement inputs export without reading a provider key", () => {
  const originalKey = process.env.ANTHROPIC_API_KEY;
  process.env.ANTHROPIC_API_KEY = "must-not-appear-in-export";
  try {
    const inputs = buildMeasurementInputs();
    const serialized = JSON.stringify(inputs);

    assert.equal(inputs.version, INPUT_FORMAT_VERSION);
    assert.deepEqual(Object.keys(inputs.conversation), Object.keys(SERVED_TOOLSETS));
    assert.equal(inputs.attributionToolset, Object.keys(SERVED_TOOLSETS)[0]);
    assert.equal(inputs.import.durable.tools.length, 1);
    assert.equal(inputs.import.sketch.tools.length, 1);
    assert.doesNotMatch(serialized, /must-not-appear-in-export/);
    assert.equal(Object.hasOwn(inputs, "apiKey"), false);

    for (const [name, tools] of Object.entries(SERVED_TOOLSETS)) {
      assert.equal(inputs.conversation[name].tools.length, tools.length);
      assert.ok(inputs.conversation[name].system.length > 0);
    }
  } finally {
    if (originalKey === undefined) {
      delete process.env.ANTHROPIC_API_KEY;
    } else {
      process.env.ANTHROPIC_API_KEY = originalKey;
    }
  }
});

test("trusted measurement turns exported request shapes into the runtime fixture", async () => {
  const inputs = buildMeasurementInputs();
  const calls = [];
  const counter = async (system, tools) => {
    calls.push({ system, tools });
    return 100 + Buffer.byteLength(system) + Buffer.byteLength(JSON.stringify(tools));
  };

  const measured = await measureInputs(inputs, counter);
  const requestShapeCount =
    Object.keys(inputs.conversation).length + Object.keys(inputs.import).length;
  const richestToolCount = inputs.conversation[inputs.attributionToolset].tools.length;

  assert.equal(measured.model, inputs.model);
  assert.equal(calls.length, requestShapeCount * 2 + richestToolCount);
  assert.deepEqual(
    Object.keys(measured.conversationTools).sort(),
    inputs.conversation[inputs.attributionToolset].tools.map((tool) => tool.name).sort(),
  );
  for (const shape of [
    ...Object.values(measured.conversation),
    ...Object.values(measured.import),
  ]) {
    assert.equal(shape.promptWithToolsTokens, shape.promptTokens + shape.toolSchemaTokens);
    assert.ok(shape.toolSchemaTokens > 0);
  }
});

test("fixture comparison passes exact measurements and reports stale values", async () => {
  const inputs = buildMeasurementInputs();
  const counter = async (system, tools) =>
    100 + Buffer.byteLength(system) + Buffer.byteLength(JSON.stringify(tools));
  const measured = await measureInputs(inputs, counter);
  const stale = structuredClone(measured);

  assert.deepEqual(diffFixtures(measured, structuredClone(measured)), []);

  stale.conversation[inputs.attributionToolset].toolSchemaTokens += 1;
  assert.deepEqual(diffFixtures(stale, measured), [
    `  conversation.${inputs.attributionToolset}.toolSchemaTokens: ` +
      `committed ${stale.conversation[inputs.attributionToolset].toolSchemaTokens} -> ` +
      `measured ${measured.conversation[inputs.attributionToolset].toolSchemaTokens}`,
  ]);
});

test("trusted measurement rejects malformed feature-branch artifacts", () => {
  const inputs = buildMeasurementInputs();
  inputs.conversation[inputs.attributionToolset].tools[0].name = "unsafe\n::workflow-command::";

  assert.throws(
    () => validateMeasurementInputs(inputs),
    /contains an invalid tool name/,
  );
});

test("regeneration workflow keeps the secret in a read-only trusted job", () => {
  const workflowPath = path.join(
    __dirname,
    "..",
    "..",
    ".github",
    "workflows",
    "regenerate-tool-schema-token-fixture.yml",
  );
  const workflow = fs.readFileSync(workflowPath, "utf8");

  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.doesNotMatch(workflow, /contents:\s*write/);
  assert.doesNotMatch(workflow, /pull_request_target/);
  assert.doesNotMatch(workflow, /\brun:\s*git push\b/);
  assert.match(workflow, /if \[\[ "\$TARGET_BRANCH" == "\$DEFAULT_BRANCH" \]\]/);
  assert.match(workflow, /if \[\[ "\$WORKFLOW_BRANCH" != "\$DEFAULT_BRANCH" \]\]/);
  assert.match(
    workflow,
    /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/,
  );
  assert.match(workflow, /--export-inputs/);
  assert.match(workflow, /--measure-inputs/);
  assert.equal(
    workflow.match(/ANTHROPIC_API_KEY: \$\{\{ secrets\.ANTHROPIC_API_KEY \}\}/g)?.length,
    1,
  );
  assert.ok(
    workflow.indexOf("measure:\n") <
      workflow.indexOf("ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}"),
  );
});

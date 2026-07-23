// The offline tool-schema contract gate (docs/tool-schema-contract.md).
//
// This file supersedes and absorbs the PR #59 regression test ("no served toolset carries a
// top-level schema combinator the Anthropic API rejects") that used to live in tools.test.js:
// the enforced-profile lint rejects top-level oneOf/anyOf/allOf/not plus every other construct
// outside the documented safe subset, across every served toolset variant. The CI real-provider
// preflight (scripts/preflight-tool-schemas.js) is the ground truth this lint approximates.
const test = require("node:test");
const assert = require("node:assert/strict");

const {
  ANTHROPIC_PROFILE,
  CROSS_PROVIDER_CORE_PROFILE,
  ENFORCED_PROFILES,
  crossProviderAdvisories,
  enforcedViolations,
  lintToolSchema,
} = require("../lib/toolSchemaContract");
const { SERVED_TOOLSETS, toolsForClientSchema } = require("../lib/tools");

function formatFindings(findings) {
  return findings
    .map((f) => `[${f.profile}] ${f.toolset} → ${f.tool} @ ${f.path || "(top level)"}: ${f.message}`)
    .join("\n");
}

test("every served toolset variant conforms to every enforced provider profile", () => {
  const violations = enforcedViolations();
  assert.equal(
    violations.length,
    0,
    `tool schemas violate the enforced provider contract - a conversation request carrying them ` +
    `would be rejected before the model runs:\n${formatFindings(violations)}`
  );
});

test("every client schema version resolves to a toolset covered by the contract lint", () => {
  // The lint iterates SERVED_TOOLSETS; this pins that the runtime cannot serve anything else,
  // including for garbage or missing client versions.
  const known = new Set(Object.values(SERVED_TOOLSETS));
  for (const version of ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", undefined, null, "garbage"]) {
    assert.equal(
      known.has(toolsForClientSchema(version)),
      true,
      `toolsForClientSchema(${String(version)}) returned a toolset the contract lint does not cover`
    );
  }
});

// The exact class of schema that took down every conversation in 2026-07: a top-level
// combinator expressing "planned target XOR performed_set_id". The mapper backstop from
// PR #59 still exists; this pins that the lint rejects it long before any request is sent.
test("the pre-#59 top-level oneOf schema is rejected by the lint", () => {
  const regression = {
    name: "set_performed_set_outcome",
    description: "regression replica",
    input_schema: {
      type: "object",
      properties: {
        performed_set_id: { type: "string" },
        exercise_instance_id: { type: "string" },
        planned_set_id: { type: "string" },
        outcome: { type: "string", enum: ["pending", "completed", "skipped"] },
        expected_revision_token: { type: "string" },
      },
      required: ["outcome", "expected_revision_token"],
      oneOf: [
        { required: ["performed_set_id"] },
        { required: ["exercise_instance_id", "planned_set_id"] },
      ],
      additionalProperties: false,
    },
  };
  const findings = lintToolSchema(regression, ANTHROPIC_PROFILE);
  assert.equal(findings.length, 1, formatFindings(findings));
  assert.equal(findings[0].keyword, "oneOf");
  assert.match(findings[0].message, /top level/);
});

test("every top-level combinator is rejected by every enforced profile", () => {
  for (const profile of ENFORCED_PROFILES) {
    for (const banned of ["oneOf", "anyOf", "allOf", "not"]) {
      const tool = {
        name: "combinator_probe",
        description: "probe",
        input_schema: {
          type: "object",
          properties: { a: { type: "string" } },
          [banned]: banned === "not" ? { required: ["a"] } : [{ required: ["a"] }],
        },
      };
      const findings = lintToolSchema(tool, profile);
      assert.equal(findings.length, 1, `${profile.id} should reject top-level ${banned}`);
      assert.equal(findings[0].keyword, banned);
    }
  }
});

test("nested combinators the Anthropic API accepts still pass the anthropic profile", () => {
  // #59's fix deliberately relies on schema-form dependencies with nested `not`; the enforced
  // profile must keep accepting exactly that shape.
  const tool = {
    name: "nested_probe",
    description: "probe",
    input_schema: {
      type: "object",
      properties: {
        a: { type: "string" },
        b: { anyOf: [{ type: "string" }, { type: "integer" }] },
      },
      dependencies: { a: { not: { required: ["b"] } } },
    },
  };
  assert.deepEqual(lintToolSchema(tool, ANTHROPIC_PROFILE), []);
});

test("known-risky constructs are each rejected with a documented reason", () => {
  const cases = [
    { keyword: "$ref", schema: { type: "object", properties: { a: { $ref: "#/$defs/x" } } } },
    { keyword: "$defs", schema: { type: "object", properties: {}, $defs: { x: { type: "string" } } } },
    { keyword: "definitions", schema: { type: "object", properties: {}, definitions: { x: { type: "string" } } } },
    { keyword: "if", schema: { type: "object", properties: {}, if: { required: ["a"] } } },
    { keyword: "then", schema: { type: "object", properties: {}, then: { required: ["b"] } } },
    { keyword: "else", schema: { type: "object", properties: {}, else: { required: ["c"] } } },
    { keyword: "dependentSchemas", schema: { type: "object", properties: {}, dependentSchemas: { a: { required: ["b"] } } } },
    { keyword: "dependentRequired", schema: { type: "object", properties: {}, dependentRequired: { a: ["b"] } } },
    { keyword: "patternProperties", schema: { type: "object", properties: {}, patternProperties: { "^x": { type: "string" } } } },
    { keyword: "propertyNames", schema: { type: "object", properties: {}, propertyNames: { minLength: 1 } } },
    { keyword: "prefixItems", schema: { type: "object", properties: { a: { type: "array", prefixItems: [{ type: "string" }] } } } },
    { keyword: "format", schema: { type: "object", properties: { a: { type: "string", format: "date-time" } } } },
    { keyword: "pattern", schema: { type: "object", properties: { a: { type: "string", pattern: "^x$" } } } },
    { keyword: "const", schema: { type: "object", properties: { a: { const: "x" } } } },
    { keyword: "contains", schema: { type: "object", properties: { a: { type: "array", contains: { type: "string" } } } } },
    { keyword: "unevaluatedProperties", schema: { type: "object", properties: {}, unevaluatedProperties: false } },
  ];
  for (const { keyword, schema } of cases) {
    const findings = lintToolSchema({ name: "probe", description: "probe", input_schema: schema }, ANTHROPIC_PROFILE);
    assert.equal(findings.length >= 1, true, `expected a finding for ${keyword}`);
    const finding = findings.find((f) => f.keyword === keyword);
    assert.ok(finding, `finding should be attributed to ${keyword}`);
    // Every known-risky construct must explain WHY it is unsafe, not just that it is banned.
    assert.equal(finding.message.includes("not in the documented safe subset"), false,
      `${keyword} should carry its documented rationale, not the generic fallback`);
  }
});

test("structural hazards are rejected: tuple items, schema-form additionalProperties, non-object root", () => {
  const tupleItems = lintToolSchema({
    name: "probe",
    description: "probe",
    input_schema: { type: "object", properties: { a: { type: "array", items: [{ type: "string" }, { type: "integer" }] } } },
  }, ANTHROPIC_PROFILE);
  assert.equal(tupleItems.length, 1);
  assert.match(tupleItems[0].message, /tuple-form items/);

  const schemaFormAdditional = lintToolSchema({
    name: "probe",
    description: "probe",
    input_schema: { type: "object", properties: {}, additionalProperties: { type: "string" } },
  }, ANTHROPIC_PROFILE);
  assert.equal(schemaFormAdditional.length, 1);
  assert.equal(schemaFormAdditional[0].keyword, "additionalProperties");

  const nonObjectRoot = lintToolSchema({
    name: "probe",
    description: "probe",
    input_schema: { type: "string" },
  }, ANTHROPIC_PROFILE);
  assert.equal(nonObjectRoot.length, 1);
  assert.match(nonObjectRoot[0].message, /type "object" at the top level/);
});

test("unknown future keywords fail by default - the subset is an allowlist, not a blocklist", () => {
  const findings = lintToolSchema({
    name: "probe",
    description: "probe",
    input_schema: { type: "object", properties: {}, someFutureKeyword: true },
  }, ANTHROPIC_PROFILE);
  assert.equal(findings.length, 1);
  assert.equal(findings[0].keyword, "someFutureKeyword");
  assert.match(findings[0].message, /not in the documented safe subset/);
});

test("cross-provider advisories are pinned - new provider-fragile constructs are a deliberate choice", () => {
  // Constructs Anthropic accepts today (the preflight proves it) but that sit outside the
  // conservative cross-provider core. Adding a tool that grows this map is allowed, but must be
  // done consciously: update this pin AND docs/tool-schema-contract.md's fragility table.
  const advisories = crossProviderAdvisories();
  const byKeyword = {};
  for (const finding of advisories) {
    byKeyword[finding.keyword] = byKeyword[finding.keyword] ?? new Set();
    byKeyword[finding.keyword].add(finding.tool);
  }
  const snapshot = Object.fromEntries(
    Object.entries(byKeyword)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([keyword, tools]) => [keyword, [...tools].sort()])
  );
  assert.deepEqual(snapshot, {
    // Schema-form dependencies (with nested `not`) are #59's chosen mutual-exclusion encoding.
    // OpenAI-style strict validators ignore them; Gemini's proto schema rejects them.
    dependencies: [
      "add_exercise",
      "add_extra_performed_set",
      "set_performed_set_outcome",
      "upsert_performed_set",
    ],
    // minProperties has no equivalent in Gemini's FunctionDeclaration schema.
    minProperties: [
      "bulk_replace_exercises",
      "convert_workout_units",
      "update_block_metadata",
      "update_choice",
      "update_exercise_metadata",
      "update_exercise_prescription",
      "update_group",
      "update_rest",
      "update_set",
      "update_set_alternative",
      "update_workout_metadata",
    ],
    // ["X","null"] type unions (nullable clear-semantics); Gemini expresses this as `nullable`.
    type: [
      "set_checkin",
      "set_equipment",
      "set_sleep",
      "set_time_available",
      "update_block_metadata",
      "update_exercise_metadata",
      "update_exercise_prescription",
      "update_group",
      "update_rest",
      "update_set",
      "update_set_alternative",
      "update_workout_metadata",
    ],
  });
});

test("the cross-provider core profile rejects the constructs the advisories track", () => {
  const tool = {
    name: "probe",
    description: "probe",
    input_schema: {
      type: "object",
      properties: { a: { type: ["string", "null"] } },
      dependencies: { a: { not: { required: ["b"] } } },
      minProperties: 1,
    },
  };
  const keywords = lintToolSchema(tool, CROSS_PROVIDER_CORE_PROFILE).map((f) => f.keyword).sort();
  assert.deepEqual(keywords, ["dependencies", "minProperties", "type"]);
});

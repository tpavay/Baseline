/**
 * The Baseline tool-schema contract: the conservative JSON-Schema subset every served tool
 * `input_schema` must stay inside so no provider can reject a conversation request at the
 * request-validation layer.
 *
 * Why this exists: in 2026-07 two tools (set_performed_set_outcome, add_exercise) shipped a
 * top-level `oneOf`. The Anthropic API rejects that with a 400 BEFORE the model runs, and
 * because every conversation request carries the full toolset, those two schemas took down
 * every conversation for every user served that toolset. The failure class is "a schema
 * construct a provider's request validator rejects", so the guard is an explicit ALLOWLIST:
 * any keyword not known-safe fails the lint, which means a new exotic construct - or one a
 * FUTURE provider rejects - cannot ship silently. See docs/tool-schema-contract.md.
 *
 * Three enforcement layers use this module:
 *  1. functions/test/toolSchemaContract.test.js - offline lint of every served toolset variant
 *     against every enforced provider profile (milliseconds, runs in `npm test`). This test
 *     supersedes and absorbs the original PR #59 "no top-level combinators" regression test.
 *  2. functions/scripts/preflight-tool-schemas.js - CI submits every served toolset variant to
 *     the real provider API and fails the build on rejection (the ground truth this lint
 *     approximates).
 *  3. Cross-provider advisories: constructs Anthropic accepts today but that sit outside the
 *     conservative cross-provider core are surfaced (and pinned in the test) so adding a new
 *     provider is "add its profile + run the preflight", not "discover breakage in production".
 */

import { SERVED_TOOLSETS, ToolSchema } from "./tools";

export interface SchemaFinding {
  profile: string;
  toolset: string;
  tool: string;
  /** Slash path into input_schema, e.g. "properties/values/items". "" is the top level. */
  path: string;
  keyword: string;
  message: string;
}

/**
 * One provider's (or the cross-provider core's) accepted subset. Adding a provider is adding a
 * profile here and appending it to ENFORCED_PROFILES - the lint, its tests, and the preflight
 * enumerate profiles; none of them needs a rewrite.
 */
export interface ProviderSchemaProfile {
  id: string;
  /** JSON-Schema keywords accepted anywhere in a tool input_schema. Everything else fails. */
  allowedKeywords: ReadonlySet<string>;
  /** Keywords rejected at the TOP LEVEL of input_schema even when allowed nested. */
  topLevelBannedKeywords: ReadonlySet<string>;
  /** Values `type` may take, as a string or a uniform array of these strings. */
  allowedTypes: ReadonlySet<string>;
  /** `format` values accepted. Only consulted when "format" is in allowedKeywords. */
  allowedFormats: ReadonlySet<string>;
  /** Whether `dependencies` entries may be full subschemas (vs only required-name arrays). */
  allowsSchemaFormDependencies: boolean;
}

/**
 * Why each known-risky construct is outside the safe subset. Used verbatim in lint messages so
 * a failure explains itself; the same rationale lives in docs/tool-schema-contract.md.
 */
export const RISKY_KEYWORD_RATIONALE: Readonly<Record<string, string>> = {
  oneOf: "combinators are rejected at the top level by Anthropic (request-wide 400; the 2026-07 outage) and unsupported by several providers when nested",
  anyOf: "combinators are rejected at the top level by Anthropic (request-wide 400) and unsupported by several providers when nested",
  allOf: "combinators are rejected at the top level by Anthropic (request-wide 400) and unsupported by several providers when nested",
  not: "negation support varies by provider; Anthropic accepts it nested only",
  $ref: "reference resolution is not guaranteed at the provider request layer; a dangling or external $ref rejects the whole request",
  $defs: "definition blocks only exist to serve $ref, which is outside the subset",
  definitions: "legacy alias of $defs; outside the subset for the same reason",
  if: "draft-07 conditionals have uneven provider support and are impossible to preflight exhaustively",
  then: "draft-07 conditionals have uneven provider support",
  else: "draft-07 conditionals have uneven provider support",
  dependentSchemas: "2019-09 keyword with uneven provider support; use schema-form `dependencies` where the enforced profile allows it",
  dependentRequired: "2019-09 keyword with uneven provider support; use array-form `dependencies` instead",
  patternProperties: "regex-keyed properties are ignored or rejected by strict provider validators",
  propertyNames: "property-name schemas are ignored or rejected by strict provider validators",
  prefixItems: "tuple validation is unsupported by provider function-calling validators",
  additionalItems: "tuple validation is unsupported by provider function-calling validators",
  unevaluatedProperties: "2019-09 keyword with uneven provider support",
  unevaluatedItems: "2019-09 keyword with uneven provider support",
  format: "format values are silently ignored by some providers and rejected by others; none is currently allowlisted",
  pattern: "regex dialects differ across providers; not currently allowlisted - extend the profile deliberately if needed",
  contains: "uneven provider support",
  const: "uneven provider support; use a single-value enum instead",
};

const JSON_TYPES = new Set(["object", "array", "string", "number", "integer", "boolean", "null"]);

/**
 * What the Anthropic Messages API accepts, held to the narrowest shape Baseline actually needs.
 * Verified against the live API by scripts/preflight-tool-schemas.js in the gated
 * provider-live-guard.yml workflow (not every PR); this offline lint is the per-PR guard.
 * Top-level combinators stay banned even though nested ones pass: a top-level combinator is the
 * exact construct that 400s every conversation request (PR #59).
 */
export const ANTHROPIC_PROFILE: ProviderSchemaProfile = {
  id: "anthropic",
  allowedKeywords: new Set([
    "type", "properties", "required", "description", "enum",
    "items", "minItems", "maxItems",
    "minimum", "maximum", "minLength", "maxLength",
    "minProperties", "maxProperties",
    "additionalProperties", "dependencies",
    "anyOf", "oneOf", "allOf", "not",
  ]),
  topLevelBannedKeywords: new Set(["oneOf", "anyOf", "allOf", "not"]),
  allowedTypes: JSON_TYPES,
  allowedFormats: new Set(),
  allowsSchemaFormDependencies: true,
};

/**
 * The conservative intersection a tool schema must fit to be portable across the function-calling
 * validators of the major providers (Anthropic, OpenAI-style strict validators, Gemini's proto-based
 * FunctionDeclaration). No combinators anywhere, no `dependencies`, no `not`, no "null" in type
 * unions, no minProperties/maxProperties. Advisory today (Anthropic is the only enforced provider);
 * it becomes an enforced profile the day a second provider ships. Deviations are pinned in
 * test/toolSchemaContract.test.js so new fragility is a deliberate, visible choice.
 */
export const CROSS_PROVIDER_CORE_PROFILE: ProviderSchemaProfile = {
  id: "cross-provider-core",
  allowedKeywords: new Set([
    "type", "properties", "required", "description", "enum",
    "items", "minItems", "maxItems",
    "minimum", "maximum", "minLength", "maxLength",
    "additionalProperties",
  ]),
  topLevelBannedKeywords: new Set(),
  allowedTypes: new Set(["object", "array", "string", "number", "integer", "boolean"]),
  allowedFormats: new Set(),
  allowsSchemaFormDependencies: false,
};

/** The profiles every served tool schema MUST pass - one per provider Baseline actually serves. */
export const ENFORCED_PROFILES: readonly ProviderSchemaProfile[] = [ANTHROPIC_PROFILE];

/** Profiles reported as advisories (latent cross-provider fragility), not build failures. */
export const ADVISORY_PROFILES: readonly ProviderSchemaProfile[] = [CROSS_PROVIDER_CORE_PROFILE];

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function findingFor(
  profile: ProviderSchemaProfile,
  toolset: string,
  tool: string,
  path: string,
  keyword: string,
  message: string,
): SchemaFinding {
  return { profile: profile.id, toolset, tool, path, keyword, message };
}

/** Lint one tool's input_schema against one profile. Empty result means the schema conforms. */
export function lintToolSchema(
  tool: ToolSchema,
  profile: ProviderSchemaProfile,
  toolset = "",
): SchemaFinding[] {
  const findings: SchemaFinding[] = [];
  const report = (path: string, keyword: string, message: string) => {
    findings.push(findingFor(profile, toolset, tool.name, path, keyword, message));
  };

  const schema = tool.input_schema;
  if (!isPlainObject(schema)) {
    report("", "input_schema", "input_schema must be a plain object");
    return findings;
  }
  if (schema.type !== "object") {
    report("", "type", "input_schema must declare type \"object\" at the top level");
  }

  const walk = (node: Record<string, unknown>, path: string, isTopLevel: boolean): void => {
    const recurse = (child: unknown, childPath: string, keyword: string) => {
      if (!isPlainObject(child)) {
        report(childPath, keyword, `${keyword} must contain a plain schema object`);
        return;
      }
      walk(child, childPath, false);
    };

    for (const [keyword, value] of Object.entries(node)) {
      const at = path === "" ? keyword : `${path}/${keyword}`;

      if (!profile.allowedKeywords.has(keyword)) {
        const rationale = RISKY_KEYWORD_RATIONALE[keyword]
          ?? "not in the documented safe subset; extend the provider profile deliberately if it is genuinely needed";
        report(path, keyword, `keyword "${keyword}" is outside the ${profile.id} profile: ${rationale}`);
        continue;
      }
      if (isTopLevel && profile.topLevelBannedKeywords.has(keyword)) {
        report(path, keyword,
          `"${keyword}" at the top level of input_schema: ${RISKY_KEYWORD_RATIONALE[keyword] ?? "banned at the top level"}`);
        continue;
      }

      switch (keyword) {
      case "type": {
        const types = Array.isArray(value) ? value : [value];
        for (const t of types) {
          if (typeof t !== "string" || !profile.allowedTypes.has(t)) {
            report(at, "type", `type value ${JSON.stringify(t)} is outside the ${profile.id} profile`);
          }
        }
        break;
      }
      case "properties": {
        if (!isPlainObject(value)) {
          report(at, keyword, "properties must be an object mapping names to schemas");
          break;
        }
        for (const [name, child] of Object.entries(value)) {
          recurse(child, `${at}/${name}`, "properties");
        }
        break;
      }
      case "items": {
        if (Array.isArray(value)) {
          report(at, keyword,
            "tuple-form items (an array of schemas) is unsupported by provider function-calling validators; use a single item schema");
          break;
        }
        recurse(value, at, keyword);
        break;
      }
      case "dependencies": {
        if (!isPlainObject(value)) {
          report(at, keyword, "dependencies must be an object");
          break;
        }
        for (const [name, entry] of Object.entries(value)) {
          if (Array.isArray(entry)) {
            if (!entry.every((item) => typeof item === "string")) {
              report(`${at}/${name}`, keyword, "array-form dependencies must list property names");
            }
          } else if (profile.allowsSchemaFormDependencies) {
            recurse(entry, `${at}/${name}`, keyword);
          } else {
            report(`${at}/${name}`, keyword,
              `schema-form dependencies are outside the ${profile.id} profile; only required-name arrays are portable`);
          }
        }
        break;
      }
      case "anyOf":
      case "oneOf":
      case "allOf": {
        if (!Array.isArray(value) || value.length === 0) {
          report(at, keyword, `${keyword} must be a non-empty array of schemas`);
          break;
        }
        value.forEach((child, index) => recurse(child, `${at}/${index}`, keyword));
        break;
      }
      case "not":
        recurse(value, at, keyword);
        break;
      case "additionalProperties":
        if (typeof value !== "boolean") {
          report(at, keyword,
            "additionalProperties must be a boolean; schema-form additionalProperties has uneven provider support");
        }
        break;
      case "required":
        if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
          report(at, keyword, "required must be an array of property names");
        }
        break;
      case "enum":
        if (!Array.isArray(value) || value.length === 0
            || !value.every((item) => item === null || ["string", "number", "boolean"].includes(typeof item))) {
          report(at, keyword, "enum must be a non-empty array of primitive values");
        }
        break;
      case "format":
        if (typeof value !== "string" || !profile.allowedFormats.has(value)) {
          report(at, keyword, `format ${JSON.stringify(value)} is outside the ${profile.id} profile`);
        }
        break;
      case "description":
        if (typeof value !== "string") report(at, keyword, "description must be a string");
        break;
      case "minimum":
      case "maximum":
      case "minLength":
      case "maxLength":
      case "minItems":
      case "maxItems":
      case "minProperties":
      case "maxProperties":
        if (typeof value !== "number") report(at, keyword, `${keyword} must be a number`);
        break;
      }
    }
  };

  walk(schema, "", true);
  return findings;
}

/** Lint every tool of every served toolset variant against one profile. */
export function lintServedToolsets(profile: ProviderSchemaProfile): SchemaFinding[] {
  const findings: SchemaFinding[] = [];
  for (const [toolsetName, tools] of Object.entries(SERVED_TOOLSETS)) {
    for (const tool of tools) {
      findings.push(...lintToolSchema(tool, profile, toolsetName));
    }
  }
  return findings;
}

/** All violations of the enforced provider profiles. Non-empty means the build must fail. */
export function enforcedViolations(): SchemaFinding[] {
  return ENFORCED_PROFILES.flatMap((profile) => lintServedToolsets(profile));
}

/**
 * Latent cross-provider fragility: constructs the enforced providers accept but that fall outside
 * the conservative cross-provider core. Reported and pinned, not failed.
 */
export function crossProviderAdvisories(): SchemaFinding[] {
  return ADVISORY_PROFILES.flatMap((profile) => lintServedToolsets(profile));
}

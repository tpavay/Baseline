import {
  ImportObservation,
  ParsedWorkoutDocument,
  WorkoutDocumentValidationDiagnostic,
  WorkoutImportPayload,
  parseWorkoutImportPayload,
  workoutImportTokenBudget,
  WORKOUT_IMPORT_MAX_OUTPUT_TOKENS,
} from "./workoutImport";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DIGEST = /^[0-9a-f]{64}$/;
export const MAX_SECTIONS = 20;
const MAX_SECTION_CHARACTERS = 6_000;
const MAX_SECTION_OBSERVATIONS = 180;
const MAX_PROVENANCE_SOURCE_IDS = 20;
const MAX_CATALOG_HINTS = 500;
export const MAX_ROOT_ENCODED_BYTES = 384 * 1_024;
// Inputs are rejected before any provider work. The stored document limit intentionally leaves
// headroom for a validated section result while remaining below Firestore's 1 MiB document cap.
export const MAX_SECTION_INPUT_BYTES = 256 * 1_024;
export const MAX_SECTION_RESULT_BYTES = 512 * 1_024;
export const MAX_SECTION_DOCUMENT_BYTES = 896 * 1_024;
export const MAX_RESULT_ENCODED_BYTES = 300 * 1_024;
export const MAX_SECTION_ATTEMPTS = 3;
export const MAX_SECTION_REPAIR_ATTEMPTS = 3;
export const MAX_SECTION_PROVIDER_CALLS = 4;
export const MAX_JOB_PROVIDER_CALLS = MAX_SECTIONS * MAX_SECTION_PROVIDER_CALLS;
// Normal calls remain at 4,096 or 6,144 tokens. Repairs and truncated responses can reserve up to
// 8,192 tokens, while this lifetime cap bounds the worst case across a 20-section import.
export const MAX_JOB_OUTPUT_TOKENS = 512 * 1_024;
export const MAX_APPLIED_REQUEST_IDS = 20;

export type WorkoutImportJobStatus = "queued" | "processing" | "completed" | "failed" | "cancelled";
export type WorkoutImportDispatchState = "needsDispatch" | "dispatched";
export type WorkoutImportSectionStatus = "pending" | "processing" | "completed" | "failed";
export type WorkoutImportFailureCode =
  | "provider_unavailable"
  | "worker_budget_exhausted"
  | "section_invalid"
  | "cross_section_assembly"
  | "result_too_large"
  | "schema_incompatible";

export interface WorkoutImportProvenance {
  primaryID: string;
  sourceObservationIDs: string[];
}

export interface ServerWorkoutImportSectionInput {
  id: string;
  order: number;
  observations: ImportObservation[];
  contextBefore: string[];
  provenance: WorkoutImportProvenance[];
  startScopeID: string;
  endScopeID: string;
  startFragmentPath: string[];
  endFragmentPath: string[];
  continuationFromSectionID?: string;
}

export interface StoredWorkoutImportSection extends ServerWorkoutImportSectionInput {
  schemaVersion: 2;
  jobID: string;
  generation: number;
  status: WorkoutImportSectionStatus;
  // Provider failure count for the current generation. Claims and infrastructure failures do not
  // increment this value.
  attempts: number;
  providerCalls: number;
  outputTokensReserved: number;
  repairAttempts: number;
  claimToken?: string;
  leasedUntil?: unknown;
  result?: ParsedWorkoutDocument;
  repairInput?: unknown;
  repairDiagnostic?: WorkoutDocumentValidationDiagnostic;
  repaired?: boolean;
  failureCode?: WorkoutImportFailureCode;
  createdAt: unknown;
  updatedAt: unknown;
  expiresAt: unknown;
}

export interface StartWorkoutImportJobPayload {
  schemaVersion: 1;
  clientJobID: string;
  requestID: string;
  jobHash: string;
  sections: ServerWorkoutImportSectionInput[];
  catalogHints: string[];
}

export interface StoredWorkoutImportJob {
  schemaVersion: 2;
  uid: string;
  clientJobID: string;
  requestID: string;
  jobHash: string;
  generation: number;
  status: WorkoutImportJobStatus;
  dispatchState: WorkoutImportDispatchState;
  dispatchAttempt: number;
  dispatchedAt?: unknown;
  sectionIDs: string[];
  catalogHints: string[];
  completedSections: number;
  totalSections: number;
  providerCalls: number;
  initialOutputTokenBudget: number;
  outputTokenBudget: number;
  outputTokensReserved: number;
  appliedRequestIDs: string[];
  cancelled: boolean;
  model: string;
  workerLeaseToken?: string;
  workerLeasedUntil?: unknown;
  document?: ParsedWorkoutDocument;
  failureCode?: WorkoutImportFailureCode;
  createdAt: unknown;
  updatedAt: unknown;
  expiresAt: unknown;
}

export function parseStartWorkoutImportJobPayload(raw: unknown): StartWorkoutImportJobPayload {
  let value = raw;
  if (typeof value === "string") {
    try { value = JSON.parse(value); } catch { throw new Error("payload must be valid JSON"); }
  }
  if (record(value) && value.schemaVersion !== 1) {
    throw new Error("schema_version_unsupported");
  }
  if (!record(value) ||
      typeof value.clientJobID !== "string" || !UUID.test(value.clientJobID) ||
      typeof value.requestID !== "string" || !UUID.test(value.requestID) ||
      typeof value.jobHash !== "string" || !DIGEST.test(value.jobHash) ||
      !Array.isArray(value.sections) || !Array.isArray(value.catalogHints)) {
    throw new Error("job payload is invalid");
  }
  if (value.sections.length === 0 || value.sections.length > MAX_SECTIONS) {
    throw new Error("section count is outside the accepted range");
  }
  const catalogHints = value.catalogHints
    .filter((item): item is string => typeof item === "string")
    .slice(0, MAX_CATALOG_HINTS)
    .map((item) => item.slice(0, 120));
  const ids = new Set<string>();
  let observationCount = 0;
  let characterCount = 0;
  const sections = value.sections.map((item, index): ServerWorkoutImportSectionInput => {
    if (!record(item) || typeof item.id !== "string" || !DIGEST.test(item.id) ||
        item.order !== index || !Array.isArray(item.observations) ||
        !Array.isArray(item.contextBefore)) {
      throw new Error("a section is invalid");
    }
    if (ids.has(item.id)) throw new Error("section identifiers must be unique");
    ids.add(item.id);
    if (item.observations.length === 0 || item.observations.length > MAX_SECTION_OBSERVATIONS) {
      throw new Error("section observation count is outside the accepted range");
    }
    const contextBefore = item.contextBefore
      .filter((line): line is string => typeof line === "string")
      .slice(-3)
      .map((line) => line.slice(0, 500));
    const payload = parseWorkoutImportPayload({
      observations: item.observations,
      catalogHints,
      contextBefore,
    });
    const sectionCharacters = payload.observations.reduce((sum, observation) => sum + observation.text.length, 0);
    if (sectionCharacters > MAX_SECTION_CHARACTERS) throw new Error("section text is too long");
    const observationIDs = new Set(payload.observations.map((observation) => observation.id));
    const provenance = parseProvenance(item.provenance, payload.observations, observationIDs);
    const startScopeID = typeof item.startScopeID === "string" && DIGEST.test(item.startScopeID)
      ? item.startScopeID
      : item.id;
    const endScopeID = typeof item.endScopeID === "string" && DIGEST.test(item.endScopeID)
      ? item.endScopeID
      : startScopeID;
    const startFragmentPath = parseFragmentPath(item.startFragmentPath, startScopeID);
    const endFragmentPath = parseFragmentPath(item.endFragmentPath, endScopeID);
    const continuationFromSectionID = typeof item.continuationFromSectionID === "string" &&
      DIGEST.test(item.continuationFromSectionID)
      ? item.continuationFromSectionID
      : undefined;
    if (continuationFromSectionID && index === 0) throw new Error("the first section cannot be a continuation");
    observationCount += payload.observations.length;
    characterCount += sectionCharacters;
    return {
      id: item.id,
      order: index,
      observations: payload.observations,
      contextBefore,
      provenance,
      startScopeID,
      endScopeID,
      startFragmentPath,
      endFragmentPath,
      ...(continuationFromSectionID ? { continuationFromSectionID } : {}),
    };
  });
  if (observationCount > 2_000 || characterCount > 40_000) {
    throw new Error("job input is too large");
  }
  for (let index = 1; index < sections.length; index += 1) {
    const previous = sections[index - 1];
    const current = sections[index];
    if (current.continuationFromSectionID &&
        (current.continuationFromSectionID !== previous.id ||
         current.startScopeID !== previous.endScopeID)) {
      throw new Error("section continuation metadata is invalid");
    }
  }
  return {
    schemaVersion: 1,
    clientJobID: value.clientJobID,
    requestID: value.requestID,
    jobHash: value.jobHash,
    sections,
    catalogHints,
  };
}

export function initialOutputTokenBudget(payload: StartWorkoutImportJobPayload): number {
  return payload.sections.reduce(
    (total, section) => total + workoutImportTokenBudget(sectionPayload(section, payload.catalogHints)),
    0,
  );
}

export function outputTokenBudget(payload: StartWorkoutImportJobPayload): number {
  const initial = initialOutputTokenBudget(payload);
  if (initial > MAX_JOB_OUTPUT_TOKENS) throw new Error("job_token_budget_too_large");
  const retryHeadroom = payload.sections.length *
    WORKOUT_IMPORT_MAX_OUTPUT_TOKENS * (MAX_SECTION_PROVIDER_CALLS - 1);
  return Math.min(MAX_JOB_OUTPUT_TOKENS, initial + retryHeadroom);
}

function parseProvenance(
  raw: unknown,
  observations: ImportObservation[],
  primaryIDs: ReadonlySet<string>,
): WorkoutImportProvenance[] {
  if (raw === undefined) {
    return observations.map((observation) => ({
      primaryID: observation.id,
      sourceObservationIDs: [observation.id],
    }));
  }
  if (!Array.isArray(raw) || raw.length !== observations.length) {
    throw new Error("section provenance is invalid");
  }
  const byPrimary = new Map<string, string[]>();
  for (const candidate of raw) {
    if (!record(candidate) || typeof candidate.primaryID !== "string" ||
        !primaryIDs.has(candidate.primaryID) || !Array.isArray(candidate.sourceObservationIDs) ||
        candidate.sourceObservationIDs.length === 0 ||
        candidate.sourceObservationIDs.length > MAX_PROVENANCE_SOURCE_IDS ||
        byPrimary.has(candidate.primaryID)) {
      throw new Error("section provenance is invalid");
    }
    const sourceObservationIDs = candidate.sourceObservationIDs
      .filter((identifier): identifier is string => typeof identifier === "string")
      .map((identifier) => identifier.slice(0, 100));
    if (sourceObservationIDs.length !== candidate.sourceObservationIDs.length ||
        !sourceObservationIDs.includes(candidate.primaryID)) {
      throw new Error("section provenance is invalid");
    }
    byPrimary.set(candidate.primaryID, [...new Set(sourceObservationIDs)]);
  }
  return observations.map((observation) => ({
    primaryID: observation.id,
    sourceObservationIDs: byPrimary.get(observation.id) ?? [observation.id],
  }));
}

export function sectionPayload(
  section: StoredWorkoutImportSection | ServerWorkoutImportSectionInput,
  catalogHints: string[],
): WorkoutImportPayload {
  return {
    observations: section.observations,
    catalogHints,
    ...(section.contextBefore.length > 0 ? { contextBefore: section.contextBefore } : {}),
    sourcePlan: {
      startFragmentPath: section.startFragmentPath,
      endFragmentPath: section.endFragmentPath,
    },
  };
}

function parseFragmentPath(raw: unknown, scopeID: string): string[] {
  if (raw === undefined) return [scopeID];
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 4 ||
      raw.some((item) => typeof item !== "string" || !DIGEST.test(item)) || raw[0] !== scopeID) {
    throw new Error("section fragment path is invalid");
  }
  return [...raw];
}

export function sectionDocumentID(jobID: string, sectionID: string): string {
  return `${jobID}_${sectionID}`;
}

export function encodedJSONByteCount(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

export function assertEncodedSize(value: unknown, maximumBytes: number, label: string): void {
  const byteCount = encodedJSONByteCount(value);
  if (byteCount > maximumBytes) throw new Error(`${label}_too_large:${byteCount}:${maximumBytes}`);
}

export function isTerminalWorkoutImportFailure(code: WorkoutImportFailureCode | undefined): boolean {
  return code === "section_invalid" || code === "cross_section_assembly" ||
    code === "result_too_large" || code === "schema_incompatible";
}

export function isTerminalWorkoutImportJob(job: Pick<StoredWorkoutImportJob, "status" | "cancelled">): boolean {
  return job.cancelled || job.status === "cancelled" || job.status === "completed" || job.status === "failed";
}

export async function mapWithConcurrency<Input, Output>(
  values: readonly Input[],
  concurrency: number,
  operation: (value: Input, index: number) => Promise<Output>,
): Promise<Output[]> {
  const results = new Array<Output>(values.length);
  let cursor = 0;
  const workerCount = Math.max(1, Math.min(Math.floor(concurrency), values.length));
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (true) {
      const index = cursor++;
      if (index >= values.length) return;
      results[index] = await operation(values[index], index);
    }
  }));
  return results;
}

export function observationIDs(sections: ServerWorkoutImportSectionInput[]): Set<string> {
  return new Set(sections.flatMap((section) => section.provenance.flatMap((item) => item.sourceObservationIDs)));
}

export function workoutImportOperationalLog(fields: {
  jobID: string;
  stage: string;
  reasonCode?: string;
  sections?: number;
  completedSections?: number;
  observations?: number;
  characters?: number;
  latencyMs?: number;
  requestBytes?: number;
  responseBytes?: number;
  outputTokens?: number;
  attempt?: number;
  generation?: number;
  dispatchAttempt?: number;
  model?: string;
}): Record<string, string | number> {
  const allowed = [
    "jobID", "stage", "reasonCode", "sections", "completedSections", "observations",
    "characters", "latencyMs", "requestBytes", "responseBytes", "outputTokens", "attempt",
    "generation", "dispatchAttempt", "model",
  ] as const;
  return Object.fromEntries(allowed.flatMap((key) => {
    const value = fields[key];
    return typeof value === "string" || typeof value === "number" ? [[key, value]] : [];
  }));
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function boundedRawIR(value: unknown): Record<string, unknown> | undefined {
  if (!record(value)) return undefined;
  try {
    assertEncodedSize(value, MAX_SECTION_INPUT_BYTES, "repair_input");
    return value;
  } catch {
    return undefined;
  }
}

export function sectionObservations(section: StoredWorkoutImportSection): ImportObservation[] {
  return section.observations;
}

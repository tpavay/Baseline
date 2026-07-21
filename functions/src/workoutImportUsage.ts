import { FieldValue, type Firestore, type Transaction } from "firebase-admin/firestore";

/**
 * Two counters, two purposes, never one for both.
 *
 * **The daily import limit is a promise to the athlete.** It counts distinct import *jobs* — one
 * thing they started — and never provider calls. Ten photos chosen together is one job. A fast-path
 * attempt that fails and falls through to the durable job is still that same one job, because both
 * endpoints are handed the same client job id and the charge is recorded against it. And a job that
 * produced nothing usable is not charged at all: a failed import is Baseline's shortcoming, not the
 * athlete's, so the charge lands on a usable result rather than at request admission.
 *
 * **Cost control is a separate, invisible guard.** Conflating the two is what made a failed import
 * cost the athlete two of their twenty-five. So bounding spend is a second counter with a
 * deliberately generous ceiling, well above what twenty-five honest imports consume, whose
 * exhaustion is an internal fault code and never reads as "you hit your daily import limit". It
 * exists because "do not charge failures" otherwise leaves the number of *attempts* unbounded.
 */

/** What the athlete is promised: distinct successful imports per day. */
export const IMPORT_DAILY_JOB_LIMIT = 25;

/**
 * The invisible ceiling on attempts per day. Each attempt is separately bounded by the per-job
 * provider budget, so this bounds total daily spend without ever being a number the athlete meets:
 * it is six times the honest limit, which no ordinary day of importing reaches.
 */
const ATTEMPTS_PER_PROMISED_IMPORT = 6;
export const IMPORT_DAILY_ATTEMPT_CEILING = IMPORT_DAILY_JOB_LIMIT * ATTEMPTS_PER_PROMISED_IMPORT;

export type ImportUsageDenial =
  /** The athlete has genuinely used their imports for today. User-facing. */
  | "daily_job_limit"
  /** The internal cost guard tripped. Never surfaced as a limit. */
  | "cost_guard"
  /** This one job has already drawn its bounded pool of provider work. */
  | "job_budget";

export class ImportUsageError extends Error {
  constructor(readonly reason: ImportUsageDenial) {
    super(reason);
    this.name = "ImportUsageError";
  }
}

interface DailyUsage {
  workoutImports: number;
  chargedImportJobIDs: string[];
  importJobAttempts: number;
}

function usage(value: FirebaseFirestore.DocumentData | undefined): DailyUsage {
  const charged = Array.isArray(value?.chargedImportJobIDs)
    ? value.chargedImportJobIDs.filter((entry: unknown): entry is string => typeof entry === "string")
    : [];
  return {
    workoutImports: count(value?.workoutImports),
    chargedImportJobIDs: charged,
    importJobAttempts: count(value?.importJobAttempts),
  };
}

function count(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

export function usageDay(now: number = Date.now()): string {
  return new Date(now).toISOString().slice(0, 10);
}

function usageReference(database: Firestore, uid: string, day: string) {
  return database.doc(`users/${uid}/usage/${day}`);
}

export interface ImportUsageLimits {
  dailyJobLimit: number;
  attemptCeiling: number;
}

export function importUsageLimits(dailyJobLimit = IMPORT_DAILY_JOB_LIMIT): ImportUsageLimits {
  return {
    dailyJobLimit,
    // The guard scales with the promise it protects, so lowering the limit in a test does not leave
    // an attempt ceiling that can never be reached.
    attemptCeiling: Math.max(
      dailyJobLimit * ATTEMPTS_PER_PROMISED_IMPORT,
      ATTEMPTS_PER_PROMISED_IMPORT,
    ),
  };
}

/**
 * Admit one attempt at `clientJobID`, inside `transaction` so callers that already hold one can
 * compose. Throws `ImportUsageError` and mutates nothing when either ceiling refuses.
 *
 * A job that has already been charged today is always admitted: the athlete paid for it once and
 * retrying it is not a second import.
 */
export async function admitImportAttemptIn(
  transaction: Transaction,
  database: Firestore,
  uid: string,
  clientJobID: string,
  now: number,
  limits: ImportUsageLimits = importUsageLimits(),
): Promise<void> {
  const reference = usageReference(database, uid, usageDay(now));
  const current = usage((await transaction.get(reference)).data());
  const alreadyCharged = current.chargedImportJobIDs.includes(clientJobID);
  if (!alreadyCharged && current.workoutImports >= limits.dailyJobLimit) {
    throw new ImportUsageError("daily_job_limit");
  }
  if (current.importJobAttempts >= limits.attemptCeiling) {
    throw new ImportUsageError("cost_guard");
  }
  transaction.set(
    reference,
    { importJobAttempts: current.importJobAttempts + 1, updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
}

export async function admitImportAttempt(
  database: Firestore,
  uid: string,
  clientJobID: string,
  now: number = Date.now(),
  limits: ImportUsageLimits = importUsageLimits(),
): Promise<void> {
  await database.runTransaction((transaction) =>
    admitImportAttemptIn(transaction, database, uid, clientJobID, now, limits));
}

/**
 * Record that this job produced something usable. Idempotent on `clientJobID`, so whichever path
 * finished first owns the single charge and the other is a no-op.
 */
export async function chargeImportJobIn(
  transaction: Transaction,
  database: Firestore,
  uid: string,
  clientJobID: string,
  now: number,
): Promise<void> {
  const reference = usageReference(database, uid, usageDay(now));
  const current = usage((await transaction.get(reference)).data());
  if (current.chargedImportJobIDs.includes(clientJobID)) return;
  transaction.set(
    reference,
    {
      workoutImports: current.workoutImports + 1,
      chargedImportJobIDs: FieldValue.arrayUnion(clientJobID),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

export async function chargeImportJob(
  database: Firestore,
  uid: string,
  clientJobID: string,
  now: number = Date.now(),
): Promise<void> {
  await database.runTransaction((transaction) =>
    chargeImportJobIn(transaction, database, uid, clientJobID, now));
}

// MARK: - One bounded pool of provider work per job

/**
 * What one job has already spent on provider work, keyed by the client job id both endpoints share.
 *
 * The durable job enforces `MAX_JOB_PROVIDER_CALLS` and `MAX_JOB_OUTPUT_TOKENS` against its own root
 * document, but the fast path runs before that document exists. This ledger is what makes the two
 * one pool: the fast path reserves against it, and the durable job seeds its root counters from it,
 * so a fast-path attempt plus the durable fall-through for the same job cannot together exceed what
 * one job is allowed however many photos or internal retries are involved.
 */
export interface ImportJobProviderLedger {
  providerCalls: number;
  outputTokensReserved: number;
}

const EMPTY_LEDGER: ImportJobProviderLedger = { providerCalls: 0, outputTokensReserved: 0 };

function ledgerReference(database: Firestore, uid: string, clientJobID: string) {
  return database.doc(`users/${uid}/importJobBudgets/${clientJobID}`);
}

function ledger(value: FirebaseFirestore.DocumentData | undefined): ImportJobProviderLedger {
  return {
    providerCalls: count(value?.providerCalls),
    outputTokensReserved: count(value?.outputTokensReserved),
  };
}

export async function importJobProviderLedgerIn(
  transaction: Transaction,
  database: Firestore,
  uid: string,
  clientJobID: string,
): Promise<ImportJobProviderLedger> {
  const snapshot = await transaction.get(ledgerReference(database, uid, clientJobID));
  return snapshot.exists ? ledger(snapshot.data()) : EMPTY_LEDGER;
}

/** Reserve one provider call against this job's pool, or throw `ImportUsageError("job_budget")`. */
export async function reserveImportJobProviderCall(
  database: Firestore,
  uid: string,
  clientJobID: string,
  outputTokens: number,
  limits: { maximumProviderCalls: number; maximumOutputTokens: number },
  now: number = Date.now(),
): Promise<void> {
  const reference = ledgerReference(database, uid, clientJobID);
  await database.runTransaction(async (transaction) => {
    const current = ledger((await transaction.get(reference)).data());
    if (current.providerCalls >= limits.maximumProviderCalls ||
        current.outputTokensReserved + outputTokens > limits.maximumOutputTokens) {
      throw new ImportUsageError("job_budget");
    }
    transaction.set(
      reference,
      {
        providerCalls: current.providerCalls + 1,
        outputTokensReserved: current.outputTokensReserved + outputTokens,
        day: usageDay(now),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

import { createHash } from "node:crypto";

import { FieldValue, Firestore, Timestamp } from "firebase-admin/firestore";

import { ParsedWorkoutDocument, WorkoutDocumentValidationDiagnostic } from "./workoutImport";
import {
  StartWorkoutImportJobPayload,
  StoredWorkoutImportJob,
  StoredWorkoutImportSection,
  WorkoutImportFailureCode,
  MAX_APPLIED_REQUEST_IDS,
  MAX_ROOT_ENCODED_BYTES,
  MAX_SECTION_ATTEMPTS,
  MAX_SECTION_DOCUMENT_BYTES,
  MAX_SECTION_INPUT_BYTES,
  MAX_SECTION_REPAIR_ATTEMPTS,
  MAX_SECTION_PROVIDER_CALLS,
  MAX_SECTION_RESULT_BYTES,
  assertEncodedSize,
  initialOutputTokenBudget,
  isTerminalWorkoutImportFailure,
  isTerminalWorkoutImportJob,
  outputTokenBudget,
  sectionDocumentID,
} from "./workoutImportJobs";
import {
  WorkoutImportJobStore,
  WorkoutImportProviderReservation,
  WorkoutImportSectionClaim,
  WorkoutImportWorkerBusy,
  WorkoutImportWorkerClaim,
  withinWorkoutImportJobBudget,
} from "./workoutImportJobRuntime";
import {
  ImportUsageError,
  admitImportAttemptIn,
  chargeImportJobIn,
  importJobProviderLedgerIn,
  importUsageLimits,
} from "./workoutImportUsage";

const ROOT_COLLECTION = "workoutImportJobs";
const SECTION_COLLECTION = "workoutImportJobSections";
const CANCELLATION_COLLECTION = "workoutImportJobCancellations";
const RETENTION_MS = 24 * 60 * 60 * 1_000;
export const WORKER_LEASE_MS = 180 * 1_000;
export const SECTION_LEASE_MS = 180 * 1_000;
export const DISPATCH_RECOVERY_MS = 210 * 1_000;

type StoreErrorCode =
  | "not-found"
  | "permission-denied"
  | "already-exists"
  | "resource-exhausted"
  /** The invisible daily cost guard, deliberately distinct from the athlete's import limit. */
  | "cost-guard"
  | "failed-precondition";

export class WorkoutImportStoreError extends Error {
  constructor(readonly code: StoreErrorCode) {
    super(code);
    this.name = "WorkoutImportStoreError";
  }
}

interface StoredCancellationTombstone {
  schemaVersion: 1;
  uid: string;
  jobID: string;
  requestID: string;
  createdAt: unknown;
  updatedAt: unknown;
  expiresAt: unknown;
}

export class FirestoreWorkoutImportJobStore implements WorkoutImportJobStore {
  constructor(
    private readonly database: Firestore,
    private readonly dailyLimit: number,
    private readonly now: () => number = Date.now,
  ) {}

  async createOrGet(
    uid: string,
    payload: StartWorkoutImportJobPayload,
    model: string,
  ): Promise<{ job: StoredWorkoutImportJob; created: boolean }> {
    const rootRef = this.root(payload.clientJobID);
    const tombstoneRef = this.cancellation(uid, payload.clientJobID);
    return this.database.runTransaction(async (transaction) => {
      const [rootSnapshot, tombstoneSnapshot] = await Promise.all([
        transaction.get(rootRef),
        transaction.get(tombstoneRef),
      ]);
      if (rootSnapshot.exists) {
        const raw = rootSnapshot.data();
        if (raw?.schemaVersion !== 2) {
          const incompatible = this.incompatibleJob(raw, payload.clientJobID);
          if (incompatible.uid !== uid) throw new WorkoutImportStoreError("permission-denied");
          transaction.update(rootRef, this.schemaIncompatibleUpdate());
          return { job: incompatible, created: false };
        }
        const existing = this.job(raw);
        if (existing.uid !== uid) throw new WorkoutImportStoreError("permission-denied");
        if (existing.jobHash !== payload.jobHash) throw new WorkoutImportStoreError("already-exists");
        return { job: existing, created: false };
      }
      if (tombstoneSnapshot.exists) {
        const tombstone = this.tombstone(tombstoneSnapshot.data());
        if (tombstone.uid === uid && tombstone.jobID === payload.clientJobID) {
          return { job: this.cancelledJob(uid, payload, model, tombstone), created: false };
        }
      }

      // The athlete's daily count is charged when this job yields a document, not here — see
      // `completeJob`. Admission only checks that they have an import left and that the invisible
      // cost guard has not tripped, and it records the attempt against that guard.
      const ledger = await importJobProviderLedgerIn(transaction, this.database, uid, payload.clientJobID);
      try {
        await admitImportAttemptIn(
          transaction, this.database, uid, payload.clientJobID, this.now(),
          importUsageLimits(this.dailyLimit),
        );
      } catch (error) {
        throw storeErrorForUsage(error);
      }
      const timestamp = this.timestamp();
      const expiresAt = Timestamp.fromMillis(timestamp.toMillis() + RETENTION_MS);
      const sectionIDs = payload.sections.map((section) => section.id);
      const initialBudget = initialOutputTokenBudget(payload);
      const root: StoredWorkoutImportJob = {
        schemaVersion: 2,
        uid,
        clientJobID: payload.clientJobID,
        requestID: payload.requestID,
        jobHash: payload.jobHash,
        generation: 1,
        status: "queued",
        dispatchState: "needsDispatch",
        dispatchAttempt: 1,
        sectionIDs,
        catalogHints: payload.catalogHints,
        completedSections: 0,
        totalSections: sectionIDs.length,
        // Seeded from the shared per-job ledger so a fast-path attempt for this same job and the
        // durable fall-through draw from one bounded pool rather than two.
        providerCalls: ledger.providerCalls,
        initialOutputTokenBudget: initialBudget,
        outputTokenBudget: outputTokenBudget(payload),
        outputTokensReserved: ledger.outputTokensReserved,
        appliedRequestIDs: [payload.requestID],
        cancelled: false,
        model,
        ...(payload.observability ? { observability: payload.observability } : {}),
        createdAt: timestamp,
        updatedAt: timestamp,
        expiresAt,
      };
      assertEncodedSize(root, MAX_ROOT_ENCODED_BYTES, "root");
      const sections = payload.sections.map((input): StoredWorkoutImportSection => {
        assertEncodedSize(input, MAX_SECTION_INPUT_BYTES, "section_input");
        const section: StoredWorkoutImportSection = {
          schemaVersion: 2,
          jobID: payload.clientJobID,
          generation: 1,
          ...input,
          status: "pending",
          attempts: 0,
          providerCalls: 0,
          outputTokensReserved: 0,
          repairAttempts: 0,
          createdAt: timestamp,
          updatedAt: timestamp,
          expiresAt,
        };
        assertEncodedSize(section, MAX_SECTION_DOCUMENT_BYTES, "section_document");
        return section;
      });
      transaction.create(rootRef, root);
      sections.forEach((section) => transaction.create(this.section(payload.clientJobID, section.id), section));
      return { job: root, created: true };
    });
  }

  async getOwned(jobID: string, uid: string): Promise<StoredWorkoutImportJob> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) throw new WorkoutImportStoreError("not-found");
      const raw = snapshot.data();
      if (raw?.schemaVersion !== 2) {
        const incompatible = this.incompatibleJob(raw, jobID);
        if (incompatible.uid !== uid) throw new WorkoutImportStoreError("not-found");
        transaction.update(reference, this.schemaIncompatibleUpdate());
        return incompatible;
      }
      const job = this.job(raw);
      if (job.uid !== uid) throw new WorkoutImportStoreError("not-found");
      return job;
    });
  }

  async recoverDispatch(jobID: string, generation: number): Promise<StoredWorkoutImportJob | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return undefined;
      const raw = snapshot.data();
      if (raw?.schemaVersion !== 2) {
        const incompatible = this.incompatibleJob(raw, jobID);
        transaction.update(reference, this.schemaIncompatibleUpdate());
        return incompatible;
      }
      const job = this.job(raw);
      if (job.generation !== generation || isTerminalWorkoutImportJob(job) || job.dispatchState === "needsDispatch") {
        return job;
      }
      const workerActive = millis(job.workerLeasedUntil) > this.now();
      const dispatchFresh = millis(job.dispatchedAt) + DISPATCH_RECOVERY_MS > this.now();
      if (workerActive || dispatchFresh) return job;
      const timestamp = this.timestamp();
      const updated: StoredWorkoutImportJob = {
        ...job,
        status: "queued",
        dispatchState: "needsDispatch",
        dispatchAttempt: job.dispatchAttempt + 1,
        dispatchedAt: undefined,
        workerLeaseToken: undefined,
        workerLeasedUntil: undefined,
        updatedAt: timestamp,
      };
      transaction.update(reference, {
        status: "queued",
        dispatchState: "needsDispatch",
        dispatchAttempt: updated.dispatchAttempt,
        dispatchedAt: FieldValue.delete(),
        workerLeaseToken: FieldValue.delete(),
        workerLeasedUntil: FieldValue.delete(),
        updatedAt: timestamp,
      });
      return updated;
    });
  }

  async markDispatched(
    jobID: string,
    generation: number,
    dispatchAttempt: number,
  ): Promise<StoredWorkoutImportJob | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return undefined;
      const raw = snapshot.data();
      if (raw?.schemaVersion !== 2) {
        const incompatible = this.incompatibleJob(raw, jobID);
        transaction.update(reference, this.schemaIncompatibleUpdate());
        return incompatible;
      }
      const job = this.job(raw);
      if (job.generation !== generation || job.dispatchAttempt !== dispatchAttempt ||
          job.dispatchState !== "needsDispatch" || isTerminalWorkoutImportJob(job)) return job;
      const timestamp = this.timestamp();
      const updated = {
        ...job,
        dispatchState: "dispatched" as const,
        dispatchedAt: timestamp,
        updatedAt: timestamp,
      };
      transaction.update(reference, {
        dispatchState: "dispatched", dispatchedAt: timestamp, updatedAt: timestamp,
      });
      return updated;
    });
  }

  async retry(jobID: string, uid: string, requestID: string): Promise<StoredWorkoutImportJob> {
    return this.database.runTransaction(async (transaction) => {
      const rootRef = this.root(jobID);
      const rootSnapshot = await transaction.get(rootRef);
      if (!rootSnapshot.exists) throw new WorkoutImportStoreError("not-found");
      const job = this.job(rootSnapshot.data());
      if (job.uid !== uid) throw new WorkoutImportStoreError("not-found");
      if (job.appliedRequestIDs.includes(requestID)) return job;
      if (job.status !== "failed" || isTerminalWorkoutImportFailure(job.failureCode) ||
          job.appliedRequestIDs.length >= MAX_APPLIED_REQUEST_IDS) return job;

      const sectionRefs = job.sectionIDs.map((sectionID) => this.section(jobID, sectionID));
      const sectionSnapshots = await Promise.all(sectionRefs.map((reference) => transaction.get(reference)));
      const generation = job.generation + 1;
      const timestamp = this.timestamp();
      for (const sectionSnapshot of sectionSnapshots) {
        if (!sectionSnapshot.exists) throw new Error("missing_section");
        const section = this.sectionValue(sectionSnapshot.data());
        if (section.status === "completed" && section.result) {
          transaction.update(sectionSnapshot.ref, {
            generation,
            claimToken: FieldValue.delete(),
            leasedUntil: FieldValue.delete(),
            updatedAt: timestamp,
          });
        } else {
          transaction.update(sectionSnapshot.ref, {
            generation,
            status: "pending",
            attempts: 0,
            claimToken: FieldValue.delete(),
            leasedUntil: FieldValue.delete(),
            failureCode: FieldValue.delete(),
            updatedAt: timestamp,
          });
        }
      }
      const completedSections = sectionSnapshots.filter((snapshot) =>
        snapshot.exists && this.sectionValue(snapshot.data()).status === "completed").length;
      const updated: StoredWorkoutImportJob = {
        ...job,
        requestID,
        appliedRequestIDs: [...job.appliedRequestIDs, requestID],
        generation,
        status: "queued",
        dispatchState: "needsDispatch",
        dispatchAttempt: job.dispatchAttempt + 1,
        dispatchedAt: undefined,
        completedSections,
        cancelled: false,
        failureCode: undefined,
        workerLeaseToken: undefined,
        workerLeasedUntil: undefined,
        updatedAt: timestamp,
      };
      assertEncodedSize(updated, MAX_ROOT_ENCODED_BYTES, "root");
      transaction.update(rootRef, {
        requestID,
        appliedRequestIDs: updated.appliedRequestIDs,
        generation,
        status: "queued",
        dispatchState: "needsDispatch",
        dispatchAttempt: updated.dispatchAttempt,
        dispatchedAt: FieldValue.delete(),
        completedSections,
        cancelled: false,
        failureCode: FieldValue.delete(),
        workerLeaseToken: FieldValue.delete(),
        workerLeasedUntil: FieldValue.delete(),
        updatedAt: timestamp,
      });
      return updated;
    });
  }

  async cancel(jobID: string, uid: string, requestID: string): Promise<StoredWorkoutImportJob | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const rootRef = this.root(jobID);
      const tombstoneRef = this.cancellation(uid, jobID);
      const [rootSnapshot, tombstoneSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(tombstoneRef),
      ]);
      const timestamp = this.timestamp();
      const expiresAt = Timestamp.fromMillis(timestamp.toMillis() + RETENTION_MS);
      if (!rootSnapshot.exists) {
        if (!tombstoneSnapshot.exists) {
          const tombstone: StoredCancellationTombstone = {
            schemaVersion: 1, uid, jobID, requestID,
            createdAt: timestamp, updatedAt: timestamp, expiresAt,
          };
          transaction.create(tombstoneRef, tombstone);
        }
        return undefined;
      }
      const job = this.job(rootSnapshot.data());
      if (job.uid !== uid) throw new WorkoutImportStoreError("not-found");
      if (job.status === "completed" || job.status === "cancelled") return job;
      const updated: StoredWorkoutImportJob = {
        ...job,
        requestID,
        status: "cancelled",
        cancelled: true,
        workerLeaseToken: undefined,
        workerLeasedUntil: undefined,
        updatedAt: timestamp,
      };
      transaction.update(rootRef, {
        requestID,
        status: "cancelled",
        cancelled: true,
        workerLeaseToken: FieldValue.delete(),
        workerLeasedUntil: FieldValue.delete(),
        updatedAt: timestamp,
      });
      transaction.set(tombstoneRef, {
        schemaVersion: 1, uid, jobID, requestID,
        createdAt: tombstoneSnapshot.data()?.createdAt ?? timestamp,
        updatedAt: timestamp, expiresAt,
      });
      return updated;
    });
  }

  async acquireWorker(
    jobID: string,
    generation: number,
    dispatchAttempt: number,
    leaseToken: string,
  ): Promise<WorkoutImportWorkerClaim | WorkoutImportWorkerBusy | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return undefined;
      const raw = snapshot.data();
      if (raw?.schemaVersion !== 2) {
        transaction.update(reference, this.schemaIncompatibleUpdate());
        return undefined;
      }
      const job = this.job(raw);
      if (job.generation !== generation || job.dispatchAttempt !== dispatchAttempt || isTerminalWorkoutImportJob(job)) {
        return undefined;
      }
      if (millis(job.workerLeasedUntil) > this.now() && job.workerLeaseToken !== leaseToken) {
        return { status: "busy" };
      }
      const timestamp = this.timestamp();
      const leasedUntil = this.lease(timestamp, WORKER_LEASE_MS);
      const updated: StoredWorkoutImportJob = {
        ...job,
        status: "processing",
        dispatchState: "dispatched",
        workerLeaseToken: leaseToken,
        workerLeasedUntil: leasedUntil,
        updatedAt: timestamp,
      };
      transaction.update(reference, {
        status: "processing",
        dispatchState: "dispatched",
        workerLeaseToken: leaseToken,
        workerLeasedUntil: leasedUntil,
        updatedAt: timestamp,
      });
      return { status: "acquired", job: updated, workerLeaseToken: leaseToken };
    });
  }

  async heartbeatWorker(jobID: string, generation: number, leaseToken: string): Promise<boolean> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return false;
      const root = this.job(snapshot.data());
      if (!this.activeWorker(root, generation, leaseToken)) return false;
      const timestamp = this.timestamp();
      transaction.update(reference, {
        workerLeasedUntil: this.lease(timestamp, WORKER_LEASE_MS), updatedAt: timestamp,
      });
      return true;
    });
  }

  async releaseWorker(
    jobID: string,
    generation: number,
    leaseToken: string,
  ): Promise<StoredWorkoutImportJob | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return undefined;
      const root = this.job(snapshot.data());
      if (root.generation !== generation || root.workerLeaseToken !== leaseToken || isTerminalWorkoutImportJob(root)) {
        return undefined;
      }
      const timestamp = this.timestamp();
      const updated: StoredWorkoutImportJob = {
        ...root,
        status: "queued",
        dispatchState: "dispatched",
        workerLeaseToken: undefined,
        workerLeasedUntil: undefined,
        updatedAt: timestamp,
      };
      transaction.update(reference, {
        status: "queued",
        dispatchState: "dispatched",
        workerLeaseToken: FieldValue.delete(),
        workerLeasedUntil: FieldValue.delete(),
        updatedAt: timestamp,
      });
      return updated;
    });
  }

  async sections(jobID: string, generation: number): Promise<StoredWorkoutImportSection[]> {
    const rootSnapshot = await this.root(jobID).get();
    if (!rootSnapshot.exists) return [];
    const root = this.job(rootSnapshot.data());
    if (root.generation !== generation) return [];
    const snapshots = await this.database.getAll(...root.sectionIDs.map((sectionID) => this.section(jobID, sectionID)));
    return snapshots
      .filter((snapshot) => snapshot.exists)
      .map((snapshot) => this.sectionValue(snapshot.data()))
      .filter((section) => section.generation === generation)
      .sort((left, right) => left.order - right.order);
  }

  async claimSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
  ): Promise<WorkoutImportSectionClaim | undefined> {
    return this.database.runTransaction(async (transaction) => {
      const rootRef = this.root(jobID);
      const sectionRef = this.section(jobID, sectionID);
      const [rootSnapshot, sectionSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(sectionRef),
      ]);
      if (!rootSnapshot.exists || !sectionSnapshot.exists) return undefined;
      const root = this.job(rootSnapshot.data());
      const section = this.sectionValue(sectionSnapshot.data());
      if (!this.activeWorker(root, generation, workerLeaseToken) || section.generation !== generation ||
          section.status === "completed" ||
          (section.status === "failed" && isTerminalWorkoutImportFailure(section.failureCode))) return undefined;
      if (section.status === "processing" && millis(section.leasedUntil) > this.now()) return undefined;
      if (section.attempts >= MAX_SECTION_ATTEMPTS) {
        const timestamp = this.timestamp();
        transaction.update(sectionRef, {
          status: "failed", failureCode: "provider_unavailable", updatedAt: timestamp,
        });
        transaction.update(rootRef, {
          status: "failed", failureCode: "provider_unavailable",
          workerLeaseToken: FieldValue.delete(), workerLeasedUntil: FieldValue.delete(), updatedAt: timestamp,
        });
        return undefined;
      }
      const timestamp = this.timestamp();
      const leasedUntil = this.lease(timestamp, SECTION_LEASE_MS);
      const claimed: StoredWorkoutImportSection = {
        ...section,
        status: "processing",
        claimToken,
        leasedUntil,
        failureCode: undefined,
        updatedAt: timestamp,
      };
      transaction.update(sectionRef, {
        status: "processing", claimToken, leasedUntil,
        failureCode: FieldValue.delete(), updatedAt: timestamp,
      });
      return { section: claimed, claimToken };
    });
  }

  async reserveProviderCall(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    outputTokens: number,
  ): Promise<WorkoutImportProviderReservation> {
    return this.database.runTransaction(async (transaction) => {
      const rootRef = this.root(jobID);
      const sectionRef = this.section(jobID, sectionID);
      const [rootSnapshot, sectionSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(sectionRef),
      ]);
      if (!rootSnapshot.exists || !sectionSnapshot.exists) return "stale";
      const root = this.job(rootSnapshot.data());
      const section = this.sectionValue(sectionSnapshot.data());
      if (!this.activeClaim(root, section, generation, workerLeaseToken, claimToken)) return "stale";
      if (!withinWorkoutImportJobBudget(root, outputTokens) ||
          section.providerCalls >= MAX_SECTION_PROVIDER_CALLS) return "budget_exhausted";
      const timestamp = this.timestamp();
      transaction.update(rootRef, {
        providerCalls: root.providerCalls + 1,
        outputTokensReserved: root.outputTokensReserved + outputTokens,
        workerLeasedUntil: this.lease(timestamp, WORKER_LEASE_MS),
        updatedAt: timestamp,
      });
      transaction.update(sectionRef, {
        providerCalls: section.providerCalls + 1,
        outputTokensReserved: section.outputTokensReserved + outputTokens,
        leasedUntil: this.lease(timestamp, SECTION_LEASE_MS),
        updatedAt: timestamp,
      });
      return "reserved";
    });
  }

  async saveRepairState(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    repairInput: unknown,
    diagnostic: WorkoutDocumentValidationDiagnostic,
  ): Promise<boolean> {
    assertEncodedSize(repairInput, MAX_SECTION_INPUT_BYTES, "repair_input");
    return this.mutateActiveSection(
      jobID, generation, workerLeaseToken, sectionID, claimToken,
      (section) => {
        if (section.repairAttempts >= MAX_SECTION_REPAIR_ATTEMPTS) return undefined;
        const timestamp = this.timestamp();
        const repairAttempts = section.repairAttempts + 1;
        assertEncodedSize({
          ...section,
          repairInput,
          repairDiagnostic: diagnostic,
          repairAttempts,
          updatedAt: timestamp,
        }, MAX_SECTION_DOCUMENT_BYTES, "section_document");
        return {
          value: true,
          update: {
            repairInput, repairDiagnostic: diagnostic, repairAttempts,
            leasedUntil: this.lease(timestamp, SECTION_LEASE_MS), updatedAt: timestamp,
          },
        };
      },
    );
  }

  async completeSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    document: ParsedWorkoutDocument,
    repaired: boolean,
    fallbackReason?: WorkoutImportFailureCode,
  ): Promise<boolean> {
    assertEncodedSize(document, MAX_SECTION_RESULT_BYTES, "section_result");
    const rootRef = this.root(jobID);
    const sectionRef = this.section(jobID, sectionID);
    return this.database.runTransaction(async (transaction) => {
      const [rootSnapshot, sectionSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(sectionRef),
      ]);
      if (!rootSnapshot.exists || !sectionSnapshot.exists) return false;
      const root = this.job(rootSnapshot.data());
      const section = this.sectionValue(sectionSnapshot.data());
      if (!this.activeClaim(root, section, generation, workerLeaseToken, claimToken)) return false;
      const timestamp = this.timestamp();
      const {
        repairInput: _repairInput,
        repairDiagnostic: _repairDiagnostic,
        claimToken: _claimToken,
        leasedUntil: _leasedUntil,
        failureCode: _failureCode,
        ...retainedSection
      } = section;
      assertEncodedSize({
        ...retainedSection,
        status: "completed",
        result: document,
        repaired,
        ...(fallbackReason ? { failureCode: fallbackReason } : {}),
        updatedAt: timestamp,
      }, MAX_SECTION_DOCUMENT_BYTES, "section_document");
      transaction.update(sectionRef, {
        status: "completed", result: document, repaired,
        repairInput: FieldValue.delete(), repairDiagnostic: FieldValue.delete(),
        claimToken: FieldValue.delete(), leasedUntil: FieldValue.delete(),
        failureCode: fallbackReason ?? FieldValue.delete(), updatedAt: timestamp,
      });
      transaction.update(rootRef, {
        completedSections: root.completedSections + 1,
        workerLeasedUntil: this.lease(timestamp, WORKER_LEASE_MS),
        updatedAt: timestamp,
      });
      return true;
    });
  }

  async failSection(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    failureCode: WorkoutImportFailureCode,
    terminal: boolean,
  ): Promise<boolean> {
    const rootRef = this.root(jobID);
    const sectionRef = this.section(jobID, sectionID);
    return this.database.runTransaction(async (transaction) => {
      const [rootSnapshot, sectionSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(sectionRef),
      ]);
      if (!rootSnapshot.exists || !sectionSnapshot.exists) return false;
      const root = this.job(rootSnapshot.data());
      const section = this.sectionValue(sectionSnapshot.data());
      if (!this.activeClaim(root, section, generation, workerLeaseToken, claimToken)) return false;
      const timestamp = this.timestamp();
      const attempts = failureCode === "provider_unavailable" ? section.attempts + 1 : section.attempts;
      transaction.update(sectionRef, {
        status: "failed", failureCode, attempts,
        claimToken: FieldValue.delete(), leasedUntil: FieldValue.delete(), updatedAt: timestamp,
      });
      if (terminal) {
        transaction.update(rootRef, {
          status: "failed", failureCode,
          workerLeaseToken: FieldValue.delete(), workerLeasedUntil: FieldValue.delete(), updatedAt: timestamp,
        });
      }
      return true;
    });
  }

  async completeJob(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    document: ParsedWorkoutDocument,
  ): Promise<boolean> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return false;
      const root = this.job(snapshot.data());
      if (!this.activeWorker(root, generation, workerLeaseToken)) return false;
      // The job produced a document, so this is where the athlete's daily count is charged.
      // Idempotent on the client job id, so a fast-path attempt that already charged it is not
      // charged twice, and a job that never got here was never charged at all.
      await chargeImportJobIn(transaction, this.database, root.uid, root.clientJobID, this.now());
      const timestamp = this.timestamp();
      const updated = {
        ...root,
        status: "completed" as const,
        document,
        completedSections: root.totalSections,
        workerLeaseToken: undefined,
        workerLeasedUntil: undefined,
        updatedAt: timestamp,
      };
      assertEncodedSize(updated, MAX_ROOT_ENCODED_BYTES, "root");
      transaction.update(reference, {
        status: "completed", document, completedSections: root.totalSections,
        workerLeaseToken: FieldValue.delete(), workerLeasedUntil: FieldValue.delete(), updatedAt: timestamp,
      });
      return true;
    });
  }

  async failJob(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    failureCode: WorkoutImportFailureCode,
  ): Promise<boolean> {
    return this.database.runTransaction(async (transaction) => {
      const reference = this.root(jobID);
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return false;
      const root = this.job(snapshot.data());
      if (!this.activeWorker(root, generation, workerLeaseToken)) return false;
      transaction.update(reference, {
        status: "failed", failureCode,
        workerLeaseToken: FieldValue.delete(), workerLeasedUntil: FieldValue.delete(), updatedAt: this.timestamp(),
      });
      return true;
    });
  }

  private async mutateActiveSection<T>(
    jobID: string,
    generation: number,
    workerLeaseToken: string,
    sectionID: string,
    claimToken: string,
    mutation: (section: StoredWorkoutImportSection) => { value: T; update: Record<string, unknown> } | undefined,
  ): Promise<T | false> {
    const rootRef = this.root(jobID);
    const sectionRef = this.section(jobID, sectionID);
    return this.database.runTransaction(async (transaction) => {
      const [rootSnapshot, sectionSnapshot] = await Promise.all([
        transaction.get(rootRef), transaction.get(sectionRef),
      ]);
      if (!rootSnapshot.exists || !sectionSnapshot.exists) return false;
      const root = this.job(rootSnapshot.data());
      const section = this.sectionValue(sectionSnapshot.data());
      if (!this.activeClaim(root, section, generation, workerLeaseToken, claimToken)) return false;
      const result = mutation(section);
      if (!result) return false;
      transaction.update(sectionRef, result.update);
      return result.value;
    });
  }

  private activeWorker(root: StoredWorkoutImportJob, generation: number, token: string): boolean {
    return root.generation === generation && root.workerLeaseToken === token &&
      millis(root.workerLeasedUntil) > this.now() && isTerminalWorkoutImportJob(root) === false;
  }

  private activeClaim(
    root: StoredWorkoutImportJob,
    section: StoredWorkoutImportSection,
    generation: number,
    workerToken: string,
    claimToken: string,
  ): boolean {
    return this.activeWorker(root, generation, workerToken) &&
      section.generation === generation && section.status === "processing" &&
      section.claimToken === claimToken && millis(section.leasedUntil) > this.now();
  }

  private job(value: FirebaseFirestore.DocumentData | undefined): StoredWorkoutImportJob {
    if (!value || value.schemaVersion !== 2) throw new WorkoutImportStoreError("failed-precondition");
    return value as StoredWorkoutImportJob;
  }

  private incompatibleJob(
    value: FirebaseFirestore.DocumentData | undefined,
    fallbackJobID: string,
  ): StoredWorkoutImportJob {
    if (!value || typeof value !== "object") {
      throw new WorkoutImportStoreError("failed-precondition");
    }
    const timestamp = this.timestamp();
    const sectionIDs = Array.isArray(value.sectionIDs)
      ? value.sectionIDs.filter((item): item is string => typeof item === "string")
      : [];
    return {
      schemaVersion: 2,
      uid: typeof value.uid === "string" ? value.uid : "",
      clientJobID: typeof value.clientJobID === "string" ? value.clientJobID : fallbackJobID,
      requestID: typeof value.requestID === "string" ? value.requestID : fallbackJobID,
      jobHash: typeof value.jobHash === "string" ? value.jobHash : "",
      generation: positiveInteger(value.generation, 1),
      status: "failed",
      dispatchState: "dispatched",
      dispatchAttempt: positiveInteger(value.dispatchAttempt, 1),
      sectionIDs,
      catalogHints: [],
      completedSections: nonnegativeInteger(value.completedSections),
      totalSections: nonnegativeInteger(value.totalSections, sectionIDs.length),
      providerCalls: nonnegativeInteger(value.providerCalls),
      initialOutputTokenBudget: nonnegativeInteger(value.initialOutputTokenBudget),
      outputTokenBudget: nonnegativeInteger(value.outputTokenBudget),
      outputTokensReserved: nonnegativeInteger(value.outputTokensReserved),
      appliedRequestIDs: [],
      cancelled: false,
      model: typeof value.model === "string" ? value.model : "unknown",
      failureCode: "schema_incompatible",
      createdAt: value.createdAt ?? timestamp,
      updatedAt: timestamp,
      expiresAt: value.expiresAt ?? Timestamp.fromMillis(timestamp.toMillis() + RETENTION_MS),
    };
  }

  private schemaIncompatibleUpdate(): Record<string, unknown> {
    return {
      status: "failed",
      failureCode: "schema_incompatible",
      workerLeaseToken: FieldValue.delete(),
      workerLeasedUntil: FieldValue.delete(),
      updatedAt: this.timestamp(),
    };
  }

  private sectionValue(value: FirebaseFirestore.DocumentData | undefined): StoredWorkoutImportSection {
    if (!value || value.schemaVersion !== 2) throw new WorkoutImportStoreError("failed-precondition");
    return value as StoredWorkoutImportSection;
  }

  private tombstone(value: FirebaseFirestore.DocumentData | undefined): StoredCancellationTombstone {
    if (!value || value.schemaVersion !== 1) throw new WorkoutImportStoreError("failed-precondition");
    return value as StoredCancellationTombstone;
  }

  private cancelledJob(
    uid: string,
    payload: StartWorkoutImportJobPayload,
    model: string,
    tombstone: StoredCancellationTombstone,
  ): StoredWorkoutImportJob {
    const initialBudget = initialOutputTokenBudget(payload);
    return {
      schemaVersion: 2,
      uid,
      clientJobID: payload.clientJobID,
      requestID: tombstone.requestID,
      jobHash: payload.jobHash,
      generation: 1,
      status: "cancelled",
      dispatchState: "needsDispatch",
      dispatchAttempt: 1,
      sectionIDs: [],
      catalogHints: [],
      completedSections: 0,
      totalSections: 0,
      providerCalls: 0,
      initialOutputTokenBudget: initialBudget,
      outputTokenBudget: outputTokenBudget(payload),
      outputTokensReserved: 0,
      appliedRequestIDs: [payload.requestID],
      cancelled: true,
      model,
      createdAt: tombstone.createdAt,
      updatedAt: tombstone.updatedAt,
      expiresAt: tombstone.expiresAt,
    };
  }

  private root(jobID: string) {
    return this.database.collection(ROOT_COLLECTION).doc(jobID);
  }

  private section(jobID: string, sectionID: string) {
    return this.database.collection(SECTION_COLLECTION).doc(sectionDocumentID(jobID, sectionID));
  }

  private cancellation(uid: string, jobID: string) {
    const id = createHash("sha256").update(`${uid}:${jobID}`).digest("hex");
    return this.database.collection(CANCELLATION_COLLECTION).doc(id);
  }

  private timestamp(): Timestamp {
    return Timestamp.fromMillis(this.now());
  }

  private lease(timestamp: Timestamp, duration: number): Timestamp {
    return Timestamp.fromMillis(timestamp.toMillis() + duration);
  }

}

/** A usage refusal keeps its own identity, so the cost guard is never reported as the import limit. */
function storeErrorForUsage(error: unknown): unknown {
  if (!(error instanceof ImportUsageError)) return error;
  return new WorkoutImportStoreError(error.reason === "cost_guard" ? "cost-guard" : "resource-exhausted");
}

function millis(value: unknown): number {
  if (value instanceof Timestamp) return value.toMillis();
  if (value && typeof value === "object" && "toMillis" in value &&
      typeof (value as { toMillis?: unknown }).toMillis === "function") {
    return (value as { toMillis: () => number }).toMillis();
  }
  return 0;
}

function positiveInteger(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : fallback;
}

function nonnegativeInteger(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : fallback;
}

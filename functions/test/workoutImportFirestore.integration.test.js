const test = require("node:test");
const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");

const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

const {
  FirestoreWorkoutImportJobStore,
} = require("../lib/workoutImportFirestoreStore");
const { WorkoutImportJobRuntime } = require("../lib/workoutImportJobRuntime");
const {
  MAX_SECTION_RESULT_BYTES,
  encodedJSONByteCount,
} = require("../lib/workoutImportJobs");

const jobID = "11111111-1111-4111-8111-111111111111";
const requestID = "22222222-2222-4222-8222-222222222222";
const sectionID = "a".repeat(64);

function payload(overrides = {}) {
  return {
    schemaVersion: 1,
    clientJobID: jobID,
    requestID,
    jobHash: "b".repeat(64),
    catalogHints: ["Run"],
    sections: [{
      id: sectionID,
      order: 0,
      observations: [{
        id: "line",
        text: "Run 400 m",
        sourceImageIndex: 0,
        confidence: 0.9,
        boundingBox: { x: 0, y: 0, width: 1, height: 0.1 },
      }],
      contextBefore: [],
      provenance: [{ primaryID: "line", sourceObservationIDs: ["line"] }],
      startScopeID: sectionID,
      endScopeID: sectionID,
    }],
    ...overrides,
  };
}

function document(title = "Run") {
  return { title, notes: [], blocks: [] };
}

function validIR() {
  return {
    schemaVersion: 1,
    title: "Run workout",
    goal: "",
    ignoredObservationIDs: [],
    records: [
      {
        id: "block",
        kind: "block",
        parentID: "",
        order: 0,
        attributes: [{ key: "name", value: "Main" }],
        sourceObservationIDs: ["o1"],
      },
      {
        id: "run",
        kind: "exercise",
        parentID: "block",
        order: 0,
        attributes: [{ key: "name", value: "Run" }],
        sourceObservationIDs: ["o1"],
      },
    ],
  };
}

function runtime(store, queue, provider, now = () => Date.now()) {
  let identifier = 0;
  return new WorkoutImportJobRuntime({
    store,
    queue,
    provider,
    now,
    randomID: () => `emulator-token-${identifier++}`,
    logger: { info() {}, warn() {} },
  });
}

let app;
let db;

test.before(async () => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, "run with Firebase emulators:exec");
  app = initializeApp({ projectId: "baseline-import-test" }, `workout-import-${Date.now()}`);
  db = getFirestore(app);
  db.settings({ ignoreUndefinedProperties: true });
});

test.after(async () => {
  await deleteApp(app);
});

test.beforeEach(async () => {
  for (const name of [
    "workoutImportJobs",
    "workoutImportJobSections",
    "workoutImportJobCancellations",
    "users",
  ]) {
    await db.recursiveDelete(db.collection(name));
  }
});

test("actual store enforces quota idempotency, hash identity, and ownership", async () => {
  let now = Date.UTC(2026, 6, 14);
  const store = new FirestoreWorkoutImportJobStore(db, 1, () => now);
  const first = await store.createOrGet("owner", payload(), "model");
  const same = await store.createOrGet("owner", payload(), "model");
  assert.equal(first.created, true);
  assert.equal(same.created, false);
  assert.equal((await db.doc("users/owner/usage/2026-07-14").get()).data().workoutImports, 1);

  await assert.rejects(
    store.createOrGet("owner", payload({ jobHash: "c".repeat(64) }), "model"),
    (error) => error.code === "already-exists",
  );
  await assert.rejects(store.getOwned(jobID, "intruder"), (error) => error.code === "not-found");
  now += 1;
  await assert.rejects(
    store.createOrGet("owner", payload({ clientJobID: "33333333-3333-4333-8333-333333333333" }), "model"),
    (error) => error.code === "resource-exhausted",
  );
});

test("actual store cancel-before-create tombstone blocks late creation without quota", async () => {
  const now = Date.UTC(2026, 6, 14);
  const store = new FirestoreWorkoutImportJobStore(db, 1, () => now);
  const cancelID = "33333333-3333-4333-8333-333333333333";
  assert.equal(await store.cancel(jobID, "owner", cancelID), undefined);
  assert.equal(await store.cancel(jobID, "owner", cancelID), undefined);
  const late = await store.createOrGet("owner", payload(), "model");
  assert.equal(late.created, false);
  assert.equal(late.job.status, "cancelled");
  assert.equal((await db.collection("workoutImportJobs").count().get()).data().count, 0);
  assert.equal((await db.collection("workoutImportJobCancellations").count().get()).data().count, 1);
  assert.equal((await db.collection("users").count().get()).data().count, 0);
});

test("actual store recovers dispatch, renews leases, allows takeover, and rejects stale completion", async () => {
  let now = 1_000;
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => now);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  const firstWorker = await store.acquireWorker(jobID, 1, 1, "worker-1");
  assert.equal(firstWorker.status, "acquired");
  assert.equal((await store.acquireWorker(jobID, 1, 1, "worker-2")).status, "busy");
  const firstClaim = await store.claimSection(jobID, 1, "worker-1", sectionID, "claim-1");
  assert.ok(firstClaim);
  const leaseBefore = (await db.collection("workoutImportJobSections").doc(`${jobID}_${sectionID}`).get())
    .data().leasedUntil.toMillis();
  now += 20_000;
  assert.equal(
    await store.reserveProviderCall(jobID, 1, "worker-1", sectionID, "claim-1", 4_096),
    "reserved",
  );
  const leaseAfter = (await db.collection("workoutImportJobSections").doc(`${jobID}_${sectionID}`).get())
    .data().leasedUntil.toMillis();
  assert.ok(leaseAfter > leaseBefore);

  now += 181_000;
  const takeover = await store.acquireWorker(jobID, 1, 1, "worker-2");
  assert.equal(takeover.status, "acquired");
  const secondClaim = await store.claimSection(jobID, 1, "worker-2", sectionID, "claim-2");
  assert.ok(secondClaim);
  assert.equal(
    await store.completeSection(jobID, 1, "worker-1", sectionID, "claim-1", document("Late"), false),
    false,
  );
  assert.equal(
    await store.completeSection(jobID, 1, "worker-2", sectionID, "claim-2", document("Current"), false),
    true,
  );
  assert.equal((await store.sections(jobID, 1))[0].result.title, "Current");

  await store.releaseWorker(jobID, 1, "worker-2");
  now += 91_000;
  const recovered = await store.recoverDispatch(jobID, 1);
  assert.equal(recovered.dispatchState, "needsDispatch");
  assert.equal(recovered.dispatchAttempt, 2);
});

test("actual store exact task replay completes after transient failure without a client status call", async () => {
  let now = 1_000;
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => now);
  let providerCalls = 0;
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async () => {
      providerCalls += 1;
      if (providerCalls === 1) throw new Error("provider unavailable");
      return validIR();
    },
  }, () => now);
  await service.start("owner", payload(), "model");

  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  const released = await store.getOwned(jobID, "owner");
  assert.equal(released.dispatchAttempt, 1);
  assert.equal(released.dispatchState, "dispatched");

  now += 1;
  await service.process(jobID, 1, 1);
  const completed = await store.getOwned(jobID, "owner");
  assert.equal(completed.status, "completed");
  assert.equal(completed.dispatchAttempt, 1);
  assert.deepEqual(completed.document.blocks[0].sourceObservationIDs, ["line"]);
  assert.deepEqual(
    completed.document.blocks[0].nodes[0].exercise.sourceObservationIDs,
    ["line"],
  );
});

test("actual store durable dispatcher heals initial enqueue failure without a client request", async () => {
  const now = 1_000;
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => now);
  const enqueued = [];
  let unavailable = true;
  const service = runtime(store, {
    enqueue: async (taskPayload) => {
      if (unavailable) throw new Error("queue unavailable");
      enqueued.push(taskPayload);
    },
  }, { request: async () => validIR() }, () => now);

  await service.start("owner", payload(), "model");
  assert.equal((await store.getOwned(jobID, "owner")).dispatchState, "needsDispatch");
  unavailable = false;
  await service.dispatch(jobID, 1);

  assert.deepEqual(enqueued, [{ serverJobID: jobID, generation: 1, dispatchAttempt: 1 }]);
  assert.equal((await store.getOwned(jobID, "owner")).dispatchState, "dispatched");
});

test("actual store hard-crash lease recovery accepts the same task payload after expiry", async () => {
  let now = 1_000;
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => now);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  assert.equal((await store.acquireWorker(jobID, 1, 1, "crashed-worker")).status, "acquired");
  assert.ok(await store.claimSection(jobID, 1, "crashed-worker", sectionID, "crashed-claim"));
  const service = runtime(store, { enqueue: async () => assert.fail("must not enqueue") }, {
    request: async () => validIR(),
  }, () => now);

  await assert.rejects(service.process(jobID, 1, 1), /worker_busy/);
  now += 180_001;
  await service.process(jobID, 1, 1);

  const completed = await store.getOwned(jobID, "owner");
  assert.equal(completed.status, "completed");
  assert.deepEqual(completed.document.blocks[0].sourceObservationIDs, ["line"]);
});

test("actual store manual retry is idempotent and preserves lifetime budget and repair state", async () => {
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => 1_000);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  await store.acquireWorker(jobID, 1, 1, "worker");
  await store.claimSection(jobID, 1, "worker", sectionID, "claim");
  assert.equal(
    await store.reserveProviderCall(jobID, 1, "worker", sectionID, "claim", 4_096),
    "reserved",
  );
  assert.equal(await store.saveRepairState(
    jobID, 1, "worker", sectionID, "claim",
    { schemaVersion: 1, title: "Invalid", goal: "", ignoredObservationIDs: [], records: [] },
    { code: "empty_workout", path: "records" },
  ), true);
  assert.equal(await store.saveRepairState(
    jobID, 1, "worker", sectionID, "claim",
    { schemaVersion: 1, title: "Still invalid", goal: "", ignoredObservationIDs: [], records: [] },
    { code: "ir.attribute", path: "ir.records[0].attributes", expectedAttribute: "name" },
  ), true);
  assert.equal(await store.saveRepairState(
    jobID, 1, "worker", sectionID, "claim",
    { schemaVersion: 1, title: "Third invalid", goal: "", ignoredObservationIDs: [], records: [] },
    { code: "ir.shape", path: "ir" },
  ), true);
  assert.equal(await store.saveRepairState(
    jobID, 1, "worker", sectionID, "claim",
    { schemaVersion: 1, title: "Fourth invalid", goal: "", ignoredObservationIDs: [], records: [] },
    { code: "ir.shape", path: "ir" },
  ), false);
  assert.equal(await store.failSection(
    jobID, 1, "worker", sectionID, "claim", "provider_unavailable", true,
  ), true);

  const retryID = "44444444-4444-4444-8444-444444444444";
  const retried = await store.retry(jobID, "owner", retryID);
  const duplicate = await store.retry(jobID, "owner", retryID);
  const section = (await store.sections(jobID, 2))[0];
  assert.equal(retried.generation, 2);
  assert.equal(duplicate.generation, 2);
  assert.equal(retried.providerCalls, 1);
  assert.equal(retried.outputTokensReserved, 4_096);
  assert.deepEqual(retried.appliedRequestIDs, [requestID, retryID]);
  assert.equal(section.providerCalls, 1);
  assert.equal(section.outputTokensReserved, 4_096);
  assert.equal(section.repairAttempts, 3);
  assert.ok(section.repairInput);
  assert.equal(section.repairInput.title, "Third invalid");
});

test("actual store cancellation blocks late section and job completion", async () => {
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => 1_000);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  await store.acquireWorker(jobID, 1, 1, "worker");
  await store.claimSection(jobID, 1, "worker", sectionID, "claim");
  await store.cancel(jobID, "owner", "55555555-5555-4555-8555-555555555555");
  assert.equal(
    await store.completeSection(jobID, 1, "worker", sectionID, "claim", document("Late"), false),
    false,
  );
  assert.equal(await store.completeJob(jobID, 1, "worker", document("Late root")), false);
  assert.equal((await store.getOwned(jobID, "owner")).status, "cancelled");
});

test("actual store accepts the fourth section provider call and rejects the fifth", async () => {
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => 1_000);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  await store.acquireWorker(jobID, 1, 1, "worker");
  await store.claimSection(jobID, 1, "worker", sectionID, "claim");

  for (let call = 1; call <= 4; call += 1) {
    assert.equal(
      await store.reserveProviderCall(jobID, 1, "worker", sectionID, "claim", 2_048),
      "reserved",
      `provider call ${call} should be allowed`,
    );
  }
  assert.equal(
    await store.reserveProviderCall(jobID, 1, "worker", sectionID, "claim", 2_048),
    "budget_exhausted",
  );
  const section = (await store.sections(jobID, 1))[0];
  const root = await store.getOwned(jobID, "owner");
  assert.equal(section.providerCalls, 4);
  assert.equal(root.providerCalls, 4);
});

test("actual store enforces exact section result boundary before Firestore persistence", async () => {
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => 1_000);
  await store.createOrGet("owner", payload(), "model");
  await store.markDispatched(jobID, 1, 1);
  await store.acquireWorker(jobID, 1, 1, "worker");
  await store.claimSection(jobID, 1, "worker", sectionID, "claim");

  const base = document("");
  const exact = document("x".repeat(MAX_SECTION_RESULT_BYTES - encodedJSONByteCount(base)));
  assert.equal(encodedJSONByteCount(exact), MAX_SECTION_RESULT_BYTES);
  assert.equal(
    await store.completeSection(jobID, 1, "worker", sectionID, "claim", exact, false),
    true,
  );

  await db.recursiveDelete(db.collection("workoutImportJobs"));
  await db.recursiveDelete(db.collection("workoutImportJobSections"));
  const second = new FirestoreWorkoutImportJobStore(db, 10, () => 2_000);
  await second.createOrGet("owner", payload(), "model");
  await second.markDispatched(jobID, 1, 1);
  await second.acquireWorker(jobID, 1, 1, "worker");
  await second.claimSection(jobID, 1, "worker", sectionID, "claim");
  await assert.rejects(
    second.completeSection(jobID, 1, "worker", sectionID, "claim", document(`${exact.title}x`), false),
    /section_result_too_large/,
  );
});

test("actual store terminalizes an incompatible stored schema before typed use", async () => {
  await db.collection("workoutImportJobs").doc(jobID).set({
    schemaVersion: 1,
    uid: "owner",
    clientJobID: jobID,
    generation: 1,
    dispatchAttempt: 1,
    completedSections: 0,
    totalSections: 1,
    model: "legacy-model",
    createdAt: 1_000,
    updatedAt: 1_000,
    expiresAt: 86_401_000,
  });
  const store = new FirestoreWorkoutImportJobStore(db, 10, () => 1_000);
  const incompatible = await store.getOwned(jobID, "owner");
  assert.equal(incompatible.status, "failed");
  assert.equal(incompatible.failureCode, "schema_incompatible");
  const persisted = (await db.collection("workoutImportJobs").doc(jobID).get()).data();
  assert.equal(persisted.status, "failed");
  assert.equal(persisted.failureCode, "schema_incompatible");
});

test("cancellation document key is private and deterministic", () => {
  const first = createHash("sha256").update(`owner:${jobID}`).digest("hex");
  const second = createHash("sha256").update(`owner:${jobID}`).digest("hex");
  assert.equal(first, second);
  assert.equal(first.length, 64);
});

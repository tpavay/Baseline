const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  createWorkoutImportProviderAliasBoundary,
} = require("../lib/workoutImport");
const {
  buildWorkoutImportFallbackSectionDocument,
  WorkoutImportJobRuntime,
  WorkoutImportProviderOutputTruncated,
  withinWorkoutImportJobBudget,
} = require("../lib/workoutImportJobRuntime");
const {
  MAX_JOB_OUTPUT_TOKENS,
  MAX_JOB_PROVIDER_CALLS,
  MAX_RESULT_ENCODED_BYTES,
  MAX_ROOT_ENCODED_BYTES,
  MAX_SECTION_DOCUMENT_BYTES,
  MAX_SECTION_INPUT_BYTES,
  MAX_SECTION_REPAIR_ATTEMPTS,
  MAX_SECTION_PROVIDER_CALLS,
  MAX_SECTION_RESULT_BYTES,
  assertEncodedSize,
  encodedJSONByteCount,
  initialOutputTokenBudget,
  outputTokenBudget,
  parseStartWorkoutImportJobPayload,
} = require("../lib/workoutImportJobs");

const jobID = "11111111-1111-4111-8111-111111111111";
const requestID = "22222222-2222-4222-8222-222222222222";

function sectionID(index = 0) {
  return (index + 10).toString(16).repeat(64).slice(0, 64);
}

function observation(id = "line", text = "Run 400 m") {
  return {
    id,
    text,
    sourceImageIndex: 0,
    confidence: 0.9,
    boundingBox: { x: 0, y: 0, width: 1, height: 0.1 },
  };
}

function payload(sectionCount = 1, text = "Run 400 m") {
  return {
    schemaVersion: 1,
    clientJobID: jobID,
    requestID,
    jobHash: "b".repeat(64),
    catalogHints: ["Run"],
    sections: Array.from({ length: sectionCount }, (_, index) => {
      const id = sectionID(index);
      const lineID = `line-${index}`;
      return {
        id,
        order: index,
        observations: [observation(lineID, text)],
        contextBefore: [],
        provenance: [{ primaryID: lineID, sourceObservationIDs: [lineID, `${lineID}-source-2`] }],
        startScopeID: id,
        endScopeID: id,
      };
    }),
  };
}

function validIR(lineID = "line-0") {
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
        sourceObservationIDs: [lineID],
      },
      {
        id: "run",
        kind: "exercise",
        parentID: "block",
        order: 0,
        attributes: [{ key: "name", value: "Run" }],
        sourceObservationIDs: [lineID],
      },
    ],
  };
}

test("OCR fallback preserves recognized lines without inventing an exercise", () => {
  const document = buildWorkoutImportFallbackSectionDocument({
    order: 1,
    observations: [
      observation("line-a", "6 sets of bike intervals"),
      observation("line-b", "50 seconds work at RPE 6-8"),
    ],
  });

  assert.equal(document.blocks[0].name, "Imported section 2");
  const fallback = document.blocks[0].nodes[0].group;
  assert.deepEqual(fallback.notes, ["6 sets of bike intervals\n50 seconds work at RPE 6-8"]);
  assert.deepEqual(fallback.children, []);
  assert.deepEqual(fallback.sourceObservationIDs, ["line-a", "line-b"]);
  assert.equal(JSON.stringify(document).includes('"exercise"'), false);
});

function parsedDocumentWithEncodedSize(targetBytes, lineID = "line-0") {
  for (let workoutNoteCount = 0; workoutNoteCount <= 50; workoutNoteCount += 1) {
    for (let blockNoteCount = 0; blockNoteCount <= 50; blockNoteCount += 1) {
      const document = {
        title: "Sized workout",
        notes: Array.from({ length: workoutNoteCount }, () => "x"),
        blocks: [{
          name: "Main",
          notes: Array.from({ length: blockNoteCount }, () => "x"),
          nodes: [{
            type: "exercise",
            exercise: {
              name: "Run",
              sets: [],
              notes: [],
              intensityTargets: [],
              sourceObservationIDs: [lineID],
            },
          }],
          sourceObservationIDs: [lineID],
        }],
      };
      const notes = [...document.notes, ...document.blocks[0].notes];
      const minimumBytes = encodedJSONByteCount(document);
      const maximumBytes = minimumBytes + (notes.length * 3_999);
      if (minimumBytes > targetBytes || maximumBytes < targetBytes) continue;
      let remaining = targetBytes - minimumBytes;
      for (let index = 0; index < notes.length && remaining > 0; index += 1) {
        const extra = Math.min(3_999, remaining);
        notes[index] += "x".repeat(extra);
        remaining -= extra;
      }
      document.notes = notes.slice(0, workoutNoteCount);
      document.blocks[0].notes = notes.slice(workoutNoteCount);
      assert.equal(remaining, 0);
      assert.equal(encodedJSONByteCount(document), targetBytes);
      return document;
    }
  }
  throw new Error(`could not construct a valid document at ${targetBytes} bytes`);
}

class MemoryStore {
  constructor(now = 0) {
    this.now = now;
    this.root = undefined;
    this.sectionsByID = new Map();
    this.tombstones = new Set();
    this.throwOnComplete = undefined;
  }

  async createOrGet(uid, input, model) {
    if (this.root) {
      if (this.root.uid !== uid) throw new Error("permission-denied");
      if (this.root.jobHash !== input.jobHash) throw new Error("already-exists");
      return { job: structuredClone(this.root), created: false };
    }
    if (this.tombstones.has(`${uid}:${input.clientJobID}`)) {
      return {
        created: false,
        job: this.makeRoot(uid, input, model, true),
      };
    }
    this.root = this.makeRoot(uid, input, model, false);
    for (const source of input.sections) {
      this.sectionsByID.set(source.id, {
        schemaVersion: 2,
        jobID: input.clientJobID,
        generation: 1,
        ...structuredClone(source),
        status: "pending",
        attempts: 0,
        providerCalls: 0,
        outputTokensReserved: 0,
        repairAttempts: 0,
        createdAt: this.now,
        updatedAt: this.now,
        expiresAt: this.now + 86_400_000,
      });
    }
    return { job: structuredClone(this.root), created: true };
  }

  makeRoot(uid, input, model, cancelled) {
    const initialBudget = initialOutputTokenBudget(input);
    return {
      schemaVersion: 2,
      uid,
      clientJobID: input.clientJobID,
      requestID: input.requestID,
      jobHash: input.jobHash,
      generation: 1,
      status: cancelled ? "cancelled" : "queued",
      dispatchState: "needsDispatch",
      dispatchAttempt: 1,
      sectionIDs: cancelled ? [] : input.sections.map((section) => section.id),
      catalogHints: input.catalogHints,
      completedSections: 0,
      totalSections: cancelled ? 0 : input.sections.length,
      providerCalls: 0,
      initialOutputTokenBudget: initialBudget,
      outputTokenBudget: outputTokenBudget(input),
      outputTokensReserved: 0,
      appliedRequestIDs: [input.requestID],
      cancelled,
      model,
      createdAt: this.now,
      updatedAt: this.now,
      expiresAt: this.now + 86_400_000,
    };
  }

  async getOwned(id, uid) {
    if (!this.root || this.root.clientJobID !== id || this.root.uid !== uid) throw new Error("not-found");
    return structuredClone(this.root);
  }

  async recoverDispatch(id, generation) {
    if (!this.root || this.root.clientJobID !== id || this.root.generation !== generation) return undefined;
    if (this.root.dispatchState === "dispatched" && !this.workerActive() &&
        (this.root.dispatchedAt ?? 0) + 210_000 <= this.now) {
      this.root.dispatchState = "needsDispatch";
      this.root.dispatchAttempt += 1;
      this.root.status = "queued";
      this.root.dispatchedAt = undefined;
      this.root.workerLeaseToken = undefined;
      this.root.workerLeasedUntil = undefined;
    }
    return structuredClone(this.root);
  }

  async markDispatched(id, generation, attempt) {
    if (!this.root || this.root.clientJobID !== id || this.root.generation !== generation ||
        this.root.dispatchAttempt !== attempt || this.root.dispatchState !== "needsDispatch") return undefined;
    this.root.dispatchState = "dispatched";
    this.root.dispatchedAt = this.now;
    return structuredClone(this.root);
  }

  async retry(id, uid, nextRequestID) {
    await this.getOwned(id, uid);
    if (this.root.appliedRequestIDs.includes(nextRequestID)) return structuredClone(this.root);
    if (this.root.status !== "failed") return structuredClone(this.root);
    this.root.appliedRequestIDs.push(nextRequestID);
    this.root.generation += 1;
    this.root.requestID = nextRequestID;
    this.root.status = "queued";
    this.root.dispatchState = "needsDispatch";
    this.root.dispatchAttempt += 1;
    this.root.failureCode = undefined;
    this.root.workerLeaseToken = undefined;
    this.root.workerLeasedUntil = undefined;
    for (const section of this.sectionsByID.values()) {
      section.generation = this.root.generation;
      section.claimToken = undefined;
      section.leasedUntil = undefined;
      if (section.status !== "completed") {
        section.status = "pending";
        section.attempts = 0;
        section.failureCode = undefined;
      }
    }
    return structuredClone(this.root);
  }

  async cancel(id, uid, nextRequestID) {
    if (!this.root) {
      this.tombstones.add(`${uid}:${id}`);
      return undefined;
    }
    await this.getOwned(id, uid);
    this.tombstones.add(`${uid}:${id}`);
    this.root.requestID = nextRequestID;
    this.root.status = "cancelled";
    this.root.cancelled = true;
    this.root.workerLeaseToken = undefined;
    this.root.workerLeasedUntil = undefined;
    return structuredClone(this.root);
  }

  async acquireWorker(id, generation, attempt, token) {
    if (!this.root || this.root.clientJobID !== id || this.root.generation !== generation ||
        this.root.dispatchAttempt !== attempt || this.root.cancelled ||
        ["completed", "failed", "cancelled"].includes(this.root.status)) return undefined;
    if (this.workerActive() && this.root.workerLeaseToken !== token) return { status: "busy" };
    this.root.status = "processing";
    this.root.workerLeaseToken = token;
    this.root.workerLeasedUntil = this.now + 180_000;
    return { status: "acquired", job: structuredClone(this.root), workerLeaseToken: token };
  }

  async heartbeatWorker(id, generation, token) {
    if (!this.activeRoot(id, generation, token)) return false;
    this.root.workerLeasedUntil = this.now + 180_000;
    return true;
  }

  async releaseWorker(id, generation, token) {
    if (!this.root || this.root.clientJobID !== id || this.root.generation !== generation ||
        this.root.workerLeaseToken !== token || ["completed", "failed", "cancelled"].includes(this.root.status)) {
      return undefined;
    }
    this.root.workerLeaseToken = undefined;
    this.root.workerLeasedUntil = undefined;
    this.root.status = "queued";
    // A retryable Cloud Tasks invocation is replayed with the same durable payload. Releasing the
    // lease must not retire that payload before Cloud Tasks has finished retrying it.
    this.root.dispatchState = "dispatched";
    return structuredClone(this.root);
  }

  async sections(id, generation) {
    if (!this.root || this.root.clientJobID !== id || this.root.generation !== generation) return [];
    return this.root.sectionIDs.map((identifier) => structuredClone(this.sectionsByID.get(identifier)));
  }

  async claimSection(id, generation, workerToken, candidateID, claimToken) {
    const section = this.sectionsByID.get(candidateID);
    if (!section || !this.activeRoot(id, generation, workerToken) || section.generation !== generation ||
        section.status === "completed" || (section.status === "processing" && section.leasedUntil > this.now)) {
      return undefined;
    }
    section.status = "processing";
    section.claimToken = claimToken;
    section.leasedUntil = this.now + 180_000;
    return { section: structuredClone(section), claimToken };
  }

  async reserveProviderCall(id, generation, workerToken, candidateID, claimToken, tokens) {
    const section = this.sectionsByID.get(candidateID);
    if (!this.activeSection(id, generation, workerToken, section, claimToken)) return "stale";
    if (this.root.outputTokensReserved + tokens > this.root.outputTokenBudget ||
        section.providerCalls >= MAX_SECTION_PROVIDER_CALLS) {
      return "budget_exhausted";
    }
    this.root.providerCalls += 1;
    this.root.outputTokensReserved += tokens;
    this.root.workerLeasedUntil = this.now + 180_000;
    section.providerCalls += 1;
    section.outputTokensReserved += tokens;
    section.leasedUntil = this.now + 180_000;
    return "reserved";
  }

  async saveRepairState(id, generation, workerToken, candidateID, claimToken, invalidIR, diagnostic) {
    const section = this.sectionsByID.get(candidateID);
    if (!this.activeSection(id, generation, workerToken, section, claimToken) ||
        section.repairAttempts >= MAX_SECTION_REPAIR_ATTEMPTS) {
      return false;
    }
    section.repairAttempts += 1;
    section.repairInput = structuredClone(invalidIR);
    section.repairDiagnostic = structuredClone(diagnostic);
    return true;
  }

  async completeSection(id, generation, workerToken, candidateID, claimToken, document, repaired) {
    if (this.throwOnComplete) throw this.throwOnComplete;
    const section = this.sectionsByID.get(candidateID);
    if (!this.activeSection(id, generation, workerToken, section, claimToken)) return false;
    section.status = "completed";
    section.result = structuredClone(document);
    section.repaired = repaired;
    section.claimToken = undefined;
    section.leasedUntil = undefined;
    section.repairInput = undefined;
    section.repairDiagnostic = undefined;
    this.root.completedSections += 1;
    return true;
  }

  async failSection(id, generation, workerToken, candidateID, claimToken, code, terminal) {
    const section = this.sectionsByID.get(candidateID);
    if (!this.activeSection(id, generation, workerToken, section, claimToken)) return false;
    section.status = "failed";
    section.failureCode = code;
    if (code === "provider_unavailable") section.attempts += 1;
    section.claimToken = undefined;
    section.leasedUntil = undefined;
    if (terminal) {
      this.root.status = "failed";
      this.root.failureCode = code;
      this.root.workerLeaseToken = undefined;
      this.root.workerLeasedUntil = undefined;
    }
    return true;
  }

  async completeJob(id, generation, workerToken, document) {
    if (!this.activeRoot(id, generation, workerToken)) return false;
    this.root.status = "completed";
    this.root.document = structuredClone(document);
    this.root.workerLeaseToken = undefined;
    this.root.workerLeasedUntil = undefined;
    return true;
  }

  async failJob(id, generation, workerToken, code) {
    if (!this.activeRoot(id, generation, workerToken)) return false;
    this.root.status = "failed";
    this.root.failureCode = code;
    this.root.workerLeaseToken = undefined;
    this.root.workerLeasedUntil = undefined;
    return true;
  }

  workerActive() {
    return this.root?.workerLeaseToken && this.root.workerLeasedUntil > this.now;
  }

  activeRoot(id, generation, token) {
    return this.root && this.root.clientJobID === id && this.root.generation === generation &&
      this.root.workerLeaseToken === token && this.root.workerLeasedUntil > this.now &&
      this.root.cancelled === false && !["completed", "failed", "cancelled"].includes(this.root.status);
  }

  activeSection(id, generation, workerToken, section, claimToken) {
    return this.activeRoot(id, generation, workerToken) && section && section.generation === generation &&
      section.status === "processing" && section.claimToken === claimToken && section.leasedUntil > this.now;
  }
}

function runtime(store, queue, provider, logger = { info() {}, warn() {} }) {
  let counter = 0;
  return new WorkoutImportJobRuntime({
    store,
    queue,
    provider,
    now: () => store.now,
    randomID: () => `token-${counter++}`,
    logger,
  });
}

test("initial enqueue failure self-heals through the durable dispatcher without a client poll", async () => {
  const store = new MemoryStore();
  const enqueues = [];
  let fail = true;
  const queue = {
    enqueue: async (taskPayload, deterministicID) => {
      enqueues.push({ taskPayload, deterministicID });
      if (fail) throw new Error("queue unavailable");
    },
  };
  const service = runtime(store, queue, { request: async () => { throw new Error("provider down"); } });
  const started = await service.start("user", payload(), "model");
  assert.equal(started.status, "queued");
  assert.equal(store.root.dispatchState, "needsDispatch");
  fail = false;
  await service.dispatch(jobID, 1);
  assert.equal(store.root.dispatchState, "dispatched");
  assert.deepEqual(enqueues[0].taskPayload, enqueues[1].taskPayload);
});

test("exact Cloud Tasks replay after a transient provider failure completes with the phone absent", async () => {
  const store = new MemoryStore();
  let providerCalls = 0;
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async () => {
      providerCalls += 1;
      if (providerCalls === 1) throw new Error("provider unavailable");
      return validIR("o1");
    },
  });
  await service.start("user", payload(), "model");

  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  assert.equal(store.root.dispatchState, "dispatched");
  assert.equal(store.root.dispatchAttempt, 1);

  await service.process(jobID, 1, 1);
  assert.equal(store.root.status, "completed");
  assert.equal(providerCalls, 2);
});

test("persistent provider outage completes with recognized text instead of a failed job", async () => {
  const store = new MemoryStore();
  let providerCalls = 0;
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async () => {
      providerCalls += 1;
      throw new Error("provider unavailable");
    },
  });
  await service.start("user", payload(), "model");

  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  await service.process(jobID, 1, 1);

  assert.equal(providerCalls, 3);
  assert.equal(store.root.status, "completed");
  assert.equal(store.root.failureCode, undefined);
  assert.equal(JSON.stringify(store.root.document).includes("Run 400 m"), true);
  assert.equal(JSON.stringify(store.root.document).includes("needs review"), true);
});

test("assembly fallback keeps successful structure beside an OCR-only review section", async () => {
  const source = payload(2);
  source.sections[0].observations[0].text = "Run 400 m";
  source.sections[1].observations[0].text = "12 Deadlifts @ bodyweight";
  source.sections[1].continuationFromSectionID = sectionID(9);
  const store = new MemoryStore();
  const providerRequests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      const request = JSON.parse(content);
      providerRequests.push(request);
      const firstObservation = request.observations?.[0];
      return firstObservation?.text === "Run 400 m"
        ? validIR(firstObservation.id)
        : { unexpected: "invalid section output" };
    },
  });

  await service.start("user", source, "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(providerRequests.length, 5);
  assert.equal(providerRequests.every((request) =>
    !request.observations || request.observations.length === 1), true);
  const document = store.root.document;
  const structuredExercise = document.blocks[0].nodes[0].exercise;
  assert.equal(structuredExercise.name, "Run");
  assert.deepEqual(structuredExercise.sourceObservationIDs, ["line-0", "line-0-source-2"]);
  const fallbackBlock = document.blocks.find((block) => block.name === "Imported section 2");
  assert.ok(fallbackBlock);
  const fallback = fallbackBlock.nodes[0].group;
  assert.deepEqual(fallback.children, []);
  assert.deepEqual(fallback.notes, ["12 Deadlifts @ bodyweight"]);
  assert.deepEqual(fallback.sourceObservationIDs, ["line-1", "line-1-source-2"]);
  assert.equal(fallback.ambiguity.includes("could not be structured automatically"), true);
  const review = document.blocks.find((block) => block.name === "Import review");
  assert.ok(review);
  assert.equal(review.nodes[0].group.ambiguity.includes("section boundary"), true);
  assert.equal(JSON.stringify(fallbackBlock).includes('"exercise"'), false);
  assert.deepEqual(document.blocks.flatMap((block) => block.nodes)
    .filter((node) => node.type === "exercise").map((node) => node.exercise.name), ["Run"]);
});

test("status recovers a dispatched task after queue exhaustion or a hard worker timeout", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  store.root.dispatchedAt = 0;
  store.root.workerLeaseToken = "dead-worker";
  store.root.workerLeasedUntil = 180_000;
  store.now = 210_001;
  const enqueues = [];
  const service = runtime(store, { enqueue: async (value) => enqueues.push(value) }, {
    request: async () => validIR("o1"),
  });

  await service.status("user", jobID);
  assert.equal(store.root.dispatchAttempt, 2);
  assert.equal(store.root.dispatchState, "dispatched");
  assert.equal(enqueues[0].dispatchAttempt, 2);
});

test("busy worker acquisition remains retryable for Cloud Tasks", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  await store.acquireWorker(jobID, 1, 1, "existing");
  const service = runtime(store, { enqueue: async () => {} }, { request: async () => validIR("o1") });
  await assert.rejects(service.process(jobID, 1, 1), /worker_busy/);
});

test("hard-crash lease recovery replays the same task after expiry without a client poll", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  const crashed = await store.acquireWorker(jobID, 1, 1, "crashed-worker");
  assert.equal(crashed.status, "acquired");
  assert.ok(await store.claimSection(jobID, 1, "crashed-worker", sectionID(), "crashed-claim"));
  const service = runtime(store, { enqueue: async () => assert.fail("no replacement task is needed") }, {
    request: async () => validIR("o1"),
  });

  await assert.rejects(service.process(jobID, 1, 1), /worker_busy/);
  store.now = 180_001;
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(store.root.dispatchAttempt, 1);
});

test("job status is scoped to the authenticated owner", async () => {
  const store = new MemoryStore();
  const service = runtime(store, { enqueue: async () => {} }, { request: async () => validIR("o1") });
  await service.start("owner", payload(), "model");
  await assert.rejects(service.status("different-user", jobID), /not-found/);
});

test("transient repair transport retry resumes persisted repair without rerunning initial inference", async () => {
  const durableID = "d".repeat(64);
  const durableSourceID = "e".repeat(64);
  const source = payload();
  source.sections[0].observations = [observation(durableID)];
  source.sections[0].provenance = [{
    primaryID: durableID,
    sourceObservationIDs: [durableID, durableSourceID],
  }];
  const store = new MemoryStore();
  await store.createOrGet("user", source, "model");
  store.root.dispatchState = "dispatched";
  const requests = [];
  const responses = [
    {
      ...validIR("o1"),
      records: [
        validIR("o1").records[0],
        { ...validIR("o1").records[1], parentID: "missing" },
      ],
    },
    new Error("provider down during repair"),
    validIR("o1"),
  ];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response;
    },
  });
  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  const section = store.sectionsByID.get(sectionID());
  assert.equal(section.repairAttempts, 1);
  assert.ok(section.repairInput);
  assert.equal(JSON.stringify(section.repairInput).includes(durableID), true);
  await service.process(jobID, 1, 1);
  assert.equal(store.root.status, "completed");
  const repairs = requests.filter((request) => request.task === "repair_one_workout_section");
  assert.equal(repairs.length, 2);
  assert.equal(requests.filter((request) => request.task === undefined).length, 1);
  for (const repair of repairs) {
    assert.deepEqual(repair.section.observations.map((item) => item.id), ["o1"]);
    assert.deepEqual(
      repair.invalidIR.records.flatMap((item) => item.sourceObservationIDs),
      ["o1", "o1"],
    );
    assert.equal(JSON.stringify(repair).includes(durableID), false);
    assert.equal(JSON.stringify(repair).includes(durableSourceID), false);
  }
  assert.deepEqual(store.root.document.blocks[0].sourceObservationIDs, [durableID, durableSourceID]);
});

test("durable runtime repairs a bounded invalid root instead of failing before repair", async () => {
  const store = new MemoryStore();
  const requests = [];
  const responses = [{ unexpected: "provider root" }, validIR("o1")];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content, maxTokens) => {
      requests.push({ content: JSON.parse(content), maxTokens });
      return responses.shift();
    },
  });

  await service.start("user", payload(), "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(requests.length, 2);
  assert.equal(requests[0].maxTokens, 4_096);
  assert.equal(requests[1].maxTokens, 8_192);
  assert.equal(requests[1].content.task, "repair_one_workout_section");
  assert.equal(requests[1].content.diagnostic.code, "ir.shape");
  assert.deepEqual(requests[1].content.invalidIR, { unexpected: "provider root" });
});

test("durable runtime can repair a new fixed validation error introduced by the first repair", async () => {
  const store = new MemoryStore();
  const initial = validIR("o1");
  initial.records[1].parentID = "missing";
  const firstRepair = validIR("o1");
  firstRepair.records.push({
    id: "note", kind: "note", parentID: "block", order: 1,
    attributes: [], sourceObservationIDs: ["o1"],
  });
  const responses = [initial, firstRepair, validIR("o1")];
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      return responses.shift();
    },
  });

  await service.start("user", payload(), "model");
  await service.process(jobID, 1, 1);

  const section = store.sectionsByID.get(sectionID());
  assert.equal(store.root.status, "completed");
  assert.equal(section.repairAttempts, 2);
  assert.equal(section.repaired, true);
  assert.equal(requests.length, 3);
  assert.equal(requests[1].diagnostic.code, "assembly.parent_missing");
  assert.equal(requests[2].diagnostic.code, "ir.attribute");
  assert.equal(requests[2].diagnostic.expectedAttribute, "text");
});

test("durable provenance repair receives the exact missing request-local aliases", async () => {
  const store = new MemoryStore();
  const input = payload();
  input.sections[0].observations.push(observation("line-missing", "12 Burpees"));
  input.sections[0].provenance.push({
    primaryID: "line-missing",
    sourceObservationIDs: ["line-missing"],
  });
  const repaired = validIR("o1");
  repaired.records.push({
    id: "burpee",
    kind: "exercise",
    parentID: "block",
    order: 1,
    attributes: [{ key: "name", value: "Burpee" }],
    sourceObservationIDs: ["o2"],
  });
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      return requests.length === 1 ? validIR("o1") : repaired;
    },
  });

  await service.start("user", input, "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.deepEqual(requests[1].diagnostic.unaccountedObservationIDs, ["o2"]);
  assert.equal(JSON.stringify(requests[1].diagnostic).includes("line-missing"), false);
  assert.match(requests[1].requirement, /diagnostic\.unaccountedObservationIDs/);
});

test("resumed provenance repair recompacts durable observation IDs before provider use", async () => {
  const store = new MemoryStore();
  const input = payload();
  input.sections[0].observations.push(observation("line-missing", "12 Burpees"));
  input.sections[0].provenance.push({
    primaryID: "line-missing",
    sourceObservationIDs: ["line-missing"],
  });
  const repaired = validIR("o1");
  repaired.records.push({
    id: "burpee",
    kind: "exercise",
    parentID: "block",
    order: 1,
    attributes: [{ key: "name", value: "Burpee" }],
    sourceObservationIDs: ["o2"],
  });
  const responses = [validIR("o1"), new Error("repair transport unavailable"), repaired];
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response;
    },
  });

  await service.start("user", input, "model");
  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  assert.deepEqual(
    store.sectionsByID.get(sectionID()).repairDiagnostic.unaccountedObservationIDs,
    ["line-missing"],
  );
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.deepEqual(requests[1].diagnostic.unaccountedObservationIDs, ["o2"]);
  assert.deepEqual(requests[2].diagnostic.unaccountedObservationIDs, ["o2"]);
  assert.equal(JSON.stringify(requests[2]).includes("line-missing"), false);
});

test("durable runtime resumes the latest second repair state after a transport failure", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  const initial = validIR("o1");
  initial.records[1].parentID = "missing";
  const firstRepair = validIR("o1");
  firstRepair.records.push({
    id: "note", kind: "note", parentID: "block", order: 1,
    attributes: [], sourceObservationIDs: ["o1"],
  });
  const responses = [initial, firstRepair, new Error("second repair unavailable"), validIR("o1")];
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response;
    },
  });

  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  const failedSection = store.sectionsByID.get(sectionID());
  assert.equal(failedSection.repairAttempts, 2);
  assert.equal(failedSection.repairDiagnostic.code, "ir.attribute");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(requests.filter((request) => request.task === undefined).length, 1);
  assert.equal(requests.filter((request) => request.task === "repair_one_workout_section").length, 3);
  assert.equal(requests[3].diagnostic.code, "ir.attribute");
});

test("an invalid resumed repair preserves OCR after the provider-call ceiling", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  const initial = validIR("o1");
  initial.records[1].parentID = "missing";
  const firstRepair = validIR("o1");
  firstRepair.records.push({
    id: "note", kind: "note", parentID: "block", order: 1,
    attributes: [], sourceObservationIDs: ["o1"],
  });
  const responses = [
    initial,
    firstRepair,
    new Error("second repair unavailable"),
    { unexpected: "invalid resumed second repair" },
  ];
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      const response = responses.shift();
      if (response instanceof Error) throw response;
      return response;
    },
  });

  await assert.rejects(service.process(jobID, 1, 1), /provider_unavailable/);
  assert.equal(store.sectionsByID.get(sectionID()).repairAttempts, 2);
  await service.process(jobID, 1, 1);

  const section = store.sectionsByID.get(sectionID());
  assert.equal(store.root.status, "completed");
  assert.equal(store.root.failureCode, undefined);
  assert.equal(section.repairAttempts, 3);
  assert.equal(section.providerCalls, MAX_SECTION_PROVIDER_CALLS);
  assert.equal(requests.length, MAX_SECTION_PROVIDER_CALLS);
  assert.deepEqual(section.result.blocks[0].nodes[0].group.notes, ["Run 400 m"]);
  assert.equal(section.result.blocks[0].nodes[0].group.children.length, 0);
});

test("durable runtime stops after three invalid repairs and completes with OCR fallback", async () => {
  const store = new MemoryStore();
  const requests = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(JSON.parse(content));
      return { unexpected: "still invalid" };
    },
  });

  await service.start("user", payload(), "model");
  await service.process(jobID, 1, 1);

  const section = store.sectionsByID.get(sectionID());
  assert.equal(store.root.status, "completed");
  assert.equal(store.root.failureCode, undefined);
  assert.equal(section.repairAttempts, 3);
  assert.equal(section.providerCalls, 4);
  assert.equal(requests.length, 4);
  assert.equal(JSON.stringify(store.root.document).includes("Run 400 m"), true);
  assert.equal(JSON.stringify(store.root.document).includes("could not be structured automatically"), true);
});

test("truncated provider output retries once at the output ceiling", async () => {
  const store = new MemoryStore();
  const requestedTokens = [];
  const records = [];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (_content, maxTokens) => {
      requestedTokens.push(maxTokens);
      if (requestedTokens.length === 1) throw new WorkoutImportProviderOutputTruncated();
      return validIR("o1");
    },
  }, {
    info(event, fields) { records.push({ event, fields }); },
    warn(event, fields) { records.push({ event, fields }); },
  });

  await service.start("user", payload(), "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.deepEqual(requestedTokens, [4_096, 8_192]);
  const truncation = records.find((record) => record.event === "workout_import_job.output_truncated");
  assert.equal(truncation.fields.reasonCode, "provider_output_truncated");
  assert.equal(JSON.stringify(records).includes("Run 400 m"), false);
});

test("persistence failure is infrastructure retry and does not increment provider failure accounting", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.dispatchState = "dispatched";
  store.throwOnComplete = new Error("firestore unavailable");
  const service = runtime(store, { enqueue: async () => {} }, { request: async () => validIR("o1") });

  await assert.rejects(service.process(jobID, 1, 1), /firestore unavailable/);
  assert.equal(store.sectionsByID.get(sectionID()).attempts, 0);
  assert.equal(store.root.dispatchAttempt, 1);
  assert.equal(store.root.dispatchState, "dispatched");
});

test("cancellation is terminal and stale completion cannot resurrect the job", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  const worker = await store.acquireWorker(jobID, 1, 1, "worker");
  assert.equal(worker.status, "acquired");
  const claim = await store.claimSection(jobID, 1, "worker", sectionID(), "claim");
  assert.ok(claim);
  await store.cancel(jobID, "user", "33333333-3333-4333-8333-333333333333");
  const completed = await store.completeSection(
    jobID, 1, "worker", sectionID(), "claim",
    { title: "Late", notes: [], blocks: [] }, false,
  );
  assert.equal(completed, false);
  assert.equal(store.root.status, "cancelled");
  assert.equal(store.root.document, undefined);
});

test("cancel-before-create tombstone is idempotent and a late start cannot consume work or resurrect", async () => {
  const store = new MemoryStore();
  const service = runtime(store, { enqueue: async () => assert.fail("must not enqueue") }, {
    request: async () => assert.fail("must not call provider"),
  });
  const command = {
    serverJobID: jobID,
    requestID: "33333333-3333-4333-8333-333333333333",
  };
  assert.equal((await service.cancel("user", command)).status, "cancelled");
  assert.equal((await service.cancel("user", command)).status, "cancelled");
  const late = await service.start("user", payload(), "model");
  assert.equal(late.status, "cancelled");
  assert.equal(store.root, undefined);
});

test("manual retry request IDs are idempotent and lifetime provider budgets and repair state survive generations", async () => {
  const store = new MemoryStore();
  await store.createOrGet("user", payload(), "model");
  store.root.status = "failed";
  store.root.failureCode = "provider_unavailable";
  store.root.providerCalls = 2;
  store.root.outputTokensReserved = 8_192;
  const section = store.sectionsByID.get(sectionID());
  section.providerCalls = 2;
  section.outputTokensReserved = 8_192;
  section.repairAttempts = 1;
  section.repairInput = validIR();
  section.repairDiagnostic = { code: "empty_workout", path: "records" };
  const nextID = "44444444-4444-4444-8444-444444444444";

  const first = await store.retry(jobID, "user", nextID);
  const duplicate = await store.retry(jobID, "user", nextID);
  assert.equal(first.generation, 2);
  assert.equal(duplicate.generation, 2);
  assert.equal(store.root.providerCalls, 2);
  assert.equal(store.root.outputTokensReserved, 8_192);
  assert.equal(section.providerCalls, 2);
  assert.equal(section.repairAttempts, 1);
  assert.ok(section.repairInput);
  assert.deepEqual(store.root.appliedRequestIDs, [requestID, nextID]);
});

test("provider call and lifetime token boundaries accept the exact ceiling and reject the next unit", async () => {
  assert.equal(MAX_SECTION_PROVIDER_CALLS, 4);
  assert.equal(MAX_JOB_PROVIDER_CALLS, 80);

  const sectionStore = new MemoryStore();
  await sectionStore.createOrGet("user", payload(), "model");
  sectionStore.root.dispatchState = "dispatched";
  await sectionStore.acquireWorker(jobID, 1, 1, "worker");
  await sectionStore.claimSection(jobID, 1, "worker", sectionID(), "claim");
  for (let call = 1; call <= MAX_SECTION_PROVIDER_CALLS; call += 1) {
    assert.equal(
      await sectionStore.reserveProviderCall(
        jobID, 1, "worker", sectionID(), "claim", 2_048,
      ),
      "reserved",
      `section provider call ${call} should be allowed`,
    );
  }
  assert.equal(
    await sectionStore.reserveProviderCall(jobID, 1, "worker", sectionID(), "claim", 2_048),
    "budget_exhausted",
  );
  assert.equal(sectionStore.sectionsByID.get(sectionID()).providerCalls, 4);

  const jobBudget = {
    providerCalls: MAX_JOB_PROVIDER_CALLS - 1,
    outputTokenBudget: MAX_JOB_OUTPUT_TOKENS,
    outputTokensReserved: MAX_JOB_OUTPUT_TOKENS - 8_192,
  };
  assert.equal(withinWorkoutImportJobBudget(jobBudget, 8_192), true);
  assert.equal(withinWorkoutImportJobBudget(jobBudget, 8_193), false);
  assert.equal(withinWorkoutImportJobBudget({
    ...jobBudget,
    providerCalls: MAX_JOB_PROVIDER_CALLS,
  }, 1), false);
});

test("token budget covers valid 16, 17, and 20 section jobs plus the densest valid 20-section mix", () => {
  for (const count of [16, 17, 20]) {
    const input = parseStartWorkoutImportJobPayload(payload(count, "x"));
    const initial = initialOutputTokenBudget(input);
    assert.equal(initial, count * 4_096);
    assert.ok(outputTokenBudget(input) >= initial);
    assert.ok(outputTokenBudget(input) <= MAX_JOB_OUTPUT_TOKENS);
  }

  const denseMix = payload(20, "x");
  for (let index = 0; index < 11; index += 1) {
    const firstID = denseMix.sections[index].observations[0].id;
    const secondID = `${firstID}-dense`;
    denseMix.sections[index].observations = [
      observation(firstID, "x".repeat(2_000)),
      observation(secondID, "x".repeat(1_501)),
    ];
    denseMix.sections[index].provenance = [
      { primaryID: firstID, sourceObservationIDs: [firstID] },
      { primaryID: secondID, sourceObservationIDs: [secondID] },
    ];
  }
  const parsedDenseMix = parseStartWorkoutImportJobPayload(denseMix);
  assert.equal(
    parsedDenseMix.sections.reduce(
      (sum, section) => sum + section.observations.reduce((subtotal, line) => subtotal + line.text.length, 0),
      0,
    ),
    38_520,
  );
  assert.equal(initialOutputTokenBudget(parsedDenseMix), (11 * 6_144) + (9 * 4_096));
  assert.ok(outputTokenBudget(parsedDenseMix) <= MAX_JOB_OUTPUT_TOKENS);
  assert.equal(MAX_JOB_OUTPUT_TOKENS, 524_288);
});

test("encoded size guards accept every exact persistence and final-result maximum and reject max plus one", () => {
  assert.equal(encodedJSONByteCount("banana"), 8);
  assert.equal(encodedJSONByteCount("🍌"), 6);
  assert.ok(MAX_SECTION_INPUT_BYTES < MAX_SECTION_DOCUMENT_BYTES);
  assert.ok(MAX_SECTION_RESULT_BYTES < MAX_SECTION_DOCUMENT_BYTES);
  for (const [label, limit] of [
    ["root", MAX_ROOT_ENCODED_BYTES],
    ["section_input", MAX_SECTION_INPUT_BYTES],
    ["section_result", MAX_SECTION_RESULT_BYTES],
    ["section_document", MAX_SECTION_DOCUMENT_BYTES],
    ["result", MAX_RESULT_ENCODED_BYTES],
  ]) {
    const exact = "x".repeat(limit - 2);
    assert.equal(encodedJSONByteCount(exact), limit);
    assert.doesNotThrow(() => assertEncodedSize(exact, limit, label));
    assert.throws(
      () => assertEncodedSize(`${exact}x`, limit, label),
      new RegExp(`${label}_too_large`),
    );
  }
});

test("production runtime accepts the exact final result limit and preserves OCR above it", async () => {
  const processPrecompletedDocument = async (targetBytes) => {
    const store = new MemoryStore();
    const service = runtime(store, { enqueue: async () => {} }, {
      request: async () => assert.fail("precompleted sections must not call the provider"),
    });
    const source = payload();
    source.sections[0].provenance = [{ primaryID: "line-0", sourceObservationIDs: ["line-0"] }];
    const input = parseStartWorkoutImportJobPayload(source);
    await service.start("user", input, "model");
    const section = store.sectionsByID.get(sectionID());
    section.status = "completed";
    section.result = parsedDocumentWithEncodedSize(targetBytes);
    store.root.completedSections = 1;
    await service.process(jobID, 1, 1);
    return store.root;
  };

  const exact = await processPrecompletedDocument(MAX_RESULT_ENCODED_BYTES);
  assert.equal(exact.status, "completed", exact.failureCode);
  assert.equal(encodedJSONByteCount(exact.document), MAX_RESULT_ENCODED_BYTES);

  const oversized = await processPrecompletedDocument(MAX_RESULT_ENCODED_BYTES + 1);
  assert.equal(oversized.status, "completed");
  assert.equal(oversized.failureCode, undefined);
  assert.ok(encodedJSONByteCount(oversized.document) < MAX_RESULT_ENCODED_BYTES);
  assert.equal(JSON.stringify(oversized.document).includes("Run 400 m"), true);
  assert.equal(JSON.stringify(oversized.document).includes("fully structured result was too large"), true);
});

test("production runtime bounds section provider concurrency at two", async () => {
  const store = new MemoryStore();
  let active = 0;
  let highWater = 0;
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      active += 1;
      highWater = Math.max(highWater, active);
      await new Promise((resolve) => setImmediate(resolve));
      active -= 1;
      return validIR(JSON.parse(content).observations[0].id);
    },
  });
  const input = parseStartWorkoutImportJobPayload(payload(4));
  await service.start("user", input, "model");
  await service.process(jobID, 1, 1);
  assert.equal(store.root.status, "completed");
  assert.equal(highWater, 2);
});

test("production runtime preserves unsupported source alternatives after assembly", async () => {
  const source = payload(2);
  source.catalogHints = [
    "Stationary Bike | aliases: spin bike; indoor bike",
    "BikeErg | aliases: concept2 bike; c2 bike",
    "Echo Bike | aliases: echo bike; assault bike",
  ];
  source.sections[0].observations[0].text = "C2 Bike/ECHO Bike";
  source.sections[1].observations[0].text = "20 seconds ECHO Bike arms only";
  const store = new MemoryStore();
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      const request = JSON.parse(content);
      const ir = validIR("o1");
      ir.records[1].attributes[0].value = request.observations[0].text.startsWith("C2")
        ? "Stationary Bike"
        : "Echo Bike";
      return ir;
    },
  });

  await service.start("user", parseStartWorkoutImportJobPayload(source), "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.deepEqual(store.root.document.blocks.map(
    (block) => block.nodes[0].exercise.name,
  ), ["BikeErg / Echo Bike", "Echo Bike"]);
});

test("live 109-hash section uses short provider aliases and emits bounded call telemetry", async () => {
  const observations = Array.from({ length: 109 }, (_, index) => {
    const targetLength = index < 66 ? 30 : 29;
    const prefix = `workout detail ${index} `;
    return observation(
      index.toString(16).padStart(64, "0"),
      prefix + "x".repeat(targetLength - prefix.length),
    );
  }).map((item, index) => ({
    ...item,
    sourceImageIndex: Math.floor(index * 5 / 109),
  }));
  assert.equal(observations.reduce((sum, item) => sum + item.text.length, 0), 3_227);
  const source = parseStartWorkoutImportJobPayload({
    schemaVersion: 1,
    clientJobID: jobID,
    requestID,
    jobHash: "f".repeat(64),
    catalogHints: ["Run"],
    sections: [{
      id: sectionID(),
      order: 0,
      observations,
      contextBefore: [],
      provenance: observations.map((item) => ({
        primaryID: item.id,
        sourceObservationIDs: [item.id],
      })),
      startScopeID: sectionID(),
      endScopeID: sectionID(),
      startFragmentPath: [sectionID()],
      endFragmentPath: [sectionID()],
    }],
  });
  const records = [];
  const requests = [];
  const store = new MemoryStore();
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      requests.push(content);
      const aliases = JSON.parse(content).observations.map((item) => item.id);
      store.now += 37;
      return {
        schemaVersion: 1,
        title: "Run workout",
        goal: "",
        ignoredObservationIDs: [],
        records: [{
          id: "block", kind: "block", parentID: "", order: 0,
          attributes: [{ key: "name", value: "Main" }],
          sourceObservationIDs: aliases.slice(0, 100),
        },
        {
          id: "run", kind: "exercise", parentID: "block", order: 0,
          attributes: [{ key: "name", value: "Run" }],
          sourceObservationIDs: aliases.slice(100),
        }],
      };
    },
  }, {
    info(event, fields) { records.push({ event, fields }); },
    warn(event, fields) { records.push({ event, fields }); },
  });

  await service.start("user", source, "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(requests.length, 1);
  const providerPayload = JSON.parse(requests[0]);
  assert.deepEqual(providerPayload.observations.map((item) => item.id),
    Array.from({ length: 109 }, (_, index) => `o${index + 1}`));
  assert.equal(requests[0].includes(observations[0].id), false);
  assert.ok(Buffer.byteLength(JSON.stringify(source.sections[0]), "utf8") -
    Buffer.byteLength(requests[0], "utf8") > 6_000);
  const providerLog = records.find((record) =>
    record.event === "workout_import_job.provider_attempt_completed");
  assert.equal(providerLog.fields.latencyMs, 37);
  assert.equal(providerLog.fields.requestBytes, Buffer.byteLength(requests[0], "utf8"));
  assert.ok(providerLog.fields.responseBytes > 0);
  assert.equal(providerLog.fields.outputTokens, 4_096);
  assert.equal(JSON.stringify(records).includes(observations[0].id), false);
});

test("all runtime log events exclude OCR and provider privacy sentinels", async () => {
  const records = [];
  const sentinel = "PRIVATE_WORKOUT_SENTINEL";
  const privateObservationID = "PRIVATE_OBSERVATION_ID_CANARY_7F2C9A";
  const durableObservationID = "a".repeat(64);
  const durableSourceID = "c".repeat(64);
  const model = "claude-test-model";
  const logger = {
    info: (event, fields) => records.push({ event, fields }),
    warn: (event, fields) => records.push({ event, fields }),
  };
  const store = new MemoryStore();
  const privatePayload = payload(2, sentinel);
  privatePayload.sections[0].observations = [observation(privateObservationID, sentinel)];
  privatePayload.sections[0].provenance = [{
    primaryID: privateObservationID,
    sourceObservationIDs: [privateObservationID],
  }];
  privatePayload.sections[1].observations = [observation(durableObservationID, sentinel)];
  privatePayload.sections[1].provenance = [{
    primaryID: durableObservationID,
    sourceObservationIDs: [durableObservationID, durableSourceID],
  }];
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async () => ({ ...validIR("o1"), title: sentinel }),
  }, logger);
  await service.start("user", privatePayload, model);
  await service.process(jobID, 1, 1);
  await service.cancel("user", {
    serverJobID: jobID,
    requestID: "55555555-5555-4555-8555-555555555555",
  });

  const dispatchStore = new MemoryStore();
  const dispatchService = runtime(dispatchStore, { enqueue: async () => { throw new Error(sentinel); } }, {
    request: async () => assert.fail("provider must not run"),
  }, logger);
  await dispatchService.start("user", payload(1, sentinel), model);

  const invalidStore = new MemoryStore();
  const invalidService = runtime(invalidStore, { enqueue: async () => {} }, {
    request: async () => ({
      schemaVersion: 1, title: sentinel, goal: "", ignoredObservationIDs: [], records: [],
    }),
  }, logger);
  await invalidService.start("user", payload(1, sentinel), model);
  await invalidService.process(jobID, 1, 1);

  const assemblyStore = new MemoryStore();
  const assemblyPayload = payload(2, sentinel);
  assemblyPayload.sections[1].continuationFromSectionID = sectionID(9);
  const assemblyService = runtime(assemblyStore, { enqueue: async () => {} }, {
    request: async (content) => validIR(JSON.parse(content).observations[0].id),
  }, logger);
  await assemblyService.start("user", assemblyPayload, model);
  await assemblyService.process(jobID, 1, 1);

  assert.deepEqual(new Set(records.map((record) => record.event)), new Set([
    "workout_import_job.accepted",
    "workout_import_job.dispatch_failed",
    "workout_import_job.worker_started",
    "workout_import_job.validation_failed",
    "workout_import_job.section_fallback_completed",
    "workout_import_job.assembly_fallback_completed",
    "workout_import_job.completed",
    "workout_import_job.cancelled",
    "workout_import_job.provider_attempt_completed",
  ]));
  const serializedRecords = JSON.stringify(records);
  for (const privateValue of [
    sentinel,
    privateObservationID,
    durableObservationID,
    durableSourceID,
  ]) {
    assert.equal(serializedRecords.includes(privateValue), false);
  }
  assert.equal(records.every((record) => record.fields.model === model), true);
});

test("shared realistic five-page OCR fixture completes per-section inference and local assembly", async () => {
  const fixturePath = (...names) => path.join(
    __dirname, "..", "..", "fixtures", "workout-import", ...names,
  );
  const input = parseStartWorkoutImportJobPayload(JSON.parse(fs.readFileSync(
    fixturePath("realistic-five-page-request.json"), "utf8",
  )));
  const sectionIR = JSON.parse(fs.readFileSync(
    fixturePath("realistic-five-page-section-ir.json"), "utf8",
  ));
  const expectedResponse = JSON.parse(fs.readFileSync(
    fixturePath("realistic-five-page-response.json"), "utf8",
  ));
  assert.equal(input.sections.length, 3);
  const irByFirstObservationText = new Map(input.sections.map((section, index) => {
    const boundary = createWorkoutImportProviderAliasBoundary({
      observations: section.observations,
      catalogHints: input.catalogHints,
      contextBefore: section.contextBefore,
      sourcePlan: {
        startFragmentPath: section.startFragmentPath,
        endFragmentPath: section.endFragmentPath,
      },
    });
    return [section.observations[0].text, boundary.compactIR(sectionIR[index])];
  }));
  const store = new MemoryStore();
  const providerRequests = [];
  let active = 0;
  let highWater = 0;
  const service = runtime(store, { enqueue: async () => {} }, {
    request: async (content) => {
      const source = JSON.parse(content);
      providerRequests.push(source);
      active += 1;
      highWater = Math.max(highWater, active);
      await new Promise((resolve) => setImmediate(resolve));
      active -= 1;
      return structuredClone(irByFirstObservationText.get(source.observations[0].text));
    },
  });

  await service.start("user", input, "model");
  await service.process(jobID, 1, 1);

  assert.equal(store.root.status, "completed");
  assert.equal(store.root.completedSections, 3);
  assert.equal(providerRequests.length, 3);
  assert.equal(highWater, 2);
  assert.equal(providerRequests.every((request) =>
    request.observations.every((line) => /^o\d+$/.test(line.id))), true);
  assert.deepEqual(store.root.document, expectedResponse);
  assert.equal(store.root.document.blocks.length, 4);
  assert.equal(store.root.document.blocks[0].nodes.length, 1);
  const medChildren = store.root.document.blocks[0].nodes[0].group.children;
  assert.equal(medChildren.length, 2);
  const aerobicIntervals = medChildren[0].group;
  assert.equal(aerobicIntervals.repeatCount, 6);
  assert.deepEqual(aerobicIntervals.notes, ["C2 Bike / Echo Bike"]);
  assert.equal(aerobicIntervals.children.length, 1);
  const intervalChoice = aerobicIntervals.children[0].choice;
  assert.equal(intervalChoice.selectionCount, 1);
  assert.deepEqual(intervalChoice.options.map(
    (option) => option.group.label,
  ), ["BikeErg", "Echo Bike"]);
  for (const option of intervalChoice.options) {
    assert.deepEqual(option.group.children.map(
      (node) => node.exercise.sets[0].metrics[0].value,
    ), [50, 20]);
    assert.deepEqual(option.group.children.map(
      (node) => [node.exercise.intensityTargets[0].lower, node.exercise.intensityTargets[0].upper],
    ), [[6, 8], [3, 3]]);
  }
  assert.equal(intervalChoice.options[0].group.children[1].exercise.notes.length, 0);
  assert.deepEqual(intervalChoice.options[1].group.children[1].exercise.notes, [
    "Use arms only during the 20-second recovery when using the Echo Bike.",
  ]);
  const alternating = medChildren[1].group;
  assert.equal(alternating.label, "Then alternate A and B");
  assert.deepEqual(alternating.children.map((node) => node.group.label), ["A", "B"]);
  assert.equal(store.root.document.blocks[2].nodes.length, 1);
  assert.equal(store.root.document.blocks[2].nodes[0].group.children.length, 4);
  assert.deepEqual(
    alternating.children[0].group
      .children[0].exercise.sourceObservationIDs,
    ["p2-sled"],
  );
  const performance = store.root.document.blocks[1];
  assert.equal(performance.name, "Performance Layer");
  assert.equal(performance.nodes.length, 2);
  assert.deepEqual(performance.nodes.map((node) => node.group.durationSeconds), [2_100, 2_100]);
  assert.deepEqual(performance.nodes.map((node) => node.group.children.map(
    (child) => child.exercise.name,
  )), [
    ["StairMaster", "Box Step Over", "Hand Release Push-Up"],
    ["StairMaster", "Dumbbell Push Press", "Wall Ball"],
  ]);
  assert.deepEqual(performance.nodes.map((node) =>
    node.group.children[0].exercise.sets[0].metrics[0]), [
    { type: "duration", value: 6, unit: "minutes" },
    { type: "duration", value: 6, unit: "minutes" },
  ]);
  assert.deepEqual(performance.nodes.map((node) => node.group.notes), [
    ["Ideally use a weight vest during this phase."],
    ["Complete this phase without the weight vest."],
  ]);
  assert.deepEqual(
    providerRequests.flatMap((request) => request.observations).map((line) => line.sourceImageIndex)
      .filter((value, index, values) => values.indexOf(value) === index),
    [0, 1, 2, 3, 4],
  );
  const requestObservations = input.sections.flatMap((section) => section.observations);
  const exactTextByID = new Map(requestObservations.map((line) => [line.id, line.text]));
  const allNotes = [];
  const allSourceIDs = new Set();
  const visit = (value) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (Array.isArray(value.notes)) allNotes.push(...value.notes);
    if (Array.isArray(value.sourceObservationIDs)) {
      value.sourceObservationIDs.forEach((identifier) => allSourceIDs.add(identifier));
    }
    Object.values(value).forEach(visit);
  };
  visit(store.root.document);
  for (const identifier of [
    "p0-note-1", "p0-note-2", "p1-above", "p1-below",
    "p0-long-context", "p1-long-context", "p2-long-context", "p3-long-context", "p4-long-context",
  ]) {
    assert.ok(allNotes.includes(exactTextByID.get(identifier)), `missing full note ${identifier}`);
  }
  assert.deepEqual(
    [...allSourceIDs].sort(),
    requestObservations.map((line) => line.id).sort(),
    "every retained request observation must have assembled provenance",
  );
});

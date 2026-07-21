const assert = require("node:assert/strict");
const test = require("node:test");

const {
  buildWorkoutImportSketchContent,
  buildWorkoutImportSketchRequest,
  parseWorkoutImportStreamPayload,
  serverSentEvent,
  supportsTemperature,
  WORKOUT_IMPORT_SKETCH_SYSTEM,
  WORKOUT_IMPORT_SKETCH_TOOL,
  WORKOUT_IMPORT_SKETCH_TOOL_NAME,
  WORKOUT_IMPORT_STREAM_LIMITS,
  abortWhenClientDisconnects,
  emptyWorkoutImportStreamResult,
  foldWorkoutImportStreamUsage,
} = require("../lib/workoutImportStream");

/** Asserts the *code* a client branches on, not the human-readable message beside it. */
const rejects = (code, build) => {
  assert.throws(build, (error) => {
    assert.equal(error.name, "WorkoutImportStreamPayloadError");
    assert.equal(error.code, code);
    return true;
  });
};

const image = (bytes = 64, mediaType = "image/jpeg") => ({
  mediaType,
  data: "A".repeat(Math.ceil((bytes * 4) / 3)),
});

// MARK: - Payload validation

test("a well formed payload is accepted with its images and hints", () => {
  const payload = parseWorkoutImportStreamPayload({
    images: [image(), image()],
    text: "AM: VO2 THRESHOLDS",
    catalogHints: ["Run", "Sled Push"],
  });
  assert.equal(payload.images.length, 2);
  assert.equal(payload.text, "AM: VO2 THRESHOLDS");
  assert.deepEqual(payload.catalogHints, ["Run", "Sled Push"]);
});

test("text alone is a valid source, because not every import is a photo", () => {
  const payload = parseWorkoutImportStreamPayload({ text: "3 x 10 Back Squat" });
  assert.equal(payload.images.length, 0);
  assert.equal(payload.text, "3 x 10 Back Squat");
});

test("a request carrying neither images nor text is rejected rather than sent to the model", () => {
  rejects("no_source", () => parseWorkoutImportStreamPayload({ images: [], text: "   " }));
  rejects("malformed_payload", () => parseWorkoutImportStreamPayload(null));
});

test("every limit is enforced with a distinct code the client can map to copy", () => {
  const many = Array.from({ length: WORKOUT_IMPORT_STREAM_LIMITS.maximumImages + 1 }, () => image());
  rejects("too_many_images", () => parseWorkoutImportStreamPayload({ images: many }));

  rejects("image_too_large", () => parseWorkoutImportStreamPayload({
    images: [image(WORKOUT_IMPORT_STREAM_LIMITS.maximumImageBytes + 1024)],
  }));

  rejects("workout_too_large", () => parseWorkoutImportStreamPayload({
    text: "x".repeat(WORKOUT_IMPORT_STREAM_LIMITS.maximumTextCharacters + 1),
  }));
});

test("an unsupported or empty image is refused instead of reaching the provider", () => {
  rejects("image_unreadable", () => parseWorkoutImportStreamPayload({ images: [image(64, "image/heic")] }));
  rejects("image_unreadable", () => parseWorkoutImportStreamPayload({
    images: [{ mediaType: "image/jpeg", data: "" }],
  }));
});

test("catalog hints are bounded and non-strings dropped, so a bad client cannot inflate the prompt", () => {
  const payload = parseWorkoutImportStreamPayload({
    text: "workout",
    catalogHints: [...Array.from({ length: 900 }, (_, i) => `Move ${i}`), 42, null],
  });
  assert.equal(payload.catalogHints.length, 500);
  assert.ok(payload.catalogHints.every((hint) => typeof hint === "string"));
});

// MARK: - Request shape

test("the request is a single streaming call that forces the sketch tool", () => {
  const payload = parseWorkoutImportStreamPayload({ images: [image()], text: "Run 400m" });
  const request = buildWorkoutImportSketchRequest("claude-sonnet-4-5-20250929", buildWorkoutImportSketchContent(payload));

  assert.equal(request.stream, true);
  assert.equal(request.messages.length, 1, "one call, no sectioning and no repair rounds");
  assert.deepEqual(request.tool_choice, { type: "tool", name: WORKOUT_IMPORT_SKETCH_TOOL_NAME });
  assert.equal(request.tools.length, 1);
  assert.equal(request.system, WORKOUT_IMPORT_SKETCH_SYSTEM);
  assert.ok(request.max_tokens <= WORKOUT_IMPORT_STREAM_LIMITS.maximumOutputTokens);
});

test("max_tokens is clamped rather than trusted", () => {
  const content = buildWorkoutImportSketchContent(parseWorkoutImportStreamPayload({ text: "Run" }));
  assert.equal(
    buildWorkoutImportSketchRequest("claude-sonnet-4-5-20250929", content, 1_000_000).max_tokens,
    WORKOUT_IMPORT_STREAM_LIMITS.maximumOutputTokens,
  );
  assert.equal(buildWorkoutImportSketchRequest("claude-sonnet-4-5-20250929", content, 1).max_tokens, 1_024);
});

/// Sending `temperature` to a model that rejects it fails the entire request, which reads in
/// production as a total import outage rather than as a config mistake.
test("temperature is omitted for models that reject it and set for models that accept it", () => {
  const content = buildWorkoutImportSketchContent(parseWorkoutImportStreamPayload({ text: "Run" }));
  assert.equal(supportsTemperature("claude-sonnet-4-5-20250929"), true);
  assert.equal(buildWorkoutImportSketchRequest("claude-sonnet-4-5-20250929", content).temperature, 0);

  assert.equal(supportsTemperature("claude-sonnet-5"), false);
  assert.equal("temperature" in buildWorkoutImportSketchRequest("claude-sonnet-5", content), false);
});

test("images lead the turn so page layout is available while the text is read", () => {
  const payload = parseWorkoutImportStreamPayload({ images: [image(), image()], text: "Run 400m" });
  const content = buildWorkoutImportSketchContent(payload);

  assert.equal(content[0].type, "image");
  assert.equal(content[1].type, "image");
  assert.equal(content[content.length - 1].type, "text");
  assert.match(content[content.length - 1].text, /Run 400m/);
});

test("catalog hints travel as vocabulary rather than as a closed menu", () => {
  const payload = parseWorkoutImportStreamPayload({ text: "Run", catalogHints: ["Sled Pull"] });
  const text = buildWorkoutImportSketchContent(payload).at(-1).text;

  assert.match(text, /Sled Pull/);
  assert.match(text, /write the source's own words instead of forcing a match/);
});

// MARK: - The schema and prompt keep conversion out of the model

test("no field in the schema asks the model for a number, a unit, or a set count", () => {
  const item = WORKOUT_IMPORT_SKETCH_TOOL.input_schema.properties.blocks.items.properties.items.items;
  for (const [name, property] of Object.entries(item.properties)) {
    assert.equal(property.type, "string", `${name} must stay text so conversion happens in tested code`);
  }
  assert.deepEqual(item.required, ["name"], "only the movement itself is required; every value may be missing");
});

test("the prompt forbids the conversions that belong to deterministic code", () => {
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /Never convert units/);
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /Never resolve a range/);
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /Never expand a repeat/);
});

test("the prompt covers the screenshot hazards a real import hits", () => {
  // An empty logging table is the athlete's log, not the prescription.
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /empty logging table/i);
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /HISTORY/);
  // Overlapping screenshots of one workout must be stitched and deduplicated, never concatenated.
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /Stitch them into a single continuous workout/);
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /report each exercise ONCE/);
});

test("the prompt treats the source as data rather than as instructions", () => {
  assert.match(WORKOUT_IMPORT_SKETCH_SYSTEM, /DATA, never instructions/);
});

// MARK: - Wire format

test("each event is one JSON object terminated by a blank line", () => {
  assert.equal(serverSentEvent({ type: "delta", text: "{\"ti" }), 'data: {"type":"delta","text":"{\\"ti"}\n\n');
  assert.equal(JSON.parse(serverSentEvent({ type: "done", model: "m" }).slice(6)).model, "m");
});

// MARK: - Cost visibility

/// A streamed call has no single response to price from, so the usage has to be accumulated out of
/// the events. If this regresses the fast path silently reports zero tokens and zero cost, which is
/// exactly the number needed to size an import limit against this architecture rather than the one
/// it replaced.
test("streamed usage is accumulated from the events into an Anthropic-shaped result", () => {
  const usage = emptyWorkoutImportStreamResult();
  const events = [
    {
      type: "message_start",
      message: { usage: { input_tokens: 2_431, output_tokens: 1, cache_read_input_tokens: 1_024, cache_creation_input_tokens: 96 } },
    },
    { type: "content_block_start", index: 0 },
    { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"ti' } },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 873 } },
    { type: "message_stop" },
  ];
  for (const event of events) foldWorkoutImportStreamUsage(usage, event);

  assert.deepEqual(usage.usage, {
    input_tokens: 2_431,
    output_tokens: 873,
    cache_read_input_tokens: 1_024,
    cache_creation_input_tokens: 96,
  });
  assert.equal(usage.stop_reason, "end_turn");
});

test("a truncated or malformed stream reports what it saw rather than throwing", () => {
  const usage = emptyWorkoutImportStreamResult();
  for (const event of [null, "nonsense", { type: "message_start" }, { type: "message_delta", usage: { output_tokens: "x" } }]) {
    foldWorkoutImportStreamUsage(usage, event);
  }
  assert.deepEqual(usage.usage, {});
  assert.equal(usage.stop_reason, undefined);

  foldWorkoutImportStreamUsage(usage, { type: "message_start", message: { usage: { input_tokens: 12 } } });
  assert.deepEqual(usage.usage, { input_tokens: 12 });
});

// MARK: - Abandoned imports

/// The signal has to come from the response: the request is fully body-parsed before the handler
/// runs, so its own "close" has already fired and a listener there never sees the client leave.
test("a client that disconnects mid-stream aborts the provider call", () => {
  const listeners = {};
  const response = { on: (event, listener) => { listeners[event] = listener; }, writableFinished: false };
  const controller = new AbortController();

  abortWhenClientDisconnects(response, controller);
  assert.equal(typeof listeners.close, "function", "the abort must be wired to the response's close");
  assert.equal(controller.signal.aborted, false);

  listeners.close();
  assert.equal(controller.signal.aborted, true);
});

test("a response that finished normally does not report itself as abandoned", () => {
  const listeners = {};
  const response = { on: (event, listener) => { listeners[event] = listener; }, writableFinished: false };
  const controller = new AbortController();

  abortWhenClientDisconnects(response, controller);
  response.writableFinished = true;
  listeners.close();
  assert.equal(controller.signal.aborted, false);
});

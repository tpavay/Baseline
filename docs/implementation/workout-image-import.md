# Baseline - Workout Image Import Implementation Plan

*Status: v1 product and ownership contract approved. The single-photo path now runs on the streaming fast path described in [Fast path](#fast-path); the durable section job described throughout the rest of this document owns multi-image imports and every retry. Firebase deployment, Firestore TTL rollout, and App Check console registration remain release steps.*

## 1. Outcome

Baseline turns one or more ordered, text-heavy workout screenshots or photos into a reviewed, reusable `WorkoutTemplate` without letting OCR or a language model write canonical workout or plan state directly.

The provider returns semantic transactions for each bounded source section.
Deterministic code validates every transaction, applies it to a temporary `CandidateGraph`, and materializes a structurally valid `WorkoutDraft` before the editor opens.
Structural uncertainty becomes a targeted `ReviewIssue` instead of malformed workout content, raw OCR, or generic warning copy.

The flow below is the durable multi-image path. One photo now takes the streaming fast path instead; see [Fast path](#fast-path).

```text
Select up to 10 ordered photos, or paste one image
→ serially load and normalize each photo into protected Application Support storage
→ run Vision OCR with bounded concurrency and checkpoint every page
→ remove only explicit screenshot chrome while preserving ambiguous cross-photo repetition
→ split the source into stable bounded sections
→ hand off an authenticated idempotent server job
→ parse and validate sections independently with bounded Cloud Tasks retries
→ apply validated semantic transactions to a CandidateGraph
→ deterministic normalization, catalog resolution, unit conversion, and structural audit
→ atomically hand off one structurally valid, user-owned WorkoutDraft
→ open the ordinary workout editor
→ athlete edits the draft and resolves blocking ReviewIssues
→ save WorkoutTemplate revision
→ success
→ optionally schedule the saved template in a separate operation
```

This feature creates a template first. It never writes directly into a `ScheduledWorkout`, never silently creates a custom exercise, and never lets a scheduling failure erase a successfully imported template.

The editor opens only when the draft contains at least one structurally valid exercise.
If the pipeline preserves only OCR text or candidate data, it has not created a workout and must show the import outcome screen instead of the editor.

## Non-Negotiable Product Invariants

1. The editor displays only structurally valid `WorkoutDraft` values.
2. Import infrastructure ends at the atomic ownership handoff before the editor opens.
3. A `WorkoutDraft` has exactly one owner at a time.
4. The model proposes semantic transactions, while Baseline validates and owns workout state.
5. `ReviewIssue` values are targeted sidecar metadata and never workout content.
6. Import never creates permanent exercise-library entries automatically.
7. The same draft type, editor, commands, validation rules, and save path apply regardless of how the draft was created.
8. The editor never renders candidate objects, parser output, OCR output, provider output, or source evidence as workout content.
9. Once ownership transfers to the user, late, retried, or replayed import work cannot mutate the draft.
10. Source photos and import evidence are temporary and disappear after Save, Discard, Cancel, or expiry.

Structural validity means that block, group, exercise, metric, ordering, identity, and reference invariants all pass deterministic validation.
It does not mean that every semantic interpretation is certain.
Any remaining semantic uncertainty must be represented by a targeted `ReviewIssue` on an otherwise valid draft.

## Fast path

A single photo takes one streaming multimodal call instead of the durable section job.
The invariants above are unchanged: the model still only proposes, deterministic code still owns structure, and the editor still opens only on a structurally valid draft.
What changes is the shape of the model's output and where normalization happens.

- The model returns an all-text reading of the source, `WorkoutImportSketch`. It is told not to convert units, resolve ranges, or expand repeats. Every property in the schema is a string, and a test fails if one stops being one.
- Deterministic conversion happens on the device in `Baseline/Features/WorkoutImport/Conversion/`: catalog identity, canonical units, set expansion, per-exercise metric selection, and one level of grouping. That layer is pure and unit-tested, and it replaces the semantic-transaction validator for this path.
- Ranges, paces, and effort language stay coach prose rather than becoming typed metrics, as does a metric stated more than once in one prescription, because collapsing it would discard work.
- `ImportExerciseMatcher` refuses near-misses. Widening past an exact catalog hit reaches only different spellings of the same movement; a qualifier in either direction stops it, and an unresolved name passes through verbatim so the draft builder raises its blocking `unknownExercise` issue with candidates.
- Routing lives in `WorkoutImportCoordinator.assembleOnFastPath`, after local OCR, which still gates the pipeline and is sent to the model with the image. Multi-image imports never take it, and anything it cannot finish falls through to the durable job, which is the retry.
- A partial stream is judged on structure, not field completeness: exercises in the right order open the editor with a warning that reading stopped early, while a parse with no exercises at all falls through to the durable job rather than opening an empty editor.
- The transport is `streamWorkoutImport`, an `onRequest` SSE endpoint rather than a callable, because a callable cannot stream. Auth and App Check are therefore verified by hand in the handler.
- The photo bytes themselves reach the provider on this path. They are relayed in memory and are never written to Firestore, Cloud Storage, or logs.

Regression cases are JSON files in `fixtures/workout-import/corpus/`, discovered at run time by `WorkoutImportCorpusTests`; adding one needs `xcodegen generate` and no test code changes. See that directory's README.

## Current resumable architecture

`WorkoutImportCoordinator` owns the import lifecycle behind a presentation-only `WorkoutImportViewModel` until atomic handoff.
`FileWorkoutImportJobRepository` stores a versioned Codable manifest plus normalized page JPEGs under protected, backup-excluded Application Support storage.
The repository commits atomically after every normalized page, OCR result, server handoff, server progress update, and candidate-graph transaction.
Import checkpoints expire after 24 hours and are removed after explicit cancellation, draft discard, successful save, or expiry.
The user-owned `WorkoutDraft` has an independent lifetime and remains resumable after the editor closes.

Vision observation identifiers, page identities, section identifiers, job hashes, and task identifiers are deterministic SHA-256 values.
Photo loading remains serial to bound memory while OCR is pipelined with a maximum concurrency of two.
Prepared local pages can resume OCR after relaunch without asking Photos for the image again.
An import interrupted before every selected photo is normalized asks the athlete to reselect the source rather than inventing or silently dropping a page.

The server exposes `startWorkoutImportJob`, `getWorkoutImportJobStatus`, `retryWorkoutImportJob`, and `cancelWorkoutImportJob` callables plus the private `processWorkoutImportJob` task worker.
The legacy `parseWorkoutImport` callable remains available for released clients.
Server jobs are owner-scoped through callable authentication, inaccessible through Firestore client rules, and deleted by the `expiresAt` TTL policy.
Cloud Tasks retries transient failures exponentially, and the worker never runs more than two provider sections concurrently for one job.
Completed section results are reused on every retry.

Each section receives a 4,096-token output allowance by default.
Large or observation-dense sections receive 6,144 tokens.
Every allowance is clamped between 2,048 and 8,192 tokens, and each provider call has a 120-second deadline.
A structured-output failure can receive up to two repair requests containing only that section, its latest invalid IR, and a fixed validator diagnostic.
When provenance is incomplete, the diagnostic names the exact missing request-local observation aliases so the provider does not need to rediscover them.
Durable observation identifiers remain on the server, and neither form is included in operational logs.

Cross-photo repeated workout text is never deleted by a deterministic scroll-overlap heuristic.
The provider may consolidate true screenshot overlap into one structured record only when it cites every contributing source observation.
Repeated intervals, percentages, headings, and coaching cues therefore remain lossless when their meaning is ambiguous.

The deterministic grounding layer repairs only source-proven shapes that have one valid interpretation.
It can reuse cited source text for a missing container label, map affirmative unqualified rest phrases such as `rest between intervals`, `rest after every round`, and `rest after the final interval` to the corresponding placement, retype a text-only adjustment as a note, and insert one omitted set wrapper for an immediately adjacent same-source metric.
Negated, conditional, and frequency-qualified rest language remains unresolved for targeted repair.
Any ambiguous label, rest placement, adjustment, or relationship remains on the targeted validation and repair path.
Variable status-bar layout recognition requires left-clock and right-battery candidates in expected geometry on at least two source images.
Clock text, battery-shaped numbers, explicit percentages, and unknown signal glyphs remain reviewable content even when they helped recognize the layout.
Only explicit interface and network tokens may be removed automatically.
Programming, headings, catalog movements, and unknown fragments are excluded from layout-based deletion.
An unknown narrow fragment at an image edge is preserved in the `CandidateGraph` instead of being silently ignored or forcing the entire import to fail.
The second repair is available only when the first repair changes the failure into another fixed validation error, and the existing four-call section ceiling remains unchanged.
Final assembly never asks the provider to regenerate the whole workout.

Operational logs and local diagnostics record only job identity, fixed stage and reason codes, counts, bounded timing, payload sizes, attempt numbers, and model metadata.
They never record OCR text, observation identifiers, workout content, filenames, source images, provider output, or athlete notes.

The product invariants and ownership model in this document are authoritative.
Existing issue #2 implementation details remain useful for transport, persistence, and retry behavior only where they do not conflict with those invariants.

## 2. Locked decisions

- The reusable domain term is **Workout Template**. Code uses `WorkoutTemplate` for committed content and `WorkoutDraft` for editable content; the former "Routine" term is retired.
- `ImportSession` owns temporary source photos, OCR evidence, checkpoints, diagnostics, provider work, and the `CandidateGraph`.
- `ImportSession` never owns the user-edited draft after handoff.
- Provider output is a transient sequence of semantic transactions, not `Workout`, `WorkoutBlock`, `PlannedExercise`, `PlannedSet`, or `WorkoutDraft`.
- `CandidateGraph` is the import pipeline's semantic workspace and never reaches the editor.
- `WorkoutDraftBuilder` is the only boundary that converts a validated `CandidateGraph` into a structurally valid editable draft.
- Blocks, exercises, sets, fields, and relationships have typed, draft-local stable identities.
- The draft uses the same identity and editing rules regardless of creation source.
- Import evidence is temporary sidecar data.
- OCR confidence, source text, image coordinates, provider output, and candidate confidence never enter the canonical `Workout` or persisted template record.
- A small generic `CreationProvenance` value may persist for analytics and debugging, but it cannot change editor, scheduling, adaptation, or history behavior.
- OCR is evidence, not a mandatory text-only interpretation path. The first slice uses OCR plus a text parser; the service boundary permits a later image-aware parser to receive the normalized source image and OCR evidence together.
- Template saving and scheduling are separate commits and separate user-visible states.
- V1 always creates a new template unless the athlete explicitly chooses an existing template to update.
- A content fingerprint may warn about likely duplicates, but it never merges, overwrites, or updates automatically.
- Normalized images exist locally only for the import-session evidence lifecycle. They are not placed in the template, SwiftData, Firestore, Cloud Storage, diagnostics, or logs.
- The durable multi-image job parses OCR text. A single photo goes to the multimodal streaming call instead; see [Fast path](#fast-path).
- Diagnostics contain operational counts and timings only. They never contain OCR text, exercise names, notes, source crops, or raw images.
- Atomic handoff ends import ownership of workout content.
- Save or Discard ends the user-owned draft lifecycle.
- The saved result is an ordinary `WorkoutTemplate` with no permanent import flag or separate engine path.
- Progressive streaming is shipped for the single-photo fast path: exercises appear as they resolve, and a row already on screen is never rewritten. Rows are shown rather than edited while the stream is open, because the transient store is rebuilt as rows land; editing opens the moment reading finishes. Progressive streaming of the durable job's sections remains deferred.

## 3. Current codebase integration

The feature builds on existing seams rather than introducing a second workout or template stack:

- `Workout`, `WorkoutBlock`, `PlannedExercise`, `Prescription`, and `PlannedSet` are the canonical planned-content values in `Baseline/Features/Workout/WorkoutModel.swift`.
- `MetricType`, `MetricUnit`, `MetricValues`, and `MetricConvert` own supported metrics, canonical units, and conversion in `Baseline/Features/Workout/Metrics.swift`.
- `ExerciseDefinition` and the current curated aliases live in `Baseline/Features/Workout/ExerciseCatalog.swift`.
- `WorkoutTemplate` and template attribution already exist in `Baseline/Features/Plan/PlanModel.swift`.
- `PlanRepository.saveAsTemplate`, `updateTemplate`, and `instantiateTemplate` already create immutable template revisions and independent scheduled copies.
- `PlanView` already offers blank workouts and existing templates from the day-level Add Workout affordance.
- `ConversationService` is an Anthropic-format conversational tool loop. Image import gets its own request contract and service; chat may launch the importer later but does not own its state or transcript.

Two prerequisites must be addressed during implementation:

1. `ExerciseCatalog.resolve` intentionally returns the generic definition for unknown input. Import must use a new matcher that returns exact/candidate/unresolved states and never treats `generic` as an accepted match.
2. `SwiftDataPlanRepository.save()` currently suppresses persistence errors with `try?`. Template save/update/instantiate need typed failure propagation before the import flow can truthfully display save and scheduling success.

## 4. Scope

### First shippable slice

- One through ten still images selected in reading order from Photos, or one image pasted into the importer.
- PNG, JPEG, and HEIC inputs after type validation.
- Local orientation correction, downsampling, metadata removal, and protected temporary storage.
- Apple Vision OCR with line text, confidence, and normalized regions.
- Baseline exercise vocabulary supplied to Vision where supported.
- One authenticated, rate-limited, inexpensive cloud text parser.
- Strict semantic-transaction decoding and server/client validation.
- A temporary `CandidateGraph` for evidence-grounded semantic assembly.
- Deterministic draft construction, unit normalization, metric validation, catalog candidate resolution, and structural audit.
- Atomic ownership handoff into the ordinary workout editor.
- Targeted `ReviewIssue` treatment through ordinary editor controls.
- Resumable user-owned drafts when the editor closes before Save.
- Explicit custom-exercise confirmation.
- Duplicate warning by content fingerprint.
- Save as a new template or explicitly update a selected existing template.
- Optional scheduling only after template-save success.
- Fixed, sanitized image corpus with expected structured results.
- Non-content operational diagnostics.

### Deferred

- Direct camera/document capture. The first slice uses Photos and paste; camera capture can follow without changing the draft model.
- Handwriting guarantees.
- Automatic parsing of full multi-day programs from one image.
- PDF import.
- Automatic model escalation. The streaming call is pinned to one model, overridable through `WORKOUT_IMPORT_STREAM_MODEL`.
- iOS 27 direct Foundation Models image input.
- Permanent source-image retention or sync.
- Automatic custom-exercise creation.
- Automatic duplicate merging or template overwrite.
- Direct import into an active workout or scheduled plan state.
- Progressive streaming of the durable job's sections, and live editing of rows while a stream is still open.

## 5. Architecture and trust boundaries

```text
SwiftUI import surface (@MainActor)
        │
        ▼
WorkoutImportViewModel (@Observable, @MainActor)
        ▲ consumes ImportSessionEvent
        │
WorkoutImportService (cancellable pipeline)
        ├── TemporaryImportStore
        ├── ImageImportNormalizer
        ├── VisionWorkoutTextRecognizer
        ├── WorkoutImportParser
        ├── SemanticTransactionValidator
        ├── CandidateGraph
        ├── WorkoutDraftBuilder
        ├── ExerciseCatalogMatcher
        ├── WorkoutImportValidator
        └── ImportDiagnosticsRecorder

WorkoutImportViewModel
        │ applies pipeline events before handoff
        ▼
ImportSession (ephemeral pipeline state)
  ├── ordered normalized source images + protected temporary files
  ├── OCR observations + source evidence
  ├── CandidateGraph + applied transaction history
  ├── checkpoints
  ├── diagnostics
  └── status + timestamps
        │ deterministic audit + atomic ownership handoff
        ▼
WorkoutDraft (ordinary editable document)
  ├── valid draft-local workout structure
  ├── targeted ReviewIssues
  ├── generic CreationProvenance
  ├── revision
  └── user ownership
        │ ordinary workout editor and commands
        │ Save
        │
        ▼
PlanStore / PlanRepository
        ├── commit 1: save or explicitly update WorkoutTemplate
        └── commit 2: optional instantiateTemplate(date, program)
```

Trust rules:

- Selected images, pasted data, OCR output, and model output are untrusted input.
- The provider may propose semantic transactions, but it cannot access persistence or mutate a `WorkoutDraft`.
- Only deterministic Baseline code validates and applies transactions, resolves exercise identity, converts units, checks metric support, creates issues, and determines whether handoff or saving is enabled.
- Atomic handoff records the draft revision and changes ownership from `.pipeline` to `.user` exactly once.
- Results received after handoff are ignored even when they belong to a retried or replayed job.
- After handoff, explicit AI edits use the ordinary validated workout command surface against the current draft revision.
- Only `PlanRepository` persists a template or schedules an instance.
- The backend authenticates, validates, rate-limits, and bounds every request; the client cannot select arbitrary provider model IDs or usage limits.

## 6. Data contracts

All import types are value types conforming to `Sendable`. Codable conformance is added only where the value crosses a process boundary, is used as a fixture, or prepares `ImportSession` for future crash-resume persistence.

### 6.1 Import session

`ImportSession` is the aggregate root for one import attempt.
It owns ephemeral pipeline state and evidence, not the editable workout document.
`WorkoutImportViewModel` owns presentation coordination and drives operations against the session before handoff.

```swift
struct ImportSession: Identifiable, Sendable {
    var id = UUID()
    var sourceImages: [ImportedWorkoutImage] = []
    var observations: [WorkoutTextObservation] = []
    var evidence: [WorkoutImportEvidence] = []
    var candidateGraph: CandidateGraph?
    var checkpoints: [ImportCheckpoint] = []
    var diagnostics = WorkoutImportDiagnostics()
    var status: WorkoutImportStatus = .selecting
    var startedAt = Date()
    var lastUpdated = Date()
}

enum WorkoutImportStatus: Equatable, Sendable {
    case selecting
    case loadingImages(completed: Int, total: Int)
    case recognizing(completed: Int, total: Int)
    case preparingSections
    case waitingForHandoff
    case retryingSections(completed: Int, total: Int)
    case processingSections(completed: Int, total: Int)
    case reviewing
    case saving
    case saved(templateID: UUID)
    case failed(message: String)
}
```

Session rules:

- `id` and `startedAt` remain stable for the life of the session.
- Every accepted transaction, checkpoint, or state transition updates `lastUpdated`.
- `sourceImages` contains the bounded, normalized images in user-selected order while review is active. Each source is also written to the session's protected temporary directory before OCR.
- Candidate nodes, confidence, evidence spans, provider results, and transaction history never become editor content.
- Handoff atomically creates or installs one user-owned `WorkoutDraft`, records its initial revision, and changes the session to `.reviewing`.
- The session cannot apply content transactions after it reaches `.reviewing`.
- Closing the editor does not cancel or delete the user-owned draft.
- The protected file batch and all image, OCR, evidence, candidate, and checkpoint data are removed on Save, Discard, Cancel, or expiry.
- No source photo or import evidence is persisted in the template.
- `WorkoutImportViewModel` serializes the state transitions and rejects stale asynchronous results by session ID.

### 6.2 Candidate graph

`CandidateGraph` is the semantic workspace between untrusted interpretation and the ordinary editable draft.
It is internal to the import pipeline and never reaches the editor.

```swift
struct CandidateGraph: Sendable, Equatable {
    var nodes: [CandidateNode]
    var relationships: [CandidateRelationship]
    var evidenceSpans: [CandidateEvidenceSpan]
    var appliedTransactions: [AppliedSemanticTransaction]
    var unresolvedInterpretations: [CandidateAmbiguity]
}
```

The graph may contain competing interpretations and confidence values because it is not user-owned workout state.
Every mutation enters through a validated semantic transaction.
The graph is discarded with the rest of the `ImportSession`.

### 6.3 Workout draft and ownership

The output of a successful import is the same `WorkoutDraft` used by manual creation, conversation, duplication, and templates.
There is no `ImportedWorkoutDraft` subtype, flag, editor, or save path.

```swift
struct WorkoutDraft: Identifiable, Sendable, Equatable {
    var id: UUID
    var workout: DraftWorkout
    var reviewIssues: [ReviewIssue]
    var creationProvenance: CreationProvenance
    var owner: WorkoutDraftOwner
    var lifecycle: WorkoutDraftLifecycle
    var revision: Int
    var createdAt: Date
    var lastUpdated: Date
}

enum WorkoutDraftOwner: Sendable, Equatable {
    case pipeline(importSessionID: UUID)
    case user
}

enum WorkoutDraftLifecycle: Sendable, Equatable {
    case active
    case committed(workoutTemplateID: UUID)
    case discarded
}
```

The pipeline owns the draft only during final deterministic construction and audit.
The editor can receive it only after one atomic transition from `.pipeline` to `.user`.
Whether the editor is currently visible is presentation state and is not part of `WorkoutDraftLifecycle`.
The active user-owned draft persists when the athlete leaves the editor and can be resumed without another import.

### 6.4 OCR evidence

```swift
struct OCRDocument: Sendable, Equatable {
    var observations: [OCRObservation]
    var imageSize: ImportImageSize
    var meanConfidence: Double?
}

struct OCRObservation: Identifiable, Sendable, Equatable {
    var id: OCRObservationID
    var text: String
    var confidence: Double
    var region: NormalizedSourceRegion
    var lineIndex: Int
}

struct NormalizedSourceRegion: Codable, Sendable, Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}
```

Coordinates stay normalized to `0...1` and use one documented origin convention. Rendering performs the coordinate conversion; import-domain types do not store `CGRect`, pixel coordinates, `UIImage`, or `CGImage`.

### 6.5 Semantic transaction contract

The provider proposes semantic transactions against candidate-local keys.
It does not return a `WorkoutDraft`, canonical workout models, or persistence commands.

```swift
struct ProposedSemanticTransactionBatch: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var transactions: [ProposedSemanticTransaction]
    var route: ImportRoute
    var providerModel: String
    var latencyMilliseconds: Int
    var estimatedCostMicros: Int?
}

struct ProposedSemanticTransaction: Codable, Sendable, Equatable {
    var id: String
    var operation: CandidateOperation
    var sourceObservationIDs: [OCRObservationID]
}

enum CandidateOperation: Codable, Sendable, Equatable {
    case setWorkoutTitle(value: String)
    case appendWorkoutNote(value: String)
    case createBlock(key: String, proposedName: String?)
    case createGroup(key: String, parentBlockKey: String, kind: String?)
    case createExercise(key: String, parentKey: String, proposedName: String)
    case attachMetric(parentExerciseKey: String, kind: String, value: String?, unit: String?)
    case attachNote(parentKey: String, value: String)
    case proposeRelationship(kind: String, sourceKeys: [String], targetKeys: [String])
}
```

Rules for this contract:

- The schema version is required and checked at the provider and application boundaries.
- Unknown keys are rejected server-side.
- Required keys and array, string, and numeric bounds are validated before any transaction is applied.
- Every referenced candidate key must already exist or be created earlier in the same validated batch.
- Applying the same transaction ID twice is idempotent.
- Provider strings are capped before prompting and again before decoding the response.
- The provider never emits canonical catalog IDs, trusted `MetricType` or `MetricUnit` values, production UUIDs, or save commands.
- Baseline may accept a strict provider-specific intermediate representation such as the current `WorkoutImportIR`, but its adapter must translate that representation into these transactions before application state changes.
- Claude, GPT, Gemini, an Apple Foundation Model, deterministic rules, or a future local model must all satisfy this same transaction boundary.

### 6.6 Draft-local identity

Use distinct wrapper types rather than bare `UUID` aliases so a block ID cannot accidentally be passed where an exercise or field ID is expected.

```swift
struct DraftBlockID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
struct DraftGroupID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
struct DraftExerciseID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
struct DraftSetID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
struct DraftFieldID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
struct DraftRelationshipID: RawRepresentable, Hashable, Codable, Sendable { var rawValue: UUID }
```

IDs are assigned once when the validated `CandidateGraph` becomes a draft.
Reordering and editing preserve them.
Copying an element creates new draft IDs.
Deleting an element removes or invalidates its review issues deterministically.

### 6.7 Editable draft content

`WorkoutDraft.workout` does not embed canonical `Workout` values because those values already carry production identities.

```swift
struct DraftWorkout: Sendable, Equatable {
    var title: DraftField<String>
    var goal: DraftField<String?>
    var blocks: [DraftBlock]
}

struct DraftBlock: Identifiable, Sendable, Equatable {
    var id: DraftBlockID
    var name: DraftField<String>
    var intent: DraftField<String?>
    var roundCount: DraftField<Int?>
    var exercises: [DraftExercise]
}

struct DraftExercise: Identifiable, Sendable, Equatable {
    var id: DraftExerciseID
    var proposedName: DraftField<String>
    var match: ExerciseMatch
    var selectedMetrics: [MetricType]
    var displayUnits: [MetricType: MetricUnit]
    var sets: [DraftSet]
    var notes: [DraftField<String>]
}

struct DraftSet: Identifiable, Sendable, Equatable {
    var id: DraftSetID
    var values: MetricValues
}
```

`DraftField<Value>` owns only the editable value and its stable `DraftFieldID`.
Temporary evidence remains in the `ImportSession` sidecar keyed by that ID while the session exists.

### 6.8 Catalog matching

```swift
enum ExerciseMatch: Sendable, Equatable {
    case exact(definitionID: String)
    case acceptedCandidate(definitionID: String)
    case candidates([ExerciseCandidate])
    case unresolved
    case customConfirmed(definitionID: String)
}

struct ExerciseCandidate: Identifiable, Sendable, Equatable {
    var id: String
    var displayName: String
    var reason: MatchReason
    var score: Double
}
```

Matching order:

1. Normalized exact canonical name.
2. Normalized exact alias, including custom definitions.
3. Explicit curated abbreviation map.
4. Bounded candidate generation for user selection.
5. Unresolved.

Substring matching alone may offer candidates but cannot auto-accept a definition. `ExerciseCatalog.generic` is never an accepted import result.

### 6.9 Import evidence and creation provenance

```swift
struct ImportEvidence: Sendable, Equatable {
    var fields: [DraftFieldID: FieldEvidence]
    var relationships: [DraftRelationshipID: RelationshipEvidence]
}

struct FieldEvidence: Sendable, Equatable {
    var sourceObservationIDs: [OCRObservationID]
    var sourceText: String?
    var regions: [NormalizedSourceRegion]
    var ocrConfidence: Double?
    var resolution: ImportResolution
}

struct RelationshipEvidence: Identifiable, Sendable, Equatable {
    var id: DraftRelationshipID
    var kind: RelationshipKind
    var sourceObservationIDs: [OCRObservationID]
    var regions: [NormalizedSourceRegion]
    var resolution: ImportResolution
}

enum ImportResolution: String, Codable, Sendable {
    case accepted
    case needsReview
    case unresolved
}
```

Evidence belongs to `ImportSession`, becomes read-only after handoff, and is not persisted into the confirmed template.

The draft and saved template may retain only small, generic creation provenance:

```swift
struct CreationProvenance: Codable, Sendable, Equatable {
    var source: CreationSource
    var createdAt: Date
    var pipelineVersion: String?
}

enum CreationSource: String, Codable, Sendable {
    case manual
    case conversation
    case photoImport
    case template
    case duplicate
    case calendarRecommendation
    case coachProgram
}
```

`CreationProvenance` cannot contain an import-session ID, source-image identifier, OCR text, crop, evidence reference, provider response, or athlete content.
The editor never branches on `CreationSource`.

### 6.10 Review issues

Semantic ambiguity is typed, localized, and actionable rather than flattened into warning strings:

```swift
struct ReviewIssue: Identifiable, Sendable, Equatable {
    var id: UUID
    var target: ReviewIssueTarget
    var code: ReviewIssueCode
    var severity: ReviewIssueSeverity
    var resolutionState: ReviewIssueResolutionState
    var allowedActions: [ReviewIssueAction]
    var sourceEvidenceID: ImportEvidenceID?
    var createdAt: Date
}

enum ReviewIssueTarget: Sendable, Equatable {
    case workout
    case block(DraftBlockID)
    case group(DraftGroupID)
    case exercise(DraftExerciseID)
    case metric(DraftFieldID)
}

enum ReviewIssueSeverity: String, Sendable {
    case requiresResolution
    case advisory
}
```

`ReviewIssue` intentionally contains no presentation message.
The iOS UI derives localized, deterministic copy from `code` and `target`.
The provider cannot author warning copy.
`allowedActions` contains serializable action descriptors, not closures or provider instructions.
An issue remains understandable if its optional source evidence expires.
Issues requiring resolution disable Save.
Advisory issues can be accepted or dismissed through ordinary editor controls.
All issues are deleted when the draft is committed or discarded.

### 6.11 Diagnostics

```swift
struct ImportDiagnostics: Sendable, Equatable {
    var importID: UUID
    var route: ImportRoute
    var parserModel: String
    var latencyMilliseconds: Int
    var estimatedCostMicros: Int?
    var ocrMeanConfidence: Double?
    var unmatchedExerciseCount: Int
    var validationIssueCount: Int
    var userCorrectionCount: Int
    var outcome: ImportOutcome?
}
```

Use integer micros for estimated currency cost at the JSON boundary. Diagnostics must not include title, workout text, exercise names, notes, parser output, source filenames, image hashes, images, or OCR regions.

## 7. Deterministic draft construction

`WorkoutDraftBuilder` is a pure, unit-testable boundary.
Given a validated `CandidateGraph`, the catalog snapshot, and unit preferences, it returns a pipeline-owned `WorkoutDraft` with targeted `ReviewIssue` values.

It performs, in order:

1. Validate the candidate graph, applied transaction IDs, and candidate-local keys.
2. Trim and normalize Unicode, whitespace, punctuation, and common multiplication symbols.
3. Assign draft-local IDs and create the parser-key-to-draft-ID map.
4. Resolve OCR observation references and attach provenance.
5. Normalize exercise labels without erasing meaningful variants.
6. Resolve exact catalog matches or attach candidates/unresolved state.
7. Map allowlisted parsed metric kinds and units into `MetricType` and `MetricUnit`.
8. Convert accepted numeric values into canonical units through `MetricConvert`.
9. Reject negative, non-finite, or impossible values and generate field issues.
10. Remove only exact duplicate parser lines that share source evidence; never heuristically merge distinct exercises.
11. Validate each selected metric against the matched definition's supported metrics.
12. Preserve unsupported or ambiguous metrics as issues rather than dropping them silently.
13. Build targeted `ReviewIssue` values and verify every target exists.
14. Run the complete structural audit for blocks, groups, exercises, metrics, ordering, identities, and references.
15. Require at least one structurally valid exercise before handoff.

The builder never creates custom definitions, writes preferences, touches `WorkoutStore`, or persists data.
An empty or text-only result is a failed import outcome, not a draft.
Once the draft passes structural audit, the coordinator atomically changes ownership to `.user`, records the revision, and routes to the ordinary editor.

## 8. Materializing canonical workout content

`WorkoutTemplateMaterializer` runs only when a user-owned draft has no unresolved `requiresResolution` issues and the athlete taps Save.

It:

- Creates a fresh `Workout.id`.
- Creates fresh `WorkoutBlock.id` values while preserving draft order.
- Creates fresh `PlannedExercise.id` values.
- Creates fresh `PlannedSet.id` values.
- Copies only accepted catalog IDs; unresolved identity blocks materialization.
- Copies canonical `MetricValues`, selected metrics, unit overrides, guidance/notes supported by the canonical model, and normalized block intent.
- Produces an ID mapping only for the duration of the confirmation operation if the UI needs to reconcile completion state.
- Does not copy draft IDs, evidence, source regions, OCR text, diagnostics, or the source image.

The result is passed through the same `PlanStore.saveAsTemplate(name:from:tags:)` path used by any other draft after persistence error propagation is added.

## 9. Service interfaces and concurrency

```swift
protocol ImageImportNormalizing: Sendable {
    func normalize(source: ImportSource) async throws -> NormalizedImportImage
}

protocol WorkoutTextRecognizing: Sendable {
    func recognize(image: NormalizedImportImage) async throws -> OCRDocument
}

protocol WorkoutImportParsing: Sendable {
    func proposeTransactions(document: OCRDocument) async throws -> ProposedSemanticTransactionBatch
}

protocol CandidateGraphApplying: Sendable {
    func apply(
        batch: ProposedSemanticTransactionBatch,
        to graph: CandidateGraph
    ) throws -> CandidateGraph
}

protocol WorkoutDraftBuilding: Sendable {
    func build(
        graph: CandidateGraph,
        catalog: ExerciseCatalogSnapshot,
        importSessionID: UUID
    ) throws -> WorkoutDraft
}

protocol WorkoutImporting: Sendable {
    func events(
        for source: ImportSource,
        sessionID: UUID
    ) -> AsyncThrowingStream<ImportSessionEvent, Error>
}

enum ImportSessionEvent: Sendable {
    case phaseChanged(ImportSessionStatus)
    case sourceNormalized(TemporaryImportSource)
    case textRecognized(OCRDocument)
    case transactionBatchValidated(ProposedSemanticTransactionBatch)
    case candidateGraphUpdated(CandidateGraph)
    case draftPrepared(WorkoutDraft)
    case ownershipHandedOff(draftID: UUID, revision: Int)
    case diagnosticsUpdated(ImportDiagnostics)
}
```

Representative pipeline events are source normalized, OCR completed, transactions validated, candidate graph updated, draft prepared, ownership handed off, diagnostics updated, and pipeline failed.
Each event carries only `Sendable` stage output.
`ImportSession.apply(event:at:)` validates session transitions only while import owns the pipeline.

Concurrency rules:

- `WorkoutImportViewModel` is `@Observable @MainActor`; it owns presentation coordination, not OCR/parser logic or import-domain state.
- The view model exposes the current `ImportSession?` only for intake, progress, source inspection, recoverable outcomes, and cleanup.
- The view model consumes pipeline events until atomic handoff.
- After handoff, review edits use ordinary typed `WorkoutDraft` commands and validation.
- ImportSession mutations cannot edit the draft after handoff.
- Service and contract values crossing isolation boundaries are `Sendable` value types.
- Image decoding/normalization and iOS 17 Vision work that blocks synchronously runs off-main using a bounded detached operation with `Data` or a temporary file URL, not `UIImage` crossing actor boundaries.
- The iOS 17 implementation uses `VNRecognizeTextRequest`; an iOS 18+ adapter may adopt the newer async `RecognizeTextRequest` without changing the protocol.
- Long OCR/build loops check cancellation. Network calls propagate cancellation and do not retry `CancellationError`.
- The event stream finishes exactly once on success, failure, or cancellation; its termination handler cancels any underlying Vision/network operation.
- The view model stores at most one import task, cancels it on replacement/discard, and uses a generation/import ID to ignore stale completions after any `await`.
- No custom actor is introduced unless a service owns mutable shared state. Stateless services remain structs.
- `ModelContext` and SwiftData models stay on `@MainActor` inside the repository and never cross into OCR/parser tasks.

## 10. Import state machine

```text
ImportSession
selecting
→ loadingImages
→ recognizing
→ preparingSections
→ assembling (fast path only; falls through to waitingForHandoff when it yields no structure)
→ waitingForHandoff
→ processingSections (retryingSections while a section is re-sent)
→ reviewing
→ saving
→ saved

Any state
└── failed

WorkoutDraft
pipelineOwned
→ userOwned(active)
   ├── committed
   └── discarded
```

The ownership transition is atomic and idempotent.
There is no state in which both the import pipeline and the user can mutate workout content.
Editor visibility is presentation state and does not change draft lifecycle.
A scheduling failure occurs after draft commit and never recreates, rolls back, or deletes the saved template.

## 11. Review UI

### Entry point

Add **Import from image** to the existing Plan Add Workout menu. If launched from a specific day, retain that date only as a post-save scheduling suggestion. Selecting the entry does not create a blank scheduled workout.

The import surface offers:

- Choose up to 10 photos with ordered selection.
- Paste image when an image is present on the pasteboard or dropped through a paste action.
- Cancel.

There is no background pasteboard inspection.

Once the import job is durably accepted and can continue without the intake surface, the leading action changes deterministically from **Cancel** to **Close**.

### Progress

The progress screen uses one headline and a natural phase label per stage:

```text
Creating your workout

Preparing photos           // loadingImages
Reading workout            // recognizing
Organizing exercises       // preparingSections
Sending to the parser      // waitingForHandoff, retryingSections
Waiting for a parser slot  // processingSections while the server reports queued
Organizing exercises       // processingSections while the server is parsing
Preparing editor           // processingSections once every section is done
```

There is no separate "Still working" state.

The fast path does not use this screen once the stream opens. `assembling` shows the workout itself as it arrives - the editor's own row components over the real parsed draft - under a **Reading your workout** line that counts the exercises resolved so far. It is not a text preview that gets swapped for the real thing later.

Stages that can count real units - photos loaded, photos recognized, sections completed - render a determinate `ProgressView` driven by those counts.
Stages that cannot count anything keep the indeterminate spinner rather than inventing a fraction or a synthetic timer.
A queued job has no section underway, so it stays indeterminate even though `processingSections` carries counts.

The detail line under each phase states the truth about backgrounding, and the two truths are different.
Device-side stages (photo load, OCR, section prep, handoff) are suspended by iOS and resume from persisted per-page progress, so they say the import pauses and picks up where it left off.
Once the job is handed off it lives on the server, so those stages say the athlete may close the screen and the result will be waiting; returning to the foreground restores durable progress by job ID.

The display is held awake for exactly the working statuses and released on every terminal state, on `onDisappear`, and on scene phase `.background`, because a leaked idle-timer disable drains the battery silently.
See `WorkoutImportView.shouldKeepScreenAwake(for:)` and `BaselineTests/WorkoutImportKeepAwakeTests.swift`.

### Handoff and outcome

A complete or usable partial draft opens directly in the ordinary workout editor.
There is no import introduction, imported-photo count, import-specific title, imported-section wrapper, raw OCR panel, candidate rendering, or generic review summary before the workout.

When Baseline creates a structurally valid draft but identifies semantic uncertainty, the editor shows the workout first and localizes each `ReviewIssue` at its affected field, metric, exercise, group, or block.
The navigation title may be **Review Workout** when unresolved issues exist.
The word "partial" is internal terminology and is never used in the editor.

When Baseline finds only part of a workout but the result contains at least one structurally valid exercise, the outcome screen says:

```text
We found part of this workout.

Review Workout
Try Again
Choose Different Photos
```

When Baseline cannot create even one structurally valid exercise, it does not open the editor.
It shows a concise failure outcome with **Try Again** and **Choose Different Photos**.

### Review layout

The review is the ordinary native workout editor, not an import-specific form:

- Template name and workout notes.
- Blocks in source order.
- Exercises and sets with the same metric vocabulary as the workout editor.
- Targeted inline issue treatment using icon + text, never color alone.
- Tap an uncertain scalar to edit the value through the normal metric control.
- Tap an unresolved exercise to choose a catalog candidate or explicitly create a custom exercise.
- The ordinary exercise overflow menu supports add, replace exercise, remove exercise, change metrics, and update units.
- Relationship issues provide direct controls at the affected structure: choose the block, choose grouping, attach a note, or select the intended relationship.
- Save is disabled only by `requiresResolution` issues.
- Advisory issues can be accepted or dismissed in context.
- **View Source Photos** is hidden in the editor overflow menu while temporary evidence exists.
- Source photos never appear inline with workout content.
- **View Source Photos** disappears permanently after Save, Discard, or import-session expiry.

The athlete is editing a `WorkoutDraft` until Save.
Closing the editor preserves the active draft.
Save commits the draft and deletes import evidence.
Discard deletes the draft and import evidence.

### Accessibility requirements

- Use semantic Dynamic Type styles; do not rely on the project's current fixed-size workout typography for new import UI.
- Every uncertainty indicator exposes a label, current resolution value, and action.
- The source-photo viewer exposes page position and dismissal controls to VoiceOver.
- Users are never required to inspect a photo or OCR text to resolve an issue.
- Relationship controls are buttons/pickers with at least 44-point targets, not tap gestures on visual connectors.
- VoiceOver focus moves to the first blocking issue after validation and returns to the launching control when the sheet closes.
- Import progress changes are announced without repeatedly interrupting VoiceOver.
- Error/review status uses text and symbols in addition to color.
- Reordering exposes accessible move-up/move-down actions even if drag reordering is added later.

## 12. Unknown exercises and custom creation

An unresolved movement blocks save until the athlete chooses one of these actions:

1. Select a catalog candidate.
2. Edit the recognized name and retry matching.
3. Explicitly choose **Create custom exercise**.
4. Delete the exercise from the draft.

Custom creation reuses the existing deliberate custom-exercise flow and requires name, category, and supported metrics. Creation is a separate explicit mutation. Only after it succeeds does the draft receive `.customConfirmed(definitionID:)`.

If custom creation fails, the draft and local source remain available for retry. No generic definition is silently substituted.

## 13. Duplicate behavior

`WorkoutContentFingerprinter` creates a SHA-256 fingerprint from a deterministic representation of the materialized workout content:

- Exclude all workout/block/exercise/set UUIDs.
- Exclude schedule date, template revision identity, provenance, diagnostics, and source data.
- Exclude import-session identity and any indication that the content was imported.
- Normalize title/name whitespace and case for comparison.
- Preserve block, exercise, and set order.
- Include accepted catalog IDs, metrics, canonical values, goal, intent, and material notes.
- Encode dictionary keys in stable order before hashing.

V1 computes fingerprints on demand against current template revisions; it does not add a fingerprint field or SwiftData migration solely for this feature.

When a likely duplicate exists:

- Show the existing template name and a nonblocking warning.
- Default action remains **Save as new template**.
- **Update existing template** requires the athlete to select the target explicitly and creates a new immutable template revision.
- Never silently merge or overwrite based on name or fingerprint.

## 14. Persistence and separate commits

### Repository hardening prerequisite

The current repository cannot report a failed `ModelContext.save()` because it suppresses the error. Before wiring the import UI, change template operations to return typed success/failure or throw:

```swift
func saveAsTemplate(name: String, from workout: Workout, tags: [WorkoutTag]) throws -> WorkoutTemplate
func updateTemplate(_ id: UUID, from workout: Workout) throws -> WorkoutTemplate
func instantiateTemplate(_ id: UUID, on date: Date, programID: UUID, actor: PlanActor) throws -> ScheduledWorkout
```

Update existing Plan, Workout, agent-tool, and test call sites in the same issue. Do not change unrelated plan mutation behavior.

### Commit 1: template

1. Materialize canonical workout values with fresh IDs.
2. Call `saveAsTemplate`, or `updateTemplate` only after explicit target selection.
3. Await/receive repository success.
4. Enter `templateSaved` and delete all temporary source images.
5. Present success independently of scheduling.

### Commit 2: optional schedule

1. Athlete chooses a date/program or accepts the launch-date suggestion.
2. Call `instantiateTemplate` with the saved template ID.
3. On success, open the independent scheduled workout if appropriate.
4. On failure, remain in `templateSaved`; offer Retry, Choose Another Date, or Done.

Template persistence and scheduling must not share a transaction or compensating delete.

## 15. Image and privacy lifecycle

### Local lifecycle

1. PhotosPicker loads selected assets sequentially in the athlete's chosen order to bound peak transfer memory.
2. Validate the uniform type and byte count before decoding.
3. Normalize orientation, dimensions, color space, and encoding; remove metadata by rendering a new image representation.
4. Write each normalized review image under one session-scoped temporary import directory using complete file protection.
5. Keep page order and dimensions in transient import state so OCR evidence remains attached to the correct image.
6. Delete the entire session directory immediately after successful template save, explicit draft discard, import cancellation, source replacement, or session expiry.
7. Sweep abandoned import files older than 24 hours when the import surface starts and on app launch through an idempotent cleanup service.

The 24-hour TTL is a technical maximum for crash recovery, not intended retention.
The `WorkoutDraft` has an independent lifetime and is not deleted when source evidence expires.
If evidence expires while an active draft remains, **View Source Photos** disappears and each `ReviewIssue` remains resolvable without that evidence.

### Cloud lifecycle

The first slice sends OCR observations and text only. It does not upload image bytes or use Cloud Storage.

The future multimodal parser may send the normalized image directly in a single authenticated request. Temporary Cloud Storage is introduced only if request size, retries, or background work require it. If introduced, it requires:

- UID-scoped paths.
- Auth ownership, content-type allowlist, and byte-size limits in `storage.rules`.
- No client list access.
- Server-side deletion after processing plus lifecycle cleanup for abandoned objects.
- Rules deployed to every environment before the client depends on the path.

### Privacy and logging

- Never log OCR text, workout titles, exercise names, notes, parser payloads, image bytes, source filenames, source regions, or provider prompts/responses.
- Provider keys remain Firebase secrets and never enter the app bundle.
- Confirm the provider's data-retention settings before production use.
- Review `PrivacyInfo.xcprivacy`, privacy policy, and App Store privacy answers before shipping. Photo selection alone does not justify broad photo-library access; use PhotosPicker rather than requesting library permission.
- The first slice does not add camera capture, so it does not change the existing camera permission copy. When workout camera capture ships, update both `project.yml` and `Info.plist` descriptions together.

## 16. Backend contract and limits

Add a dedicated second-generation callable function such as `parseWorkoutImport`. Do not reuse the conversation endpoint or its transcript wire format.

### Request

```text
schemaVersion
importID
locale
observations[]:
  id
  text
  confidence
  normalized region
  line index
```

### Response

```text
schemaVersion
semanticTransactions[]
route
providerModel
latencyMilliseconds
estimatedCostMicros?
```

### Initial Baseline limits

These app limits intentionally sit well below the platform ceiling and should be adjusted only from evaluation data:

- One through ten ordered still images per import.
- Accepted source file: at most 20 MB before normalization.
- Normalized longest edge: at most 2,400 pixels.
- Normalized local review file: target at most 4 MB.
- OCR observations sent to the parser: at most 1,000.
- Combined OCR text: at most 40,000 Unicode scalar values.
- Individual OCR line: at most 1,000 Unicode scalar values.
- Parser response: at most 250 exercises and 2,000 sets, with bounded notes and string lengths.
- Client timeout: explicit and greater than the Firebase callable default only if evaluation shows it is required; no indefinite wait.
- Retry: one automatic retry only for transient transport/provider failures, never for authentication, validation, rate limit, cancellation, or schema errors.

Cloud Functions second generation currently permits a 32 MB uncompressed HTTP request, but image base64 and callable framing add overhead. The durable job sends OCR text only. The streaming fast path does send image bytes and stays well below the platform maximum through its own limits in `WORKOUT_IMPORT_STREAM_LIMITS`: at most 10 images, 5 MB per image, 20 MB in total, and 60,000 characters of accompanying text.

### Server enforcement

- Require Firebase Auth and derive UID from `req.auth`; never accept UID from the request body.
- Configure and enforce Firebase App Check for the import function before production rollout.
- Validate the outer request before constructing a prompt.
- Keep user/OCR input in the user-content channel, never concatenate it into system instructions.
- Use an import-specific provider interface and parser prompt.
- Use structured output/tool schema and validate the returned object again before responding.
- The client does not choose the model. The server reads `WORKOUT_IMPORT_MODEL`, or `WORKOUT_IMPORT_STREAM_MODEL` for the streaming path, or task configuration.
- Use an import-specific per-user daily quota, payload limit, concurrency/burst guard, provider spending cap, and billing alert.
- Return stable error codes: unauthenticated, app-check-required, invalid-image, input-too-large, no-text, parser-invalid, rate-limited, provider-unavailable, timeout.
- Log only `importID`, UID hash or protected UID as already permitted operationally, route/model, duration, token/cost counts, bounded counts, and error code.

App Check setup requires adding the Firebase App Check product to the iOS target, configuring App Attest for production and the debug provider for local development, monitoring metrics, then enabling `enforceAppCheck: true` on the function.

## 17. Diagnostics lifecycle

The backend creates initial non-content diagnostics when parsing completes. The app increments local counters while the athlete reviews:

- Scalar value edit.
- Exercise match changed.
- Exercise deleted/added.
- Block or exercise reordered.
- Relationship issue resolved.
- Custom exercise confirmed.

Pre-handoff counters live on `ImportSession.diagnostics`.
Post-handoff correction counters are recorded by a content-free draft outcome tracker keyed to the originating import ID.
The tracker observes ordinary draft commands but cannot mutate the draft or retain workout content.
After Save or Discard, the app sends one bounded outcome event to a dedicated authenticated, App Check-protected callable.
The backend combines parse and outcome metrics in structured Cloud Logging.

V1 does not create a Firestore diagnostics collection. This avoids a new synced schema and rule surface until diagnostics query/retention requirements are known. A later durable store requires explicit strict rules, field allowlists, retention, and deployment to all environments before client use.

## 18. Error recovery

| Failure | State retained | User action |
|---|---|---|
| Photos/iCloud load fails | No draft | Retry selection or paste |
| Any unsupported/corrupt/oversized image in the batch | No draft | Choose another image |
| Normalization fails | Original picker selection only | Retry or replace |
| OCR finds no useful text on any page | No partial draft | Retry OCR or replace the affected selection. OCR gates the pipeline, so the fast path is not reached either, even though it could read the image itself |
| Fast-path stream fails or yields no exercises | Images + OCR evidence | Automatic: the durable job takes over as the retry |
| Fast-path stream ends early with exercises already resolved | User-owned draft + a warning issue | Review the workout against the photo; the missing tail is edited in |
| Parser offline/times out | Images + OCR evidence | Retry without rerunning OCR |
| Parser schema invalid | Images + OCR evidence | Retry; log schema error without content |
| Candidate graph cannot produce one valid exercise | Import evidence only | Try Again or Choose Different Photos; never open the editor |
| Structural draft audit fails | Import evidence + candidate graph | Deterministic repair or retry before handoff; never render malformed content |
| Catalog match unresolved in a valid draft | User-owned draft + targeted issue | Choose, edit, create custom, or delete through the ordinary editor |
| Custom creation fails | User-owned draft | Retry; no generic fallback |
| Template save fails | User-owned draft + temporary evidence when available | Retry Save or Discard |
| Template save succeeds | Saved template; source deleted | Done or optionally schedule |
| Scheduling fails | Saved template | Retry date/program or finish |
| App terminates before handoff | Import checkpoints + protected source batch | Resume the import job when supported or present the recoverable outcome |
| App terminates or editor closes after handoff | User-owned draft + temporary evidence until expiry | Resume the existing draft without another import |
| User cancels before handoff | Nothing retained | Delete source, checkpoints, candidates, and pending work |
| User discards after handoff | Nothing retained | Delete the draft and import evidence |

Source images are deleted only after durable template-save success, not when save begins.

## 19. Testing and evaluation

### Pure unit tests with Swift Testing

- Semantic-transaction contract validation: missing keys, duplicate transaction IDs, invalid ordering, dangling relationships, limits, and schema versions.
- Import-session state transitions, stable timestamps/identity, retry behavior, and future Codable round-trip readiness.
- Candidate-graph transaction idempotency and deterministic replay.
- Atomic ownership handoff succeeds exactly once.
- Late, retried, and replayed provider results cannot mutate a user-owned draft.
- Every draft accepted by the editor passes the complete structural audit and contains at least one valid exercise.
- OCR-only and candidate-only results never open the editor.
- Unit parsing/normalization: kg/lb, m/km/mi, seconds/minutes, multiplication symbols, decimal values.
- Catalog matching: exact name, exact alias, abbreviations, candidate-only fuzzy matches, unknown result.
- Metric compatibility: unsupported metrics become issues and are never silently discarded.
- Draft-local identity: IDs survive edit/reorder and do not leak into materialized canonical content.
- Evidence integrity: field and relationship evidence follows draft IDs; deleting targets removes dangling evidence.
- Relationship resolution for round scope, grouping, note attachment, and columns.
- Materialization creates fresh workout/block/exercise/set IDs every time.
- Duplicate fingerprint stability and meaningful-change sensitivity.
- ReviewIssue copy is derived from codes and never accepted from provider output.
- Save gating: `requiresResolution` versus advisory issues.
- Diagnostics correction counts contain no content fields.
- Cancellation and stale-result protection in the view model without timing-based sleeps.

### Repository integration tests

- Imported materialized content saves as an immutable template revision.
- A closed user-owned draft survives and reopens in the ordinary editor.
- Manual and photo-created drafts use the same editor commands, validation, and persistence path.
- Explicit update creates a new template revision and leaves scheduled instances unchanged.
- Save failure is surfaced.
- Scheduling creates an independent workout with template/revision attribution.
- Scheduling failure after save leaves the template available.
- Duplicate warning never changes persistence without explicit user selection.

Use an in-memory `ModelContainer` per test. Keep SwiftData and its models on `@MainActor`. Tests must not share `UserDefaults`, model containers, temp directories, or global mutable fixtures.

### Service tests

- Vision recognizer fixtures run locally and return ordered observations with normalized regions.
- Parser client tests use injected fakes; unit tests never call a live provider.
- Transport tests validate authentication/error mapping, status handling, cancellation, and response bounds.
- Temporary store tests verify complete file protection where testable, replacement cleanup, save/discard cleanup, and TTL sweep.

### Backend tests

- Request validator rejects missing auth-equivalent context, over-limit text/arrays, invalid regions/confidence, and unexpected fields.
- Provider output validator rejects extra/missing fields, duplicate keys, dangling references, NaN/infinite/range violations, and oversized output.
- Rate limit is server-controlled and cannot be reset by request data.
- Logging serializer proves content-bearing keys are absent.
- Prompt construction keeps instructions and OCR content in separate roles.

No new backend test dependency is required initially: use Node's built-in test runner after compiling testable pure modules, or add a test framework only with explicit approval.

### Evaluation mode

Add a non-production `ImportEvaluationRunner` that uses the same production protocols and deterministic builder:

```text
Fixture image
→ normalize once
→ OCR once
→ Parser A ─┐
→ Parser B ─┼→ validate/build each result → compare with gold fixture → report
→ Parser C ─┘
```

Evaluation requirements:

- Lives in the test/developer tooling boundary, not the shipping import flow.
- Accepts `[any WorkoutImportParsing]`; model/provider identity comes from each adapter's diagnostics, not hardcoded comparison logic.
- Reuses one normalized image and one `OCRDocument` so OCR variation does not contaminate parser comparison.
- Runs each transaction batch through the same contract validator, `CandidateGraph`, `WorkoutDraftBuilder`, structural audit, and template materializer used by production.
- Compares structured fields, relationships, issues, correction operations, latency, token use, and estimated cost against a hand-authored expected result.
- Emits machine-readable JSON/CSV plus a concise human report without copying source workout text into general application logs.
- Supports offline replay from captured, sanitized parser responses so most evaluation runs do not spend provider tokens.
- Never fans out one production user import to multiple providers.
- Provider/model changes are accepted only after evaluation on the fixed corpus and review of regressions in safety-critical values such as load, distance, duration, and round scope.

This makes Claude, Gemini, GPT, Apple, deterministic code, or future local-model comparisons an adapter and configuration choice rather than a feature rewrite.

### Fixed image corpus

Create sanitized or synthetic fixtures under `BaselineTests/Fixtures/WorkoutImport/`:

- Clean single-block screenshot.
- Named warm-up/strength/conditioning blocks.
- Sets × reps × load in kg and lb.
- Distance/time/calorie/cardio prescriptions.
- Superset/circuit with explicit heading.
- Round count applying to one block.
- Coach notes attached to workout versus exercise.
- OCR-confusable values such as 15/75 and 0/O.
- Known aliases and an unknown movement.
- Duplicate workout with formatting differences.
- Multi-column example expected to raise a relationship issue in the first slice rather than silently flatten.

Each fixture has:

- Source image.
- Expected OCR assertions tolerant to documented Vision variation where necessary.
- Hand-authored semantic-transaction fixture for deterministic candidate-graph and builder tests.
- Expected draft summary and issue list.
- Expected canonical workout after explicit resolutions.

The corpus must not contain real athlete names, private coach notes, copyrighted program pages without permission, or production user data.

### Evaluation metrics

Track per corpus and later opt-in real imports:

- Exercise identity accuracy.
- Block and exercise order accuracy.
- Set/rep/load/distance/time value accuracy.
- Unit accuracy.
- Structural relationship accuracy.
- Unresolved exercise count.
- Blocking/review issue count.
- User correction count.
- Save completion rate.
- Parse latency.
- Estimated provider cost.

Model changes require corpus evaluation.
Choose the inexpensive parser by total correction burden, latency, and cost, not by a single provider benchmark.

## 20. File plan

Suggested feature structure:

```text
Baseline/Features/WorkoutImport/
  Models/
    ImportSession.swift
    ImportIdentifiers.swift
    OCRDocument.swift
    SemanticTransaction.swift
    CandidateGraph.swift
    ImportEvidence.swift
    ImportDiagnostics.swift
  Services/
    WorkoutImportService.swift
    ImageImportNormalizer.swift
    TemporaryImportStore.swift
    VisionWorkoutTextRecognizer.swift
    WorkoutImportParser.swift
    CloudWorkoutImportParser.swift
    SemanticTransactionValidator.swift
    CandidateGraphApplier.swift
    WorkoutDraftBuilder.swift
    ExerciseCatalogMatcher.swift
    WorkoutContentFingerprinter.swift
  ViewModels/
    WorkoutImportViewModel.swift
  Views/
    WorkoutImportView.swift
    WorkoutImportProgressView.swift
    WorkoutImportOutcomeView.swift
    ImportSourcePhotosView.swift
```

The ordinary draft, review issue, command, validation, and editor types live with the workout authoring feature rather than under `WorkoutImport`.

Existing files expected to change during implementation:

- `Baseline/Features/Plan/PlanView.swift` - launch import and carry optional post-save date suggestion.
- `Baseline/Features/Workout/ExerciseCatalog.swift` and/or a catalog snapshot provider - expose data to the matcher without changing existing manual resolution behavior.
- `Baseline/Shared/Services/PlanRepository.swift` - propagate template persistence/instantiation failures and expose duplicate comparison against current revisions.
- `Baseline/Shared/Settings/PlanStore.swift` - surface typed template operations to UI.
- `Baseline/Features/Workout/WorkoutView.swift` - adapt existing template calls to typed failures; no importer logic.
- `Baseline/App/BaselineApp.swift` - inject the import client/services and run temp cleanup, or inject them at the feature boundary if app-wide ownership is unnecessary.
- `project.yml` - Firebase App Check product and any test fixture/resource configuration; run `xcodegen generate` afterward.
- `functions/src/index.ts` - export the import and outcome callables.
- `functions/src/import/*` - request contract, validation, prompt, provider seam, limits, and diagnostics.
- `functions/package.json` - test/build scripts; no new dependency without approval.
- `firestore.rules` - no import change in V1 if diagnostics remain Cloud Logging-only.
- `storage.rules` - no import change in V1 because images are not uploaded.
- `PrivacyInfo.xcprivacy`, privacy policy, App Store privacy answers - audit before shipping.

Tests:

```text
BaselineTests/WorkoutImport/
  ImportSessionTests.swift
  WorkoutDraftBuilderTests.swift
  ExerciseCatalogMatcherTests.swift
  WorkoutTemplateMaterializerTests.swift
  WorkoutContentFingerprinterTests.swift
  WorkoutImportViewModelTests.swift
  WorkoutImportRepositoryTests.swift
  TemporaryImportStoreTests.swift
  Fixtures/
```

## 21. Build sequence

### Phase 0 - contract and repository prerequisites

1. Resolve the GitHub issue and create the issue-numbered feature branch from `develop`.
2. Land the terminology cleanup.
3. Define and fixture-test the session, semantic-transaction, candidate-graph, draft, evidence, ownership, and review-issue contracts.
4. Make template repository operations report persistence failure.
5. Add deterministic duplicate comparison without a SwiftData schema migration.
6. Add Firebase App Check client setup and validate it in dev before enforcing the new function.

### Phase 1 - complete clean-screenshot path

1. Ordered multi-photo/paste intake and temporary protected batch lifecycle.
2. Image normalization.
3. Vision OCR and exercise custom vocabulary.
4. Text-parser callable with strict validation and quotas.
5. Semantic transaction validation, deterministic candidate graph, catalog matcher, metric and unit validation, structural audit, and draft builder.
6. Atomic ownership handoff into the ordinary editor with targeted issue resolution.
7. Explicit custom exercise confirmation.
8. Save template commit, success state, and separate optional scheduling.
9. Diagnostics outcome reporting.
10. Corpus, unit, integration, accessibility, and failure-recovery tests.

### Phase 2 - evaluate before expanding

1. Run the fixed corpus and real clean screenshots.
2. Measure corrections, validation failures, latency, and cost.
3. Improve aliases, deterministic builder rules, prompt, and review controls first.
4. Decide whether multimodal fallback is justified and define its threshold from observed failures.

### Phase 3 - multimodal fallback, only after approval

1. Add `MultimodalWorkoutImportParser` behind the existing parser protocol.
2. Send normalized image + OCR evidence for complex/failed imports.
3. Add route criteria and explicit accurate-retry action.
4. Add provider/image lifecycle and cost tests.
5. Consider iOS 27 on-device image parsing behind availability gates.

## 22. Acceptance criteria for the first slice

- One through ten ordered clean workout screenshots can become one ordinary user-owned `WorkoutDraft` and then a persisted `WorkoutTemplate` without creating scheduled plan state.
- `ImportSession` owns only temporary source, OCR evidence, checkpoints, candidate graph, diagnostics, status, and lifecycle timestamps.
- `WorkoutDraft` owns editable workout content, targeted review issues, revision, lifecycle, and its single current owner.
- The model response proposes semantic transactions and never constructs or persists a draft or canonical workout identity.
- The editor never renders OCR, provider output, candidate nodes, transaction output, or malformed workout content.
- A draft cannot be handed off unless the complete structural audit passes and at least one valid exercise exists.
- Atomic handoff transfers ownership exactly once, and late import work cannot mutate the user-owned draft.
- Closing the editor preserves the draft and reopening resumes the same draft revision.
- Complete and usable partial results open the same ordinary workout editor.
- OCR-only, text-only, and candidate-only results show an outcome screen instead of the editor.
- All draft nodes keep stable draft-local IDs through edits and reordering.
- Source photos are available only through the hidden editor overflow action while temporary evidence exists.
- Source photos never appear inline with workout content and disappear permanently after Save, Discard, or expiry.
- Unknown exercises block save until explicitly resolved; no generic or custom exercise is silently created.
- Unsupported metrics and ambiguous units are visible issues, never silently dropped or guessed.
- Template save success is durable and visible before scheduling starts.
- Scheduling failure does not delete, roll back, duplicate, or hide the saved template.
- Duplicate detection never overwrites or updates without explicit selection.
- All local source images are removed on save/discard/expiry and are absent from permanent records and logs.
- Backend requests require Auth and App Check, enforce bounds and rate limits, and keep provider keys server-side.
- Diagnostics contain no workout content.
- Imported and manually authored drafts and templates use the same domain objects, editor, commands, validation, persistence, scheduling, and history behavior.
- Only generic `CreationProvenance` may remain after Save; no import evidence, imported subtype, behavior flag, or special engine path remains.
- Tests run without live provider calls and cover the fixed image corpus, deterministic transformations, persistence boundaries, cancellation, and error recovery.

## 23. Implemented UI decisions

- V1 launches from the Plan day-level Add Workout menu.
- Photo intake and progress are a full-screen import flow before handoff.
- Progress uses one **Creating your workout** headline with a per-stage phase label; see [Progress](#progress) for the phases, determinate-versus-indeterminate rule, and keep-awake behavior.
- Cancel changes to Close only after the import job is durably accepted.
- Complete and usable partial results hand off to the ordinary workout editor without an import introduction.
- The editor displays targeted issues in context and never displays raw OCR or imported-section placeholders.
- **View Source Photos** is hidden in the editor overflow and is temporary.
- Leaving the editor preserves the active draft until Save or Discard.
- Likely duplicates are shown before persistence with explicit update or save-as-new actions.
- Custom exercises reuse Baseline's existing explicit creation surface.
- Save completes before the separate Add to Plan action; the launch date is preselected but editable.

## 24. Release activation checklist

1. Register both Firebase apps for App Check with App Attest and enable the App Attest capability for the App Store signing profile.
2. Generate a fresh simulator debug token, register it in each development Firebase project, and keep it in local/CI secret storage only.
3. Deploy `parseWorkoutImport` and `streamWorkoutImport` after confirming their secrets exist in the target project: `ANTHROPIC_API_KEY` plus the Langfuse observability secrets (`LANGFUSE_SECRET_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_BASE_URL`); the deploy fails while any is unset. See [firebase-setup.md](../firebase-setup.md) for the `functions:secrets:set` commands.
4. Leave `IMPORT_ENFORCE_APP_CHECK` unset while monitoring valid/invalid request metrics; set it to `true` only after legitimate builds are verified.
5. Optionally set `WORKOUT_IMPORT_MODEL`; the pinned default is `claude-sonnet-4-5-20250929`. `WORKOUT_IMPORT_STREAM_MODEL` overrides it for the streaming fast path only and defaults to the same model.
6. Run the sanitized screenshot corpus on physical devices before enabling the feature for TestFlight users.

## References

- Apple Vision `RecognizeTextRequest`: https://developer.apple.com/documentation/vision/recognizetextrequest
- Apple PhotosPicker + Transferable sample: https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app
- Firebase callable functions: https://firebase.google.com/docs/functions/callable
- Cloud Functions quotas: https://firebase.google.com/docs/functions/quotas
- Firebase App Check enforcement: https://firebase.google.com/docs/app-check/cloud-functions

# Tool-schema token fixture

`measure-tool-schema-tokens.js` is the authoritative fixture generator and stale-fixture checker.
Anthropic's `count_tokens` response includes provider-calculated tool-use overhead, so an exact fixture cannot be derived from bytes or a local tokenizer.

## Regenerate without a local Anthropic key

Push the feature-branch commit containing every prompt and schema change.
Then dispatch the trusted workflow from `develop`, passing the feature branch as data:

```sh
gh-axi workflow run regenerate-tool-schema-token-fixture.yml \
  --ref develop \
  --field branch="$(git branch --show-current)"
```

Find and watch the resulting run:

```sh
gh-axi run list \
  --workflow regenerate-tool-schema-token-fixture.yml \
  --branch develop \
  --event workflow_dispatch \
  --limit 5
gh-axi run watch <run-id>
```

Download the completed fixture into a temporary directory and verify that it was measured from the current commit before copying it into the branch:

```sh
fixture_tmp="$(mktemp -d)"
gh-axi run download <run-id> \
  --name tool-schema-token-fixture \
  --dir "$fixture_tmp"
test "$(cat "$fixture_tmp/source-branch.txt")" = "$(git branch --show-current)"
test "$(cat "$fixture_tmp/source-commit.txt")" = "$(git rev-parse HEAD)"
cp "$fixture_tmp/functions/src/toolSchemaTokens.json" \
  functions/src/toolSchemaTokens.json
git diff -- functions/src/toolSchemaTokens.json
```

Commit the fixture diff to the same feature branch.
The pull request's `functions-token-fixture` job runs `npm run tokens:check` against the same endpoint and fails if the committed fixture is stale.

The workflow is intentionally split into two jobs.
Feature-branch code only compiles and exports the exact request shapes in a job with no secrets.
The secret-bearing job checks out the reviewed script from the default branch, validates the exported JSON, calls only Anthropic's fixed `count_tokens` endpoint, and uploads the result.
Both jobs have read-only repository permissions, persisted checkout credentials are disabled, and the workflow rejects the default branch as a measurement target.
It cannot push to any branch or bypass pull-request review.

One run is isolated to one captured source commit.
A newer dispatch for the same branch cancels the older run, and the downloaded source metadata prevents a result from being silently applied after that branch advances.

## Local maintainer commands

A maintainer who already has an Anthropic key may still run:

```sh
ANTHROPIC_API_KEY=... npm --prefix functions run tokens:measure
ANTHROPIC_API_KEY=... npm --prefix functions run tokens:check
```

Never edit `functions/src/toolSchemaTokens.json` by hand.

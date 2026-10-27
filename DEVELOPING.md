# DEVELOPING.md

Development instructions for this package. Harness-agnostic: Claude Code, Codex, OpenCode and
a human at a terminal all follow this file. Where a harness adapter is mentioned it is an
example, never the mechanism — the contract is the `make` targets and the exit codes.

You are here because you are changing the playbook, the scripts, the gates, the template or
the docs. You are not building a product for an operator. If you were started by
`bin/run-*.sh` with a run prompt and `intake.yaml` exists, you are in the wrong file: go back
to `AGENTS.md`.

## Never execute a real run to try it out

`bin/run-claude.sh`, `bin/run-codex.sh` and `bin/run-factory.sh` are not test commands. They
provision real infrastructure, create real billing catalog entries, and spend real money, under
`bypassPermissions` with the no-questions hook armed so nothing will stop to confirm. There is
no dry-run flag on a factory run.

Development is exercised through `make test` and fake harnesses on `PATH`. That is the only
sanctioned way to observe launcher behaviour; `bin/test-failover.sh` demonstrates it.

If a real run is genuinely needed, that is the operator's explicit decision, never an agent's.
Undoing one is `template/teardown.sh` driven by the `PROVISIONED.md` ledger — which is why
every provisioned row must carry a teardown command.

## Asking questions is correct here

Run mode forbids questions because nobody is listening. Development inverts that: a human is
sitting there, and a wrong assumption costs more than a question. Ask.

The guards that make run mode work must not be weakened to make development comfortable:

- `.claude/settings.json` denies `AskUserQuestion` and `ExitPlanMode`.
- A `Stop`/`SubagentStop` hook rejects any final message that interrogates the user.
- `bin/run-claude.sh` launches under `bypassPermissions`.

This list is authoritative; `CONTRIBUTING.md` and the lab README point at it rather than
restating it. All three are correct for an unattended run. Deleting a denial or disarming the
hook so your session can ask a question silently breaks the package's reason to exist.

**The remedy, and it is Claude-Code-specific.** Claude Code resolves project settings from
the session's project root, and a nested `.claude/settings.json` is not a settings source. So
start the session from the **parent directory of this checkout** — any directory that is not
this repo root — and edit files under it; this package's `.claude/settings.json` is then not
loaded and its denials do not apply, while the file itself stays untouched. That parent
directory is "the lab" wherever it is named in these docs.

Other harnesses are not affected by `.claude/settings.json` at all, so they need no remedy —
but the trade is different for them. Codex loads `AGENTS.md` and `codex/config.toml` from the
repo root, so starting one directory up means it loads neither. Run Codex from inside the
checkout and rely on the mode router at the top of `AGENTS.md`.

The mechanism is undocumented behaviour of one Claude Code version. Re-measure after an
upgrade rather than trusting this paragraph; the lab README records how it was measured.

## Test-driven development

### Seams

A seam is the public boundary where behaviour is observable without reaching inside. Tests
live at seams. A test that reaches past one is testing an implementation, and it will break on
a refactor that changed no behaviour.

This package has fourteen, and knowing which one you are touching tells you where the test
goes. Every suite named below is a `dev/test.sh` suite name unless it is a path:

| # | Seam | What goes in, what comes out | Suite |
|---|---|---|---|
| 1 | `bin/detect-question.sh` | stdin text in; exit 0 interrogative, 1 clean, 2 malformed pattern file | `detector` |
| 2 | `bin/question-patterns.txt` | data, not code. One rule per line, one fixture per rule | `patterns` |
| 3 | `.claude/hooks/no-questions.sh` | hook JSON on stdin; decision JSON on stdout, exit 0 | `detector` |
| 4 | `.claude/hooks/on-api-failure.sh` | hook JSON on stdin; a breadcrumb file out | `failover` |
| 5 | `bin/run-claude.sh`, `bin/run-codex.sh`, `bin/run-factory.sh` | argv and env in; exit code plus `artifacts/` out | `failover` |
| 6 | `bin/validate-intake.mjs` | a file path in; exit code and a report out, `--json` for machines | `intake` |
| 7 | `template/billing-core/*.mjs` | module exports; the injected store port is the seam | `billing` |
| 8 | `template/gates/*.sh` | env in (`APP_URL`, `MONTHLY_INFRA_BUDGET_USD`); exit 0 pass / 1 fail / 77 skip | `gates` |
| 9 | `template/verify.sh` | `--list`, `--gate <name>`; an artifact file and an exit code | `gates` |
| 10 | `template/secret-scan.sh`, `template/preflight.sh`, `template/teardown.sh` | exit codes plus stdout contracts: `OK`/`FAIL`/`ABSENT`, `--dry-run` vs `--yes` | `secrets` (scan only) |
| 11 | `gateway/*.sh` | daemon lifecycle and port state; `probe.sh --induce-failure` is the fallback proof | `failover` |
| 11b | `bin/render-gateway-config.mjs` | `gateway/providers.conf` + `FACTORY_MODEL_CHAIN` in, a LiteLLM config and a shell sidecar out. Pure: no daemon, no network, so test it by rendering and reading. Both directions matter — a valid chain must render in order, an invalid one must refuse rather than route nowhere | `chain` |
| 12 | `intake.schema.json` <-> `QUESTIONNAIRE.md` <-> `intake.example.yaml` | three-file consistency | `intake`, via `--check-docs` |
| 13 | `dev/test.sh` | `--list`, `--quick`, `--suite NAME`; one aggregated exit code | itself; `make check` |
| 14 | `dev/lint.sh` + `dev/port-rules.txt` + `dev/make-rules.txt` | rule tables as data; one hit list and one exit code | `portability`, plus lint's own `selfcheck` |

Notes that change how you test each:

- **Seam 2 is data.** Edit `bin/question-patterns.txt` here and nowhere else. Both harnesses
  read the same file, so the rule cannot drift between them. Never copy a pattern into an
  adapter. Add a rule and you add its fixture to `bin/question-pattern-fixtures.txt` in the
  same commit: the `patterns` suite requires one fixture per rule that **only that rule**
  matches, which is what makes each rule individually load-bearing. Without that bijection a
  rule could be deleted with every gate still green — the realistic cases in
  `bin/test-detect-question.sh` are each caught by several rules at once.
- **Seam 3 must fail open.** The contract is the JSON payload, so tests feed crafted payloads
  rather than running a harness. A hook that blocked on its own bug would be worse than the
  behaviour it guards.
- **Seam 5 is process-level.** Drive it with a fake harness on `PATH`. Never call a real model
  from a test.
- **Seam 7's seam is the injected store port.** `template/billing-core/store-memory.mjs` is the
  test double and holds
  a controllable clock, so tests call `advance()` instead of sleeping. Never reach past the port
  into the store's `Map`s.
- **Seam 8 has three exit codes, not two.** 0 pass, 1 fail, 77 skip (`SKIP_EXIT` in
  `template/gates/_lib.sh`). A skip must also print `SKIP: <reason>` at column zero, or
  `template/verify.sh` scores it a specific failure: "skipped without naming a BLOCKER". A
  test that asserts "exit is 0 or 1" reads a correct skip as a failure and never covers the
  bug verify.sh exists to catch.
- **Seam 8's load-bearing rule, and the one distinction it turns on:** a check that is missing
  or unimplementable **FAILS** — "no test was written" must never read the same as "the test
  passed". A *capability* that is unavailable on the achieved tier (no public URL yet, no SMS
  credential) may `skip()` and name the BLOCKER. Missing work fails; missing capability skips.
  A SKIP is never a pass either way.

### Red before green

Write the failing test first. Watch it fail for the reason you expect — a test that passes
before the change tests nothing. Then write only enough code to pass it. No speculative
features, no parameters without a caller.

### Vertical slices, not horizontal

One seam, one test, one minimal implementation, then the next. Writing all the tests first
verifies *imagined* behaviour and locks in a test structure chosen before you understood the
implementation. Each test is a tracer bullet: it responds to what the previous cycle taught you.

Refactoring is not part of the red-green loop. It belongs to review, as its own commit.

### Three anti-patterns

**Implementation-coupled.** Mocks an internal collaborator, tests a private function, or
verifies through a side channel. The tell: it breaks on a refactor when behaviour did not
change. Here that looks like **asserting** the exact counter path
`$TMPDIR/no-questions-<key>.count` that `.claude/hooks/no-questions.sh` writes, instead of
asserting the BLOCK/ALLOW decision JSON. Likewise, reading the memory store's `entitlements`
map directly instead of calling `can()`.

The line is assertions, not fixtures. **Fixture setup may know the path; an assertion may
not.** `bin/test-detect-question.sh:56-59` builds those counter paths deliberately, to clear
stale counters between runs and to inject a corrupt one — there is no other way to reach
either state, and every assertion in that file is still on the decision JSON. That coupling
is intentional and is why renaming the key format means editing that file. Copy the shape,
not the conclusion that paths are fair game in assertions.

**Tautological.** The assertion recomputes the expected value the way the code does, so it
passes by construction and can never disagree with the code. Here that looks like a
`bin/detect-question.sh` case that loads `bin/question-patterns.txt` and greps with the same
regex the
script uses, or a quota test that asserts `quotaFor(...)` equals `QUOTAS[plan][metric]` by
importing `QUOTAS`. Expected values come from an independent source: a known-good literal
(`"Which billing provider should I use?"` -> BLOCK), a worked example, or the number written in
`playbook/subscription-billing.md`.

**Horizontal slicing.** Breadth before any depth works. Here that looks like writing cases
for all nine `dev/test.sh` suites, or all nine `template/gates/*.sh`, before the first one
passes. The observable tell: every case in the new file fails, and they all fail for the same
unimplemented reason. One passing vertical slice beats nine red ones — the second slice
should be able to learn from the first.

### Where a new test goes

| Change | Test |
|---|---|
| A new question pattern | The rule in `bin/question-patterns.txt`, its isolating fixture in `bin/question-pattern-fixtures.txt`, and a realistic case in `bin/test-detect-question.sh` |
| Billing semantics | `template/billing-core/test/*.test.mjs`, driven by `createMemoryStore` and its clock |
| A new gate | See "Adding a gate" below — it is not a one-liner |
| Launcher or failover behaviour | `bin/test-failover.sh`, with a fake harness on `PATH` |
| An intake field | All three seam-12 files, then `dev/test.sh`'s `intake` suite: reject the bad intake, accept `intake.example.yaml`, and `--check-docs` exits 0 |
| `secret-scan.sh`, `preflight.sh`, `teardown.sh` | `suite_secrets` in `dev/test.sh` — it already plants a fake live key to prove the scanner fires |
| `template/verify.sh` dispatch or the gate list | `suite_gates` in `dev/test.sh` |
| The gateway daemon or its fallback chain | `bin/test-failover.sh`; `gateway/probe.sh --induce-failure` by hand for the live path |
| A `make` target, a lint rule, or a test suite | `dev/test.sh` and `dev/lint.sh` are the harness. A portability rule is a line in `dev/port-rules.txt` or `dev/make-rules.txt` |

### Adding a gate

The nine acceptance-gate names are a pinned invariant, not a list to append to. `dev/test.sh`'s
`gates` suite asserts the exact nine names, in order, and that each resolves to an executable
`template/gates/<name>.sh`. `template/verify.sh` and `playbook/acceptance-gates.md` both say
"the nine".

So adding a tenth gate is a playbook change, not a code change, and it touches four places in
**one** commit: the new `template/gates/<name>.sh`, the `GATES` list in `template/verify.sh`,
the `expected` string and count in `suite_gates`, and `playbook/acceptance-gates.md`. Updating
that assertion alongside the gate is not weakening a test — it is the test's definition
changing with the contract. Deleting or loosening the assertion to avoid the edit is.

Prefer adding a check to an existing gate. Nine is a deliberate number.

The existing suites are the worked examples. Read the one closest to your change before
writing a new test:

- `bin/test-detect-question.sh` — a pure stdin/exit-code seam.
- `template/billing-core/test/*.test.mjs` — a module seam with an injected port and a
  controllable clock.
- `bin/test-failover.sh` — a process seam driven by fake harnesses.

## Gates

**`make check` must be green before any commit.** That is `lint` then `test`, and it is the
one command to remember. `make test` alone now carries the portability suite too, but
`make check` is what the PR template and the pre-commit hook are written against.

The package's own rule applies to its development: **a self-reported success never passes a
gate, only an exit code does.** "I verified it works" is not evidence. Paste the command and
its exit status.

The gates are only worth that if they can see a break. When you fix something `make check`
missed, close the hole in the same commit — the regression test is the deliverable, and the
fix is what proves it fails for the right reason.

Never weaken a test to make a check pass. No `.skip`, no loosened assertion, no deleted case,
no `@ts-ignore`-equivalent. If a test fails because the code is wrong, fix the code. If a test
is genuinely wrong, that is its own commit with its own reasoning, not a drive-by edit inside a
feature change.

### Portability floor

`make lint` enforces this; know it before you write the code it will reject.

- `/bin/bash` is **GNU bash 3.2.57** (macOS). No `mapfile`, no `declare -A`, no `${var^^}`,
  no `sed -r` (use `sed -E`), no `grep -P`, no `readlink -f`, no `date -d`.
- **macOS has no `timeout` binary.** Do not call it.
- `node --test` does not accept a directory on Node 22. The working forms are
  `node --test 'template/billing-core/test/*.test.mjs'` or
  `cd template/billing-core && node --test`.
- **No `package.json`, no lockfile, no third-party dependency.** `template/billing-core/README.md`
  explains why: an agent that has to run an install step before it can test has one more way to
  fail unattended. This is a hard constraint, not a preference.
- Every new `.sh` needs its exec bit set and must pass `bash -n` and `shellcheck`. `shfmt` is
  not available; do not add a check that needs it.
- `bash -n` cannot see any of this — it parses `mapfile`, `declare -A`, `sed -r` and bare
  `timeout` without complaint. The `portability` suite is what catches them, from the rule
  tables in `dev/port-rules.txt` and `dev/make-rules.txt`. Add a construct to the table in the
  same commit that bans it.

## Branch, then PR

Never commit to `main`. Every change — feature, fix, docs, chore — starts on a branch cut
from the **latest** `origin/main` and lands through a pull request.

```sh
git fetch origin
git switch -c feat/short-slug origin/main    # not from your stale local main
...work, commit on green...
git push -u origin HEAD
gh pr create --fill                          # title must be a conventional subject
```

Branch from `origin/main`, not from local `main`: a branch cut from a stale local ref carries
commits that are already merged, and the `commits` workflow then validates a range that is
not what you changed.

The branch name is not load-bearing; the **PR title** is. A squash merge takes the title as
the commit subject, so the title is what `release-please` reads to decide the next version.
`dev/check-commits.sh --title "<your title>"` checks it before CI does.

`main` is protected by convention here, not by policy, until branch protection is enabled on
the repository. Until then the rule is only as strong as this document — so follow it even
when a direct push would work.

## Architecture decisions

The package's own decisions live in `docs/adr/`, one file per decision, numbered and
immutable once merged. `docs/adr/README.md` carries the template and the rule for when to
write one.

A *run*'s decisions are not these. Those go in the product's own `DECISIONS.md` and the
product's own `docs/adr/`, because they belong to the product's repository. The factory and
the thing it builds keep separate audit trails.

## Atomic commits

One logical change per commit.

- **Test and implementation land together.** A commit that cannot be verified at that commit is
  not atomic, and it breaks `git bisect`.
- **Never mix a refactor with a behaviour change.** They are reviewed differently and they
  bisect differently. A diff that moves code and changes it hides the change.
- **Commit only on green.** `make check` first.
- **Conventional Commits, enforced.** `<type>(<scope>)!: <description>`, header under 72
  characters, no trailing period, blank line before the body. The body explains **why**, not
  what — the diff already says what. `dev/check-commits.sh` is the rule; the `commit-msg` hook
  runs it locally and the `commits` workflow runs the same script on every commit in a PR.

  This is not style policing. `release-please` derives the next version from these types, so a
  wrong one does not fail loudly — it ships the change with **no release at all**:

  | Type | Effect |
  |---|---|
  | `feat` | minor bump while 0.x, minor after 1.0 |
  | `fix`, `perf` | patch bump |
  | `feat!`, or a `BREAKING CHANGE:` footer | minor while 0.x, major after 1.0 |
  | `docs`, `test`, `ci`, `chore`, `refactor`, `style`, `build`, `revert` | changelog only |

  A squash merge takes the **PR title** as the subject, so the title is what decides the
  release. CI checks it separately for that reason — valid branch commits are not enough.

  History before this rule is not conventional and is never scanned: the workflow checks only
  `origin/main..HEAD`.
- **Seam 12 moves in one commit.** `intake.schema.json`, `QUESTIONNAIRE.md` and
  `intake.example.yaml` describe the same contract three times. A commit that changes one
  leaves the tree in a state `node bin/validate-intake.mjs --check-docs` fails: it requires
  every schema property, and every enum value, to be named in `QUESTIONNAIRE.md` and present
  in `intake.example.yaml`. The plain happy-path run still exits 0 on a drifted tree, so
  `--check-docs` is the one that holds the seam. Change all three or none.

Do not add a trailer or co-author line that this repo's history does not already use.

## Releases

Nobody picks a version number. `release-please` reads the conventional-commit history on
`main`, keeps a release PR up to date with the computed version and changelog, and on merge
tags the commit and publishes the GitHub release.

```
PR merged to main  ->  release-please opens/updates a release PR
release PR merged  ->  tag vX.Y.Z + GitHub release + CHANGELOG.md + version.txt
release published  ->  release-assets re-runs the gate, packages the bundle, attaches it
```

`release-assets` runs `make check` again against the tag before packaging. That is not
belt-and-braces: release-please's PR is opened by `GITHUB_TOKEN`, and a PR opened by that
token does not trigger other workflows, so `ci` never ran on the release PR itself.

The bundle is the tree minus `.git`, `.github` and `artifacts` — `dev/` and the `Makefile`
stay in, because `README.md`, `AGENTS.md` and this file all reference those paths and a
bundle whose own documentation points at missing files is worse than a slightly larger one.
Packaging unpacks the tarball and runs the suites against the extracted copy, since a lost
exec bit or an over-broad exclude only shows up there.

Two things live outside this repo and both fail confusingly:

- **Settings → Actions → General → "Allow GitHub Actions to create and approve pull
  requests"** must be on, or release-please 403s instead of opening its PR.
- There is **no Dockerfile**, so `docker` detects that and no-ops. The container belongs to
  the generated product (`playbook/deploy-pipeline.md`'s local-container fallback tier), not
  to the factory. Add one at the root or one level down and it starts building and pushing to
  GHCR with no edit to the workflow.

## Getting started

```sh
make setup      # bootstrap and doctor; idempotent, installs nothing globally
make check      # lint then test. The one command to run before a commit
```

Then:

| Target | Does |
|---|---|
| `make test` | every suite, aggregated; nonzero if any fail. `ARGS="--quick"`, `ARGS="--suite NAME"`, `ARGS=--list` |
| `make lint` | syntax, `shellcheck`, portability, self-check, exec bits, pointer sizes |
| `make gates` | **always FAILs here** — it is the product gate runner and expects a built product. Useful only as `make gates ARGS=--list` |
| `make hooks` | install the git pre-commit hook. Runs lint + `test --quick` (so `failover` is skipped) against the **working tree, not the index** — a partially staged commit can pass it and still be red at HEAD, so `make check` is still required before you push |
| `make clean` | remove `artifacts/` and recreate it empty. It holds operator run output — gateway logs and verify transcripts — not build output |

Use exactly these names in anything you write. They are the whole interface.

## Where things live

| Path | Role |
|---|---|
| `playbook/` | Authoritative content. Platform-neutral prose the run follows |
| `.claude/`, `codex/` | Adapters. Thin pointers and settings, never content |
| `template/` | The executable scaffold copied into the generated product |
| `bin/` | Shared tooling both harnesses call |
| `gateway/` | Model failover: LiteLLM config and daemon lifecycle |
| `dev/` | The development harness: what every `make` target actually runs — `setup.sh`, `lint.sh`, `test.sh`, `hooks/pre-commit`, and the `port-rules.txt` / `make-rules.txt` tables. Add a suite or a lint rule here, never in the `Makefile` recipe |

**Content lives once.** Fixing a playbook finding has exactly one site: the `playbook/` file
that owns the domain. `.claude/skills/` and `.claude/agents/` point at it; `codex/config.toml`
points at it. Turning a pointer into a copy is a regression, because the copy will drift and
nothing will notice. If you are editing the same sentence in two files, one of them should be a
reference.

`template/` is the one exception to "edit here, it runs here": it is source for a *different*
repo. Nothing in `template/` may assume this repo's layout or its absent `package.json`.

## Unverified areas

`gateway/`, `bin/run-factory.sh` and `bin/test-failover.sh` came from a workflow whose verify
phase never ran. `bin/test-failover.sh` passes today, but treat the code it covers as less
settled than the rest, and prefer adding a case over trusting a reading.

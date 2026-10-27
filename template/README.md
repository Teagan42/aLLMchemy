# template/

The runnable part of the package. Everything under `playbook/` tells an agent what to
build; this directory is the machinery that checks whether it did.

**The one rule: a gate that cannot prove itself FAILS. It does not SKIP.** "No test was
written" and "the test passed" must never produce the same report, because nobody is going
to click through the product before launch. Every delegating gate here fails with the exact
command the owning agent has to implement.

## Contents

| Path | What it is |
|---|---|
| `verify.sh` | The gate runner. Implements the contract in `playbook/acceptance-gates.md` |
| `gates/<name>.sh` | One script per acceptance gate, dispatched by `verify.sh` |
| `gates/_lib.sh` | Shared helpers, sourced by every gate |
| `secret-scan.sh` | Working tree plus every reachable commit. Exit 0 clean, 1 on a hit |
| `preflight.sh` | Credential probe emitting OK / FAIL / ABSENT, and a `CAPABILITIES.md` table |
| `teardown.sh` | Destroys every `PROVISIONED.md` row in reverse order. `--dry-run` is the default |
| `billing-core/` | Zero-dependency reference for the billing semantics; see `template/billing-core/README.md` |
| `fixtures/PROVISIONED.md` | A four-row ledger for exercising `teardown.sh` and `gates/cost.sh` |

## Running it

```sh
./template/verify.sh                   # all nine gates; exit 0 only if all pass
./template/verify.sh --gate billing    # one gate
./template/verify.sh --list            # the nine names
./template/secret-scan.sh              # before the first commit, and again before the last
./template/preflight.sh --out CAPABILITIES.md
./template/teardown.sh --dry-run --ledger PROVISIONED.md
node --test template/billing-core/test/*.test.mjs
```

The gates are named, never numbered: `build`, `core`, `recurrence`, `billing`, `security`,
`legal`, `operations`, `cost`, `stranger-path`. Numbers are reserved for the `G1`–`G8`
product-selection gates in `playbook/product-selection.md`.

## What the generated product copies

Copy `verify.sh`, `gates/`, `secret-scan.sh`, `preflight.sh` and `teardown.sh` into the
product repo. Extend the gate bodies; do not reinvent the runner, the artifact format or
the exit-code semantics.

`billing-core/` is ported rather than copied: translate it to the product's language and
ORM, and keep the tests. They are the specification.

## Product-independent, already implemented

These gates need no product-specific code and should not be rewritten.

- **`security`** — runs `secret-scan.sh` over the tree and the whole history, runs
  `pnpm audit --audit-level=high`, and asserts the security-header and auth-route test
  files both exist, are non-empty, mention what they assert, and exit 0. A
  present-but-failing test file is not a pass, an empty one is a FAIL, and a missing one is
  a FAIL: the assertion it carries *is* the gate, and presence alone is self-report.
- **`cost`** — parses `PROVISIONED.md`, sums the fixed monthly column plus every
  `converts-to:` amount, compares both against `MONTHLY_INFRA_BUDGET_USD`, and fails on a
  row with no teardown command, a blank `#`, a non-numeric price, a Usage risk cell that
  names no ceiling, a missing required column, zero rows, or no budget at all. An asserted
  budget nothing sums against is not a ceiling, and a Usage risk column nothing parses is
  not a spend cap.
- **`operations`** — checks `/healthz` shape against `$APP_URL` (database field, build SHA,
  and `last_cron_success` parsed and no older than `CRON_MAX_AGE_SECONDS` — a field that
  merely exists proves nothing), that `rollback.sh` exists and is executable, that
  `teardown.sh --dry-run` enumerates every ledger row, and that `RUNBOOK.md` covers all
  seven required procedures. With a local `$APP_URL` the deployed half is a declared SKIP
  and the local checks still run.
- **`build`** — runs the product's install, typecheck, lint and build, then greps for
  `@ts-ignore` / `eslint-disable` added since `BUILD_BASE_REF`. A green build bought with a
  suppression is a red build.

## Delegating, and failing when the check is absent

`core`, `recurrence`, `billing`, `legal` and `stranger-path` each run one named product
command. Every assertion they own needs the product's own routes, fixtures and copy, so the
gate script cannot contain them. What it can do is refuse to pass without them:

```
FAIL  gate billing has no runnable check: the owning agent must implement pnpm test:gate:billing
```

`billing` runs the `billing-core` reference suite when it is present, so the matrix
semantics are verified even before the product's own tests exist. In a generated repo
`billing-core` has been *ported*, so the reference suite is gone — the gate then requires a
matrix manifest (`billing-matrix.txt`, or `$BILLING_MATRIX_MANIFEST`) listing the rows the
ported suite covers, and FAILs unless rows 1-12 and 14-17 are all named. A double-charge is
one of the three never-downgradable failures, so it cannot rest on an uninspected claim.

### Product test commands

Eight of the nine gates end in a product command, including the four implemented ones: the
file checks above are necessary, not sufficient. Only `build` has no such command, because
its product command *is* typecheck, lint and build.

| Gate | Command | Override |
|---|---|---|
| `core` | `pnpm test:gate:core` | `CORE_TEST_CMD` |
| `recurrence` | `pnpm test:gate:recurrence` | `RECURRENCE_TEST_CMD` |
| `billing` | `pnpm test:gate:billing` | `BILLING_TEST_CMD` |
| `security` | `pnpm test:gate:security` | `SECURITY_TEST_CMD` |
| `legal` | `pnpm test:gate:legal` | `LEGAL_TEST_CMD` |
| `operations` | `pnpm test:gate:operations` | `OPERATIONS_TEST_CMD` |
| `cost` | `pnpm test:gate:cost` | `COST_TEST_CMD` |
| `stranger-path` | `pnpm test:gate:stranger-path` | `STRANGER_PATH_TEST_CMD` |

A `pnpm test:gate:x` command counts as runnable only when `package.json` actually declares
the script. `command -v pnpm` proves nothing about whether anyone wrote the test.

## Environment

| Variable | Default | Used by |
|---|---|---|
Intake mappings first — these four are the ones a run silently gets wrong when nobody
exports them.

| Variable | Intake field | Default | Used by |
|---|---|---|---|
| `APP_URL` | — (the deployed URL) | — | `operations`, `recurrence`, `stranger-path` |
| `MONTHLY_INFRA_BUDGET_USD` | `monthly_infra_budget_usd` | none; read from `intake.yaml`, else FAIL | `cost` |
| `GO_LIVE` | `go_live` | `false` | `preflight.sh` (Tier L is unreachable without it) |
| `CREDENTIALS_FILE` | `credentials_file` | `./.env.intake` | `preflight.sh` |

| Variable | Default | Used by |
|---|---|---|
| `PROVISIONED_LEDGER` | `$PROJECT_DIR/PROVISIONED.md` | `cost`, `operations` |
| `INTAKE_FILE` | `$PROJECT_DIR/intake.yaml` | `cost` |
| `PROJECT_DIR` | `$PWD` | every gate |
| `ARTIFACT_DIR` | `./artifacts` | `verify.sh` |
| `BUILD_BASE_REF` | first of `origin/main`, `origin/master`, `main`, `master` that resolves | `build` |
| `CRON_MAX_AGE_SECONDS` | `172800` | `operations` |
| `APP_DOMAIN`, `APP_REGION` | `platform-subdomain`, `provider-default` | `preflight.sh` |
| `GATE_SKIP_<NAME>` | unset | `verify.sh` |

Command and path overrides, each replacing one default the gate would otherwise assume:

| Variable | Default | Used by |
|---|---|---|
| `SECRET_SCAN` | `$TEMPLATE_DIR/secret-scan.sh` | `security` |
| `TEARDOWN_SH` | `$PROJECT_DIR/teardown.sh` | `operations` |
| `RUNBOOK` | `$PROJECT_DIR/RUNBOOK.md` | `operations` |
| `SECURITY_HEADERS_TEST`, `AUTH_ROUTES_TEST` | located by convention | `security` |
| `BILLING_MATRIX_MANIFEST` | `$PROJECT_DIR/billing-matrix.txt` | `billing` |
| `AUDIT_CMD` | `pnpm audit --audit-level=high` | `security` |
| `INSTALL_CMD`, `TYPECHECK_CMD`, `LINT_CMD`, `BUILD_CMD` | the product's pnpm scripts | `build` |
| `<GATE>_TEST_CMD` | `pnpm test:gate:<gate>` | the delegating gates, per the table above |

## How a SKIP works

A skip has to name the `BLOCKER` that caused it, or it is a FAIL. Two ways to declare one:

- Set `GATE_SKIP_<NAME>` (uppercase, hyphens as underscores — `GATE_SKIP_STRANGER_PATH`) to
  the blocker text. The gate is then not run at all.
- Have the gate print a line beginning `SKIP: ` at **column zero** and exit `77`. Column
  zero is the test, so the indented output of `gates/_lib.sh` can never trip it by accident.

Exit `77` with no reason is a FAIL. So is a missing gate script.

`verify.sh` exits 0 only when every gate PASSed — a SKIP is not a pass. The distinction
lives in the report, not the exit code: route a FAIL to its owning agent with the failing
command and full output, and a SKIP to `HANDOFF.md` as a `BLOCKER` with remediation steps.

## Artifacts

Each run writes `artifacts/verify-<timestamp>.txt` and copies it to
`artifacts/verify-latest.txt`, the path `playbook/autonomy-contract.md` cites in its
blocker template. Per gate: status, the exact command, the exit code, the named blocker, and
full output for anything that did not pass. A passing gate's output is suppressed, because
it buries the one thing a reader came for. The summary table is printed last.

## Portability

POSIX bash with `set -uo pipefail`, tested on macOS bash 3.2 and GNU bash. No `mapfile`, no
`declare -A`, no GNU-only `sed`/`grep` flags, `sed -E` rather than `sed -r`. The only hard
dependencies are `awk`, `sed`, `grep`, `curl` and `git`; `node` is needed for the
`billing-core` reference suite.

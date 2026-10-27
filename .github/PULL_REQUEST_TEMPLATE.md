Answer in prose. `DEVELOPING.md` is the contract these questions come from.

**What changed, and why.** The diff says what. Say why.

**Which seam.** Name it from the table in `DEVELOPING.md`, and point at the test that covers
the change. A change with no test needs a reason here.

**Evidence.** Paste the command and its exit status. `make check` green on your machine; a
self-reported success is not evidence.

**Could the gates see this break?** If you fixed something `make check` reported as green,
say which suite now catches it. A fix with no failing-first test is a claim.

**No gate weakened.** Confirm no test was skipped, loosened or deleted. If one was genuinely
wrong, that is its own commit — link it. Updating `suite_gates`'s pinned nine names alongside
a deliberate gate-list change is not weakening; see "Adding a gate" in `DEVELOPING.md`.

**Intake changes only.** `intake.schema.json`, `QUESTIONNAIRE.md` and `intake.example.yaml`
describe one contract three times and move in one commit. Confirm all three moved, and that
`node bin/validate-intake.mjs --check-docs` exits 0 — the plain
`node bin/validate-intake.mjs intake.example.yaml` run exits 0 even on a drifted tree and
cannot stand in for it.

**Conventional title.** This PR's title becomes the commit subject on a squash merge, so it
is what `release-please` reads to pick the next version. `feat:` and `fix:` move the version;
`docs:`, `ci:`, `chore:` and the rest land in the changelog only. A wrong type does not fail
loudly — it ships with no release. `dev/check-commits.sh --title "<your title>"` checks it
before CI does.

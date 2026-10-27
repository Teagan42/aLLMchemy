# CONTRIBUTING.md

`DEVELOPING.md` is the full contract — the seam map, the TDD loop, the portability floor, and
why the run-mode guards must stay. Read it before your first change. This file is the minimum.

1. **`make setup`**, then **`make check`**. Installs nothing globally; there is no dependency
   step and must never be one.
2. **Work test-first.** Find the seam in `DEVELOPING.md`'s table, write the failing test, watch
   it fail for the reason you expect, then write enough code to pass it. One seam per cycle.
3. **`make check` green before every commit.** That is lint then test. A self-reported success
   never passes a gate; only an exit code does.
4. **Atomic commits.** One logical change. Test and implementation together. Never a refactor
   mixed with a behaviour change. Imperative subject, body says why.
5. **Never weaken a gate.** No `.skip`, no loosened assertion, no deleted case. If a test fails
   because the code is wrong, fix the code. If `make check` missed a break, closing that hole
   is part of the fix.

Two things that will bite you if nobody says them out loud:

- **Never launch `bin/run-*.sh` to try something out.** A factory run spends real money and
  provisions real infrastructure under `bypassPermissions`, with no dry-run flag. Exercise
  launchers with fake harnesses on `PATH`, as `bin/test-failover.sh` does.
- **In development you may ask questions.** The run-mode guards that forbid it — and the
  Claude-Code-specific way to work around them without touching this repo's settings — are
  listed once, in `DEVELOPING.md`, "Asking questions is correct here". Read it there; do not
  weaken a guard to make your session easier.

Branch from the latest `origin/main` and open a PR; never commit to `main` directly. The PR
title must be a conventional subject (`feat:`, `fix:`, `docs:` …) because a squash merge uses
it as the commit subject and `release-please` reads it to pick the next version.

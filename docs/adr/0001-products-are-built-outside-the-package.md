# 0001. Build products outside the package, with cwd inside it

Date: 2026-10-27
Status: accepted

## Context

`bin/run-factory.sh` built the product in the package's own working tree. Three problems
followed: the product's files were committable into the factory's history, one factory could
only ever hold one product, and the product's audit trail (`DECISIONS.md`, `HANDOFF.md`) was
mixed with the factory's own.

The obvious fix — run the agent with its working directory set to the product — breaks the
Claude Code adapter. The permission denials on `AskUserQuestion` and `ExitPlanMode`, the
`Stop`/`SubagentStop` no-questions hooks, the seven role subagents and the six skill pointers
are all scoped to the project directory. Running from the product directory disarms every one
of them with no error, and a run without the question guard hangs forever, which is the
failure this package exists to prevent.

## Decision

The product is built at an absolute path outside the package, `../projects/<run>` by default,
one directory per product, each its own git repository with its own `docs/adr/`.

The working directory stays the package, so the adapter keeps working. The product is reached
by absolute path, granted write access with `--add-dir`, and named to the agent in the
kickoff prompt and in `FACTORY_PROJECT_DIR`.

Because that makes correct behaviour a matter of instruction, it is also checked: the
supervisor snapshots the package's git status before the run and diffs it after. Files that
appeared in the package fail the run, and so does a product directory holding nothing but the
seeded scaffolding. A product directory inside the package is refused before the harness
starts.

## Consequences

The agent has a writable directory that is not its working directory, which is unusual and
has to be stated explicitly in the prompt rather than inferred.

The isolation check is only as good as its two assertions. It catches files written into the
package and a product that was never built; it cannot catch a product written to some third
location. Reconsider the plugin-based approach (`--plugin-dir` carrying agents and skills)
if the adapter ever needs to travel with the run for other reasons.

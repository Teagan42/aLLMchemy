# Architecture decisions

The package's own decisions, separate from the ones a *run* makes. A run records its
choices in the product's `DECISIONS.md` and the product's own `docs/adr/`, because those
belong to the product's repository, not to the factory that built it.

One file per decision, `NNNN-kebab-title.md`, numbered in order and never renumbered. An
ADR is immutable once merged: supersede it with a new one and link both ways rather than
editing history.

Write one when a choice is costly to reverse, when a reasonable engineer would ask "why is
it like this", or when the answer is buried in a commit message nobody will find.

```markdown
# NNNN. Title in the imperative

Date: YYYY-MM-DD
Status: accepted | superseded by [NNNN](NNNN-....md)

## Context
What forced a decision. The constraint, not the narrative.

## Decision
What was chosen, stated plainly.

## Consequences
What this costs, what it rules out, and what would make us revisit it.
```

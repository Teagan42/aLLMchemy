# Thin delegation only. All logic lives in dev/, so Codex, Claude Code and a human on a
# plane run the same scripts, and the docs can name one command per job.
#
# Kept to the intersection of GNU make and BSD make: no pattern-specific variables, no
# .DEFAULT_GOAL, no $(shell). `help` is the first target, which is how both makes pick a
# default. Recipe lines are tabs.
#
# That claim is enforced by dev/make-rules.txt, which dev/lint.sh applies to this file. It
# is a rule table, not a real BSD make: no bmake is installed on the reference machine and
# both CI runners are GNU. Run a real BSD make over this file if one ever becomes available.
#
# Pass arguments through ARGS:  make test ARGS="--suite intake"

ARGS =

.PHONY: help setup check test lint gates hooks clean

help:
	@printf 'aLLMchemy — development targets. See DEVELOPING.md.\n\n'
	@printf '  make setup    check tools, repair exec bits, create artifacts/ (installs nothing)\n'
	@printf '  make check    lint then test. The one command to run before a commit\n'
	@printf '  make test     every suite; nonzero if any fails. ARGS="--quick" or "--suite NAME"\n'
	@printf '  make lint     syntax, shellcheck, portability, self-check, exec bits, pointer sizes\n'
	@printf '  make gates    template/verify.sh — the PRODUCT gate runner. Always FAILs here\n'
	@printf '  make hooks    install the git pre-commit hook (lint + test --quick)\n'
	@printf '  make clean    remove artifacts/ and recreate it empty\n\n'
	@printf 'Pass arguments through ARGS, e.g. make gates ARGS=--list\n'

# The headline command. `make test` alone now carries the portability suite too, but a
# single name for "everything that must be green before a commit" is what the docs and the
# agent instructions can point at without listing two.
check: lint test

setup:
	@./dev/setup.sh $(ARGS)

test:
	@./dev/test.sh $(ARGS)

lint:
	@./dev/lint.sh $(ARGS)

# The acceptance-gate runner that ships inside a generated product. It expects a built
# product in the working directory, so run from this repo it reports all nine gates FAILing
# and exits nonzero. That is correct, not a broken repo. Useful here only as
# `make gates ARGS=--list`. dev/test.sh's `gates` suite is what tests it.
gates:
	@./template/verify.sh $(ARGS)

hooks:
	@./dev/setup.sh --hooks $(ARGS)

# artifacts/ holds gateway logs and verify transcripts — operator run output, not build
# output. Say what actually happened, and leave the tree in the state `make setup` promises.
clean:
	@if [ ! -d artifacts ]; then printf 'artifacts/ was already absent\n'; \
	elif [ -z "`ls -A artifacts`" ]; then printf 'artifacts/ was already empty\n'; \
	else printf 'removing artifacts/ — %s entr(ies)\n' "`ls -A artifacts | wc -l | tr -d ' '`"; \
	rm -rf artifacts; fi
	@mkdir -p artifacts

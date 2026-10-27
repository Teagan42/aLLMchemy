# aLLMchemy

The autonomous micro-SaaS foundry: it conceives, builds, deploys, bills for, verifies and hands off subscription products without a human in the loop once a run starts. This glossary separates the foundry's own vocabulary from that of the products it builds, because the two domains share words and mean different things by them.

## Language

### The foundry and its people

**Foundry**:
The system that produces subscription products autonomously. One foundry serves many products.
_Avoid_: factory, package, pipeline

**Operator**:
The human who supplies a run configuration and credentials, starts a run, and is then absent for its duration.
_Avoid_: user, owner, customer

**Product**:
A subscription micro-SaaS the foundry builds. It has its own repository, its own audit trail, and its own subscribers — none of which are the foundry's.
_Avoid_: app, project, SaaS

**Subscriber**:
An end user who pays for a product. Never the operator, and never a concept the foundry itself has.
_Avoid_: user, customer

**Embedder**:
Software that consumes the foundry as a library rather than through its command line.

### Execution

**Run**:
One execution of the foundry against one run configuration, producing at most one product. Runs are isolated from each other and survive process restarts.

**Workspace**:
The directory a run owns, holding the product's repository alongside the run's own durable state. One per run.

**Step**:
The unit of work the foundry schedules, journals and resumes. Finer-grained than a phase.

**Phase**:
An inherited grouping of steps describing the shape of a run — preflight, invent, scaffold, billing, surface, release, verify, handoff. Descriptive; the step graph is what executes.

**Attempt**:
One execution of a step. A step keeps its identity across attempts; an attempt does not, because telling the third attempt from the first is the point of recording one.

**Completion predicate**:
The check a step declares so the foundry can determine independently whether that step already happened, without trusting a record of it. It may answer satisfied, unsatisfied, or **unevaluable** — and the third answer is not a kind of "no".

**Journal**:
A run's append-only record of facts observed and decisions taken. A run's state is *derived* from it, never asserted in it, because a process can die between an effect and its record.

**Intent**:
The foundry's record that it is about to act on the outside world, written before it acts. An intent with no matching confirmation is the signal to go and look.

**Confirmation**:
The foundry's record that an external act completed, written after it completes.

**Idempotency key**:
A value identifying one external effect, derived only from durable facts so it survives a restart unchanged and a retry presents the same one.

**Reconciliation**:
Asking a provider what actually exists, when the foundry cannot tell from its own records. The provider is the authority; reconciliation is how the journal catches up to it.

**Harness**:
A third-party coding-agent runtime the foundry drives to perform generative work. Replaceable, and never trusted.

**Role**:
A declared specialisation the foundry invokes a harness as — architect, builder, billing engineer, and so on. A role names its inputs, its outputs, the tools it may use, and how its completion is verified.

**Model tier**:
Which class of model actually performed a run's work, after any failover. Recorded because identical results mean different things from a frontier model and from local inference.

### Decisions and evidence

**Decision**:
A recorded resolution of something the foundry could not ask about, carrying its rationale, the evidence it rests on, how confident that evidence makes it, and what reversing it would cost.

**Blocker**:
An external obstacle the foundry cannot clear, recorded with its impact, its cause, and the exact steps that would remediate it. Never a reason to stop work that does not depend on it, and never a question.

**Gate**:
An executable acceptance check whose result the foundry determines by running it, not by being told. A gate that cannot prove itself fails.

**Negative control**:
An input a gate declares as one that must make it fail. A gate that passes its own negative control is reported broken rather than green.

**Evidence record**:
The immutable output of an engine-executed check — what ran, what it returned, and against which artifacts — which a handoff cites instead of asserting.

**Outcome tier**:
How far a run actually got. **L**: deployed publicly with live billing validated. **T**: deployed publicly with test-mode billing validated; the default success. **D**: a locally verified artifact with no public deployment; always degraded, never done.

**Handoff**:
The account a completed run gives the operator: the outcome tier reached, what exists, what it costs, what is blocked, and how to reverse all of it.

### Configuration and credentials

**Run configuration**:
The typed, fully-resolved set of operator parameters governing one run. Every field has a value; a wholly unspecified configuration is valid.
_Avoid_: intake, settings, options

**Intake document**:
A file an operator writes that a run configuration can be read from. One source among several, not the configuration itself.

**Policy**:
A rule trusted code enforces, authored by the foundry rather than the operator. Distinct from configuration, which supplies parameters rather than rules.

**Policy pack**:
A named, independently versioned bundle of policy that a run configuration selects.

**Credential**:
A secret authorising access to an external service. Every credential has a provenance and a destination, and the two are independent.

**Supplied credential**:
A credential the operator provided. The foundry reads it and never revokes it.

**Acquired credential**:
A credential the foundry obtained during a run, by registering for a service. It is a provisioned resource: recorded on creation, and revoked when the run is reversed.

**Foundry-used credential**:
A credential only the engine ever holds, authorising its own work. It never reaches a harness, a workspace, or a product.

**Product-destined credential**:
A credential a product needs to operate, bound for that product's secret store. Declared as such rather than inferred from its name.

**Credential source**:
Where a run's supplied credentials are read from. Replaceable, because an operator's secrets already live somewhere.

**Funding instrument**:
The account or wallet a run spends from. It is supplied, and it is the only thing bounding what a run can spend — no policy ceiling stands behind it.

**Acquisition**:
Registering for an external service during a run, producing an acquired credential and a resource the run now owns.

**Recovery root**:
The acquired account every other acquired account can be recovered through, typically an email account. First in a handoff and last to be torn down, because revoking it orphans everything beneath it.

**Capability**:
Something a run has been shown it can actually do, established by probing rather than declared. Absent capabilities remove work from a run rather than being noted as caveats.

**Privileged operation**:
An act that reaches outside a run's workspace — creating, changing or destroying something external, or spending. Only the foundry performs one; a harness can ask for one but never does it.

**Engine tool**:
A typed operation the foundry exposes to a harness, and the only route to a privileged operation. Asking is the harness's half; checking, performing, and recording are the foundry's.

**Confinement**:
The container boundary the foundry imposes on a harness, holding no credentials and no general egress. Distinct from a harness's own sandbox feature, which is weaker and differently named.
_Avoid_: sandbox, jail

**Tool grant**:
The set of tools a role is permitted, declared on its manifest. It says what is offered; it is not what makes an operation safe.

**Egress profile**:
The network a role may reach, declared per role. A build role needs registries and documentation; an acquisition step needs the open web, and that breadth is recorded rather than ambient.

**Provider**:
An external service the foundry uses on an operator's behalf. Interchangeable within its class.

**Provider class**:
A kind of provider — hosting, database, billing, DNS and so on. Operations differ per class; only validation, capability declaration, teardown and cost reporting are common to all.

**Adapter**:
The code that makes one provider usable. It declares what that provider can do, validates its credentials, performs its class's operations, and knows how to reverse them.

**Ledger entry**:
A resource's identity in the foundry's own terms. Destructive operations name one of these rather than a provider's identifier, so a run cannot be asked to destroy something it did not create.

**Teardown descriptor**:
The recorded means of reversing one resource, written when the resource is created rather than recalled afterwards.

**Dependency edge**:
A recorded "this resource contains that one", stated by the adapter at creation. Teardown walks these in reverse; a cycle is an error.

**Usage ceiling**:
What bounds a resource's metered cost, drawn from a closed set of possibilities. It is reported, not enforced — no spending limit stands behind it.

**Provisioned resource**:
Something external a run brought into existence. Each one is recorded as it is created, costed, and reversible by a recorded command.

**Resource ledger**:
The complete record of a run's provisioned resources. It is what makes unattended autonomy acceptable, because it is what makes a run reversible.

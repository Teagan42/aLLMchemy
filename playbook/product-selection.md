# Product Selection

Pick one product, once, and never revisit it. This document exists to make the choice
mechanical, because an unattended run cannot afford taste debates and because the usual
failure is not picking badly — it is picking three times.

## The actual constraint

"A product the average person pays $5/month for" sounds like the hard part. It isn't. The
hard part is that the product must be **invented, built, billed, deployed, and verified by
software, with no human in the loop, and then keep running with no human in the loop.**

That eliminates most of what a human founder would pick. No human labor in delivery means
no services business. No content licensing means no media product. No two-sided market
means no marketplace. What survives is a narrow and genuinely viable band: software that
*watches something on the user's behalf and tells them about it.* Read the archetypes
before generating candidates; they are where the survivors live.

The second constraint people get wrong is retention. At $5/month, acquisition cost barely
matters but churn is fatal. A product the user opens once and never needs again is a $5
one-time sale wearing a subscription costume. The product must have an engine: something
that happens on a schedule, without the user asking, that they would notice the absence of.
Gate G6 enforces this and it is the gate most candidates fail.

## Hard gates

Binary. Any failure eliminates the candidate. No partial credit, no "we could work around
it" — the workaround is how a run ends up shipping nothing.

| Gate | Test |
|---|---|
| **G1 Zero human labor** | No step in delivery requires a person. No manual review, curation, moderation queue, support SLA, or fulfilment. |
| **G2 No regulated data** | No PHI, no card numbers touching our servers (the billing provider's hosted checkout holds those), no KYC, no credit or lending decisions, no background checks, no children's data under COPPA. |
| **G3 Lawful inputs** | Every data source is a public API, an official feed, a user-supplied input, or content the user already owns. No paywall circumvention, no ToS-violating scraping, no republishing licensed media. If it needs a `robots.txt` violation, it is out. |
| **G4 Unit economics** | COGS ≤ 20% of price at 1,000 subscribers. At $5 that is **≤ $1.00/user/month.** Compute it, don't estimate it. |
| **G5 Time to value ≤ 60s** | From signup to first real output, with no integration beyond one email address, phone number, URL, or file upload. No OAuth into a system of record, no CSV mapping wizard, no waiting for data to accumulate. |
| **G6 Autonomous recurrence** | The product acts on the user's behalf at least weekly without being opened. Write the sentence "every $PERIOD it $ACTION even if the user never logs in." If you can't, eliminate it. |
| **G7 Agent-buildable** | No hardware, no mobile app store review, no business bank account beyond the billing provider, no partner contracts, no human identity verification. Buildable and testable in one session. |
| **G8 Instantly cancellable** | Cancel is self-service, immediate, and leaves the user no worse off. Their data is exportable. Nothing is held hostage. |

G4 is the one candidates fail silently, so compute it explicitly:

```
Revenue                            $5.00
Payment fees   2.9% + $0.30       -$0.45   (merchant-of-record providers: ~5% + $0.50)
                                  ------
Gross available                    $4.55
COGS ceiling (20% of revenue)      $1.00

Per-user-per-month cost model — fill in real numbers, not vibes:
  Compute        requests/user/mo x $/request
  Database       rows + storage + egress
  Email          messages/user/mo x $/message      (~$0.0004 on Resend/Postmark at volume)
  SMS            messages/user/mo x $0.0079        (US; this is what kills SMS in a base plan)
  Inference      tokens/user/mo x $/token          (compute at the model's real price)
  Third-party    per-call API fees
                 ----------------------------------
  Total must be ≤ $1.00
```

Inference deserves its own warning. At Haiku-class pricing, roughly 1M input tokens per
user per month fits inside $1. A product that runs a frontier model over a large context
on every user interaction does not fit, and "we'll add rate limits later" is not a plan —
G4 requires the quota be **enforced in code**, as a hard per-user counter checked before
the expensive call, with a tested denial path. Write the test that proves a user hitting
the ceiling gets a graceful message rather than an unbounded bill.

## Scorecard

Score survivors 1–5 on each axis. Multiply by weight. Highest total wins.

| Axis | Weight | 1 | 5 |
|---|---|---|---|
| Willingness to pay $5 | ×3 | "I'd use it if free" | Replaces a cost or a recurring annoyance that already bothers them |
| Audience breadth | ×2 | A niche needing explanation | Most adults recognise the problem in one sentence |
| Retention strength | ×3 | Value is one-shot | Cancelling means losing an ongoing watch they rely on |
| Landing-page legibility | ×2 | Needs a diagram and a demo | Headline alone conveys it |
| Build simplicity | ×2 | Many integrations, fragile parsing | CRUD + a cron + a notification |
| Add-on headroom | ×1 | Nothing to sell beyond base | Obvious tiers: more watches, more channels, more history |
| Resists "I'd just DIY it" | ×1 | A spreadsheet does this | Requires persistent infrastructure the user won't run |

Tie-breakers in order: higher retention score, then lower build complexity, then broader
audience. If still tied, take the candidate earliest in the archetype priority list.

Generate **at least eight** candidates before scoring. Fewer than eight means you anchored
on the first idea. If `product_direction` is set, bias candidate generation toward it, but
do not exempt those candidates from the gates — a direction that cannot pass G1–G8 gets the
nearest passing neighbour, and `DECISIONS.md` records the substitution and its cause.

## Archetypes that pass

Priority order. These are not suggestions to copy; they are the shapes that survive the
gates, and a candidate's resemblance to one is evidence it will too.

**1. The watcher.** Monitors something that changes and matters, alerts on change. Passes
G6 natively — watching *is* the recurrence. Cheap: a cron, a diff, a notification.
*Examples:* price drops on a saved wishlist; a small site's uptime, TLS expiry, and DNS
drift; a permit or docket or case-status page; rent-relevant listings in a postcode; stock
of a specific item at a specific store.

**2. The digest.** Compiles many scattered public sources into one scheduled message.
Value is the aggregation and the discipline of delivery.
*Examples:* one morning message merging weather, school calendar, bin collection day, and
commute disruption; a local-government digest for one address; a hyperlocal outage feed.

**3. The expiry tracker.** Remembers dated obligations a person will otherwise forget, and
warns early enough to act. Extremely strong retention: the user's accumulated data is the
switching cost.
*Examples:* warranty and receipt vault with claim-window alerts; free-trial and
subscription-renewal tracker that warns before each charge and flags price rises; document
expiry (passport, licence, inspection, insurance, domain).

**4. The nudge.** Scheduled accountability against a commitment the user set.
*Examples:* escalating reminders for a habit with a public streak; a check-in that emails a
chosen contact if you don't respond.

**5. The remembering converter.** Transforms input the user supplies, but accumulates state
so it improves and so leaving costs something.
*Examples:* recipe URL to grocery list that remembers the pantry; receipts to a monthly
spend summary; documents to a searchable personal archive.

Note what all five share: **the user's data accumulates, and the system acts on a schedule.**
That combination is what makes $5/month defensible rather than a one-time purchase.

## Anti-patterns

Eliminate on sight. Each has a specific fatal gate, listed so the reasoning is auditable
rather than a matter of preference.

| Anti-pattern | Fails | Why |
|---|---|---|
| Social network, community, forum | G5, G6 | Cold start. Value is zero until others arrive, and an agent cannot seed a population. |
| Two-sided marketplace | G1, G5 | Needs supply acquisition, which is human work. |
| Bare LLM chat wrapper | G4, G6 | Token cost unbounded, no recurrence engine, no moat, and the user already has ChatGPT. |
| Media, courses, curated content | G1, G3 | Content production is human labor; licensing is a contract. |
| Anything needing a mobile app | G7 | App store review is a human gate measured in days. |
| Bookkeeping, tax, payroll, lending | G2 | Regulated, and wrong output causes real harm. |
| Health, symptom, medication advice | G2 | PHI and liability. |
| Dating, identity verification | G2, G7 | Trust and safety is a human-labor function. |
| Crypto, trading signals | G2 | Financial advice and regulatory exposure. |
| "AI agent that does your X for you" | G4, G8 | Open-ended autonomy on a user's behalf has unbounded cost and unbounded blast radius. |
| Ad-supported anything | — | Not a subscription. |

## PRODUCT-SPEC.md contract

Write this file before any code. Downstream agents treat it as the source of truth and will
not re-derive it.

```markdown
# PRODUCT-SPEC

## One-liner
<what it does, for whom, in one sentence a stranger understands>

## The promise
<the specific recurring thing it does on the user's behalf>

## Recurrence engine
Every <period>, the system <action>, producing <output>, delivered via <channel>,
whether or not the user logs in.
  Schedule: <cron expression>
  Trigger source: <API/feed/user data>
  Failure behaviour: <what happens when the source is down>

## Time to value
Signup at T+0 → <first output> by T+<seconds>. The only input required is <one thing>.

## Hard gates
| Gate | Verdict | Evidence |
(all eight, each PASS with a one-line justification)

## Unit economics at 1,000 users
(the full cost table, with the computed per-user total and the enforced quota)
  per-user COGS: $<amount>
  Enforced quota: <limit>, checked in <file:function>, tested in <test file>

The `per-user COGS: $<amount>` line is parsed literally by the `cost` gate, which fails
unless the amount is ≤ 20% of `price_usd`. Keep the exact wording: it is what turns G4 from
a self-reported verdict into a check.

## Scorecard
| Axis | Score | Weight | Weighted | Note |
(total, and the tie-break if one applied)

## Rejected candidates
| Candidate | Eliminated by | Note |
(all seven-plus others; this is the audit trail that stops Phase 2 from reopening)

## Data model
<entities, fields, retention period per entity>

## Surfaces
<routes: public, authed, admin, webhook, cron>

## External dependencies
| Service | Purpose | Auth | Rate limit | Fallback when down |

## Plan catalog
<base plan, add-ons, annual — per addon-design>

## Out of scope for v1
<explicitly deferred, so later phases do not drift into it>
```

The "Rejected candidates" section is not decoration. It is what prevents a later phase from
re-litigating the choice when implementation gets tedious.

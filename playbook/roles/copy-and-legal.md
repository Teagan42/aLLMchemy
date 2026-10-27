# Copy and Legal

Read `playbook/autonomy-contract.md` and `playbook/acceptance-gates.md` first. No human is available. Never ask a
question — not about tone, not about brand, not about wording. `brand_tone` in the intake
is your only style input and its default is sufficient.

Two jobs that look unrelated but aren't: the landing page states what the product does, and
the legal pages state what it does with people's data. Both are promises to a stranger who
has no other way to check. Both have to be true.

## Scope

1. **Landing page.** One screen that conveys the product without scrolling. Headline is the
   promise, not a slogan. Show the real recurring output — a sample of the actual alert or
   digest beats any amount of description. State the price, the interval, and that it
   renews, above the fold.
2. **Pricing page.** The ladder from `playbook/addon-design.md`. Hide add-ons whose `enabled_when` is
   false. Show how to cancel.
3. **Onboarding.** The shortest path from signup to first value, under 60 seconds, asking
   for exactly one input. Every additional field is a person who leaves.
4. **Lifecycle emails:** welcome with first value, trial or dunning notices, cancellation
   confirmation, renewal reminder for the annual plan. Plain text or simple HTML; no
   image-only emails.
5. **Legal surface,** sized to `audience_region`: ToS, privacy policy, refund and
   cancellation policy, cookie and consent banner for `eu` or `global`.
6. `GET /api/account/export` and `DELETE /api/account`, both tested. `DELETE /api/account`
   is the only caller of the provider port's `cancelImmediately`: cancel at the provider,
   set `current_period_end = now()` and `status='canceled'`, **then** delete or anonymise.
   Deleting the rows first leaves the provider billing a subscription with no entitlement
   left for the reconciler to compare against, and the sweep can no longer see the row.
   Matrix row 17 in `playbook/subscription-billing.md` is the test; `billing-engineer` owns
   the port method, so agree the order with it rather than each assuming the other did it.

## Rules

- Write for someone who has never heard of this. No jargon, no hype, no exclamation marks
  unless `brand_tone` says otherwise.
- **The privacy policy must be factually true.** Enumerate the real subprocessors from
  `CAPABILITIES.md` — host, database, billing, email, SMS, inference — and the real
  retention period per entity from `PRODUCT-SPEC.md`. A generated policy that describes
  practices the code does not follow is a false statement to users and a legal exposure,
  not a formality.
- Never claim a certification the product does not have. No "SOC 2", no "HIPAA compliant",
  no "bank-grade encryption", no "military-grade" anything.
- No fake social proof. No invented testimonials, no fabricated user counts, no "join
  10,000 subscribers" on a product with zero subscribers. This is the one place an
  unsupervised run can easily produce something dishonest, so hold the line: describe the
  product, not an imagined reception.
- Refund policy must state something real and specific that the operator can honour —
  default to a 14-day no-questions refund, and say so in `RUNBOOK.md` so it gets honoured.
- Pricing copy must match the provider catalog exactly. A mismatch between the page and the
  charge is the fastest route to a chargeback.
- Accessible markup: landmarks, labelled inputs, visible focus states, alt text, and
  contrast at WCAG AA. Mobile-first — most of this audience arrives on a phone.
- Footer links to ToS, privacy, and refund policy on every page, plus from checkout.

## Return

Page routes, the legal document paths, the subprocessor list as written, the export and
delete test output, and the first-value timing measurement.

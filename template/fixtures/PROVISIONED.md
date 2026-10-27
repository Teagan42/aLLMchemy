# Provisioned resources

Fixture ledger. Used to exercise `template/teardown.sh` and `template/gates/cost.sh`
without a real run. Teardown commands are deliberately harmless `printf` calls so `--yes`
is safe to test.

The Usage risk column is a controlled vocabulary, because `gates/cost.sh` parses it: `none`,
`capped-at-tier`, `provider-cap:<amount>` or `converts-to:<amount>`. Free prose there is a
FAIL — an uncapped metered resource is what empties an account overnight.

| # | Provider | Resource | Fixed USD/mo | Usage risk | Teardown |
|---|----------|----------|--------------|------------|----------|
| 1 | Fly.io | app `digestly` (shared-1x, 256MB) | 0.00 | capped-at-tier (egress inside the free allowance) | `printf 'would run: flyctl apps destroy digestly -y\n'` |
| 2 | Neon | project `digestly-prod` free tier | 0.00 | capped-at-tier | `printf 'would run: neonctl projects delete digestly-prod\n'` |
| 3 | Stripe | product + 2 prices | 0.00 | none | `printf 'would run: stripe products update prod_x --active=false\n'` |
| 4 | Upstash | Redis `digestly-cache` paid tier | 3.50 | capped-at-tier (commands capped by plan) | `printf 'would run: upstash redis delete digestly-cache\n'` |

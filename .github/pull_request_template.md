## Linked ticket
<!-- Required: paste the Rally ticket URL or ID -->
Closes #<!-- RALLY-XXX -->

## What changed and why
<!-- 2-5 sentences. What does this PR do? Why is this the right approach? -->

## Type of change
- [ ] `feat` — new module or resource
- [ ] `fix` — broken infra or drift correction
- [ ] `refactor` — no resource changes (rename, move, restructure)
- [ ] `perf` — cost or performance optimisation
- [ ] `security` — IAM, network, encryption hardening
- [ ] `chore` / `ci` — tooling, workflow, variable updates

## Environments affected
- [ ] `live/_shared` — shared resources (networking, IAM base)
- [ ] `live/develop`
- [ ] `live/prod`

## Plan summary
<!-- Paste or link to the `tofu plan` output from the CI comment -->

## Infra checklist
- [ ] `tofu plan` output reviewed — no unexpected destroys or replacements
- [ ] Any `destroy` on a prod resource has explicit written justification above
- [ ] State backend is correct for the target workspace
- [ ] No hardcoded secrets, account IDs, or ARNs — all via variables/data sources
- [ ] Sensitive outputs marked `sensitive = true`
- [ ] New IAM roles/policies follow least-privilege
- [ ] New resources tagged with `Project`, `Env`, `ManagedBy = opentofu`
- [ ] Drift check done if touching existing prod resources (`tofu plan` shows no unexpected diff)

## Reviewer notes
<!-- Anything the reviewer should pay special attention to -->

---
name: upgrading-decidim
description: Use when a new Decidim version is released and this module must support it, when spec/lib/overrides_spec.rb fails, or when bumping DECIDIM_VERSION, the Gemfile pin, or the Ruby and Node versions in this repository.
---

# Upgrading this module to a new Decidim version

## Overview

This module registers a verification workflow and copies a handful of Decidim
files. Nearly all upgrade risk sits in two places: the copied files drifting
from their originals, and the four undocumented Decidim behaviours the flow
depends on. `spec/lib/overrides_spec.rb` catches the first automatically. The
second needs a human decision every time.

**REQUIRED BACKGROUND:** read `docs/writing-an-ephemeral-verification.md` before
changing the controller. `AGENTS.md` lists the traps.

## First: is the module still needed?

Before upgrading, check whether Decidim now ships an ephemeral SMS workflow of
its own, or turned the ephemeral flow into something configurable. If it does,
the right outcome may be to retire this module rather than port it.

```bash
grep -rni "ephemeral" "$(bundle show decidim-verifications)"/{lib,app} | grep -i sms
```

Also skim the release notes for `AuthorizeUser`, `EphemeralSessionChecker`,
`OnboardingManager` and `WorkflowManifest`.

## Procedure

Do these in order. Do not skip step 4 because the specs are green.

### 1. Bump the two version declarations

| File | What to change |
|---|---|
| `lib/decidim/ephemeral_verifications/version.rb` | `DECIDIM_VERSION` — the *supported range*, e.g. `[">= 0.32.0", "< 0.33"]` |
| `Gemfile` | `DECIDIM_VERSION` — the single *point release* the suite runs against |
| `lib/decidim/ephemeral_verifications/version.rb` | `VERSION` — the gem's own version. Deliberately independent of Decidim's, but a new supported range is a minor bump |

The first two are deliberately different: the gemspec declares a window, the
Gemfile pins one version.

**Three files carry a Ruby version and they must agree with the new Decidim's
own requirement** — read it rather than assuming, because ours has been wrong
before:

```bash
ruby -e 'g=Gem::Specification.load(ARGV[0]); puts g.required_ruby_version' \
  "$(bundle show decidim-core)/decidim-core.gemspec"
cat "$(bundle show decidim)/.node-version"   # and "engines" in its package.json
```

- `decidim-ephemeral_verifications.gemspec` → `required_ruby_version`
- `.rubocop.yml` → `TargetRubyVersion`
- `.github/workflows/ci.yml` → `RUBY_VERSION` and `NODE_VERSION`

```bash
bundle update decidim
```

### 2. Regenerate the test app

The generated app captures the Decidim version, so it must be rebuilt, not
migrated:

```bash
docker compose up -d
rm -rf spec/decidim_dummy_app
bundle exec rake test_app
```

### 3. Diff the copied files

```bash
bundle exec rspec spec/lib/overrides_spec.rb
```

A failure names each Decidim file that changed. For each one, diff the new
upstream version against our adaptation and decide whether the change applies:

```bash
git -C /path/to/decidim diff v0.31.6..v0.32.0 -- \
  decidim-verifications/app/controllers/decidim/verifications/sms/authorizations_controller.rb
```

`Overrides.tracked_paths` covers three different kinds of coupling, and each
needs a different reaction:

| Upstream file | How we depend on it | If it changed |
|---|---|---|
| `sms/authorizations_controller.rb` | **copied and adapted** | Port the change into ours, or justify not doing so |
| `sms/authorizations/{new,edit}.html.erb` | **copied and adapted** | Same — plus check the ephemeral bits of `verifications/authorizations/new.html.erb` |
| `sms/mobile_phone_form.rb` | our `MobilePhoneForm` **subclasses** it | Re-check the overrides still make sense, especially `unique?` and the private `verification_code` |
| `sms/confirmation_form.rb` | **reused unchanged** | Confirm it still holds only the code and still skips the terms validation when built without a user |
| `authorize_user.rb`, `confirm_user_authorization.rb`, `perform_authorization_step.rb`, `ephemeral_session_checker.rb`, `sms/engine.rb`, `_tos_acceptance_field.html.erb` | **called or rendered, not copied** | Re-read against step 4 — these are where the load-bearing assumptions live |

Accept the new state only after reviewing:

```bash
bundle exec rake overrides:checksums
```

### 4. Re-verify the four load-bearing behaviours

Green specs prove our code still runs. They do not prove these assumptions
still hold — a change here can leave the suite passing while the flow is subtly
broken in production. Check each against the new source:

1. **`AuthorizeUser` is still absent from the multistep path.** If Decidim
   starts calling it from `ConfirmUserAuthorization`, our `resolve_duplicates`
   would run it twice.
2. **`EphemeralSessionChecker#authorizations_permitted_paths?` still excludes
   `:pending` from `user_pending?`.** If upstream fixes that, the
   `onboarding.authorization_path` dance in the controller becomes unnecessary.
3. **`[decidim_user_id, name]` is still unique** and `AuthorizationTransfer.perform!`
   still moves the other participant's record onto the current user. This is why
   `resolve_duplicates` destroys ours first.
4. **`tos_agreement` is still conditional** on `user.ephemeral? && !user.tos_accepted?`.
   This is why eligibility is a separate attribute rather than a relabelled
   terms-of-service checkbox.

Where to read each, under `$(bundle show decidim-verifications)` and
`$(bundle show decidim-core)`:

| # | File |
|---|---|
| 1 | `app/commands/decidim/verifications/confirm_user_authorization.rb`, `app/commands/decidim/verifications/authorize_user.rb` |
| 2 | `app/controllers/concerns/decidim/ephemeral_session_checker.rb` (`authorizations_permitted_paths?`, `user_pending?`) |
| 3 | `app/models/decidim/authorization_transfer.rb` plus the unique index on `decidim_authorizations` |
| 4 | `app/services/decidim/authorization_handler.rb` (`ephemeral_tos_pending?`) |

Also re-check `lib/decidim/verifications/workflow_manifest.rb` for new
attributes worth setting, confirm `lib/decidim/verifications/adapter.rb` still
resolves engines via `send("decidim_#{name}")` and still demands
`edit_authorization_path` / `renew_authorization_path`, and confirm the
`Decidim.sms_gateway_service` contract is still `new(number, code, context)`
plus `#deliver_code` — the specs stub the gateway, so a signature change passes
locally and breaks in production.

**Check whether the revoke workaround is still needed.**
`lib/tasks/decidim/ephemeral_verifications.rake` exists only because upstream's
`decidim-verifications/lib/tasks/revoke.rake` builds its tasks before the
initializers that register workflows (decidim#16546). That upstream file is
tracked by the checksum guard. If it is fixed, delete ours — otherwise both
define the same task and Rake runs both bodies.

### 5. Run everything

```bash
bundle exec rspec
bundle exec rubocop
```

Browser specs are the ones that catch flow-level breakage — the redirect
deadlock only ever showed up there. If they fail intermittently rather than
consistently, suspect a timing race in the spec before suspecting the code, and
read `AGENTS.md`'s testing notes.

### 6. Branch, do not break the old version

The ecosystem convention is one branch per Decidim minor. This module has not
had to do it yet, so the first upgrade establishes it: branch off the current
Decidim version *before* the bump commit, so installations on the old version
keep a working ref, rather than widening `DECIDIM_VERSION` to span two minors.

Several files hardcode the version in prose:

- `.github/workflows/ci.yml` — the workflow name `[CI] Tests (Decidim 0.xx)`
- `README.md` — the requirements section, and the opening paragraph's claim
  about what Decidim does and does not ship
- `AGENTS.md` — the same claim
- `docs/writing-an-ephemeral-verification.md` — states which version it is
  verifiable against; re-check its assertions, do not just bump the number

## Common mistakes

| Mistake | Consequence |
|---|---|
| Running `rake overrides:checksums` to make a red spec green | The whole point of the guard is lost; upstream changes ship unreviewed |
| Migrating the dummy app instead of regenerating it | The app keeps the old Decidim's generated config and assets |
| Widening `DECIDIM_VERSION` to cover two minors | Untested combination; the Gemfile only ever pins one |
| Trusting green specs as proof the upgrade is complete | Step 4 assumptions are invisible to the suite |
| Bumping only the gemspec range or only the Gemfile | They serve different purposes and both need changing |
| Assuming a Ruby or Node version instead of reading Decidim's | Both have been wrong in this repo; the gemspec once advertised a Ruby that Decidim could not install on |
| Treating a tracked file that vanished upstream as a broken spec | It is drift: the file was renamed or removed. Update `tracked_paths`, then regenerate |

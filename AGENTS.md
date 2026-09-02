# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## What this is

A Decidim module registering one verification workflow, **`ephemeral_sms`**,
which lets a participant verify by SMS and complete a single action without
creating an account.

Decidim 0.31 ships the ephemeral *machinery* but no concrete verification
method — the admin documentation implies it is a system-panel toggle, and it is
not. Everything interesting about this module is in how it fits around Decidim's
undocumented behaviour, which is written up in
[docs/writing-an-ephemeral-verification.md](docs/writing-an-ephemeral-verification.md).
**Read that document before changing the controller** and update it when relevant
changes are made to this module.

When a new Decidim version is released, follow the `upgrading-decidim` skill in
`.agents/skills/` — it covers the version declarations, the copy-drift guard and
the assumptions the specs cannot check.

## Commands

```bash
docker compose up -d                 # Postgres on 5433, just for this repo
bundle install
bundle exec rake test_app            # generates spec/decidim_dummy_app (slow: compiles assets)
bundle exec rspec
bundle exec rspec spec/requests      # the fast, browserless part
bundle exec rspec path/to/spec.rb:12 # a single example
bundle exec rubocop -a
bundle exec rake development_app     # a real app to click through
bundle exec rake overrides:checksums # accept upstream changes to copied files
```

No database configuration is needed: `spec/database_defaults.rb` points the
generated app at the compose service, and every value defers to the environment
so CI can override it. `rake test_app` must be re-run after changing anything
the generated app captures (the Gemfile, the Decidim version).

Browser specs need Chrome and chromedriver; the README documents fetching both
via Selenium Manager without root. A flatpak or snap Chromium will not work.

## Architecture

`lib/decidim/ephemeral_verifications/sms/engine.rb` is the whole wiring: an
isolated Rails engine whose `initializer` registers the workflow. One engine per
strategy; it infers the gem root, so `app/` and `config/locales` load from it.
Add a top-level engine only if a second strategy arrives.

The flow is two steps, both in
`app/controllers/.../sms/authorizations_controller.rb`:

1. `new`/`create` — `MobilePhoneForm` (inherits the core SMS form, so code
   generation and the gateway call stay upstream's problem) takes a phone
   number, a required eligibility confirmation, and the terms of service. The
   SMS is sent *during validation*.
2. `edit`/`update` — the core `ConfirmUserAuthorization` compares the code and
   grants, then `resolve_duplicates` runs `Decidim::Verifications::AuthorizeUser`
   with `TransferHandler`.

### Four things that will bite you

These are not stylistic; each one was a bug found by running the code.

**`AuthorizeUser` is not in the multistep path.** It is what implements every
ephemeral behaviour — session recovery, ephemeral-to-account transfer, terms of
service persistence — and Decidim only reaches it from *direct* (form-based)
workflows. SMS cannot be direct, because the code does not exist until the phone
number is submitted. So this module calls it itself, in step two, and **only
after the code is confirmed**: resolving duplicates earlier would hand one
participant's session to anyone who types their phone number.

**Duplicates must be tolerated in step one and resolved in step two.**
`unique?` is overridden to return true. Rejecting in step one is what hard-locks
a returning participant out of a vote they already cast.

**A granted authorization has to make way before a transfer.**
`[decidim_user_id, name]` is unique and `AuthorizationTransfer.perform!` moves
the *other* participant's record onto this user, so `resolve_duplicates`
destroys ours first when a duplicate exists.

**`onboarding.authorization_path` must be set and then cleared.** Setting it is
what makes step two reachable at all (once an ungranted authorization exists the
action status is `:pending`, which drops this engine's paths out of
`EphemeralSessionChecker`'s allowlist). Clearing it on success is what stops an
infinite redirect: after granting, `:create` requires `not_already_active?` and
`:update` requires `!granted?`, so both steps become forbidden and the
participant is bounced here, refused, sent to the root, and bounced back.

### Copied Decidim files

The controller and both views are adapted copies of Decidim files.
`spec/lib/overrides_spec.rb` checksums their upstream originals against
`spec/overrides.yml`; when Decidim changes one, that spec fails, which is the
signal to review our copy. Regenerate with `rake overrides:checksums` **after**
reviewing, never to silence it. Add a path to `Overrides.tracked_paths` when
copying anything new.

## Testing notes

`spec/requests` covers the workflow's logic without a browser and is where most
regressions belong. `spec/system` drives the real funnel per component and is
slow.

Recurring traps, all of which have produced false passes or false failures here:

- **The `:ephemeral` factory trait does not model a real ephemeral user.**
  `Decidim::CreateEphemeralUser` confirms the user and leaves
  `accepted_tos_version` nil; the trait does neither. Use
  `create(:user, :ephemeral, :confirmed, accepted_tos_version: nil)`, or the
  terms of service validation is silently skipped and Devise bounces the
  session.
- **The record holding a verification code is the ungranted one** — granting
  clears `verification_metadata`, and a returning participant has an older
  granted authorization alongside the new one. Always scope on
  `granted_at: nil`.
- **`expect { click }.to change { ... }` does not wait.** A click starts a POST
  and redirects; assert on the page first, then on the database.
- **Method arguments are evaluated before Capybara waits**, so reading a code
  from the database as a `fill_in` argument can happen before the request that
  generated it finished. Assert the page has arrived first.
- **Exceptions raised inside a Decidim command's `on(:ok)` block are swallowed**
  by the command's own `rescue StandardError`, and surface as that command's
  `:invalid` branch. Capture the result and act on it outside the block.
- `Capybara.default_max_wait_time` is raised in `spec/spec_helper.rb`; Decidim
  leaves the 2 second default, which is too tight for these pages.

## Conventions

The workflow name `ephemeral_sms` is simultaneously the mount path, the
`decidim_<name>` route proxy, the value in `decidim_authorizations.name` and the
i18n key root. **It cannot change once authorizations exist** —
`Decidim::Authorization` validates that a workflow of its name is registered.

Register from an engine `initializer`, never `config.to_prepare`, and never
guard on host-application configuration: engine initializers run *before* the
application's `config/initializers`.

Keep every route under the engine's mount point, and keep
`edit_authorization_path` and `renew_authorization_path` defined — the Adapter
looks them up by name and raises otherwise.

Nothing installation-specific belongs in the gem. The eligibility confirmation
ships generic wording and is meant to be overridden per organization through
`decidim-term_customizer`; checkbox labels are rendered as HTML by Decidim's
form builder, so a link works.

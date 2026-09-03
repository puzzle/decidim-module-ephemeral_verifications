# Decidim Ephemeral Verifications

Lets participants verify themselves and complete a single action — voting in a
participatory budget, supporting a proposal, answering a survey — **without
creating an account**.

Decidim 0.31 introduced the machinery for this ("ephemeral verifications"), but
it ships no concrete verification method: the
[decidim documentation](https://docs.decidim.org/en/v0.31/admin/participants/authorizations/ephemeral_verifications#_configuration)
implies the feature can be switched on in the system panel, and it cannot. Every
installation has to supply a workflow in code. This module supplies one, based
on SMS.

## What you get

A verification workflow registered as **`ephemeral_sms`**:

1. The participant clicks the action button while logged out. Decidim creates a
   throwaway ("ephemeral") session for them instead of showing a login dialog.
2. They give a mobile phone number and tick a required **eligibility
   confirmation** (plus the terms of service, the first time).
3. They receive a code by SMS and enter it.
4. They are verified and returned to the action they wanted to perform.

It also handles what Decidim's multistep verification path leaves out:

- **Coming back.** Verifying again with the same phone number hands the earlier
  ephemeral session back, with whatever was done in it. Without this a returning
  participant is hard-blocked by the duplicate check, with their earlier
  contribution orphaned.
- **Signing up later.** A registered participant who verifies a phone number
  previously used ephemerally has the authorization *and the records authored
  with it* transferred to their account.
- **Terms of service.** Recorded for ephemeral participants, as Decidim expects.

## What you need to bring yourself

- Decidim `>= 0.31.0, < 0.32`
- An SMS gateway configured as `Decidim.sms_gateway_service`. Any class matching
  Decidim's gateway contract works — `new(phone_number, code, context)` plus
  `#deliver_code` — so this module carries no gateway of its own. See
  [the Decidim SMS docs](https://docs.decidim.org/en/develop/services/sms).
- Other types of verification are not implemented yet. If you want to implement
  one, see the [docs](docs/writing-an-ephemeral-verification.md) in this module.
  Contributions are welcome.

## Installation

```ruby
gem "decidim-ephemeral_verifications", github: "puzzle/decidim-module-ephemeral_verifications"
```

```bash
bundle install
```

There are no migrations. Then, as an administrator:

1. In the **system panel**, edit the organization and tick
   *SMS verification without an account* under *Available authorizations*.
2. In the **organization admin**, open the component and, under its permissions,
   enable `ephemeral_sms` for the action participants should be able to perform.

> **Configure `ephemeral_sms` as the only handler for that action.** The
> workflow serves registered participants too, so adding Decidim's built-in
> `sms` handler alongside it would force them through two separate SMS
> verifications while guests only ever see this one.

> **Changing a component's permissions revokes verifications.** Decidim
> deliberately revokes every granted authorization of an ephemeral workflow
> across the whole organization whenever that workflow is added to a
> component's permissions or its options change. Do not re-save that form while
> a vote is running.

## Customising the wording

Every string is a normal translation, so
[decidim-term_customizer](https://github.com/mainio/decidim-module-term_customizer)
can override it per organization. The one you will almost certainly want to
change is the eligibility confirmation:

```
decidim.authorization_handlers.ephemeral_sms.fields.eligible_confirmation_html
```

It ships as a generic "I confirm that I am eligible to take part." Checkbox
labels are rendered as HTML by Decidim's form builder, so the replacement may
contain a link.

## Development

```bash
docker compose up -d               # a Postgres just for this repository
bundle install
bundle exec rake test_app          # generates spec/decidim_dummy_app
bundle exec rspec
bundle exec rake development_app   # a real app to click through
```

The suite needs no configuration and no other application's database.
`docker-compose.yml` runs Postgres on **5433**, so it coexists with one already
listening on 5432, and `database_defaults.rb` points the generated app at
it. Every value defers to the environment, so `DATABASE_HOST`, `DATABASE_PORT`,
`DATABASE_USERNAME` and `DATABASE_PASSWORD` still win if you would rather use
your own Postgres — which is what CI does.

### Stopping things again

```bash
docker compose down                  # stop Postgres, keep the data
docker compose down -v               # ...and discard the databases too
rm -rf spec/decidim_dummy_app        # drop the generated test app
rm -rf development_app               # drop the generated development app
```

The two generated apps are gitignored and disposable — `rake test_app` and
`rake development_app` recreate them. Nothing else needs stopping: `rspec`
starts its own Puma and Chrome and shuts both down when it finishes, and
`rake development_app` only generates the app (`cd development_app && bin/rails
server` runs it, so Ctrl-C stops it). Dropping just the databases, without
removing the volume:

```bash
docker compose exec pg psql -U decidim -c \
  'DROP DATABASE IF EXISTS decidim_module_ephemeral_verifications_test_app_test'
```

System specs need Chrome and chromedriver. `selenium-webdriver` bundles
Selenium Manager, so both can be fetched without root and without touching the
system package manager:

```bash
SM=$(dirname $(gem which selenium/webdriver))/../bin/linux/selenium-manager
$SM --browser chrome --browser-version stable --output json
```

That prints the paths it downloaded under `~/.cache/selenium`. Symlink them
somewhere on your `PATH` (as `google-chrome` and `chromedriver`) and the specs
will find them. A flatpak or snap Chromium will *not* work: the driver needs a
real binary path, and the sandbox cannot reach Selenium's temporary profiles.

`bundle exec rspec spec/lib/overrides_spec.rb` checksums the Decidim files this
module copies or closely adapts. When Decidim changes one of them the spec
fails, which is the signal to review our copy; `bundle exec rake
overrides:checksums` accepts the new state afterwards.

## How it works

If you want to build your own ephemeral verification, or maintain this one, read
[docs/writing-an-ephemeral-verification.md](docs/writing-an-ephemeral-verification.md).
It documents the parts of Decidim that are not documented upstream.

## License

AGPL-3.0. See [LICENSE.txt](LICENSE.txt).

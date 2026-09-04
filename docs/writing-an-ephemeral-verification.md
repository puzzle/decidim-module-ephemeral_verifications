# Writing an ephemeral verification for Decidim

Decidim 0.31 lets a participant verify themselves and complete one action
without registering. The
[decidim documentation](https://docs.decidim.org/en/v0.31/admin/participants/authorizations/ephemeral_verifications#_configuration)
describes the feature as if it could be switched on in the system panel; it
cannot. Decidim ships the machinery and no concrete verification method, so
every installation that wants this has to supply one in code.

This is a guide to building one. It is written to be useful outside this module,
and every claim is verifiable against Decidim 0.31.

Read it in order. Section 1 is the decision that shapes everything else,
section 2 is the machinery you register into, section 3 is what Decidim does at
runtime, section 4 and section 5 are the two things you have to supply
yourself, and section 6 is the checklist.

## 1. First decide: direct or multistep

A **direct** workflow (`workflow.form = "SomeHandler"`) is one form, one
request, one command. Decidim owns the controller:
`AuthorizationsController#new` renders your handler's `to_partial_path`
partial, and `#create` reconstructs the handler and hands it to
`Decidim::Verifications::AuthorizeUser`, which validates and grants in one go.

A **multistep** workflow (`workflow.engine = …`) means you own the controller
and the URLs, and state travels between requests in the ungranted
authorization's `verification_metadata`: `PerformAuthorizationStep` writes it,
`ConfirmUserAuthorization` compares it and grants.

`ephemeral` is orthogonal to both — but only the direct path goes through
`AuthorizeUser`, and `AuthorizeUser` is where all the ephemeral behaviour lives:

```ruby
if !handler.unique? && handler.user_transferrable?
  handler.user = handler.duplicate.user
  Authorization.create_or_update_from(handler)
  return broadcast(:transfer_user, handler.user)
end
return transfer_authorization if !handler.unique? && handler.transferrable?
if handler.invalid?
  register_conflict
  return broadcast(:invalid)
end
return broadcast(:invalid) unless set_tos_agreement
```

- `:transfer_user` — duplicate exists and *both* users are ephemeral: the
  session hops to the earlier ephemeral user, recovering their votes and
  drafts.
- `:transferred` — duplicate belongs to a deleted or ephemeral user while the
  current user is a real account: `Authorization#transfer!` moves the
  authorization *and the authored records* to that account.
- `set_tos_agreement` — an ephemeral participant must tick `tos_agreement`, and
  this is the only place `accepted_tos_version` is written.

**A multistep workflow gets none of that.** If you build one, you must supply
it yourself.

### Worked example: why SMS forces multistep

SMS cannot fit the direct shape, because the code does not exist until the
phone number has been submitted. Core's `MobilePhoneForm` shows the dependency
plainly: `verification_code` is computed *during validation* by calling
`deliver_code`, and the value is written into `verification_metadata` for a
later request to compare. One submission cannot both trigger the send and
collect what the send produced.

The cheapest way to get the ephemeral behaviour back is not to reimplement it
but to run `AuthorizeUser` yourself, after the code has been confirmed:

```ruby
Decidim::Verifications::ConfirmUserAuthorization.call(authorization, form, session) do
  on(:ok) { resolve_duplicates }   # runs AuthorizeUser with a small value-object handler
  # ...
end
```

**The order is a security property, not a detail.** The code is the proof of
phone ownership. Resolving duplicates before confirming it would let anyone
type a stranger's number and inherit their session and their vote.

That ordering is also why step one must *tolerate* duplicates. `unique_id`
identifies a proof, not a user, and Decidim's invariant — enforced by
`AuthorizationHandler#uniqueness` — is that one identity must not hold two
authorizations of the same kind. That refusal is correct for registered
accounts. It is wrong for ephemeral ones, because the account is disposable but
the person is not, and `DestroyEphemeralUser` keeps their granted
authorization. A returning participant therefore collides with *their own*
earlier proof and, without special handling, gets a generic error and is locked
out of a vote they already cast. So: override `unique?` in the first step, and
let `AuthorizeUser` arbitrate in the second.

Two authorizations transiently share a `unique_id` while this happens. That is
legal — the index is not unique — and `AuthorizationHandler#duplicate` scopes
to `User.where.not(id: user.id)`, so it resolves to the right record. Do delete
the redundant one afterwards, or a third visit finds two candidates.

Soft-deleted users stay visible to `#duplicate`: `Decidim::User` has no
`default_scope`, and `transferrable?` explicitly tests `duplicate.user.deleted?`.

## 2. Authorizations, workflows and the registry

Four loosely coupled layers. Knowing which layer owns which decision is most of
the work.

### The manifest and the registry — what verification methods exist

`Decidim::Verifications.register_workflow(:name) { |w| … }` reaches
`Decidim::WorkflowRegistry#register_workflow`, which builds a
`Decidim::Verifications::WorkflowManifest`, calls `validate!` on it (a bad
manifest raises at boot) and adds it to a `Set`.

| Reader | Returns |
| --- | --- |
| `Decidim.authorization_workflows` | every manifest |
| `Decidim.authorization_handlers` | `select(&:form)` — the *direct* ones |
| `Decidim.authorization_engines` | `select(&:engine)` — the *multistep* ones |
| `Decidim.authorization_admin_engines` | those with an `admin_engine` |

Registering looks like this. Everything else in this guide is about getting the
two flags at the top right:

```ruby
Decidim::Verifications.register_workflow(:my_verification) do |workflow|
  workflow.ephemeral = true
  workflow.renewable = false

  workflow.engine = MyModule::Verification::Engine  # or: workflow.form = "MyHandler"
  workflow.icon = "message-3-line"
end
```

**`ephemeral`** (default `false`) is what opts the workflow into everything in
sections 3 and 4. Without it the workflow behaves like any other verification
and a visitor must register first.

**`renewable`** defaults to **`true`**, and for an ephemeral workflow that
default is usually wrong. It publishes `GET <engine>/authorizations/renew`,
wired straight to `DestroyUserAuthorization`, so a granted authorization gains a
self-destruct URL once `time_between_renewals` has passed — reachable by
prefetch or an `<img src>`, since it is a GET. Decide it like this:

- **`false`** if the thing you verify is a scarce identity that must not be
  recycled. A phone number is: a participant who received a *transferred*
  authorization could otherwise destroy it, free the number, and let a second
  authorization be granted for it — one phone, two votes. Setting it false makes
  `Authorization#renewable?` false, which also denies the `:renew` permission,
  so the route can stay declared and inert.
- **`true`** only if re-verifying is genuinely something participants should be
  able to do, and re-verifying cannot buy anything. Then you also owe i18n keys
  for every attribute you store, because the renew modal renders them through
  `AuthorizationMetadataCell`.

The other attributes — `name`, `form`, `engine`, `admin_engine`, `expires_in`,
`time_between_renewals`, `action_authorizer`, `metadata_cell`, `icon` and an
`options` settings manifest — are the same for ephemeral and ordinary
workflows; read `lib/decidim/verifications/workflow_manifest.rb` for the
current set rather than trusting a list here.

`authorization_handler_form`, `save_authorizations` and
`promote_authorization_validation_errors` are **not** verification manifest
attributes — they belong to `Decidim::Initiatives::SignatureWorkflowManifest`,
which is a different feature with its own ephemeral flow. Searching the
codebase for "ephemeral" turns them up first and they are a possible source of
confusion.

Two traps live here:

- The registry `Set` is keyed by object identity and `WorkflowManifest` does not
  override `hash`/`eql?`, so registering a second manifest under an existing
  name does **not** replace it. You get two, and the mount step below runs
  twice, producing `ArgumentError: Invalid route name, already in use:
  'decidim_<name>'` at boot.
- `Decidim::Authorization` validates that a workflow of its `name` is
  registered, so renaming or unregistering a workflow makes every existing row
  of that name unsaveable.

### Mounting — what URLs exist

`Decidim::Verifications::Engine`'s routes block, inside `authenticate(:user)`:

```ruby
Decidim.authorization_engines.each do |manifest|
  mount manifest.engine, at: "/#{manifest.name}", as: "decidim_#{manifest.name}"
end
```

The workflow name is therefore simultaneously the URL segment and the route
proxy name. Routes are drawn after all initializers run, so registering from a
Rails engine `initializer` block happens in time. `config.to_prepare` does not
reliably.

### The Adapter — one interface over both workflow types

`Decidim::Verifications::Adapter` wraps a manifest and is what the rest of
Decidim talks to. It resolves the engine with `send("decidim_#{name}")`, which
is why the mount name and the workflow name have to agree.

| Method | Direct workflow | Multistep workflow |
| --- | --- | --- |
| `root_path` | `new_authorization_path(handler: name)` | `decidim_<name>.root_path` |
| `resume_authorization_path` | **raises** `InvalidVerificationRoute` | `decidim_<name>.edit_authorization_path` |
| `renew_path` | `renew_authorizations_path(handler:)` | `decidim_<name>.renew_authorization_path` |
| `admin_root_path` | **raises** | `decidim_admin_<name>.root_path` |

`resume_authorization_path` and `renew_path` are looked up on the engine by
name with `respond_to?` and raise `MissingVerificationRoute` when absent, so a
multistep engine must declare routes named exactly `edit_authorization_path`
and `renew_authorization_path`. Declaring a singular
`resource :authorizations, as: :authorization` with `get :renew, on: :collection`
is the idiomatic way to get them.

### Enabling — two independent switches, both required

Per organization, in the **system panel** under *Available authorizations*,
which writes `Decidim::Organization#available_authorizations`. That form lists
`Decidim.authorization_workflows` unfiltered, so ephemeral workflows appear
there like any other.

Per action, in the component's (or resource's) `permissions` jsonb:

```ruby
{ "vote" => { "authorization_handlers" => { "ephemeral_sms" => { "options" => {} } } } }
```

`ActionAuthorizer#authorization_handlers` intersects the two with
`.slice(*available_authorizations)`, so skipping the system-panel step silently
drops the handler *and* discards the admin's per-component selection.

### Evaluation

`Decidim::ActionAuthorizer.new(user, action, component, resource).authorize`
returns an `AuthorizationStatusCollection` with one `AuthorizationStatus` per
configured handler. `DefaultActionAuthorizer#authorize` returns, in order:

`:missing` (no record) → `:expired` → `:pending` (record exists, `granted_at`
is nil) → `:unauthorized` (a metadata field does not match the action's
options) → `:incomplete` (a required field is blank) → `:ok`.

Permission classes then just ask `.ok?`. Voting on a budget project is nothing
more than `Decidim::Budgets::Permissions#can_vote_project?` calling
`authorized?(:vote, resource: project)` — there is no component-specific
ephemeral code to write.

### The record

`Decidim::Authorization` holds `name`, `decidim_user_id`, `unique_id`,
`metadata`, `verification_metadata` and `granted_at`. Both metadata columns are
encrypted at rest. The only unique index is `[decidim_user_id, name]`;
`unique_id` is indexed but **not** unique, which matters in section 4.

## 3. How Decidim processes an ephemeral participant

`ephemeral` is a flag, not a mechanism. It opts a workflow into a flow that
lives in `decidim-core`. Here is the whole sequence for a logged-out visitor
voting on a budget project.

1. **Page render.** The vote button goes through `authorized_to` →
   `ActionAuthorizer` with `user = nil`. Because every handler configured for
   the action is ephemeral, `AuthorizationStatusCollection#ephemeral?` is true,
   so `Decidim::ActionAuthorizationHelper#sign_in_required?` returns **false** —
   no login dialog. The button becomes a `POST` to
   `decidim_verifications.renew_onboarding_data_authorizations_path` carrying
   `data-onboarding-*` attributes.
2. **Intent capture.** `onboarding_pending_action.js` writes an `onboarding`
   cookie on `mousedown`: `{action, model, permissionsHolder, redirectPath}`.
3. **Ephemeral user creation.** That POST hits
   `Decidim::Verifications::AuthorizationsController`, whose
   `before_action :set_ephemeral_user` rebuilds an `OnboardingManager` from the
   cookie, confirms `authorizations.ephemeral?`, and runs
   `Decidim::CreateEphemeralUser`. There is no `ephemeral` column and no
   `EphemeralUser` class: it is a `Decidim::User` with `managed: true`, no
   email, a generated nickname, `confirmed_at` set, and
   `extended_data: {"ephemeral" => true}`. It is signed in, the cookie is
   merged into `extended_data["onboarding"]` and deleted.
4. **Dispatch.** Redirect to `onboarding_pending`, which sees
   `single_authorization_required?` and redirects to
   `statuses.first.current_path` — with status `:missing` that is
   `Adapter#root_path`, i.e. your engine's root.
5. **Your workflow runs.** See section 4 for the one thing you must do here.
6. **Sandbox.** Every subsequent HTML request runs
   `EphemeralSessionChecker#check_ephemeral_user_session`, which enforces
   session expiry and a path allowlist.
7. **Return.** Once the authorization is granted the status is `:ok`;
   `onboarding_pending` flashes a notice and redirects to
   `finished_redirect_path`. Note `clear_onboarding_data!` is a deliberate
   no-op for ephemeral users, so the sandbox stays in force for the session.
8. **Teardown.** The header's *Close* link, or `onboarding_manager.expired?`
   (`Decidim.config.expire_session_after`) on the next request, runs
   `Decidim::DestroyEphemeralUser`. It destroys only authorizations with
   `granted_at: nil` and soft-deletes the user. **The granted authorization
   deliberately survives on a soft-deleted user**, which is what makes
   section 3 possible.

One rule with wide consequences, in `AuthorizationStatusCollection`:

```ruby
next if @ephemeral_user && !handler.ephemeral?
```

For an ephemeral participant, non-ephemeral handlers are dropped entirely, and
`#ephemeral?` requires `statuses.all?(&:ephemeral?)`. So you **cannot** chain a
generic ephemeral form with a separate, non-ephemeral second verification —
the second one is filtered out. Whatever your verification needs to do has to
happen inside one ephemeral workflow.

The filter is one-directional, though: an ephemeral handler *is* evaluated for
a registered, logged-in participant. Your ephemeral workflow therefore serves
both populations, which is easy to forget when deciding what to ask for.

## 4. The deadlock every multistep ephemeral workflow hits

`EphemeralSessionChecker#authorizations_permitted_paths?` builds its allowlist
like this:

```ruby
paths_list = if authorizations.user_pending?  then statuses.map(&:current_path).prepend(authorizations_path)
             elsif authorizations.ok?         then [finished_redirect_path, component_path].compact
             else                                  []
             end
paths_list.prepend(pending_authorizations_path, decidim.page_path(terms_of_service_page))
paths_list.find { |el| /\A#{URI.parse(el).path}/.match?(request.path) }
```

and `user_pending?` is

```ruby
!global_code && statuses.any? { |status| [:missing, :expired, :incomplete].include?(status.code) }
```

`:pending` is deliberately absent from that list, while `global_code` *returns*
`:pending`. So:

| Stage | Status | Allowlist |
| --- | --- | --- |
| before step one | `:missing` | `authorizations_path` and `root_path` → your whole engine is reachable |
| **after step one** | `:pending` | `[]` → only the onboarding page and the terms page |
| after step two | `:ok` | `finished_redirect_path`, `component_path` |

In the middle row your own second step is not permitted, so the checker
redirects to `/authorizations/onboarding_pending`, whose
`single_authorization_required?` branch redirects straight back to
`resume_authorization_path`. That is an infinite loop, and it lands exactly
where a real participant is: between the two steps.

The escape hatch is the unconditional
`paths_list.prepend(pending_authorizations_path, …)`, where

```ruby
pending_authorizations_path = onboarding_manager.authorization_path ||
                              decidim_verifications.onboarding_pending_authorizations_path
```

So write your engine's root into
`extended_data["onboarding"]["authorization_path"]`. That makes it a permitted
prefix in *every* state and points any bounce back into your own flow:

```ruby
before_action :remember_authorization_path

def remember_authorization_path
  return unless current_user&.ephemeral?

  root = decidim_my_workflow.root_path
  return if onboarding_manager.authorization_path == root

  current_user.update(
    extended_data: current_user.extended_data.deep_merge(
      Decidim::OnboardingManager::DATA_KEY => { "authorization_path" => root }
    )
  )
end
```

`decidim-initiatives` is the only precedent in Decidim itself:
`InitiativeSignaturesController#current_initiative_onboarding_data` sets
`"authorization_path" => initiative_signatures_path(current_initiative)` for
exactly this reason, and `#clear_authorization_path` resets it afterwards.

This is also the one place where keeping every route under the engine's mount
point pays off: a single prefix entry covers the entire flow.

## 5. Limits you have to add yourself

Decidim's ephemeral flow removes the account barrier. Everything an account used
to imply — that someone confirmed an email, that a request is attributable, that
a rate limit has a subject — stops being true, and the pieces upstream provides
do not fill the gap. Whatever your verification costs to attempt, assume an
unauthenticated visitor will attempt it in a loop.

### An unauthenticated visitor spends your SMS budget

Step one sends a message to whatever number is typed, and a workflow that
supports resending (a "did not receive the code?" link, or `destroy` followed by
a fresh `create`) will send another. Nothing upstream caps this: Decidim's only
brake is the generic per-IP `Rack::Attack.throttle` of 100 requests a minute,
which is per-IP rather than per-number and trivially distributed. Every
iteration costs money and delivers a message to a third party who did not ask
for it.

Cap resends against the `code_sent_at` you are already storing — a short
cooldown plus an hourly ceiling per `unique_id` — and tell integrators to add a
`Rack::Attack` rule for the create action.

### The code is brute-forceable, and upstream's throttle does not stop it

`Decidim::Verifications::ConfirmUserAuthorization` counts failures in
`session[:failed_attempts]`. Decidim runs the **cookie** session store, so that
counter is held by the client: replay the cookie captured after step one and the
count is always zero. Even when it does trip, the response is
`sleep rand * failed_attempts` — a delay, never a lockout.

There is also no expiry. `code_sent_at` is written into `verification_metadata`
and **never read** — `confirmation_successful?` compares only the code — and
nothing reaps ungranted authorizations except the ephemeral session teardown. So
a registered participant's pending record and its code live indefinitely.

Neither weakness matters much for upstream's own `sms` workflow, which is not
ephemeral and requires a confirmed account. It matters here, because confirming
a code is what triggers session recovery and record transfer: grinding a code
for a number you do not own hands you that participant's ephemeral session, or
moves their authored records onto your account.

Enforce both server-side, on the record rather than in the session: reject a
code older than a few minutes, count attempts in `verification_metadata`, and
destroy the record once the count is exceeded so a fresh code is required.

### What the test suite can and cannot tell you

The four assumptions in sections 3 and 4 are not verifiable by a test: they are
statements about Decidim's behaviour, and our code exercises them rather than
asserting them. What a checksum guard over the upstream files *can* do is
guarantee you are told when the ground moves — a change to
`action_authorizer.rb`, `permissions.rb`, `authorization_handler.rb`,
`authorization.rb`, `authorization_transfer.rb` or `renewable.rb` fails a test
instead of passing silently, which forces a re-read.

That is the distinction worth keeping straight: the suite does not verify the
assumptions, it refuses to stay quiet when the files they live in change. Track
a file if and only if a documented assumption depends on it. Measured against
Decidim's history, this costs nothing day to day — none of those files changed
across any 0.31 patch release — and fires at minor upgrades, which is when you
have to look anyway.

## 6. Checklist

1. Pick a workflow name that cannot collide, and never change it once
   authorizations exist.
2. Set `renewable = false` unless re-verifying is both wanted and harmless
   (section 2), and add the two limits from section 5 — neither is optional for
   a workflow an unauthenticated visitor can reach.
3. Register from a Rails engine `initializer` block, not `config.to_prepare`.
   Do not guard on host-app configuration: engine initializers run *before* the
   application's `config/initializers`.
4. Make `handler_name` equal the workflow name.
5. Return a stable `unique_id`, or session recovery and account transfer
   silently do not work.
6. Declare `edit_authorization_path` and `renew_authorization_path`.
7. Keep every route under the engine's mount point, and store
   `onboarding.authorization_path` (section 4).
8. Supply `AuthorizeUser`'s behaviour yourself if you are multistep, after
   confirming the participant's proof (section 3).
9. Add `decidim.authorization_handlers.<name>.{name,explanation,fields.*}` and
   `decidim.authorization_handlers.admin.<name>.help`. Without `name` your
   workflow shows up as a humanised key.
10. Ship a `decidim:verifications:revoke:<name>` rake task: the auto-generated
   one never materialises, because rake files load before the initializers that
   register workflows (decidim#16546).
11. Tell administrators that adding your ephemeral workflow to a component's
    permissions, or changing its options, revokes every granted authorization
    of that name across the organization — `UpdateComponentPermissions`
    calls `RevokeByNameAuthorizations` on purpose.
12. Remember that registered participants reach your ephemeral workflow too, so
    anything you must ask *everyone* cannot ride on `tos_agreement`, which is
    only shown when `user.ephemeral? && !user.tos_accepted?`.

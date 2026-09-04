# Writing an ephemeral verification for Decidim

Decidim 0.31 lets a participant verify themselves and complete one action
without registering. The [decidim documentation][docs] describes the feature as
if it could be switched on in the system panel; it cannot. Decidim ships the
machinery and no concrete verification method, so every installation that wants
this has to supply one in code.

Part I describes what Decidim does, conceptually. Part II is the decisions and
the code needed to add a workflow to it.

[docs]: https://docs.decidim.org/en/v0.31/admin/participants/authorizations/ephemeral_verifications#_configuration

# Part I — how ephemeral verification works

## The idea

An ordinary Decidim verification answers "may this participant do this?" for
someone who already has an account: they register, confirm an email, prove
something about themselves, and the result is recorded against that account. An
**ephemeral** verification answers the same question for a visitor who never
registers. Decidim creates a throwaway participant on the spot, lets them prove
the one thing the action requires, confines them to that action, and soft-deletes
the account afterwards — while keeping the proof, so the same person is
recognised if they come back or later register properly.

Some terms which recur throughout, and are worth separating:

- a **workflow** is one verification method — SMS, an ID check, a census
  lookup. It is registered once when the application boots, and its *manifest*
  declares how it behaves, including whether it is ephemeral.
- an **authorization** is one row recording that one participant proved one
  thing through one workflow. It is *ungranted* while the proof is in progress
  and *granted* once it succeeded.
- **onboarding data** is what the throwaway participant carries around: the
  action they originally clicked, and where to send them when they are done.
- **one-step** *(direct)* vs. **multistep** verification workflow. Simple
  verification strategies can be implemented in a one-step flow, inheriting
  more pre-implemented logic from the Decidim core. Others, like SMS with one
  form for entering the number and sending the SMS and another one for entering
  the SMS code, need to be implemented as multistep.

## The journey

Any action an admin can put behind a verification works this way — voting in a
participatory budget, supporting a proposal, answering a survey.
The sequence below follows a logged-out visitor clicking one such action, whose
permissions require ephemeral verifications only.

1. **The button.** Rendering the action's button asks whether this visitor may
   perform it. Because no account is needed for any of the verifications
   configured for the action, Decidim skips the login dialog it would otherwise
   show and turns the button into a POST to Decidim's own onboarding endpoint,
   carrying which action was clicked (a cookie written on `mousedown` carries
   the same intent into the request that follows).
2. **The throwaway participant.** That POST creates and signs in an *ephemeral
   user*: an ordinary participant record flagged as ephemeral — no email
   address, a generated nickname, already confirmed, no terms of service
   accepted yet — with the clicked action stored on it as onboarding data.
   There is no separate class and no separate table.
3. **The onboarding page.** That POST finishes by redirecting to Decidim's
   *onboarding pending* page, the dispatcher of the whole flow. It looks up
   how far each verification required for the remembered action has got, and
   decides what the participant should see:
   - **exactly one verification left to complete** redirects straight into
     that workflow: its root URL when nothing has been started, its resume URL
     when a record is already in progress.
   - **several** renders a list to work through one at a time, saying which are
     already done.
   - **nothing left** forwards to the action the participant originally clicked.

4. **The proof.** Part II. It ends with an authorization granted.
5. **The sandbox.** For as long as the onboarding data still names an action,
   the participant may only reach a short allowlist of paths derived from how
   far the verification has got (see below). Anything else is redirected back
   to the onboarding page. Additionally, ephemeral sessions are limited to
   `Decidim.config.expire_session_after`.
6. **Back to the action.** With all authorizations granted, the onboarding page
   takes its third branch and the action goes through. The sandbox stays in
   force for the rest of the session: a throwaway participant never
   automatically becomes a general-purpose account.
7. **Closing.** A *Close* link in the header, or the session expiring,
   soft-deletes the participant — ungranted authorizations are destroyed with
   them, but **the granted authorization survives**. That surviving row is what
   the next section rests on.

## What the identity outlives

Because the proof outlives the throwaway account, the identity behind it — a
phone number, a personal identifier — can be recognised later. Decidim resolves
that in a single place, `Decidim::Verifications::AuthorizeUser` — the command
that grants an authorization from a submitted form — and there are three
outcomes:

- **Nobody else holds this identity.** The authorization is granted. For an
  ephemeral participant this is also the only moment their terms of service
  acceptance is recorded.
- **An earlier ephemeral participant holds it.** The visitor *is* that earlier
  participant coming back, so their earlier session is handed back to them,
  along with the vote, draft or comment they left in it.
- **They hold a real account now.** The authorization, and the records authored
  with it, are transferred onto that account.

An ephemeral verification workflow needs to handle all of this: without it a
returning participant is refused as a duplicate of themselves and locked out of
a vote they already cast. A one-step workflow gets all three for free, because
Decidim calls that command for it; a multistep one has to call it itself
(Part II, steps 1 and 7).

## How far the verification has got, and where that lets the participant go

For each verification configured for an action, Decidim derives a status:
`:missing` (no record at all), `:expired`, `:pending` (a record exists but is
not granted), `:unauthorized` or `:incomplete` (granted, but what it recorded
does not satisfy this particular action) and `:ok`.

The sandbox's allowlist is derived from the same status:

| Stage                      | Status     | Where the participant may go                                                             |
|----------------------------|------------|------------------------------------------------------------------------------------------|
| always allowed             | any        | Decidim's onboarding page and the terms of service, plus onboarding data path, see below |
| nothing started            | `:missing` | the whole verification workflow, and Decidim's authorizations page                       |
| a record exists, ungranted | `:pending` | -                                                                                        |
| granted                    | `:ok`      | the action they came for, and the component holding it                                   |

Additionally, the participant's onboarding data may store a path prefix which
is allowlisted in every state (Part II, step 8). This way our verification
workflow can permit the workflow-specific paths where the participant still
needs to be for completing a pending verification. Otherwise, the sandbox
would send the user to Decidim's onboarding page, leaving them unable to
complete the verification, or worse — if a single verification is
required — redirects straight back into the workflow it just came from: an
infinite loop.

## Two rules that follow

**Only ephemeral verifications may be required on the action.** A logged-out
visitor is offered the account-free route only if *every* verification the
action requires is ephemeral; a single non-ephemeral one alongside brings the
login dialog back for everybody. And once the participant is ephemeral, Decidim
drops the non-ephemeral verifications from the check entirely, so they could
never be satisfied in that session anyway. An ephemeral workflow therefore
cannot be chained with a separate, non-ephemeral second check — everything the
verification needs has to happen inside the one workflow.

**Registered participants use it too.** That dropping only happens the other
way round: a *non-ephemeral* verification is dropped for an ephemeral
participant, while an ephemeral workflow is evaluated for everybody, logged-in
account holders included, so it serves both populations.

## How Decidim interacts with a verification workflow

### The three URLs Decidim asks for

Nothing in Decidim links to a workflow's controller directly. It goes through
`Decidim::Verifications::Adapter`, which turns a workflow name into paths:

| Adapter method | What it means | One-step workflow | Multistep workflow |
| --- | --- | --- | --- |
| `root_path` | start verifying | Decidim's own form page | the engine's root |
| `resume_authorization_path` | continue where you left off | **raises** | the engine's `edit_authorization_path` |
| `renew_path` | verify again | Decidim's renew action | the engine's `renew_authorization_path` |

A multistep workflow must publish routes under those names; the adapter looks
them up by name and raises otherwise. `renew_path` is not needed if the
the workflow is configured not to be renewable. A one-step workflow gets all
three for free.

### The authorization record

An authorization holds the workflow `name`, the participant, a `unique_id`
identifying *what was proven* (e.g. the hashed phone number), `metadata` kept
after the fact, `verification_metadata` used while the proof is in progress,
and `granted_at`. Both metadata columns are encrypted at rest. A participant
can hold only one authorization per workflow — that pair is uniquely indexed —
but **`unique_id` is deliberately not unique**, because the same identity may
legitimately appear on two rows while a returning participant is being
recognised.

# Part II — writing an ephemeral verification

## Step 1. Decide: one-step (direct) or multistep

A **one-step** (in Decidim's terms *direct*) workflow declares
`workflow.form = "SomeHandler"` and Decidim owns the controller: it renders the
handler's partial, then hands the submitted handler to
`Decidim::Verifications::AuthorizeUser`, which validates and grants in one go.

A **multistep** workflow declares `workflow.engine = …` and owns its controller
and URLs. State travels between requests in the ungranted authorization's
`verification_metadata`: `PerformAuthorizationStep` writes it,
`ConfirmUserAuthorization` compares it and grants.

Choose one-step whenever the proof can be supplied in a single submission.
In multistep workflows, Decidim's `AuthorizeUser` must be explicitely called
or a manual implementation must be supplied for recording terms of service
acceptance, handing an earlier ephemeral session back to someone verifying the
same identity again, and moving an authorization plus the records authored with
it onto a real account when they register.

SMS is multistep by necessity: We need a form for collecting the user's phone
number, and then a second form for entering the received code.

Either shape has to be able to grant within the participant's own session. A
verification that is granted later by a reviewer — an uploaded identity
document, a letter with a code — cannot be ephemeral: closing the session
destroys the ungranted authorization along with the throwaway account, so the
review has nothing left to approve.

## Step 2. Register the workflow

```ruby
# lib/decidim/ephemeral_verifications/my_verification/engine.rb
Decidim::Verifications.register_workflow(:my_verification) do |workflow|
  workflow.ephemeral = true
  workflow.renewable = false

  workflow.icon = "message-3-line"

  # only if it's a one-step verification:
  workflow.form = "MyVerificationHandler"
  # only if it's a multistep verification:
  workflow.engine = MyModule::Verification::Engine
end
```

Register from a Rails engine `initializer` block. Do not guard the registration
on host-application configuration — engine initializers run *before* the
application's `config/initializers`.

Pick the name (here `my_verification`) carefully. It must be unique within the
Decidim installation. It is also the mount path, the `decidim_<name>` route proxy
the adapter resolves, the value stored in `decidim_authorizations.name` and the
i18n key root, all at once — and it can never change once authorizations exist,
because the model validates that a workflow of its name is registered.

**`ephemeral`** (default `false`) is the flag that makes Decidim create a
throwaway participant for this workflow, sandbox them and keep their
authorization afterwards. Without it the workflow behaves like any other
verification and a visitor has to register first.

**`renewable`** (default: `true`, and for an ephemeral workflow that
default is usually wrong). Renewing a workflow involves destroying the existing
authorization (possible after `time_between_renewals` has passed). This frees the
verified credential: an adversarial participant can drop the authorization they
hold, and create a new ephemeral session with the same credential to act again.
Decide it like this:
- **`false`** if the verified thing is a scarce identity that must not be
  recycled, like a phone number.
- **`true`** only if re-verifying is something participants should be able to
  do. Then the following are also necessary:
  - `time_between_renewals`, saying how soon this is allowed
  - a `renew` route and
  - in a multistep workflow, `include Decidim::Verifications::Renewable` in the
    controller (step 6)
  - a `fields.<key>` translation for every key the handler writes into
    `metadata`, because the renewal dialog renders them through `metadata_cell`
    (step 10).

**`expires_in`** (default: never) puts an end date on a granted authorization:
past it the status becomes `:expired` and the participant is sent back to the
start. Unlike renewal this is not a way to free the identity — the row survives
and still wins the duplicate lookup, so a returning person is recognised and
handed their earlier participation back.

The other attributes behave the same for ephemeral and ordinary workflows; see
`lib/decidim/verifications/workflow_manifest.rb` for the current list. Note that
`authorization_handler_form`, `save_authorizations` and
`promote_authorization_validation_errors` are **not** among them: they belong to
`Decidim::Initiatives::SignatureWorkflowManifest`, a different feature with its
own ephemeral flow, and a search for "ephemeral" turns them up first.

## Step 3. Write the handler

Every workflow, one-step or multistep, needs at least one
`Decidim::AuthorizationHandler` subclass. It is a form object that collects
what the participant submits, validates it, and says what should be written to
the authorization record. For a one-step workflow it is the *whole*
implementation, named to the manifest as a String:
`workflow.form = "MyVerificationHandler"`.

```ruby
class MyVerificationHandler < Decidim::AuthorizationHandler
  attribute :document_number, String

  validates :document_number, presence: true
  validate :document_is_in_the_census

  def handler_name
    "my_verification"
  end

  def unique_id
    Digest::MD5.hexdigest("#{document_number}-#{Rails.application.secret_key_base}")
  end

  def metadata
    super.merge({ "postal_code" => census_record.postal_code })
  end
end
```

**`handler_name`** must equal the workflow name. It defaults to the class name,
demodulised and underscored.

**`unique_id`** is the identity the whole flow turns on: it is what
`AuthorizeUser` matches to recognise a returning participant, hand back an
earlier ephemeral session or transfer an authorization to a new account.
Returning `nil` (the default) skips the uniqueness check altogether, so none of
that happens — the workflow just grants a fresh authorization every time.
Derive it from the identity being proven, and **hash it**: `unique_id` is the
one identity column that is *not* encrypted at rest.

**`metadata`** is what survives granting — the attributes an admin can gate on
(step 4) and an administrator can later inspect. By convention, anything not
directly about the authorization goes under an `"extras"` key, which the
renewal view then leaves out. **`verification_metadata`** is the opposite: the
proof still in progress, wiped when the authorization is granted, and how a
multistep workflow carries state from one request to the next.
**`verification_attachment`** takes a file when the proof is a document.

A one-step workflow usually needs no view. Decidim renders the handler's own
partial if one exists at `to_partial_path` — `"<handler name minus a trailing
_handler>/form"`, so `app/views/my_verification/_form.html.erb` — and falls
back to `form.all_fields` when it does not. Either way Decidim's page supplies
the submit button and, for an ephemeral participant who has not accepted yet,
the terms of service checkbox. Write the partial only to control the layout or
the labels of the fields themselves.

`tos_agreement` is an attribute every handler inherits, validated only when
`user.ephemeral? && !user.tos_accepted?`. Decidim's page renders that checkbox
itself for a one-step workflow, even alongside a custom partial; a multistep
workflow has to put it in its own first template, or `AuthorizeUser` refuses to
grant.

A multistep workflow needs one handler (form) per step, and then one additional
last one. `AuthorizeUser` (step 7) takes a handler, but by the time it runs,
the proof is already on the record and the participant has nothing left to
submit. So build that handler *from the authorization* instead of from params —
a value object over what was already persisted:

```ruby
class TransferHandler < Decidim::AuthorizationHandler
  attribute :unique_id, String
  attribute :metadata, Hash, default: {}

  validates :unique_id, presence: true

  def handler_name
    "my_verification"
  end

  def self.from_authorization(authorization)
    metadata = authorization.metadata.to_h
    new(
      user: authorization.user,
      unique_id: authorization.unique_id,
      metadata:,
      tos_agreement: metadata["tos_agreement"]
    )
  end
end
```

Declaring `unique_id` and `metadata` as attributes overrides the methods the
base class defines, which is the point: the values come from the record, not
from a fresh proof. Carry `tos_agreement` across too — it is what
`AuthorizeUser` records for an ephemeral participant, so step one has to have
put it in `metadata`. And validate what the handler carries: `AuthorizeUser`
refuses an invalid handler, and a blank `unique_id` would silently grant an
authorization that recognises nobody.

## Step 4. Let admins configure constraints

The same verification can serve different actions with different requirements —
a district for one vote, an age range for another — without a second workflow.
Declare the settings in the manifest, and Decidim exposes them per action in
the component's permissions form:

```ruby
workflow.options do |options|
  options.attribute :postal_code, type: :string, required: false
end
```

Out of the box the comparison is strict and name-based: for every option the
admin filled in, Decidim looks up the `metadata` entry of the **same name** and
requires the two to be equal. A different value is `:unauthorized`, a missing
one `:incomplete`, and both mean the participant is verified but not for *this*
action. So a bare option only works when the handler stores exactly the value
an admin types, under exactly that key.

Anything richer — a list of accepted values, a range, a value derived from what
was stored — needs `workflow.action_authorizer = "MyActionAuthorizer"`, a
subclass of `Decidim::Verifications::DefaultActionAuthorizer`. The pattern is
to take the option out of the hash so the inherited comparison cannot report it
as missing, let `super` do the ordinary checks, and then decide:

```ruby
class MyActionAuthorizer < Decidim::Verifications::DefaultActionAuthorizer
  def authorize
    allowed = options.delete("allowed_postal_codes")&.split(/[\W,;]+/)
    status_code, data = *super

    status_code = :unauthorized if status_code == :ok && allowed.present? &&
                                   allowed.exclude?(authorization.metadata["postal_code"])

    [status_code, data]
  end
end
```

`data[:extra_explanation]` is where a refusal like that says why, and
`redirect_params` can pass the constraint into the verification form so it can
mention it up front.

## Step 5. Multistep: declare the routes the Adapter demands

A route named exactly `edit_authorization_path` must exist: it is the resume
path the adapter hands out for a pending authorization, so without it the
onboarding page cannot send anyone into step two. `renew_authorization_path` is
not needed if the workflow is set to `renewable = false`.

```ruby
routes do
  resource :authorizations, only: [:new, :create, :edit, :update, :destroy], as: :authorization do
    get :renew, on: :collection # drop this line if the workflow is not renewable
    # if you have more than two steps, add more routes for them here
  end

  root to: "authorizations#new"
end
```

The engine is mounted at `/<workflow name>`. Keep every route under that mount
point — step 8 allowlists the whole flow by a single path prefix.

## Step 6. Multistep: write the controller

Subclass `Decidim::Verifications::ApplicationController`. It brings the signed-in
participant, the verifications layout, `enforce_permission_to`, the
`decidim_verifications` route helpers and the `redirect_url` the adapter paths
carry around, so the participant ends up back where they came from. A two-step
verification maps onto five actions:

| Action | Responsibility |
| --- | --- |
| `new` | render the first form — or redirect to the resume path if an ungranted record already exists (step 8) |
| `create` | validate the first form and hand it to `PerformAuthorizationStep`, then redirect to the resume path |
| `edit` (resume) | render the second form |
| `update` | hand the second form to `ConfirmUserAuthorization`, which grants, and then resolve duplicates (step 7) |
| `destroy` | discard the pending record so the proof can be asked for again — a mistyped identifier, or a challenge that never arrived |

A flow needing more than two exchanges is the same pattern repeated: every
intermediate step writes what it learned with `PerformAuthorizationStep`, and
only the last one confirms.

A renewable workflow also has to `include Decidim::Verifications::Renewable` in
its controller: that concern is where the `renew` and `renew_modal` actions the
route points at come from, and it is also what enforces the `:renew` permission
on them.

All forms are `Decidim::AuthorizationHandler` subclasses, and between them they
carry the state from one request to the next:

- the **first** issues the challenge while it validates — sending a code,
  querying a register, filing a request — and exposes `unique_id`, `metadata`,
  `verification_metadata` and `verification_attachment`. Whatever the
  participant will have to match later goes into `verification_metadata`, and
  `PerformAuthorizationStep` copies all four onto the ungranted authorization
  record.
- the **second** holds only what the participant brings back. Its
  `verification_metadata` is compared key by key against what was stored, and
  `ConfirmUserAuthorization` grants when every key matches. Build it *without*
  a user, or the terms of service validation every handler inherits demands the
  checkbox a second time.

Guard all steps with Decidim's own permissions:
`enforce_permission_to(:create, :authorization, authorization:)` in `new` and
`create`, the `:update` counterpart in `edit`, `update` and any later steps.
Those are what refuse a second authorization while one is already active
(`not_already_active?`) and refuse to confirm one that is already granted.

Override `after_failure_path` for ephemeral participants while you are there:
it defaults to Decidim's authorizations page, which the sandbox does not
allowlist for them, so a refused permission would throw them out of the flow
instead of back into it.

Look the record and the adapter up once, and expose the record to the views with
`helper_method :authorization`:

```ruby
def authorization
  @authorization ||= Decidim::Authorization.find_or_initialize_by(user: current_user, name: WORKFLOW_NAME)
end

def adapter
  @adapter ||= Decidim::Verifications::Adapter.from_element(WORKFLOW_NAME)
end
```

The templates, `new` and `edit`, live under the controller's own view path.
Rails builds template prefixes from the controller and its superclasses, so
Decidim's own verification templates are never among them: there is nothing to
fall back on, and each template has to be a complete page.

## Step 7. Multistep: run `AuthorizeUser` after the proof is confirmed

Rather than reimplementing session recovery, record transfer and terms of
service persistence, call the command that already does all three from the
second step, with a handler built from the record:

```ruby
confirmed = false
Decidim::Verifications::ConfirmUserAuthorization.call(authorization, form, session) do
  on(:ok) { confirmed = true }
  on(:already_confirmed) { confirmed = true }
  on(:invalid) { confirmed = false }
end

resolve_duplicates if confirmed
```

**Only after the proof is confirmed.** What the user submits in the last form
is the evidence that this participant really holds the identity; resolving
duplicates before checking it would hand a stranger's session, and their vote,
to an attacker who can't provide the final proof.

**Capture the result, act outside the block.** A command's `on` callbacks run
inside its own `rescue StandardError`, so an exception raised while resolving
duplicates is swallowed and reported to the participant as a failed
confirmation.

**Tolerate duplicates in all steps, arbitrate at the end.** Override `unique?`
to return true in all handlers (forms) except for the final `TransferHandler`.
`AuthorizationHandler#uniqueness` refuses a second authorization of the same
kind for the same identity — correct for registered accounts, wrong here,
because the ephemeral account is soft-deleted after one action but the granted
authorization survives. A returning participant otherwise collides with their
*own* earlier proof. Two authorizations transiently sharing a `unique_id` is
legal (the index is not unique) and unambiguous. Delete the redundant record
afterwards, or a third visit finds two candidates.

```ruby
handler = TransferHandler.from_authorization(authorization)
authorization.destroy! unless handler.unique?

Decidim::Verifications::AuthorizeUser.call(handler, current_organization) do
  on(:ok) { finish }
  on(:transferred) { |transfer| finish(transferred_message(transfer)) }
  on(:transfer_user) { |authorized_user| recover_session(authorized_user) }
  on(:invalid) { … }
end
```

Those four branches are the outcomes from part I, and each one leaves the
controller something different to do:

- **`:ok`** — nobody else holds this identity. The terms of service acceptance
  is recorded if the participant is ephemeral, the authorization is created or
  refreshed, and the flow is simply finished.
- **`:transfer_user`** — the identity is already held by an *ephemeral*
  participant, and so is this one: the earlier participant is the same person
  coming back. The command re-grants on that earlier user and yields them, and
  the controller has to sign them in — that yield *is* the session recovery,
  and nothing recovers if it is ignored.
- **`:transferred`** — the identity is held by an ephemeral or soft-deleted
  participant while this one is a registered account, so the authorization
  moves here. It yields a `Decidim::AuthorizationTransfer`, whose `records` are
  the contributions that came with it — worth telling the participant about,
  since a vote or a comment they made anonymously is now on their account.
- **`:invalid`** — nothing was granted. Either the handler failed validation, or
  an ephemeral participant never accepted the terms of service, or the transfer
  was refused. In the validation and refusal cases Decidim also records a
  `Decidim::Verifications::Conflict` and notifies the organization's admins, so
  the participant needs an explanation rather than a retry loop.

**Destroy the freshly granted record before transferring.** A participant may
hold only one authorization per workflow, and `AuthorizationTransfer.perform!`
moves the *other* participant's record onto this user, so the record just
granted has to make way. Build the handler first — it carries everything from
that record that matters — and keep the destroy and the command together, so
a failure cannot leave the participant verified nowhere.

## Step 8. Multistep: keep the flow allowlisted

The moment step one saves an ungranted authorization, the sandbox around an
ephemeral session stops permitting the workflow's own paths. Whether this is
intended behaviour or a Decidm bug, the solution typically employed is to
write the engine's root into the path prefix the sandbox allowlists in every
state:

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

**Clear that key on every exit** — success, transfer, recovered session,
unresolvable conflict. On a recovered session, clear it on the recovered user
too: they carry their own onboarding data from the earlier session.

**All but the last steps have to resume rather than refuse** — once an ungranted
authorization exists `:create` is denied by `not_already_active?`, so a second tab,
a reload or a bookmarked URL raises `ActionForbidden` and lands in the same loop.
Have `new` redirect to `resume_authorization_path` when a pending record exists.

## Step 9. Add the security limits Decidim does not

The ephemeral flow removes the account barrier, so everything an account used to
imply — a confirmed email, an attributable request, a rate limit with a subject
— stops being true. Assume an unauthenticated visitor attempts the verification
in a loop. Decidim's only brake is a generic per-IP `Rack::Attack.throttle` of
100 requests a minute, which is trivially distributed, so whatever the
verification must not allow in bulk has to be limited by the workflow itself —
**on the authorization record**, never in the session.

**Whatever the handler does, it does for anyone.** If validation is what
triggers the out-of-band work — a message, a metered API call, a letter — then
it runs for every submission, whoever sent it. So it is worth knowing what one
attempt costs, and telling integrators which action deserves a `Rack::Attack`
rule of its own.

**Guessing at other people's identities is not throttled at all.** With no
account to hold on to, nothing stands between a visitor and iterating over
identifiers — document numbers, phone numbers — except the handler's own
validation. Where the underlying source will confirm that an identifier exists,
that is an oracle worth rate limiting per identity, not only per IP.

A multistep flow has two more exposures, because it leaves a record and a
secret lying around between the steps:

- **The secret can be ground down.** `ConfirmUserAuthorization` counts failures
  in `session[:failed_attempts]`, and with Decidim's **cookie** session store
  this makes it client-held outright. Count attempts in `verification_metadata`
  instead, and destroy the record once the count is exceeded, so that a fresh
  challenge is required.
- **The pending record does not expire.** Decidim stores a timestamp alongside
  the proof but then ignores it. Reject anything older than a few minutes
  yourself.

Also cap the restart path: `destroy` followed by a fresh `create` re-issues the
challenge, so measure a cooldown, and a ceiling per identity, against the time
the last one was issued.

All of this matters more for an ephemeral workflow than for the account-bound
verification it may be modelled on, because impersonation attacks are more
easily possible with the session recovery and record transfer mechanisms.

## Step 10. Translations, tasks, and switching it on

Add `decidim.authorization_handlers.<name>.name` — without it the workflow
shows up as a humanised key — plus `.explanation` for the sentence
participants read before starting, `.fields.<attribute>` for the labels of a
custom form partial, and `decidim.authorization_handlers.admin.<name>.help`
for the admin's permissions form. Validation messages come from
`activemodel.attributes.<handler_name>.<attribute>` like any other Rails
form. A multistep workflow additionally owns every title, button and flash
string of its own controller and templates, under a scope of its own
choosing.

Ship a `decidim:verifications:revoke:<name>` rake task. The auto-generated one
never materialises, because rake files load before the initializers that
register workflows (decidim#16546).

Finally, a registered workflow does nothing until an administrator sets two
independent switches, and both are required: the workflow has to be ticked per
organization in the **/system panel** under *Available authorizations*, and
then required per action, in the component's (or resource's) permissions. The
two are intersected, so skipping the system-panel step silently drops the
workflow *and* discards the per-action selection.

> :warning: Saving that permissions form — adding the workflow to an action, or
> changing its options — revokes every granted authorization of that name
> across the whole organization: `UpdateComponentPermissions` calls
> `RevokeByNameAuthorizations` on purpose.

## What a test suite can and cannot cover

Part I is a set of statements about Decidim, and a workflow's specs exercise
them rather than assert them. Checksumming the upstream files they live in
cannot verify an assumption still holds, but it does guarantee that a change to
where one lives fails a test instead of passing silently. Track a file if and
only if a documented assumption depends on it. In this module that guard is
`spec/lib/overrides_spec.rb`, and the upgrade procedure that acts on it is
`.agents/skills/upgrading-decidim/SKILL.md`.

## Checklist

1. Pick a workflow name that cannot collide, and never change it once
   authorizations exist.
2. Register from a Rails engine `initializer`.
3. Set `ephemeral = true`, and `renewable = false` unless re-verifying is both
   wanted and harmless.
4. Write the handler: `handler_name` equal to the workflow name, a stable and
   hashed `unique_id`, and `metadata` keys named after the options an admin may
   gate the action on — or a custom action authorizer, if the comparison is not
   an equality.
5. Multistep: declare `edit_authorization_path` (and, if renewable,
   `renew_authorization_path` plus the `Renewable` concern in the controller),
   and keep every route under the engine's mount point.
6. Multistep: write the five (or more, depending on your steps) controller 
   actions on top of `PerformAuthorizationStep` and `ConfirmUserAuthorization`,
   guarded by the `:create` / `:update` / ... authorization permissions.
7. Multistep: tolerate duplicates in initial steps; run `AuthorizeUser` in
   the final step, only after the proof is confirmed.
8. Multistep: set `onboarding.authorization_path` on entry, clear it on every
   exit, and resume instead of refusing when a pending record exists.
9. Know what one attempt costs, and rate limit per identity rather than per IP.
   Multistep: expire the pending proof, cap the attempts against it and cool
   down re-issues, all on the record.
10. Add the i18n keys and the revoke rake task.
11. Enable it in both places: the system panel's *Available authorizations* and
    the component's action permissions.

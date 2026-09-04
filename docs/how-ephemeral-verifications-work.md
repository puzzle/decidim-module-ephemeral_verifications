# How ephemeral verifications work in Decidim

Decidim 0.31 lets a participant verify themselves and complete one action
without registering. The [decidim documentation][docs] describes the feature as
if it could be switched on in the system panel; it cannot. Decidim ships the
machinery and no concrete verification method, so every installation that wants
this has to supply one in code.

This document describes what Decidim does, conceptually. To build a workflow of
your own, read
[writing-an-ephemeral-verification.md](writing-an-ephemeral-verification.md)
afterwards. Both are verifiable against Decidim 0.31.

[docs]: https://docs.decidim.org/en/v0.31/admin/participants/authorizations/ephemeral_verifications#_configuration

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

4. **The proof.** The workflow's own business, and the subject of
   [writing-an-ephemeral-verification.md](writing-an-ephemeral-verification.md).
   It ends with an authorization granted.
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
(see steps 3 and 7 of
[writing-an-ephemeral-verification.md](writing-an-ephemeral-verification.md)).

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
is allowlisted in every state (see step 8 of
[writing-an-ephemeral-verification.md](writing-an-ephemeral-verification.md)).
This way our verification
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


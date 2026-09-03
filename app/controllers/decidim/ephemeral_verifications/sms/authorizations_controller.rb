# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # Adapted from `Decidim::Verifications::Sms::AuthorizationsController`.
      #
      # The differences from upstream are: the i18n scope, the workflow name,
      # remembering the authorization path (see `remember_authorization_path`)
      # and resolving duplicates once the code is confirmed (see
      # `resolve_duplicates`).
      class AuthorizationsController < Decidim::Verifications::ApplicationController
        I18N_SCOPE = "decidim.ephemeral_verifications.sms"

        # A code is worthless to an attacker who cannot use it before it dies,
        # and cheap to grind if they can try forever. Both limits are enforced
        # on the authorization record, not in the session.
        CODE_VALID_FOR = 10.minutes
        MAX_ATTEMPTS = 5
        RESEND_COOLDOWN = 1.minute

        include Decidim::Verifications::Renewable
        include Decidim::HtmlSafeFlash

        before_action :remember_authorization_path

        helper_method :authorization

        def new
          # Resume rather than refuse. Once step one has saved an ungranted
          # authorization, `:create` is denied by `not_already_active?`, so a
          # second tab, a reload or a bookmarked URL would raise
          # ActionForbidden, bounce to the root, and be sent straight back here
          # by EphemeralSessionChecker — an infinite loop.
          return redirect_to adapter.resume_authorization_path(redirect_url:) if pending_authorization?

          enforce_permission_to(:create, :authorization, authorization:)

          @form = MobilePhoneForm.new(user: current_user)
        end

        def create
          enforce_permission_to(:create, :authorization, authorization:)

          return redirect_to(adapter.resume_authorization_path(redirect_url:), alert: t("authorizations.create.too_soon", scope: I18N_SCOPE)) if resend_too_soon?

          # `user:` goes in `additional_params`, which `from_params` merges
          # last. Passing it inside `params` lets a crafted `mobile_phone[user]`
          # displace `current_user` and forge the terms-of-service gate.
          @form = MobilePhoneForm.from_params(params, user: current_user)

          Decidim::Verifications::PerformAuthorizationStep.call(authorization, @form) do
            on(:ok) do
              flash[:notice] = t("authorizations.create.success", scope: I18N_SCOPE)
              redirect_to adapter.resume_authorization_path(redirect_url:)
            end

            on(:invalid) do
              flash.now[:alert] = t("authorizations.create.error", scope: I18N_SCOPE)
              render :new, status: :unprocessable_entity
            end
          end
        end

        def edit
          # Nothing to confirm — the code was never requested, or it expired and
          # was destroyed. Without this, a stray confirmation would persist a
          # fresh empty authorization on the way to failing.
          return redirect_to adapter.root_path(redirect_url:) unless pending_authorization?

          enforce_permission_to(:update, :authorization, authorization:)

          @form = confirmation_form
        end

        def update
          # Nothing to confirm — the code was never requested, or it expired and
          # was destroyed. Without this, a stray confirmation would persist a
          # fresh empty authorization on the way to failing.
          return redirect_to adapter.root_path(redirect_url:) unless pending_authorization?

          enforce_permission_to(:update, :authorization, authorization:)

          @form = confirmation_form

          # Upstream counts failures in `session[:failed_attempts]`, and Decidim
          # runs the cookie session store, so that counter is held by the client
          # and a replayed cookie resets it. It also never checks `code_sent_at`.
          # Both have to be enforced on the record instead.
          return expire_code! if code_expired? || too_many_attempts?

          # Reuses upstream's code comparison along with its
          # MAX_FAILED_ATTEMPTS throttling. It grants the authorization, which
          # is why duplicates are resolved afterwards.
          #
          # Note the result is captured rather than acted on inside the block:
          # those callbacks run inside the command's own `rescue StandardError`,
          # so anything raised while resolving duplicates would be swallowed and
          # reported to the participant as a wrong code.
          confirmed = false
          Decidim::Verifications::ConfirmUserAuthorization.call(authorization, @form, session) do
            on(:ok) { confirmed = true }
            on(:already_confirmed) { confirmed = true }
            on(:invalid) { confirmed = false }
          end

          return resolve_duplicates if confirmed

          # Reaching the attempt cap kills the code and responds itself.
          return if record_failed_attempt!

          flash.now[:alert] = t("authorizations.update.error", scope: I18N_SCOPE)
          render :edit, status: :unprocessable_entity
        end

        def destroy
          enforce_permission_to(:destroy, :authorization, authorization:)

          # This is the resend path — `create` is forbidden while a record is
          # pending, so a resend loop runs through here and would otherwise
          # wipe the `code_sent_at` the cooldown is measured against.
          return redirect_to(adapter.resume_authorization_path(redirect_url:), alert: t("authorizations.create.too_soon", scope: I18N_SCOPE)) if resend_too_soon?

          authorization.destroy!
          flash[:notice] = t("authorizations.destroy.success", scope: I18N_SCOPE)

          redirect_to action: :new
        end

        private

        def authorization
          @authorization ||= Decidim::Authorization.find_or_initialize_by(
            user: current_user,
            name: WORKFLOW_NAME
          )
        end

        def adapter
          @adapter ||= Decidim::Verifications::Adapter.from_element(WORKFLOW_NAME)
        end

        def pending_authorization?
          authorization.persisted? && !authorization.granted?
        end

        # Sending an SMS costs money and reaches a third party who did not ask
        # for it, and `destroy` followed by `create` is a resend loop the edit
        # view offers as a link.
        def resend_too_soon?
          return false unless pending_authorization?

          sent_at = authorization.verification_metadata["code_sent_at"]
          return false if sent_at.blank?

          Time.zone.parse(sent_at.to_s) > RESEND_COOLDOWN.ago
        rescue ArgumentError, TypeError
          false
        end

        def code_expired?
          sent_at = authorization.verification_metadata["code_sent_at"]
          return false if sent_at.blank?

          Time.zone.parse(sent_at.to_s) < CODE_VALID_FOR.ago
        rescue ArgumentError, TypeError
          false
        end

        def failed_attempts
          authorization.verification_metadata["failed_attempts"].to_i
        end

        def too_many_attempts?
          failed_attempts >= MAX_ATTEMPTS
        end

        # Returns true when the cap was reached, in which case it has already
        # destroyed the code and issued the response.
        def record_failed_attempt!
          attempts = failed_attempts + 1

          if attempts >= MAX_ATTEMPTS
            expire_code!
            return true
          end

          authorization.update!(
            verification_metadata: authorization.verification_metadata.merge("failed_attempts" => attempts)
          )
          false
        end

        # Destroying the record is what makes the limits bite: the participant
        # has to request a fresh code, which is rate limited in turn.
        def expire_code!
          authorization.destroy!
          forget_authorization_path(current_user)

          flash[:alert] = t("authorizations.update.expired", scope: I18N_SCOPE)
          redirect_to adapter.root_path(redirect_url:)
        end

        # An ephemeral participant may only be sent somewhere the session
        # checker allowlists; `authorizations_path` is not on that list.
        def after_failure_path
          return decidim_verifications.onboarding_pending_authorizations_path if current_user.ephemeral?

          decidim_verifications.authorizations_path
        end

        # Upstream's confirmation form is reused as is: it holds nothing but
        # the code, and it is deliberately built without a user so the
        # inherited terms of service validation stays out of the way.
        def confirmation_form
          Decidim::Verifications::Sms::ConfirmationForm.from_params(params.slice(:confirmation))
        end

        # Without this an ephemeral participant deadlocks between the two
        # steps. `EphemeralSessionChecker` allowlists the workflow's own paths
        # only while no authorization record exists; as soon as step one saves
        # an ungranted one the status becomes `:pending`, the allowlist
        # collapses to the onboarding page, and that page redirects straight
        # back here. Pointing `onboarding.authorization_path` at this engine's
        # root makes it a permitted prefix in every state and sends any bounce
        # back into this flow. `Decidim::Initiatives` does the same for its
        # multistep ephemeral signature flow.
        def remember_authorization_path
          return unless current_user&.ephemeral?

          root = decidim_ephemeral_sms.root_path
          return if onboarding_manager.authorization_path == root

          current_user.update(
            extended_data: current_user.extended_data.deep_merge(
              Decidim::OnboardingManager::DATA_KEY => { "authorization_path" => root }
            )
          )
        end

        # ...and it has to be given back once the authorization is granted, or
        # the participant deadlocks again on the way out. `:create` requires
        # `not_already_active?` and `:update` requires `!granted?`, so both of
        # this engine's steps stop being permitted the moment verification
        # succeeds. Every request would then be bounced here, forbidden,
        # redirected to the root, and bounced here again.
        #
        # Clearing the key restores the default, `onboarding_pending`, which is
        # always allowlisted and which forwards to the intended action.
        # `Decidim::Initiatives#clear_authorization_path` does the same.
        def forget_authorization_path(user)
          return unless user&.ephemeral?

          onboarding = user.extended_data[Decidim::OnboardingManager::DATA_KEY]
          return if onboarding.blank? || onboarding["authorization_path"].blank?

          user.update(
            extended_data: user.extended_data.merge(
              Decidim::OnboardingManager::DATA_KEY => onboarding.except("authorization_path")
            )
          )
        end

        # The multistep path never reaches `Decidim::Verifications::AuthorizeUser`,
        # so on its own it implements none of the ephemeral behaviour. Running
        # it here, and only after the code has been confirmed, restores all of
        # it without reimplementing any of it.
        def resolve_duplicates
          handler = TransferHandler.from_authorization(authorization)

          # When another participant holds an authorization for this same phone
          # number, `AuthorizeUser` resolves it by moving a record onto one of
          # the two users. `[decidim_user_id, name]` is unique, so the record
          # just granted has to make way first; the handler above already
          # carries everything from it that matters.
          # One transaction: `AuthorizeUser` can still fail after the destroy
          # (transfers disabled, the duplicate vanishing, a missing terms
          # acceptance), and a half-applied resolution leaves the participant
          # verified nowhere.
          ActiveRecord::Base.transaction do
            authorization.destroy! unless handler.unique?
          end

          Decidim::Verifications::AuthorizeUser.call(handler, current_organization) do
            on(:ok) { finish }

            on(:transferred) { |transfer| finish(transferred_message(transfer)) }

            on(:transfer_user) { |authorized_user| recover_session(authorized_user) }

            on(:invalid) do
              # Without this the participant is stranded: the stored
              # authorization path still points here, but every action is now
              # forbidden, so they bounce between this engine and the root.
              forget_authorization_path(current_user)

              flash[:alert] = t("authorizations.update.conflict", scope: I18N_SCOPE)
              redirect_to after_failure_path
            end
          end
        end

        def finish(message = nil)
          forget_authorization_path(current_user)

          flash[:notice] = message || t("authorizations.update.success", scope: I18N_SCOPE)
          redirect_to redirect_url || decidim_verifications.authorizations_path
        end

        # The participant already had an ephemeral session for this phone
        # number, so hand them back the earlier one together with whatever
        # they did in it.
        def recover_session(authorized_user)
          # ponytail: the abandoned ephemeral user record is left behind, exactly
          # as upstream's direct controller leaves it. Its authorization is
          # already gone, dropped in `resolve_duplicates`.
          abandoned = current_user

          authorized_user.update(last_sign_in_at: Time.current, deleted_at: nil)
          # The recovered participant carries their own onboarding data from the
          # earlier session, which may still point here.
          forget_authorization_path(authorized_user)

          sign_out(abandoned)
          sign_in(authorized_user)

          redirect_to decidim_verifications.onboarding_pending_authorizations_path
        end

        def transferred_message(transfer)
          message = t("authorizations.update.success", scope: I18N_SCOPE)
          return message if transfer.records.none?

          flash[:html_safe] = true
          <<~HTML
            <p>#{CGI.escapeHTML(message)}</p>
            <p>#{CGI.escapeHTML(t("authorizations.update.transferred", scope: I18N_SCOPE))}</p>
            #{transfer.presenter.records_list_html}
          HTML
        end
      end
    end
  end
end

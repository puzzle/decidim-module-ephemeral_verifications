# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # Adapted from `Decidim::Verifications::Sms::AuthorizationsController`.
      # `spec/lib/overrides_spec.rb` fails when that upstream file changes, so
      # the divergence cannot go unnoticed across a Decidim upgrade.
      #
      # The differences from upstream are: the i18n scope, the workflow name,
      # remembering the authorization path (see `remember_authorization_path`)
      # and resolving duplicates once the code is confirmed (see
      # `resolve_duplicates`).
      class AuthorizationsController < Decidim::Verifications::ApplicationController
        I18N_SCOPE = "decidim.ephemeral_verifications.sms"

        include Decidim::Verifications::Renewable
        include Decidim::HtmlSafeFlash

        # This engine isolates its own namespace, so helpers from the core and
        # verifications engines are not included automatically.
        helper Decidim::Verifications::ApplicationHelper
        helper Decidim::DecidimFormHelper
        helper Decidim::TranslationsHelper
        helper Decidim::LayoutHelper

        before_action :remember_authorization_path

        helper_method :authorization

        def new
          enforce_permission_to(:create, :authorization, authorization:)

          @form = MobilePhoneForm.new(user: current_user)
        end

        def create
          enforce_permission_to(:create, :authorization, authorization:)

          @form = MobilePhoneForm.from_params(params.merge(user: current_user))

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
          enforce_permission_to(:update, :authorization, authorization:)

          @form = confirmation_form
        end

        def update
          enforce_permission_to(:update, :authorization, authorization:)

          @form = confirmation_form

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

          flash.now[:alert] = t("authorizations.update.error", scope: I18N_SCOPE)
          render :edit, status: :unprocessable_entity
        end

        def destroy
          enforce_permission_to(:destroy, :authorization, authorization:)

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

        # Upstream's confirmation form is reused as is: it holds nothing but
        # the code, and it is deliberately built without a user so the
        # inherited terms of service validation stays out of the way.
        def confirmation_form
          Decidim::Verifications::Sms::ConfirmationForm.from_params(params)
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
          authorization.destroy! unless handler.unique?

          Decidim::Verifications::AuthorizeUser.call(handler, current_organization) do
            on(:ok) { finish }

            on(:transferred) { |transfer| finish(transferred_message(transfer)) }

            on(:transfer_user) { |authorized_user| recover_session(authorized_user) }

            on(:invalid) do
              flash[:alert] = t("authorizations.update.conflict", scope: I18N_SCOPE)
              redirect_to decidim_verifications.authorizations_path
            end
          end
        end

        def finish(message = nil)
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

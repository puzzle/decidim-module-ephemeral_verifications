# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # Step one of the flow: the participant gives a phone number and confirms
      # that they are eligible to take part.
      #
      # Inherits the core SMS form, so the code generation, the gateway call
      # (including the `{ organization: }` context) and the phone number
      # sanitisation all stay upstream's problem.
      class MobilePhoneForm < Decidim::Verifications::Sms::MobilePhoneForm
        attribute :eligible_confirmation, Boolean

        validates :eligible_confirmation, allow_nil: false, acceptance: true

        def handler_name
          WORKFLOW_NAME
        end

        # Persisted so step two can tell that the terms of service were
        # accepted, and so an administrator can later see that eligibility was
        # confirmed. `Decidim::Authorization` encrypts this column.
        def metadata
          super.merge(
            "tos_agreement" => tos_agreement.present?,
            "eligible_confirmation" => eligible_confirmation.present?
          )
        end

        # Deliberately permissive: a returning participant legitimately has an
        # authorization with this same `unique_id` from an earlier ephemeral
        # session, and `AuthorizationHandler#uniqueness` would reject them here
        # with a generic error and no way forward.
        #
        # Duplicates are instead resolved in the controller's `update` action,
        # once the SMS code has proven that this participant owns the phone
        # number. Resolving them here would mean handing someone else's session
        # to anyone who types their number.
        def unique?
          true
        end

        private

        # Reading `verification_code` is what actually sends the SMS (see the
        # parent class), and the parent declares its presence validation before
        # ours run, so without this an unticked checkbox would still cost a
        # real message. The conditions are checked directly rather than through
        # `errors`, because validation order would make that unreliable.
        def verification_code
          return if missing_prerequisites?

          super
        end

        def missing_prerequisites?
          return true if mobile_phone_number.blank?
          return true unless eligible_confirmation
          return true if ephemeral_tos_pending? && !tos_agreement

          false
        end
      end
    end
  end
end

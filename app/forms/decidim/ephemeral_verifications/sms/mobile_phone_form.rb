# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # Step one of the flow: the participant gives a phone number and confirms
      # that they are eligible to take part.
      #
      # Inherits the core SMS form, so the code generation, the gateway call
      # (including the `{ organization: }` context) and the `unique_id` formula
      # all stay upstream's problem. What it adds on top is normalisation: the
      # number is reduced to E.164 before upstream hashes it, see `PhoneNumber`.
      class MobilePhoneForm < Decidim::Verifications::Sms::MobilePhoneForm
        attribute :eligible_confirmation, Boolean

        validates :eligible_confirmation, allow_nil: false, acceptance: true
        validate :mobile_phone_number_is_a_mobile_number

        def handler_name
          WORKFLOW_NAME
        end

        # The canonical spelling, which is what upstream hashes into the
        # `unique_id` and hands to the gateway. Falls back to upstream's
        # sanitised string when the number does not parse, so that the presence
        # validation keeps reporting a blank field as blank and our own
        # validation can report the rest.
        def mobile_phone_number
          phone_number&.canonical || super
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

        # Parsed from the value as typed, not from upstream's sanitised string:
        # that one has already lost the parentheses that make "+41 (0)79 ..."
        # unambiguous.
        def phone_number
          raw = attributes["mobile_phone_number"]
          return if raw.blank?
          return @phone_number if defined?(@phone_number) && @phone_number_raw == raw

          @phone_number_raw = raw
          @phone_number = PhoneNumber.parse(raw)
        end

        def mobile_phone_number_is_a_mobile_number
          return if attributes["mobile_phone_number"].blank?
          return if phone_number.mobile?

          errors.add(:mobile_phone_number, :invalid, message: I18n.t("decidim.ephemeral_verifications.sms.mobile_phone.not_a_mobile_number"))
        end

        # Reading `verification_code` is what actually sends the SMS (see the
        # parent class), and the parent declares its presence validation before
        # ours run, so without this an unticked checkbox or a number that is
        # not a mobile phone would still cost a real message. The conditions
        # are checked directly rather than through `errors`, because validation
        # order would make that unreliable.
        def verification_code
          return if missing_prerequisites?

          super
        end

        def missing_prerequisites?
          return true unless phone_number&.mobile?
          return true unless eligible_confirmation
          return true if ephemeral_tos_pending? && !tos_agreement

          false
        end
      end
    end
  end
end

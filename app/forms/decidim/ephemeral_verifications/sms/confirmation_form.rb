# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # Step two of the flow: the code the participant received by SMS.
      #
      # Inherits the core SMS confirmation form, which carries nothing but the
      # code and exposes it through `verification_metadata` for
      # `ConfirmUserAuthorization` to compare against the stored value.
      #
      # Declared here rather than pointing the controller at the parent
      # directly, so that this workflow owns both of its form objects: the
      # parent is free to grow a field or a validation that only makes sense for
      # a registered participant, and this is the seam where that would be
      # overridden.
      class ConfirmationForm < Decidim::Verifications::Sms::ConfirmationForm
        # The parent does not set this, so it would otherwise default to
        # "confirmation_form" — a name no workflow is registered under.
        def handler_name
          WORKFLOW_NAME
        end
      end
    end
  end
end

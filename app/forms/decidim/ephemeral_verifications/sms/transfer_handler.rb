# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # A value object handed to `Decidim::Verifications::AuthorizeUser` once
      # the SMS code has been confirmed, so that command can apply the
      # ephemeral behaviour the multistep path skips: persisting the terms of
      # service acceptance, recovering an earlier ephemeral session with the
      # same phone number, and transferring an ephemeral authorization to a
      # registered account.
      #
      # It carries the values already persisted in step one rather than the
      # phone number itself, so instantiating it can never trigger another SMS.
      class TransferHandler < Decidim::AuthorizationHandler
        attribute :unique_id, String
        attribute :metadata, Hash, default: {}

        validates :unique_id, presence: true

        def handler_name
          WORKFLOW_NAME
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
    end
  end
end

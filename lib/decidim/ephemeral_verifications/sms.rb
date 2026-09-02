# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    module Sms
      # The name this verification workflow is registered under.
      #
      # It is simultaneously the mount path (`/ephemeral_sms/...`), the route
      # proxy name (`decidim_ephemeral_sms`, resolved by
      # `Decidim::Verifications::Adapter#main_engine` via
      # `send("decidim_#{name}")`), the value stored in
      # `decidim_authorizations.name`, and the root of the workflow's i18n
      # keys. Changing it after authorizations exist makes those rows
      # unsaveable, because `Decidim::Authorization` validates that a workflow
      # of that name is registered.
      WORKFLOW_NAME = "ephemeral_sms"
    end
  end
end

require "decidim/ephemeral_verifications/sms/engine"

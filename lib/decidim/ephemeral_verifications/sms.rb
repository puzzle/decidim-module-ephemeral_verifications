# frozen_string_literal: true

require "phonelib"

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

      # The country a phone number typed without a country code belongs to, as
      # an ISO 3166-1 alpha-2 code ("CH"). Set it from a host application
      # initializer:
      #
      #   Decidim::EphemeralVerifications::Sms.default_country = "CH"
      #
      # Optional. Left unset, phonelib's own `default_country` applies, and
      # without that too only international spellings ("+41 79 ...") are
      # accepted — the safe default for a gem that knows nothing about the
      # installation. It is read per request, so the order in which
      # initializers run does not matter.
      mattr_accessor :default_country, default: nil
    end
  end
end

require "decidim/ephemeral_verifications/sms/engine"

# frozen_string_literal: true

require "decidim/core"
require "decidim/verifications"

module Decidim
  module EphemeralVerifications
    module Sms
      # Two-step SMS verification that participants can complete without an
      # account. See docs/writing-an-ephemeral-verification.md for how the
      # surrounding Decidim machinery works.
      class Engine < ::Rails::Engine
        isolate_namespace Decidim::EphemeralVerifications::Sms

        # `Decidim::Verifications::Adapter` looks up `edit_authorization_path`
        # and `renew_authorization_path` by name (with `respond_to?`) and
        # raises `MissingVerificationRoute` when they are absent. A singular
        # `resource` declared `as: :authorization` is what produces exactly
        # those helper names.
        routes do
          resource :authorizations, only: [:new, :create, :edit, :update, :destroy], as: :authorization do
            get :renew, on: :collection
          end

          root to: "authorizations#new"
        end

        # Unlike the core SMS engine, this deliberately does not guard on
        # `Decidim.sms_gateway_service`. Engine initializers run before the
        # host application's config/initializers (the application is ordered
        # last in `Rails::Application#railties_initializers`), so a gateway
        # configured there is not visible yet at this point. The gateway is
        # only needed when a code is actually delivered.
        initializer "decidim_ephemeral_verifications_sms.workflow" do
          Decidim::Verifications.register_workflow(WORKFLOW_NAME) do |workflow|
            workflow.ephemeral = true
            workflow.engine = Decidim::EphemeralVerifications::Sms::Engine
            workflow.icon = "message-3-line"
          end
        end
      end
    end
  end
end

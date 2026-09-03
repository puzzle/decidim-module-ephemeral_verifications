# frozen_string_literal: true

require "spec_helper"

describe "Ephemeral SMS verification when creating a proposal" do
  include_context "with a component"

  let(:manifest_name) { "proposals" }
  let!(:organization) { create(:organization, available_authorizations: %w(ephemeral_sms)) }
  let!(:component) do
    create(
      :proposal_component,
      :with_creation_enabled,
      manifest:,
      participatory_space:,
      permissions: {
        create: { "authorization_handlers" => { "ephemeral_sms" => {} } }
      }
    )
  end

  let(:action_button) { "New proposal" }
  let(:success_content) { "Create new proposal" }

  it_behaves_like "an ephemeral SMS verified action"

  context "when the participant comes back with the same phone number" do
    let(:phone) { "+41791234567" }

    # Granting clears `verification_metadata`, so the record holding a code is
    # always the ungranted one — which matters on the second pass, where the
    # earlier granted authorization is still around.
    def pending_code
      Decidim::Authorization
        .where(name: "ephemeral_sms", granted_at: nil)
        .order(:id).last
        .verification_metadata["verification_code"]
    end

    it "recovers the earlier session together with the draft" do
      switch_to_host(organization.host)
      visit main_component_path(component)

      click_on action_button
      fill_in :mobile_phone_mobile_phone_number, with: phone
      check :mobile_phone_eligible_confirmation
      check :mobile_phone_tos_agreement
      click_on "Send me an SMS"
      expect(page).to have_current_path(%r{/authorizations/edit}, url: true, ignore_query: true)
      expect(page).to have_content("Introduce the verification code you received")
      fill_in :confirmation_verification_code, with: pending_code
      click_on "Confirm"

      fill_in :proposal_title, with: "A proposal from a guest"
      fill_in :proposal_body, with: "With enough body text to satisfy the validations."
      click_on "Continue"

      expect(page).to have_content("Proposal successfully created")

      # Closing the ephemeral session signs the participant out and navigates,
      # which replaces the document. Anchor on the new page before touching it
      # again, or a query still resolving nodes from the old one fails with
      # "Node with given id does not belong to the document".
      accept_confirm { find("#main-bar [data-close]").click }
      expect(page).to have_no_css("#main-bar [data-close]")

      visit main_component_path(component)
      click_on action_button
      fill_in :mobile_phone_mobile_phone_number, with: phone
      check :mobile_phone_eligible_confirmation
      # A fresh ephemeral user, so the terms of service are pending again.
      check :mobile_phone_tos_agreement
      click_on "Send me an SMS"
      expect(page).to have_current_path(%r{/authorizations/edit}, url: true, ignore_query: true)
      expect(page).to have_content("Introduce the verification code you received")
      fill_in :confirmation_verification_code, with: pending_code
      click_on "Confirm"

      expect(page).to have_content("Edit proposal draft")
      expect(page).to have_field(:proposal_title, with: "A proposal from a guest")
    end
  end
end

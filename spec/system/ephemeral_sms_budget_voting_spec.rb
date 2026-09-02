# frozen_string_literal: true

require "spec_helper"

# The participatory budget vote is what the workflow was built for, and upstream
# has no ephemeral coverage for budgets at all.
describe "Ephemeral SMS verification when voting on a budget project" do
  include_context "with a component"

  let(:manifest_name) { "budgets" }
  let!(:organization) { create(:organization, available_authorizations: %w(ephemeral_sms)) }
  let!(:component) do
    create(
      :budgets_component,
      manifest:,
      participatory_space:,
      settings: { vote_rule_threshold_percent_enabled: false, vote_rule_minimum_budget_projects_enabled: false },
      permissions: {
        vote: { "authorization_handlers" => { "ephemeral_sms" => {} } }
      }
    )
  end
  let!(:budget) { create(:budget, component:) }
  let!(:project) { create(:project, budget:, budget_amount: 25_000_000) }

  let(:action_button) { "Add" }
  let(:success_content) { "successfully" }

  before do
    switch_to_host(organization.host)
  end

  it "lets a logged out visitor verify by SMS and vote" do
    visit Decidim::EngineRouter.main_proxy(component).budget_projects_path(budget)

    expect { click_on action_button, match: :first }.to change { Decidim::User.ephemeral.count }.by(1)

    fill_in :mobile_phone_mobile_phone_number, with: "+41791234567"
    check :mobile_phone_eligible_confirmation
    check :mobile_phone_tos_agreement
    click_on "Send me an SMS"

    fill_in :confirmation_verification_code,
            with: Decidim::Authorization.find_by(name: "ephemeral_sms").verification_metadata["verification_code"]
    click_on "Confirm"

    expect(Decidim::Authorization.find_by(name: "ephemeral_sms")).to be_granted

    click_on action_button, match: :first

    expect(Decidim::Budgets::Order.count).to eq(1)
    expect(Decidim::Budgets::Order.last.projects).to contain_exactly(project)
  end
end

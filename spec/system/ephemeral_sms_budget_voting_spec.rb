# frozen_string_literal: true

require "spec_helper"

# The participatory budget vote is what this workflow was built for, and upstream
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
      permissions: {
        vote: { "authorization_handlers" => { "ephemeral_sms" => {} } }
      }
    )
  end
  let!(:budget) { create(:budget, component:, total_budget: 100_000_000) }
  let!(:project) { create(:project, budget:, budget_amount: 80_000_000) }

  let(:phone) { "+41791234567" }
  let(:vote_button) { "#project-vote-button-#{project.id}" }

  def sent_code
    Decidim::Authorization
      .where(name: "ephemeral_sms", granted_at: nil)
      .order(:id).last
      .verification_metadata["verification_code"]
  end

  before do
    switch_to_host(organization.host)
    visit Decidim::EngineRouter.main_proxy(component).budget_projects_path(budget)
  end

  it "lets a logged out visitor verify by SMS and vote" do
    find(vote_button).click

    # Waiting on the page rather than wrapping the click in a `change` matcher,
    # which does not wait for the POST and redirects it triggers.
    expect(page).to have_content("Request your verification code")
    expect(Decidim::User.ephemeral.count).to eq(1)

    fill_in :mobile_phone_mobile_phone_number, with: phone
    check :mobile_phone_eligible_confirmation
    check :mobile_phone_tos_agreement
    click_on "Send me an SMS"

    expect(page).to have_content("Introduce the verification code you received")
    fill_in :confirmation_verification_code, with: sent_code
    click_on "Confirm"

    expect(page).to have_content("You have been successfully authorized")

    authorization = Decidim::Authorization.find_by(name: "ephemeral_sms")
    expect(authorization).to be_granted

    # The end state that matters for this module: the guest may now perform the
    # action the funnel was entered for.
    status = Decidim::ActionAuthorizer.new(authorization.user, "vote", component, project).authorize
    expect(status).to be_ok

    # And the vote itself goes through. The button posts over AJAX, so wait for
    # it to flip before looking at the database.
    find(vote_button).click
    # The button posts over AJAX and the response morphs the project item, so
    # wait for it to flip before looking at the database.
    expect(page).to have_css("#{vote_button}[data-add='false']")

    expect(Decidim::Budgets::Order.count).to eq(1)
    expect(Decidim::Budgets::Order.last.projects).to contain_exactly(project)
  end
end

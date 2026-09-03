# frozen_string_literal: true

# Drives the whole funnel the way a participant does: click the action button
# while logged out, get an ephemeral session, verify by SMS, complete the
# action. Reused per component so the workflow is exercised generically rather
# than only against the one component the pilot happens to use.
#
# Expects `component`, `organization`, `action_button` and `success_content` to
# be defined, plus a `complete_action` step.
shared_examples "an ephemeral SMS verified action" do
  let(:phone) { "+41791234567" }

  # The pending authorization is the one holding a code: granting clears
  # `verification_metadata`, and a returning participant has an older granted
  # record alongside the new one.
  def sent_code
    Decidim::Authorization
      .where(name: "ephemeral_sms", granted_at: nil)
      .order(:id).last
      .verification_metadata["verification_code"]
  end

  def request_the_code
    fill_in :mobile_phone_mobile_phone_number, with: phone
    check :mobile_phone_eligible_confirmation
    check :mobile_phone_tos_agreement
    click_on "Send me an SMS"
  end

  # `sent_code` reads the database, and method arguments are evaluated before
  # `fill_in` gets a chance to wait for anything, so the page has to be settled
  # first or the code is read before the request that generates it has finished.
  def confirm_the_code
    # `have_current_path` polls `current_url` and holds no node references, so
    # it cannot trip over the DOM being replaced. Once the URL has settled the
    # document is stable and a content assertion is safe.
    expect(page).to have_current_path(%r{/authorizations/edit}, url: true, ignore_query: true)
    expect(page).to have_content("Introduce the verification code you received")

    fill_in :confirmation_verification_code, with: sent_code
    click_on "Confirm"
  end

  before do
    switch_to_host(organization.host)
    visit main_component_path(component)
  end

  it "starts an ephemeral session instead of asking for a login" do
    expect(page).to have_no_css("#loginModal", visible: :visible)

    click_on action_button

    # Waiting on the page rather than wrapping the click in a `change` matcher:
    # the click kicks off a POST and a couple of redirects, and the matcher does
    # not wait for them.
    expect(page).to have_content("Request your verification code")
    expect(Decidim::User.ephemeral.count).to eq(1)
  end

  it "verifies by SMS and lets the participant through" do
    click_on action_button

    expect(page).to have_content("Request your verification code")
    request_the_code
    confirm_the_code

    expect(page).to have_content(success_content)
  end

  it "requires the eligibility confirmation" do
    click_on action_button

    fill_in :mobile_phone_mobile_phone_number, with: phone
    check :mobile_phone_tos_agreement
    click_on "Send me an SMS"

    expect(page).to have_content("There was a problem with your request.")
    expect(Decidim::Authorization.count).to eq(0)
  end

  it "requires the terms of service" do
    click_on action_button

    fill_in :mobile_phone_mobile_phone_number, with: phone
    check :mobile_phone_eligible_confirmation
    click_on "Send me an SMS"

    expect(page).to have_content("There was a problem with your request.")
    expect(Decidim::Authorization.count).to eq(0)
  end

  it "rejects a wrong code" do
    click_on action_button
    request_the_code

    expect(page).to have_content("Introduce the verification code you received")
    fill_in :confirmation_verification_code, with: "000000"
    click_on "Confirm"

    expect(page).to have_content("Your verification code does not match ours.")
  end
end

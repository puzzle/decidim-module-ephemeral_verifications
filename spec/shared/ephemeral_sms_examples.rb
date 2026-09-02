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

  def sent_code
    Decidim::Authorization.find_by(name: "ephemeral_sms").verification_metadata["verification_code"]
  end

  def request_the_code
    fill_in :mobile_phone_mobile_phone_number, with: phone
    check :mobile_phone_eligible_confirmation
    check :mobile_phone_tos_agreement
    click_on "Send me an SMS"
  end

  def confirm_the_code
    fill_in :confirmation_verification_code, with: sent_code
    click_on "Confirm"
  end

  before do
    switch_to_host(organization.host)
    visit main_component_path(component)
  end

  it "starts an ephemeral session instead of asking for a login" do
    expect(page).to have_no_css("#loginModal", visible: :visible)

    expect { click_on action_button }.to change { Decidim::User.ephemeral.count }.by(1)
  end

  it "verifies by SMS and lets the participant through" do
    click_on action_button

    expect(page).to have_content("Request your verification code")
    request_the_code

    expect(page).to have_content("Introduce the verification code you received")
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

    fill_in :confirmation_verification_code, with: "000000"
    click_on "Confirm"

    expect(page).to have_content("Your verification code does not match ours.")
  end
end

# frozen_string_literal: true

require "spec_helper"

# These exercise the parts of the flow this module actually owns, without a
# browser: the two steps, the deadlock guard between them, and the duplicate
# resolution that Decidim's multistep path does not provide. The end-to-end
# funnel (button -> onboarding cookie -> ephemeral user) is core's code and is
# covered by the system specs.
describe "Ephemeral SMS authorizations" do
  let(:organization) { create(:organization, available_authorizations: %w(ephemeral_sms)) }
  let(:participatory_space) { create(:participatory_process, :with_steps, organization:) }
  let(:permissions) do
    { create: { "authorization_handlers" => { "ephemeral_sms" => {} } } }
  end
  let!(:component) do
    create(:proposal_component, :with_creation_enabled, participatory_space:, permissions:)
  end

  # A real ephemeral participant is created by `Decidim::CreateEphemeralUser`,
  # which confirms them and leaves `accepted_tos_version` nil. The `:ephemeral`
  # trait alone does neither, and an unconfirmed user is bounced to sign in.
  let(:user) { create(:user, :ephemeral, :confirmed, organization:, accepted_tos_version: nil) }
  let(:phone) { "+41791234567" }

  let(:new_path) { "/ephemeral_sms/authorizations/new" }
  let(:collection_path) { "/ephemeral_sms/authorizations" }
  let(:edit_path) { "/ephemeral_sms/authorizations/edit" }

  let(:authorization) { Decidim::Authorization.find_by(name: "ephemeral_sms", user:) }
  let(:sent_code) { authorization.verification_metadata["verification_code"] }

  def request_code(overrides = {})
    post collection_path, params: {
      mobile_phone: {
        mobile_phone_number: phone,
        eligible_confirmation: "1",
        tos_agreement: "1"
      }.merge(overrides)
    }
  end

  before do
    host! organization.host
    # The intended action, as core's onboarding funnel would have stored it.
    user.update(
      extended_data: user.extended_data.merge(
        "onboarding" => {
          "action" => "create",
          "permissions_holder" => component.to_gid.to_s,
          "redirect_path" => Decidim::EngineRouter.main_proxy(component).root_path
        }
      )
    )
    login_as user, scope: :user
  end

  describe "step one" do
    it "renders the phone number form with both confirmations" do
      get new_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("mobile_phone[mobile_phone_number]")
      expect(response.body).to include("mobile_phone[eligible_confirmation]")
      expect(response.body).to include("mobile_phone[tos_agreement]")
    end

    it "stores an ungranted authorization and moves on to the code" do
      expect { request_code }.to change(Decidim::Authorization, :count).by(1)

      expect(authorization).not_to be_granted
      expect(authorization.unique_id).to be_present
      expect(sent_code).to match(/\A\d{6}\z/)
      expect(response).to redirect_to(%r{/ephemeral_sms/authorizations/edit})
    end

    it "records the intended workflow path so the participant is not bounced later" do
      request_code

      expect(user.reload.extended_data.dig("onboarding", "authorization_path")).to eq("/ephemeral_sms/")
    end

    context "without the eligibility confirmation" do
      it "re-renders the form and stores nothing" do
        expect { request_code(eligible_confirmation: "0") }.not_to change(Decidim::Authorization, :count)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "without the terms of service" do
      it "re-renders the form and stores nothing" do
        expect { request_code(tos_agreement: "0") }.not_to change(Decidim::Authorization, :count)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe "step two" do
    before { request_code }

    # Regression guard: while the authorization is ungranted the action status
    # is :pending, which drops the workflow's own paths out of
    # EphemeralSessionChecker's allowlist. Without the stored
    # authorization_path this redirects to the onboarding page, which redirects
    # straight back here.
    it "is reachable rather than bouncing to the onboarding page" do
      get edit_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("confirmation[verification_code]")
    end

    it "grants the authorization for the right code" do
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      expect(authorization.reload).to be_granted
      expect(response).to have_http_status(:redirect)
    end

    it "records the accepted terms of service on the participant" do
      expect { put collection_path, params: { confirmation: { verification_code: sent_code } } }
        .to change { user.reload.accepted_tos_version }.from(nil)

      expect(user.reload.accepted_tos_version).to be_within(1.second).of(organization.tos_version)
    end

    # The earlier version of this module deadlocked here: the stored
    # authorization_path kept pointing at this engine, but neither of its steps
    # is permitted once the authorization is granted, so every request was
    # bounced here, forbidden, sent to the root, and bounced here again.
    it "settles on a real page instead of looping after verification" do
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      12.times do
        break unless response.status == 302

        follow_redirect!
      end

      expect(response).to have_http_status(:ok)
    end

    it "gives back the authorization path once verified" do
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      expect(user.reload.extended_data.dig("onboarding", "authorization_path")).to be_nil
    end

    it "rejects a wrong code without granting" do
      put collection_path, params: { confirmation: { verification_code: "000000" } }

      expect(authorization.reload).not_to be_granted
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "a returning participant with the same phone number" do
    let(:earlier_user) { create(:user, :ephemeral, :confirmed, organization:) }
    let!(:earlier_authorization) do
      create(
        :authorization,
        :granted,
        user: earlier_user,
        name: "ephemeral_sms",
        unique_id: unique_id_for(phone)
      )
    end

    def unique_id_for(number)
      Decidim::EphemeralVerifications::Sms::MobilePhoneForm
        .from_params(mobile_phone_number: number, user:)
        .unique_id
    end

    it "still accepts the phone number rather than locking them out" do
      expect { request_code }.to change(Decidim::Authorization, :count).by(1)

      expect(response).to redirect_to(%r{/ephemeral_sms/authorizations/edit})
    end

    it "hands the earlier session back once the code is confirmed" do
      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      expect(response).to redirect_to(%r{/authorizations/onboarding_pending})
      expect(earlier_authorization.reload).to be_granted
      expect(earlier_authorization.user).to eq(earlier_user)
    end

    it "leaves exactly one authorization for the phone number" do
      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      expect(Decidim::Authorization.where(name: "ephemeral_sms", unique_id: earlier_authorization.unique_id).count).to eq(1)
    end
  end

  describe "a registered participant verifying a phone number used ephemerally" do
    let(:user) { create(:user, :confirmed, organization:) }
    let(:earlier_user) { create(:user, :ephemeral, :confirmed, organization:) }
    let!(:earlier_authorization) do
      create(
        :authorization,
        :granted,
        user: earlier_user,
        name: "ephemeral_sms",
        unique_id: Decidim::EphemeralVerifications::Sms::MobilePhoneForm
                     .from_params(mobile_phone_number: phone, user:).unique_id
      )
    end

    it "transfers the earlier authorization to the account" do
      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      expect(earlier_authorization.reload.user).to eq(user)
    end
  end
end

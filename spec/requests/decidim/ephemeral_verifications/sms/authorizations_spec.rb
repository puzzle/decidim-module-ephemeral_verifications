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

    # Regression guard: unless the stored authorization_path is cleared, it
    # keeps pointing at this engine, but neither of its steps is permitted once
    # the authorization is granted, so every request is bounced here,
    # forbidden, sent to the root, and bounced here again.
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

  describe "the limits on a code" do
    before { request_code }

    # Decidim decides how long a code lives and how many guesses it gets. A
    # spent code is killed, so the participant has to request a fresh one
    # instead of waiting out a lock.
    it "gives up on the code after repeated wrong guesses" do
      code = sent_code

      4.times { put collection_path, params: { confirmation: { verification_code: "000000" } } }
      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).not_to be_empty

      put collection_path, params: { confirmation: { verification_code: "000000" } }
      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty

      # The real code is worthless now; a fresh one has to be requested.
      put collection_path, params: { confirmation: { verification_code: code } }
      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:, granted_at: nil)).to be_empty
    end

    it "refuses a code that has gone stale" do
      code = sent_code
      travel_to(11.minutes.from_now) do
        put collection_path, params: { confirmation: { verification_code: code } }
      end

      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty
    end

    it "still accepts the code inside the validity window" do
      code = sent_code
      travel_to(9.minutes.from_now) do
        put collection_path, params: { confirmation: { verification_code: code } }
      end

      expect(authorization.reload).to be_granted
    end

    it "takes the number of guesses from Decidim's configuration" do
      allow(Decidim).to receive(:verification_max_failed_attempts).and_return(2)

      put collection_path, params: { confirmation: { verification_code: "000000" } }
      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).not_to be_empty

      put collection_path, params: { confirmation: { verification_code: "000000" } }
      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty
    end

    it "takes the code lifetime from Decidim's configuration" do
      allow(Decidim).to receive(:verification_code_expiry_minutes).and_return(2)

      code = sent_code
      travel_to(3.minutes.from_now) do
        put collection_path, params: { confirmation: { verification_code: code } }
      end

      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty
    end

    it "kills the code at the cap even when Decidim's lock lasts no time" do
      allow(Decidim).to receive(:verification_unlock_in).and_return(0.seconds)

      Decidim.verification_max_failed_attempts.times do
        put collection_path, params: { confirmation: { verification_code: "000000" } }
      end

      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty
    end

    # Two requests racing past the cap: the loser finds the record locked.
    it "refuses even the right code on a locked record" do
      code = sent_code
      authorization.update!(failed_attempts: Decidim.verification_max_failed_attempts, locked_at: Time.current)

      put collection_path, params: { confirmation: { verification_code: code } }

      expect(Decidim::Authorization.where(name: "ephemeral_sms", user:)).to be_empty
      expect(response).to have_http_status(:redirect)
    end

    # Every resend is real money and a message to a third party. The reset link
    # in the edit view is the path that matters: `create` is forbidden while a
    # record is pending, so a resend loop runs destroy -> create.
    it "will not reset the code immediately" do
      expect { delete collection_path }.not_to change(Decidim::Authorization, :count)

      expect(response).to redirect_to(%r{/ephemeral_sms/authorizations/edit})
    end

    it "allows a reset once the cooldown has passed" do
      first = sent_code

      travel_to(2.minutes.from_now) do
        delete collection_path
        request_code
      end

      expect(Decidim::Authorization.find_by(name: "ephemeral_sms", user:).verification_metadata["verification_code"]).not_to eq(first)
    end
  end

  describe "renewal" do
    before do
      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }
    end

    # `renewable` is deliberately false: renewal is a destructive GET, and a
    # participant holding a transferred authorization could otherwise free the
    # phone number and let a second vote be cast with it.
    it "is not offered for a granted authorization" do
      expect(authorization.reload).to be_granted
      expect(authorization).not_to be_renewable
    end
  end

  describe "returning to step one while a code is pending" do
    before { request_code }

    # `:create` is denied by not_already_active? once a record exists, so
    # without the resume guard this 403s, bounces to the root, and comes back.
    it "resumes instead of refusing" do
      get new_path

      expect(response).to redirect_to(%r{/ephemeral_sms/authorizations/edit})
    end

    it "does not loop when the engine root is opened again" do
      get "/ephemeral_sms/"

      5.times do
        break unless response.status == 302

        follow_redirect!
      end

      expect(response).to have_http_status(:ok)
    end
  end

  describe "when the authorization cannot be resolved" do
    let(:earlier_user) { create(:user, :ephemeral, :confirmed, organization:) }
    let!(:earlier_authorization) do
      create(
        :authorization,
        :granted,
        user: earlier_user,
        name: "ephemeral_sms",
        unique_id: Decidim::EphemeralVerifications::Sms::MobilePhoneForm
                     .from_params({ mobile_phone_number: phone }, user:).unique_id
      )
    end
    let(:user) { create(:user, :confirmed, organization:) }

    around do |example|
      Decidim::AuthorizationTransfer.disable!
      example.run
      Decidim::AuthorizationTransfer.enable!
    end

    # AuthorizeUser broadcasts :invalid here. The participant must not be left
    # bouncing between this engine and the root.
    it "sends the participant somewhere real rather than deadlocking" do
      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      5.times do
        break unless response.status == 302

        follow_redirect!
      end

      expect(response).to have_http_status(:ok)
    end
  end

  describe "mass assignment" do
    # from_params merges the nested hash over the top level, so passing the user
    # inside params would let this displace current_user and forge the terms gate.
    it "cannot displace the current user through nested params" do
      post collection_path, params: {
        mobile_phone: {
          mobile_phone_number: phone,
          eligible_confirmation: "1",
          user: { extended_data: { ephemeral: true }, accepted_tos_version: Time.current }
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Decidim::Authorization.where(name: "ephemeral_sms")).to be_empty
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

    # The earlier session's onboarding data names whatever they did then,
    # e.g. a survey they already answered.
    it "resumes the action of this session, not the earlier one's" do
      stale_component = create(:proposal_component, participatory_space:)
      # Merged: `ephemeral?` is itself a key of extended_data.
      earlier_user.update(
        extended_data: earlier_user.extended_data.merge(
          "onboarding" => {
            "action" => "vote",
            "permissions_holder" => stale_component.to_gid.to_s,
            "redirect_path" => Decidim::EngineRouter.main_proxy(stale_component).root_path
          }
        )
      )

      request_code
      put collection_path, params: { confirmation: { verification_code: sent_code } }

      onboarding = earlier_user.reload.extended_data["onboarding"]
      expect(onboarding).to include(
        "action" => "create",
        "permissions_holder" => component.to_gid.to_s
      )
      expect(onboarding).not_to have_key("authorization_path")
    end

    context "when someone else also started, and abandoned, a verification of that number" do
      let(:abandoned_user) { create(:user, :ephemeral, :confirmed, organization:) }
      let!(:abandoned_authorization) do
        create(
          :authorization,
          :pending,
          user: abandoned_user,
          name: "ephemeral_sms",
          unique_id: earlier_authorization.unique_id,
          verification_metadata: { "verification_code" => "000000", "code_sent_at" => 1.day.ago }
        )
      end

      # Decidim's `find_by` returns the row that comes first on disk, and a
      # row is rewritten whenever it is updated. In production the voter's
      # record was granted, so it usually sits behind every attempt that was
      # started before the grant; this update puts it there.
      before { earlier_authorization.update!(metadata: earlier_authorization.metadata.merge("touched" => true)) }

      it "merges with the voter's granted record, not the abandoned pending one" do
        request_code
        put collection_path, params: { confirmation: { verification_code: sent_code } }

        granted = Decidim::Authorization.where(name: "ephemeral_sms", unique_id: earlier_authorization.unique_id).where.not(granted_at: nil)
        expect(granted).to contain_exactly(earlier_authorization)
        expect(abandoned_authorization.reload).not_to be_granted
      end
    end
  end

  describe "a national spelling" do
    let(:phone) { "079 123 45 67" }

    around do |example|
      previous = Decidim::EphemeralVerifications::Sms.default_country
      Decidim::EphemeralVerifications::Sms.default_country = default_country
      example.run
    ensure
      Decidim::EphemeralVerifications::Sms.default_country = previous
    end

    context "with a default country configured" do
      let(:default_country) { "CH" }

      it "is keyed exactly like the international spelling" do
        request_code

        expect(authorization.unique_id).to eq(Decidim::EphemeralVerifications::Sms::PhoneNumber.digest("+41791234567"))
      end
    end

    context "without one" do
      let(:default_country) { nil }

      it "is refused on the form, with nothing stored and nothing sent" do
        expect { request_code }.not_to change(Decidim::Authorization, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("does not look like a mobile phone number")
      end
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

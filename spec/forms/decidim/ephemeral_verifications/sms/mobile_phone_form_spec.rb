# frozen_string_literal: true

require "spec_helper"

module Decidim
  module EphemeralVerifications
    module Sms
      describe MobilePhoneForm do
        subject(:form) { described_class.from_params(attributes.merge(user:)) }

        let(:organization) { create(:organization) }
        # `Decidim::CreateEphemeralUser` leaves `accepted_tos_version` nil, which
        # is what makes `ephemeral_tos_pending?` true. The `:ephemeral` factory
        # trait alone does not: the base user factory sets that column.
        let(:user) { create(:user, :ephemeral, :confirmed, organization:, accepted_tos_version: nil) }
        let(:mobile_phone_number) { "+41791234567" }
        let(:attributes) do
          {
            mobile_phone_number:,
            eligible_confirmation: "1",
            tos_agreement: "1"
          }
        end

        # The gateway is what costs money, so every example counts deliveries
        # rather than trusting that validation did the right thing.
        let(:gateway) { class_double(Decidim::Verifications::Sms::ExampleGateway) }
        let(:delivery) { instance_double(Decidim::Verifications::Sms::ExampleGateway, deliver_code: true) }

        before do
          allow(Decidim).to receive(:sms_gateway_service).and_return("Decidim::Verifications::Sms::ExampleGateway")
          allow(Decidim::Verifications::Sms::ExampleGateway).to receive(:new).and_return(delivery)
        end

        it { is_expected.to be_valid }

        it "reports the registered workflow name, so the authorization is stored under it" do
          expect(form.handler_name).to eq("ephemeral_sms")
          expect(form.handler_name).to eq(Decidim::EphemeralVerifications::Sms::WORKFLOW_NAME)
        end

        it "derives a stable unique_id from the phone number without storing it" do
          expect(form.unique_id).not_to include("791234567")
          expect(form.unique_id).to eq(described_class.from_params(attributes.merge(user:)).unique_id)
        end

        it "records the confirmations in the metadata for the second step" do
          expect(form).to be_valid
          expect(form.metadata).to include(
            "tos_agreement" => true,
            "eligible_confirmation" => true
          )
        end

        it "delivers exactly one code for a valid submission" do
          expect(Decidim::Verifications::Sms::ExampleGateway).to receive(:new).once.and_return(delivery)

          expect(form).to be_valid
        end

        describe "the eligibility confirmation" do
          context "when it is not ticked" do
            let(:attributes) { super().merge(eligible_confirmation: "0") }

            it { is_expected.not_to be_valid }

            it "adds an error on the checkbox" do
              form.valid?

              expect(form.errors[:eligible_confirmation]).not_to be_empty
            end

            # Reading verification_code is what sends the SMS, and the parent
            # class declares its presence validation before ours runs.
            it "does not send an SMS" do
              expect(Decidim::Verifications::Sms::ExampleGateway).not_to receive(:new)

              form.valid?
            end
          end

          context "when it is missing entirely" do
            let(:attributes) { super().except(:eligible_confirmation) }

            it { is_expected.not_to be_valid }
          end
        end

        describe "the terms of service" do
          context "when they are not accepted by an ephemeral participant" do
            let(:attributes) { super().merge(tos_agreement: "0") }

            it { is_expected.not_to be_valid }

            it "does not send an SMS" do
              expect(Decidim::Verifications::Sms::ExampleGateway).not_to receive(:new)

              form.valid?
            end
          end

          context "when the participant is a registered account" do
            let(:user) { create(:user, :confirmed, organization:) }
            let(:attributes) { super().except(:tos_agreement) }

            # Decidim only asks ephemeral participants who have not accepted
            # them yet, which is exactly why eligibility cannot ride along on
            # the same checkbox.
            it { is_expected.to be_valid }
          end
        end

        describe "normalisation" do
          around do |example|
            previous = Sms.default_country
            Sms.default_country = "CH"
            example.run
          ensure
            Sms.default_country = previous
          end

          let(:spellings) { ["079 123 45 67", "+41 79 123 45 67", "0041 79 123 45 67", "+41 (0)79 123 45 67"] }

          def form_for(spelling)
            described_class.from_params(attributes.merge(mobile_phone_number: spelling, user:))
          end

          # The bug report: one phone, three verifications, three votes.
          it "derives the same unique_id whichever way the number is spelled" do
            expect(spellings.map { |spelling| form_for(spelling).unique_id }.uniq).to eq([form.unique_id])
          end

          # Guards the formula `PhoneNumber.digest` replicates from upstream.
          it "keys the authorization by the hash of the E.164 spelling" do
            expect(form.unique_id).to eq(PhoneNumber.digest("+41791234567"))
          end

          it "hands the gateway the E.164 spelling" do
            expect(form_for("079 123 45 67")).to be_valid

            expect(Decidim::Verifications::Sms::ExampleGateway).to have_received(:new).with("+41791234567", anything, anything)
          end

          context "with a landline" do
            let(:mobile_phone_number) { "+41 44 123 45 67" }

            it { is_expected.not_to be_valid }

            it "explains it on the field and does not send an SMS" do
              expect(Decidim::Verifications::Sms::ExampleGateway).not_to receive(:new)

              form.valid?

              expect(form.errors[:mobile_phone_number]).not_to be_empty
            end
          end

          context "with something that is not a number" do
            let(:mobile_phone_number) { "+41 79 12" }

            it { is_expected.not_to be_valid }
          end

          context "without a default country" do
            around do |example|
              Sms.default_country = nil
              example.run
            end

            it "still accepts an international spelling" do
              expect(form_for("+41 79 123 45 67")).to be_valid
            end

            it "refuses a national one rather than guessing" do
              expect(Decidim::Verifications::Sms::ExampleGateway).not_to receive(:new)

              expect(form_for("079 123 45 67")).not_to be_valid
            end
          end
        end

        describe "a blank phone number" do
          let(:mobile_phone_number) { "" }

          it { is_expected.not_to be_valid }

          it "does not send an SMS" do
            expect(Decidim::Verifications::Sms::ExampleGateway).not_to receive(:new)

            form.valid?
          end
        end

        describe "duplicates" do
          let(:other_user) { create(:user, :ephemeral, organization:) }
          let!(:duplicate) do
            create(
              :authorization,
              :granted,
              user: other_user,
              name: "ephemeral_sms",
              unique_id: described_class.from_params(attributes.merge(user:)).unique_id
            )
          end

          # Rejecting here is what would lock a returning participant out, so
          # duplicates are deliberately deferred to the confirmation step.
          it "stays valid so the flow can resolve them after the code is confirmed" do
            expect(form).to be_valid
            expect(form.duplicate).to eq(duplicate)
          end
        end
      end
    end
  end
end

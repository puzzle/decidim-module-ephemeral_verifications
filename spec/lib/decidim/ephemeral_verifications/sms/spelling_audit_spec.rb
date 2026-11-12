# frozen_string_literal: true

require "spec_helper"
require "decidim/ephemeral_verifications/sms/spelling_audit"

module Decidim
  module EphemeralVerifications
    module Sms
      describe SpellingAudit do
        subject(:audit) { described_class.new(country: "CH", prefixes: %w(7912345), digits: 2, output:) }

        let(:output) { StringIO.new }
        # One phone, three participants: the bug. Plus one participant who
        # spelled a different number nationally, and one who is fine.
        let!(:national) { authorization_for("0791234567") }
        let!(:international) { authorization_for("+41791234567") }
        let!(:with_zeros) { authorization_for("0041791234567") }
        let!(:other_number) { authorization_for("0791234599") }
        let!(:canonical) { authorization_for("+41791234500") }
        let!(:outside_range) { authorization_for("+41761234567") }
        let(:organization) { create(:organization) }

        def ephemeral_user
          create(:user, :ephemeral, :confirmed, organization:)
        end

        def authorization_for(spelling, user: ephemeral_user)
          create(:authorization, :granted, user:, name: "ephemeral_sms", unique_id: PhoneNumber.digest(spelling))
        end

        before { audit.run }

        it "recovers every record in the range, and which spelling it was keyed by" do
          expect(audit.matches.map(&:authorization_id)).to contain_exactly(national.id, international.id, with_zeros.id, other_number.id, canonical.id)
          expect(audit.legacy_matches.map(&:authorization_id)).to contain_exactly(national.id, with_zeros.id, other_number.id)
        end

        it "reports the numbers verified by more than one participant" do
          expect(audit.collisions.keys).to eq(["+41791234567"])
          expect(audit.collisions["+41791234567"]).to contain_exactly(national, international, with_zeros)
        end

        it "masks the numbers unless told otherwise" do
          expect(output.string).to include("+4179•••••67")
          expect(output.string).not_to include("+41791234567")
          expect(output.string).to include("more than one participant")
        end

        it "rekeys the legacy records to the canonical spelling on request" do
          expect(audit.rewrite!).to eq(3)

          expect(national.reload.unique_id).to eq(international.unique_id)
          expect(with_zeros.reload.unique_id).to eq(international.unique_id)
          expect(other_number.reload.unique_id).to eq(PhoneNumber.digest("+41791234599"))
          expect(canonical.reload.unique_id).to eq(PhoneNumber.digest("+41791234500"))
        end

        it "round-trips through a file, so the rewrite needs no second scan" do
          path = File.join(Dir.mktmpdir, "audit.json")
          audit.save(path)
          loaded = described_class.load(path, output:)

          expect(loaded.matches).to match_array(audit.matches)
          expect(loaded.rewrite!([national.id, canonical.id])).to eq(1)
          expect(output.string).to include("skipped: #{canonical.id}")
          expect(national.reload.unique_id).to eq(international.unique_id)
          expect(with_zeros.reload.unique_id).to eq(PhoneNumber.digest("0041791234567"))
        end

        context "when forking" do
          subject(:audit) { described_class.new(country: "CH", prefixes: %w(7912345), digits: 2, processes: 3, output:) }

          it "finds the same records" do
            expect(audit.matches.map(&:authorization_id)).to contain_exactly(national.id, international.id, with_zeros.id, other_number.id, canonical.id)
          end
        end
      end
    end
  end
end

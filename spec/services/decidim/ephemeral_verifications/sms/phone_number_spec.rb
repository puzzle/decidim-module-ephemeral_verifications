# frozen_string_literal: true

require "spec_helper"

module Decidim
  module EphemeralVerifications
    module Sms
      describe PhoneNumber do
        around do |example|
          previous = Sms.default_country
          Sms.default_country = default_country
          example.run
        ensure
          Sms.default_country = previous
        end

        let(:default_country) { "CH" }

        # The bug report, verbatim: three ways to write one phone.
        it "reduces every spelling of a number to the same canonical form" do
          canonicals = ["079 123 45 67", "+41 79 123 45 67", "0041 79 123 45 67", "+41 (0)79 123 45 67", "079-123-45-67"]
                       .map { |spelling| described_class.parse(spelling).canonical }

          expect(canonicals.uniq).to eq(["+41791234567"])
        end

        it "derives one unique_id for all of them" do
          ids = ["079 123 45 67", "+41 79 123 45 67", "0041 79 123 45 67"].map { |spelling| described_class.parse(spelling).unique_id }

          expect(ids.uniq.size).to eq(1)
        end

        it "rejects what cannot receive an SMS" do
          expect(described_class.parse("+41 44 123 45 67")).not_to be_mobile
          expect(described_class.parse("+41 79 12")).not_to be_mobile
          expect(described_class.parse("not a number")).not_to be_mobile
          expect(described_class.parse("+41 44 123 45 67").canonical).to be_nil
        end

        it "keeps a US number, where libphonenumber cannot tell mobile from landline" do
          expect(described_class.parse("+1 202 555 0123")).to be_mobile
        end

        context "without a default country" do
          let(:default_country) { nil }

          it "accepts only international spellings" do
            expect(described_class.parse("+41 79 123 45 67")).to be_mobile
            expect(described_class.parse("079 123 45 67")).not_to be_mobile
          end

          it "falls back to a country the host configured for phonelib itself" do
            Phonelib.default_country = "CH"

            expect(described_class.parse("079 123 45 67")).to be_mobile
          ensure
            Phonelib.default_country = nil
          end
        end

        describe ".spellings" do
          it "lists what core's sanitisation could have made of a Swiss number, canonical first" do
            expect(described_class.spellings(country_code: "41", national_number: "791234567", trunk_prefix: "0", international_prefix: "00")).to eq(
              %w(+41791234567 0791234567 791234567 +410791234567 +41791234567 00410791234567 0041791234567 410791234567 41791234567).uniq
            )
          end

          it "covers both the plan's international prefix and 00" do
            spellings = described_class.spellings(country_code: "1", national_number: "2025550123", trunk_prefix: "1", international_prefix: "011")

            expect(spellings).to include("01112025550123", "0012025550123", "12025550123")
          end

          it "copes with a plan that has no trunk prefix" do
            spellings = described_class.spellings(country_code: "39", national_number: "3331234567", trunk_prefix: nil, international_prefix: "00")

            expect(spellings).to include("3331234567", "00393331234567")
            expect(spellings).to all(match(/\A[+0-9]+\z/))
          end
        end
      end
    end
  end
end

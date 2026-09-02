# frozen_string_literal: true

require "spec_helper"
require "decidim/ephemeral_verifications/overrides"
require "digest"
require "yaml"

# This module copies or closely adapts a handful of Decidim files. Copies drift
# silently across upgrades, so their upstream originals are checksummed here:
# when Decidim changes one of them, this fails and someone has to look at our
# version and decide whether it needs the same change.
#
# To accept the upstream change after reviewing our copy, regenerate the
# checksums with:
#
#   bundle exec rake overrides:checksums
#
describe "overrides of Decidim files" do
  let(:checksums) { YAML.load_file(File.expand_path("../overrides.yml", __dir__)) }

  it "lists at least the files we copied" do
    expect(checksums).not_to be_empty
  end

  it "matches the upstream originals" do
    # A renamed or removed file is drift too, and reporting it here beats an
    # Errno::ENOENT that reads like breakage rather than signal.
    stale = checksums.filter_map do |relative_path, expected|
      actual = Decidim::EphemeralVerifications::Overrides.checksum(relative_path)
      next "#{relative_path} (no longer exists in Decidim)" if actual.nil?

      relative_path unless actual == expected
    end

    expect(stale).to be_empty, <<~MSG
      These Decidim files changed upstream since our copies were made:

        #{stale.join("\n  ")}

      Review the corresponding files in this module, then run
      `bundle exec rake overrides:checksums` to accept the new state.
    MSG
  end
end

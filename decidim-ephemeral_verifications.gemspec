# frozen_string_literal: true

require_relative "lib/decidim/ephemeral_verifications/version"

Gem::Specification.new do |spec|
  spec.name = "decidim-ephemeral_verifications"
  spec.version = Decidim::EphemeralVerifications::VERSION
  # decidim-core 0.31 itself requires "~> 3.3.0"; advertising less is a lie.
  spec.required_ruby_version = ">= 3.3"
  spec.license = "AGPL-3.0"
  spec.authors = ["Carlo Beltrame"]
  spec.email = ["beltrame@puzzle.ch"]

  spec.summary = "Ephemeral verification workflows for Decidim."
  spec.description = "Lets participants verify themselves and take part without creating an account. " \
                     "Ships an SMS-based ephemeral verification workflow."
  spec.homepage = "https://github.com/puzzle/decidim-module-ephemeral_verifications"
  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "{app,config,lib,docs}/**/*",
    "LICENSE-AGPLv3.txt",
    "Rakefile",
    "README.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "decidim-core", *Decidim::EphemeralVerifications::DECIDIM_VERSION
  spec.add_dependency "decidim-verifications", *Decidim::EphemeralVerifications::DECIDIM_VERSION
end

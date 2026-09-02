# frozen_string_literal: true

require "decidim/dev/common_rake"

desc "Generates a dummy app for testing"
task test_app: "decidim:generate_external_test_app"

desc "Generates a development app"
task :development_app do
  Bundler.with_original_env do
    generate_decidim_app(
      "development_app",
      "--app_name", "#{base_app_name}_development_app",
      "--path", "..",
      "--recreate_db",
      "--demo"
    )
  end
  seed_db("development_app")
end

namespace :overrides do
  desc "Regenerates the checksums of the Decidim files this module copies"
  task :checksums do
    require "decidim/ephemeral_verifications/overrides"

    data = Decidim::EphemeralVerifications::Overrides.write_checksums!
    puts "Wrote #{data.size} checksums to #{Decidim::EphemeralVerifications::Overrides.checksums_path}"
  end
end

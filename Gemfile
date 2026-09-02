# frozen_string_literal: true

source "https://rubygems.org"

# Inside the generated development app the relative require has to go one level
# up, because this Gemfile is copied there almost as is.
base_path = ""
base_path = "../" if File.basename(__dir__) == "development_app"
require_relative "#{base_path}lib/decidim/ephemeral_verifications/version"

# The point release the test suite runs against. The gem itself declares the
# wider DECIDIM_VERSION range.
DECIDIM_VERSION = "0.31.6"

gem "decidim", DECIDIM_VERSION
gem "decidim-ephemeral_verifications", path: base_path.empty? ? "." : base_path

group :development, :test do
  # The generated test app's config/boot.rb requires it, and an external test
  # app boots against this Gemfile.
  gem "bootsnap", require: false
  gem "decidim-budgets", DECIDIM_VERSION
  gem "decidim-dev", DECIDIM_VERSION
  gem "decidim-participatory_processes", DECIDIM_VERSION
  gem "decidim-proposals", DECIDIM_VERSION
end

group :development do
  gem "faker"
  gem "letter_opener_web"
  gem "listen"
  gem "puma"
  gem "web-console"
end

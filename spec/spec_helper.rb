# frozen_string_literal: true

require "decidim/dev"

ENV["ENGINE_ROOT"] = File.dirname(__dir__)

Decidim::Dev.dummy_app_path = File.expand_path(File.join(__dir__, "decidim_dummy_app"))

require "decidim/dev/test/base_spec_helper"

# Decidim leaves Capybara's default two second wait in place, which is tight for
# pages as heavy as the budgets project list — and every step of this flow is a
# POST followed by a couple of redirects. Without this the browser specs time
# out intermittently on assertions that are actually correct.
Capybara.default_max_wait_time = 10

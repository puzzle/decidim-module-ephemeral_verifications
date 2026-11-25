# frozen_string_literal: true

module Decidim
  module EphemeralVerifications
    # The gem's own version, bumped independently of Decidim.
    VERSION = "0.2.0"

    # The range of Decidim versions this gem is known to work with. Kept
    # separate from VERSION on purpose: the gemspec, the Gemfile and the
    # generated development app all read this one constant.
    DECIDIM_VERSION = [">= 0.31.9", "< 0.32"].freeze
  end
end

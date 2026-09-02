# frozen_string_literal: true

SimpleCov.start do
  root ENV.fetch("ENGINE_ROOT", nil)

  add_filter "/spec"
  add_filter "/lib/decidim/ephemeral_verifications/version.rb"
end

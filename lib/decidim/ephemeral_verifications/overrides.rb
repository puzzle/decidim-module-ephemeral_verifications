# frozen_string_literal: true

require "yaml"
require "digest"

module Decidim
  module EphemeralVerifications
    # Resolves and checksums the Decidim files this module copies or closely
    # adapts, so that an upstream change to any of them fails a test instead of
    # silently diverging. Used by spec/lib/overrides_spec.rb and by the
    # `overrides:checksums` rake task.
    module Overrides
      # Paths are given as "<gem name>:<path within that gem>".
      def self.resolve(relative_path)
        gem_name, path = relative_path.split(":", 2)
        raise ArgumentError, "expected '<gem>:<path>', got #{relative_path.inspect}" if path.nil?

        spec = Gem.loaded_specs.fetch(gem_name) do
          raise ArgumentError, "#{gem_name} is not loaded"
        end

        Pathname.new(spec.full_gem_path).join(path)
      end

      # Returns nil when the file no longer exists upstream, which is drift
      # worth reporting rather than an exception to debug.
      def self.checksum(relative_path)
        path = resolve(relative_path)
        return nil unless path.exist?

        Digest::SHA256.hexdigest(path.read)
      end

      def self.checksums_path
        Pathname.new(__dir__).join("../../../spec/overrides.yml").expand_path
      end

      # Track a file if and only if a documented assumption depends on it: the
      # ones this module copies, and the ones whose behaviour the flow rests on.
      # A checksum cannot verify an assumption still holds — it guarantees that
      # a change to where the assumption lives fails a test instead of passing
      # silently. Measured against Decidim's history this costs nothing day to
      # day (none of these changed across any 0.31 patch release) and fires at
      # minor upgrades, which is when it has to be re-read anyway.
      def self.tracked_paths
        %w(
          decidim-verifications:app/controllers/decidim/verifications/sms/authorizations_controller.rb
          decidim-verifications:app/forms/decidim/verifications/sms/mobile_phone_form.rb
          decidim-verifications:app/forms/decidim/verifications/sms/confirmation_form.rb
          decidim-verifications:app/views/decidim/verifications/sms/authorizations/new.html.erb
          decidim-verifications:app/views/decidim/verifications/sms/authorizations/edit.html.erb
          decidim-verifications:app/views/decidim/verifications/authorizations/_tos_acceptance_field.html.erb
          decidim-verifications:lib/decidim/verifications/sms/engine.rb
          decidim-verifications:lib/tasks/revoke.rake
          decidim-verifications:app/commands/decidim/verifications/authorize_user.rb
          decidim-verifications:app/commands/decidim/verifications/confirm_user_authorization.rb
          decidim-verifications:app/commands/decidim/verifications/perform_authorization_step.rb
          decidim-core:app/controllers/concerns/decidim/ephemeral_session_checker.rb
          decidim-core:app/services/decidim/action_authorizer.rb
          decidim-core:app/permissions/decidim/permissions.rb
          decidim-core:app/models/decidim/authorization.rb
          decidim-core:app/models/decidim/authorization_transfer.rb
          decidim-verifications:app/services/decidim/authorization_handler.rb
          decidim-verifications:app/controllers/concerns/decidim/verifications/renewable.rb
        ).freeze
      end

      def self.write_checksums!
        data = tracked_paths.index_with { |path| checksum(path) }
        missing = data.select { |_, digest| digest.nil? }.keys
        raise "No longer present in Decidim, update tracked_paths first:\n  #{missing.join("\n  ")}" if missing.any?

        checksums_path.write(YAML.dump(data))
        data
      end
    end
  end
end

# frozen_string_literal: true

# `decidim-verifications/lib/tasks/revoke.rake` builds one revoke task per
# registered engine workflow, but rake files are loaded before the initializers
# that register them, so the task for this workflow never materialises. Same
# bug, same workaround as decidim#16546.
namespace :decidim do
  namespace :verifications do
    namespace :revoke do
      desc "Revokes authorizations for the ephemeral_sms workflow"
      task ephemeral_sms: :environment do
        name = Decidim::EphemeralVerifications::Sms::WORKFLOW_NAME
        count = Decidim::Authorization.where(name:).destroy_all.size
        puts "Revoked #{count} #{name} authorizations."
      end
    end
  end
end

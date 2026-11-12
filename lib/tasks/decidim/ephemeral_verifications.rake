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

namespace :decidim do
  namespace :ephemeral_verifications do
    namespace :sms do
      desc "Finds ephemeral_sms authorizations keyed by a legacy phone number spelling, in a mobile numbering range or among " \
           "the numbers listed in a JSON file, and writes the matches to OUTPUT. " \
           "COUNTRY=CH OUTPUT=audit.json {PREFIXES=76,77,78,79 DIGITS=7 [PROCESSES=4] | NUMBERS=sent.json} [REVEAL=1]"
      task audit_phone_spellings: :environment do
        require "decidim/ephemeral_verifications/sms/spelling_audit"

        Decidim::EphemeralVerifications::Sms::SpellingAudit.new(
          country: ENV.fetch("COUNTRY"),
          prefixes: ENV["PREFIXES"]&.split(","),
          digits: ENV["DIGITS"].presence,
          numbers: ENV["NUMBERS"].presence && Decidim::EphemeralVerifications::Sms::SpellingAudit.strings_in(ENV.fetch("NUMBERS")),
          processes: ENV.fetch("PROCESSES", 1),
          reveal: ENV["REVEAL"].present?
        ).run.save(ENV.fetch("OUTPUT"))
      end

      desc "Prints the report of an earlier scan again. INPUT=audit.json [REVEAL=1]"
      task report_phone_spellings: :environment do
        require "decidim/ephemeral_verifications/sms/spelling_audit"

        Decidim::EphemeralVerifications::Sms::SpellingAudit.load(ENV.fetch("INPUT"), reveal: ENV["REVEAL"].present?).report
      end

      desc "Rekeys the legacy records of an earlier scan to the canonical spelling, all of them or only IDS. INPUT=audit.json [IDS=12,57]"
      task rekey_phone_spellings: :environment do
        require "decidim/ephemeral_verifications/sms/spelling_audit"

        ids = ENV["IDS"].presence&.split(",")&.map { |id| Integer(id.strip) }
        Decidim::EphemeralVerifications::Sms::SpellingAudit.load(ENV.fetch("INPUT")).rewrite!(ids)
      end
    end
  end
end

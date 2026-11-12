# frozen_string_literal: true

require "json"
require "phonelib"

module Decidim
  module EphemeralVerifications
    module Sms
      # Finds the `ephemeral_sms` authorizations granted before phone numbers
      # were normalised, and the participants who verified more than once by
      # spelling the same number differently.
      #
      # Nothing but the salted hash of the spelling is stored, so the only way
      # back to the number is forward: enumerate a mobile numbering range,
      # compute every spelling's hash and look each one up. A national mobile
      # range is small enough for that to take minutes (Switzerland: four
      # prefixes of seven digits, about forty million numbers, each in nine
      # spellings), but not seconds, so the scan is done once and `save`d, and
      # the report and the rekeying work from that file (`load`). When the SMS
      # gateway's log of recipients is at hand, `numbers:` scans those instead
      # of the range, which takes seconds and also finds numbers the range
      # would have missed.
      #
      # It needs the production secret key base and, by construction, ends up
      # knowing which number each record belongs to. Numbers are masked in the
      # report unless `reveal:` is given; the saved file holds them in clear.
      # Nothing is written to the database unless `rewrite!` is called, which
      # rekeys legacy records to the canonical id so the flow no longer depends
      # on `legacy_unique_ids` to recognise them.
      class SpellingAudit
        Match = Struct.new(:canonical, :spelling, :authorization_id, keyword_init: true)

        attr_reader :country, :prefixes, :digits, :numbers, :processes, :output, :reveal
        attr_accessor :matches

        # country  - ISO 3166-1 alpha-2 code of the numbering plan ("CH"), and
        #            the country a listed number without one belongs to.
        # prefixes - leading digits of the national significant numbers to
        #            scan, without the trunk prefix (%w(76 77 78 79)).
        # digits   - how many digits follow each prefix (7 for Switzerland).
        # numbers  - instead of a range, the numbers to check, in any spelling;
        #            entries that are not a phone number are skipped.
        def initialize(country:, prefixes: nil, digits: nil, numbers: nil, processes: 1, output: $stdout, reveal: false) # rubocop:disable Metrics/ParameterLists
          @country = country.to_s.upcase
          @prefixes = Array(prefixes).map { |prefix| prefix.to_s.gsub(/\D/, "") }
          @digits = digits && Integer(digits)
          @numbers = numbers && numbers.map { |raw| Phonelib.parse(raw.to_s, @country) }.select(&:valid?).uniq(&:e164)
          @skipped = numbers ? numbers.size - @numbers.size : 0
          @processes = [Integer(processes), 1].max
          @output = output
          @reveal = reveal
          @matches = []
        end

        # An audit rebuilt from a file written by `save`, so that reporting and
        # rekeying do not repeat the scan.
        def self.load(path, output: $stdout, reveal: false)
          data = JSON.parse(File.read(path))
          audit = new(country: data.fetch("country"), prefixes: data["prefixes"], digits: data["digits"], numbers: data["numbers"], output:, reveal:)
          audit.matches = data.fetch("matches").map { |match| Match.new(**match.symbolize_keys) }
          audit
        end

        # Every string in a JSON file, whatever its structure: a gateway log
        # is as likely to be a list of objects as a list of numbers.
        def self.strings_in(path)
          strings = []
          walk = lambda do |node|
            case node
            when Hash then node.each_value(&walk)
            when Array then node.each(&walk)
            when String then strings << node
            end
          end
          walk.call(JSON.parse(File.read(path)))
          strings
        end

        def run
          raise ArgumentError, "give either numbers or prefixes and digits" unless numbers || (prefixes.any? && digits)

          @index = Decidim::Authorization.where(name: WORKFLOW_NAME).pluck(:unique_id, :id).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
          output.puts "#{@index.values.sum(&:size)} #{WORKFLOW_NAME} authorizations, #{scope}..."

          plan # load the numbering plan once, in the parent, not in every worker
          @matches = scan
          report
          self
        end

        def save(path)
          File.write(path, JSON.pretty_generate(country:, prefixes:, digits:, numbers: numbers&.map(&:e164), scanned_at: Time.current, matches: matches.map(&:to_h)))
          output.puts "Wrote #{matches.size} matches to #{path}. It holds phone numbers next to participant ids: keep it on the server and delete it when done."
        end

        def legacy_matches
          matches.reject { |match| match.spelling == match.canonical }
        end

        # Groups of records that belong to the same number but to different
        # participants: the double votes.
        def collisions
          by_number.select { |_, records| records.map(&:decidim_user_id).uniq.size > 1 }
        end

        # Rekeys the legacy records — all of them, or only the authorizations
        # whose ids are given — to the canonical spelling.
        def rewrite!(ids = nil)
          selected = legacy_matches
          if ids
            selected = selected.select { |match| ids.include?(match.authorization_id) }
            missing = ids - selected.map(&:authorization_id)
            output.puts "Not legacy matches of this scan, skipped: #{missing.join(", ")}" if missing.any?
          end

          rewritten = selected.sum do |match|
            Decidim::Authorization.find(match.authorization_id).update!(unique_id: PhoneNumber.digest(match.canonical))
            1
          end
          output.puts "Rewrote #{rewritten} legacy unique ids to the canonical spelling."
          rewritten
        end

        def report
          output.puts "Found #{matches.size} authorizations for #{by_number.size} numbers; #{legacy_matches.size} keyed by a legacy spelling."

          matches.group_by(&:canonical).sort.each { |canonical, group| report_number(canonical, group) }

          output.puts "#{collisions.size} numbers verified by more than one participant." if collisions.any?
        end

        private

        def plan
          @plan ||= Phonelib.phone_data[country] || raise(ArgumentError, "unknown country #{country.inspect}")
        end

        def scan
          # The children only hash, never touch the database, and leave through
          # `exit!`, so the connection they inherit is neither used nor closed
          # from their side. Dropping it before forking would be the textbook
          # precaution, but it also drops the transaction a spec runs in.
          return scan_slice(0) if processes == 1

          workers = processes.times.map do |slice|
            reader, writer = IO.pipe
            reader.binmode
            writer.binmode
            pid = fork do
              reader.close
              writer.write(Marshal.dump(scan_slice(slice)))
              writer.close
              # Skip at_exit handlers: they belong to the parent's Rails process.
              exit!(0) # rubocop:disable Rails/Exit
            end
            writer.close
            [pid, reader]
          end

          # Wait for these pids only: `Process.waitall` would also wait for any
          # other child of the process, such as the chromedriver a system spec
          # leaves running, and never return.
          workers.flat_map do |pid, reader|
            found = Marshal.load(reader.read) # rubocop:disable Security/MarshalLoad
            Process.wait(pid)
            found
          end
        end

        def scope
          if numbers
            "checking #{numbers.size} listed numbers (#{@skipped} entries skipped)"
          else
            "scanning #{prefixes.size} prefixes of #{digits} digits in #{country}"
          end
        end

        def scan_slice(slice)
          found = []
          each_number(slice) do |canonical, national_number, plan|
            spellings(national_number, plan).each do |spelling|
              ids = @index[PhoneNumber.digest(spelling)]
              next unless ids

              ids.each { |id| found << Match.new(canonical:, spelling:, authorization_id: id) }
            end
          end
          found
        end

        # Yields the canonical spelling, the national significant number and
        # the numbering plan of every number in this worker's share.
        def each_number(slice)
          if numbers
            numbers.each_with_index do |number, index|
              yield number.e164, number.national_number, Phonelib.phone_data[number.country] if index % processes == slice
            end
            return
          end

          space = 10**digits
          prefixes.each do |prefix|
            (slice...space).step(processes) do |number|
              national_number = "#{prefix}#{number.to_s.rjust(digits, "0")}"
              yield "+#{plan[:country_code]}#{national_number}", national_number, plan
            end
            output.puts "  prefix #{prefix} done" if processes == 1
          end
        end

        def spellings(national_number, plan)
          PhoneNumber.spellings(
            country_code: plan[:country_code],
            national_number:,
            trunk_prefix: plan[:national_prefix],
            international_prefix: plan[:international_prefix] || "00"
          )
        end

        def by_number
          @by_number ||= begin
            records = Decidim::Authorization.where(id: matches.map(&:authorization_id)).includes(:user).index_by(&:id)
            matches.group_by(&:canonical).transform_values { |group| group.map { |match| records[match.authorization_id] }.compact }
          end
        end

        def report_number(canonical, group)
          records = by_number[canonical]
          flag = records.map(&:decidim_user_id).uniq.size > 1 ? "  <-- more than one participant" : ""
          output.puts "#{mask(canonical)}#{flag}"

          group.each do |match|
            authorization = records.find { |record| record.id == match.authorization_id }
            next unless authorization

            note = match.spelling == canonical ? " (canonical)" : ""
            output.puts "  #{describe(authorization)}  typed as #{mask(match.spelling)}#{note}"
          end
        end

        def describe(authorization)
          user = authorization.user
          kind = [user.ephemeral? ? "ephemeral" : "registered", ("deleted" if user.deleted?)].compact.join(", ")
          state = authorization.granted? ? "granted #{authorization.granted_at.to_date}" : "pending"
          "authorization #{authorization.id}  user #{user.id} (#{kind})  #{state}  #{activity(user)}"
        end

        # What the participant did with the verification, so a double vote can
        # be told from an idle second verification.
        def activity(user)
          ACTIVITY.filter_map do |label, model, column, scope|
            model = model.safe_constantize
            next unless model && model.column_names.include?(column.to_s)

            relation = model.where(column => user.id)
            relation = scope.call(relation) if scope
            "#{label}: #{relation.count}"
          end.join("  ")
        end

        ACTIVITY = [
          ["budget orders", "Decidim::Budgets::Order", :decidim_user_id, ->(orders) { orders.where.not(checked_out_at: nil) }],
          ["proposal votes", "Decidim::Proposals::ProposalVote", :decidim_author_id, nil],
          ["survey answers", "Decidim::Forms::Answer", :decidim_user_id, nil],
          ["comments", "Decidim::Comments::Comment", :decidim_author_id, nil],
          ["coauthorships", "Decidim::Coauthorship", :decidim_author_id, nil]
        ].freeze

        def mask(number)
          return number if reveal

          visible = number.start_with?("+") ? 5 : 3
          number[0, visible] + ("•" * [number.size - visible - 2, 0].max) + number[-2, 2]
        end
      end
    end
  end
end

# frozen_string_literal: true

require "phonelib"

module Decidim
  module EphemeralVerifications
    module Sms
      # The phone number a participant typed, reduced to the one spelling that
      # identifies it.
      #
      # "079 123 45 67", "+41 79 123 45 67" and "0041 79 123 45 67" reach the
      # same phone, and the code sent to it proves the same thing, so they have
      # to produce the same `unique_id` — or one person is verified three times
      # and casts three votes. Core's sanitisation (keep digits and `+`) does not
      # get there; libphonenumber, through phonelib, does.
      class PhoneNumber
        # What can receive an SMS. `fixed_or_mobile` is what libphonenumber
        # reports where a numbering plan does not tell the two apart (the US).
        MOBILE_TYPES = [:mobile, :fixed_or_mobile].freeze

        # `default_country` is what makes a national spelling parseable.
        # phonelib falls back to its own `Phonelib.default_country` when given
        # nil; without either, only international spellings are accepted.
        def self.parse(raw, default_country = Sms.default_country)
          new(Phonelib.parse(raw.to_s, default_country))
        end

        # Core's `unique_id` formula, so the legacy and canonical ids are
        # comparable with what `Decidim::Verifications::Sms::MobilePhoneForm`
        # stores. `spec/overrides.yml` tracks that form; a change there fails
        # the overrides spec, which is the cue to revisit this.
        def self.digest(spelling)
          Digest::SHA256.hexdigest("#{spelling}-#{Rails.application.secret_key_base}")
        end

        attr_reader :parsed

        def initialize(parsed)
          @parsed = parsed
        end

        def mobile?
          parsed.valid? && parsed.types.intersect?(MOBILE_TYPES)
        end

        # E.164, e.g. "+41791234567", or nil when the number is not a mobile
        # phone number. Chosen as the canonical form on purpose: it is also the
        # spelling core's sanitisation kept intact, so every authorization
        # granted for an international spelling before normalisation is
        # already keyed correctly.
        def canonical
          parsed.e164 if mobile?
        end

        def unique_id
          self.class.digest(canonical) if canonical
        end
      end
    end
  end
end

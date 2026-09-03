# frozen_string_literal: true

require "spec_helper"
require "i18n/tasks"

# Deliberately only the missing-keys check — see config/i18n-tasks.yml for why
# the unused-keys and normalisation checks are not useful for this module.
describe "I18n" do
  let(:i18n) { I18n::Tasks::BaseTask.new }
  let(:missing_keys) { i18n.missing_keys }

  it "does not have missing keys" do
    expect(missing_keys).to be_empty, "#{missing_keys.inspect} are missing"
  end
end

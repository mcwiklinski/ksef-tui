# frozen_string_literal: true

require "test_helper"

class InvoiceItemSummaryTest < ActiveSupport::TestCase
  def test_validates_host_and_ksef_number_uniqueness
    InvoiceItemSummary.create!(
      host: "api-test.example",
      ksef_number: "KSEF-1",
      summary: "Office supplies",
      source: "openai"
    )

    duplicate = InvoiceItemSummary.new(
      host: "api-test.example",
      ksef_number: "KSEF-1",
      summary: "Duplicate summary",
      source: "fallback"
    )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:ksef_number], "has already been taken"
  end

  def test_allows_same_ksef_number_for_different_hosts
    InvoiceItemSummary.create!(
      host: "api-test.example",
      ksef_number: "KSEF-1",
      summary: "Office supplies",
      source: "openai"
    )

    summary = InvoiceItemSummary.new(
      host: "api-prod.example",
      ksef_number: "KSEF-1",
      summary: "Office supplies",
      source: "openai"
    )

    assert_predicate summary, :valid?
  end

  def test_rejects_summaries_longer_than_seven_words
    summary = InvoiceItemSummary.new(
      host: "api-test.example",
      ksef_number: "KSEF-2",
      summary: "one two three four five six seven eight",
      source: "openai"
    )

    refute_predicate summary, :valid?
    assert_includes summary.errors[:summary], "must contain at most 7 words"
  end
end

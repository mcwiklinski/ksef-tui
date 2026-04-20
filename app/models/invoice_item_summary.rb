# frozen_string_literal: true

class InvoiceItemSummary < ApplicationRecord
  SOURCES = %w[openai fallback].freeze
  MAX_WORDS = 7

  validates :host, :ksef_number, :summary, :source, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :ksef_number, uniqueness: { scope: :host }
  validate :summary_word_count_within_limit

  scope :for_host, ->(host) { where(host: host.to_s) }

  private

  def summary_word_count_within_limit
    return if summary.blank?
    return if summary.split.size <= MAX_WORDS

    errors.add(:summary, "must contain at most #{MAX_WORDS} words")
  end
end

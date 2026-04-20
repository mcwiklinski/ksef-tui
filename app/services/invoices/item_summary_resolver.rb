# frozen_string_literal: true

module Invoices
  class ItemSummaryResolver
    MAX_WORDS = InvoiceItemSummary::MAX_WORDS
    GENERIC_FALLBACK = "Invoice items"
    OPENAI_SOURCE = "openai"
    FALLBACK_SOURCE = "fallback"
    MAX_PROMPT_ITEMS = 12
    OPENAI_REASONING_EFFORT = "low"
    OPENAI_VERBOSITY = "low"
    OPENAI_TEMPERATURE = 0.1
    CODE_TOKEN_PATTERN = /\A(?=.*\d)[\p{L}\d-]{5,}\z/u
    ALPHANUMERIC_TOKEN_PATTERN = /\A(?=.*\d)(?=.*\p{L})[\p{L}\d-]{3,}\z/u
    LONG_UPPERCASE_TOKEN_PATTERN = /\A[\p{Lu}\d-]{5,}\z/u
    NUMERIC_TOKEN_PATTERN = /\A\d{2,}\z/

    def initialize(client:, llm_client: nil)
      @client = client
      @llm_client = llm_client || Openai::ResponsesClient.new
    end

    def resolve(ksef_number:)
      raise ArgumentError, "ksef_number is required" if ksef_number.to_s.strip.empty?

      summary = find_cached_summary(ksef_number)
      return summary if summary

      invoice = Ksef::Models::Invoice.find(ksef_number: ksef_number, client: client)
      create_summary_for_invoice(invoice)
    end

    private

    attr_reader :client, :llm_client

    def create_summary_for_invoice(invoice)
      summary_text, source = build_summary(invoice)
      persist_summary(
        host: invoice_host,
        ksef_number: invoice.ksef_number,
        summary: summary_text,
        source: source
      )
    end

    def build_summary(invoice)
      candidate, rejected_answer = generate_openai_summary(invoice, strict: false)
      return [ candidate, OPENAI_SOURCE ] if candidate.present?

      candidate, = generate_openai_summary(
        invoice,
        strict: true,
        previous_attempt: rejected_answer,
        truncate: true
      )
      return [ candidate, OPENAI_SOURCE ] if candidate.present?

      [ fallback_summary(invoice.items), FALLBACK_SOURCE ]
    end

    def generate_openai_summary(invoice, strict:, previous_attempt: nil, truncate: false)
      return [ nil, nil ] if invoice.items.empty?
      return [ nil, nil ] unless llm_client.configured?

      raw_text = llm_client.generate_text(
        instructions: openai_instructions(strict: strict, previous_attempt: previous_attempt),
        input: openai_input(invoice),
        max_output_tokens: 24,
        temperature: OPENAI_TEMPERATURE,
        reasoning_effort: OPENAI_REASONING_EFFORT,
        verbosity: OPENAI_VERBOSITY
      )

      [
        normalize_generated_summary(raw_text, invoice: invoice, truncate: truncate),
        raw_text
      ]
    rescue Openai::ResponsesClient::Error => e
      Rails.logger.warn("Invoice item summary OpenAI generation failed for #{invoice.ksef_number}: #{e.message}")
      [ nil, nil ]
    end

    def openai_instructions(strict:, previous_attempt: nil)
      guidance = [
        "Generate the shortest human-friendly expense label for filenames and CSV exports.",
        "This is a filing label, not a literal restatement of invoice lines.",
        "Return plain text only in the source language of the item descriptions.",
        "Prefer 2 to 5 words.",
        "Never exceed 7 words.",
        "Prefer a broad category or umbrella label over literal product or service names.",
        "Use seller context only to disambiguate the likely purchase category.",
        "Never return the seller or buyer legal name by itself.",
        "Avoid SKUs, CN codes, catalog numbers, model numbers, or duplicated item names.",
        "If multiple lines are variants of the same thing, choose one concise category.",
        "Use umbrella labels when they are clearer than listing low-level services.",
        "Do not use quotes, bullets, labels, or punctuation-heavy formatting.",
        "Do not mention the word invoice unless it is part of an actual item description.",
        'Examples: "EFECTA 95 CN27101245" -> "Paliwo".',
        'Examples: "Worki do segregacji", "Worki na śmieci" -> "Worki na śmieci".',
        'Examples: "Amazon Simple Storage", "Amazon EC2 Container" -> "Amazon AWS".'
      ]

      if strict
        guidance << "The previous answer was too literal, too technical, too long, or just repeated line names."
        guidance << %(Previous rejected answer: "#{normalize_plain_text(previous_attempt)}".) if previous_attempt.present?
        guidance << "Correct it by making the label broader, shorter, and more useful to a human scanning filenames."
        guidance << "Be extra strict about returning 7 words or fewer."
      end

      guidance.join(" ")
    end

    def openai_input(invoice)
      lines = invoice.items.first(MAX_PROMPT_ITEMS).each_with_index.filter_map do |item, index|
        parts = []
        description = normalize_plain_text(item["description"])
        next if description.blank?

        parts << description

        quantity = item["quantity"].to_s.strip
        unit = item["unit"].to_s.strip
        if quantity.present?
          quantity_details = [ quantity, unit.presence ].compact.join(" ")
          parts << "qty #{quantity_details}"
        end

        "#{index + 1}. #{parts.reject(&:blank?).join(' | ')}"
      end

      context_lines = [
        "Purpose: Create the shortest human-friendly expense label for a filename or CSV row.",
        "Seller context: #{normalize_plain_text(invoice.seller_name).presence || 'Unknown seller'}"
      ]
      invoice_type = normalize_plain_text(invoice.invoice_type)
      context_lines << "Invoice type: #{invoice_type}" if invoice_type.present?

      <<~TEXT.strip
        #{context_lines.join("\n")}
        Item lines:
        #{lines.join("\n")}
      TEXT
    end

    def normalize_generated_summary(text, invoice:, truncate:)
      normalized = normalize_plain_text(text)
      normalized = collapse_repeated_leading_phrase(normalized)
      return nil if normalized.blank?
      return nil if party_label?(normalized, invoice)
      return nil if code_heavy?(normalized)

      words = normalized.split
      return nil if words.empty?

      if words.size > MAX_WORDS
        return nil unless truncate

        normalized = words.first(MAX_WORDS).join(" ")
      end

      normalized
    end

    def normalize_plain_text(text)
      text.to_s
        .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        .gsub(/[\r\n\t]/, " ")
        .gsub(/[“”„"']/, "")
        .gsub(/[^\p{L}\p{N}\s-]/u, " ")
        .gsub(/\s+/, " ")
        .strip
    end

    def party_label?(summary, invoice)
      candidate = canonical_text(summary)
      return true if candidate.blank?

      [ invoice.seller_name, invoice.buyer_name ].compact.any? do |party_name|
        candidate == canonical_text(party_name)
      end
    end

    def canonical_text(text)
      normalize_plain_text(text).downcase
    end

    def fallback_summary(items)
      phrases = items.filter_map do |item|
        phrase = fallback_description(item["description"])
        phrase if phrase.present?
      end.uniq

      return GENERIC_FALLBACK if phrases.empty?

      summary = phrases.min_by { |phrase| [ phrase.split.size, phrase.length ] }
      summary = collapse_repeated_leading_phrase(summary)
      summary = summary.to_s.split.first(MAX_WORDS).join(" ").strip
      summary.presence || GENERIC_FALLBACK
    end

    def fallback_description(text)
      words = normalize_plain_text(text).split.reject { |word| technical_token?(word) }
      words.join(" ").strip
    end

    def collapse_repeated_leading_phrase(summary)
      words = summary.to_s.split
      return summary if words.length < 4

      first_word = canonical_text(words.first)
      repeated_index = words.index.with_index { |word, index| index.positive? && canonical_text(word) == first_word }
      return summary unless repeated_index

      collapsed = words[repeated_index..].join(" ").strip
      collapsed.split.size < words.size ? collapsed : summary
    end

    def code_heavy?(summary)
      summary.to_s.split.any? { |word| technical_token?(word) }
    end

    def code_token?(word)
      word.match?(CODE_TOKEN_PATTERN)
    end

    def technical_token?(word)
      code_token?(word) ||
        word.match?(ALPHANUMERIC_TOKEN_PATTERN) ||
        word.match?(LONG_UPPERCASE_TOKEN_PATTERN) ||
        word.match?(NUMERIC_TOKEN_PATTERN)
    end

    def persist_summary(host:, ksef_number:, summary:, source:)
      InvoiceItemSummary.create!(
        host: host,
        ksef_number: ksef_number,
        summary: summary,
        source: source
      )
    rescue ActiveRecord::RecordNotUnique
      InvoiceItemSummary.find_by!(host: host, ksef_number: ksef_number)
    end

    def find_cached_summary(ksef_number)
      InvoiceItemSummary.find_by(host: invoice_host, ksef_number: ksef_number)
    end

    def invoice_host
      client.host.to_s
    end
  end
end

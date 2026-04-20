# frozen_string_literal: true

require "test_helper"

module Invoices
  class ItemSummaryResolverTest < ActiveSupport::TestCase
    class FakeClient
      attr_reader :host, :requested_paths

      def initialize(xml:, host: "api-test.example")
        @xml = xml
        @host = host
        @requested_paths = []
      end

      def get_xml(path)
        @requested_paths << path
        @xml
      end
    end

    class FakeLlmClient
      attr_reader :calls

      def initialize(responses: [], configured: true, error: nil)
        @responses = responses.dup
        @configured = configured
        @error = error
        @calls = []
      end

      def configured?
        @configured
      end

      def generate_text(**kwargs)
        @calls << kwargs
        raise @error if @error

        @responses.shift
      end
    end

    def setup
      super
      @invoice_xml = <<~XML
        <fa:Faktura xmlns:fa="http://crd.gov.pl/wzor/2025/06/25/13775/">
          <fa:Podmiot1>
            <fa:DaneIdentyfikacyjne>
              <fa:Nazwa>XML Seller</fa:Nazwa>
            </fa:DaneIdentyfikacyjne>
            <fa:Adres>
              <fa:Ulica>Sprzedazowa</fa:Ulica>
              <fa:NrDomu>7</fa:NrDomu>
              <fa:KodPocztowy>00-010</fa:KodPocztowy>
              <fa:Miejscowosc>Warszawa</fa:Miejscowosc>
            </fa:Adres>
          </fa:Podmiot1>
          <fa:Podmiot2>
            <fa:DaneIdentyfikacyjne>
              <fa:Nazwa>XML Buyer</fa:Nazwa>
            </fa:DaneIdentyfikacyjne>
            <fa:Adres>
              <fa:Ulica>Kupiecka</fa:Ulica>
              <fa:NrDomu>8</fa:NrDomu>
              <fa:KodPocztowy>00-020</fa:KodPocztowy>
              <fa:Miejscowosc>Warszawa</fa:Miejscowosc>
            </fa:Adres>
          </fa:Podmiot2>
          <fa:Fa>
            <fa:P_2>XML/1</fa:P_2>
            <fa:RodzajFaktury>VAT</fa:RodzajFaktury>
          </fa:Fa>
          <fa:FaWiersz>
            <fa:NrWierszaFa>1</fa:NrWierszaFa>
            <fa:P_7>Biurko ergonomiczne premium</fa:P_7>
            <fa:P_8B>2</fa:P_8B>
            <fa:P_8A>szt</fa:P_8A>
          </fa:FaWiersz>
          <fa:FaWiersz>
            <fa:NrWierszaFa>2</fa:NrWierszaFa>
            <fa:P_7>Lampa biurkowa LED</fa:P_7>
            <fa:P_8B>2</fa:P_8B>
            <fa:P_8A>szt</fa:P_8A>
          </fa:FaWiersz>
        </fa:Faktura>
      XML
    end

    def test_returns_cached_summary_without_fetching_invoice_or_calling_llm
      InvoiceItemSummary.create!(
        host: "api-test.example",
        ksef_number: "KSEF-1",
        summary: "Cached office gear",
        source: "openai"
      )

      client = FakeClient.new(xml: @invoice_xml)
      llm_client = FakeLlmClient.new(responses: [ "Should not be used" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-1")

      assert_equal "Cached office gear", summary.summary
      assert_empty client.requested_paths
      assert_empty llm_client.calls
    end

    def test_generates_and_persists_openai_summary
      client = FakeClient.new(xml: @invoice_xml)
      llm_client = FakeLlmClient.new(responses: [ "Biurka i lampy" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-XML-1")

      assert_equal "Biurka i lampy", summary.summary
      assert_equal "openai", summary.source
      assert_equal [ "/invoices/ksef/KSEF-XML-1" ], client.requested_paths
      assert_equal summary, InvoiceItemSummary.find_by!(host: "api-test.example", ksef_number: "KSEF-XML-1")

      llm_call = llm_client.calls.first
      assert_equal "low", llm_call[:reasoning_effort]
      assert_equal "low", llm_call[:verbosity]
      assert_equal 0.1, llm_call[:temperature]
      assert_includes llm_call[:instructions], "shortest human-friendly expense label"
      assert_includes llm_call[:input], "Seller context: XML Seller"
      assert_includes llm_call[:input], "Invoice type: VAT"
      assert_includes llm_call[:input], "1. Biurko ergonomiczne premium | qty 2 szt"
      refute_includes llm_call[:input], "XML Buyer"
      refute_includes llm_call[:input], "Sprzedazowa"
      refute_includes llm_call[:input], "Kupiecka"
    end

    def test_retries_once_then_uses_shorter_openai_summary
      client = FakeClient.new(xml: @invoice_xml)
      llm_client = FakeLlmClient.new(responses: [
        "one two three four five six seven eight",
        "Biurka i lampy"
      ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-XML-2")

      assert_equal "Biurka i lampy", summary.summary
      assert_equal 2, llm_client.calls.length
      assert_includes llm_client.calls.second[:instructions], "Previous rejected answer"
      assert_includes llm_client.calls.second[:instructions], "one two three four five six seven eight"
    end

    def test_falls_back_to_item_descriptions_when_llm_output_is_invalid
      client = FakeClient.new(xml: @invoice_xml)
      llm_client = FakeLlmClient.new(responses: [ "XML Seller", "XML Buyer" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-XML-3")

      assert_equal "Lampa biurkowa LED", summary.summary
      assert_equal "fallback", summary.source
    end

    def test_retries_with_stricter_prompt_for_fuel_style_output
      client = FakeClient.new(xml: invoice_xml_with_descriptions("EFECTA 95 CN27101245"))
      llm_client = FakeLlmClient.new(responses: [ "EFECTA 95 CN27101245", "Paliwo" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-FUEL-1")

      assert_equal "Paliwo", summary.summary
      assert_equal "openai", summary.source
      assert_equal 2, llm_client.calls.length
    end

    def test_collapses_duplicate_bag_labels_to_single_human_friendly_summary
      client = FakeClient.new(xml: invoice_xml_with_descriptions("Worki do segregacji", "Worki na śmieci"))
      llm_client = FakeLlmClient.new(responses: [ "Worki do segregacji Worki na śmieci" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-BAGS-1")

      assert_equal "Worki na śmieci", summary.summary
      assert_equal "openai", summary.source
    end

    def test_retries_with_stricter_prompt_for_aws_service_names
      client = FakeClient.new(xml: invoice_xml_with_descriptions("Amazon Simple Storage", "Amazon EC2 Container"))
      llm_client = FakeLlmClient.new(responses: [ "Amazon Simple Storage Amazon EC2 Container", "Amazon AWS" ])

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-AWS-1")

      assert_equal "Amazon AWS", summary.summary
      assert_equal "openai", summary.source
      assert_equal 2, llm_client.calls.length
    end

    def test_uses_generic_fallback_when_invoice_has_no_item_descriptions
      client = FakeClient.new(xml: <<~XML)
        <fa:Faktura xmlns:fa="http://crd.gov.pl/wzor/2025/06/25/13775/">
          <fa:Fa>
            <fa:P_2>XML/2</fa:P_2>
          </fa:Fa>
        </fa:Faktura>
      XML
      llm_client = FakeLlmClient.new(configured: false)

      summary = ItemSummaryResolver.new(client: client, llm_client: llm_client).resolve(ksef_number: "KSEF-XML-4")

      assert_equal "Invoice items", summary.summary
      assert_equal "fallback", summary.source
    end

    private

    def invoice_xml_with_descriptions(*descriptions)
      rows = descriptions.map.with_index(1) do |description, index|
        <<~XML
          <fa:FaWiersz>
            <fa:NrWierszaFa>#{index}</fa:NrWierszaFa>
            <fa:P_7>#{description}</fa:P_7>
            <fa:P_8B>1</fa:P_8B>
            <fa:P_8A>szt</fa:P_8A>
          </fa:FaWiersz>
        XML
      end.join

      <<~XML
        <fa:Faktura xmlns:fa="http://crd.gov.pl/wzor/2025/06/25/13775/">
          <fa:Podmiot1>
            <fa:DaneIdentyfikacyjne>
              <fa:Nazwa>XML Seller</fa:Nazwa>
            </fa:DaneIdentyfikacyjne>
          </fa:Podmiot1>
          <fa:Podmiot2>
            <fa:DaneIdentyfikacyjne>
              <fa:Nazwa>XML Buyer</fa:Nazwa>
            </fa:DaneIdentyfikacyjne>
          </fa:Podmiot2>
          <fa:Fa>
            <fa:P_2>XML/1</fa:P_2>
          </fa:Fa>
          #{rows}
        </fa:Faktura>
      XML
    end
  end
end

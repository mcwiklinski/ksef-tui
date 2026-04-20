# frozen_string_literal: true

require "application_system_test_case"

class InvoiceItemSummariesTest < ApplicationSystemTestCase
  def setup
    super
    @config_path = File.join(Dir.tmpdir, "invoice_item_summaries_test_#{Process.pid}_#{object_id}.yml")
    File.write(@config_path, <<~YAML)
      settings:
        default_host: "api.default.example"
      profiles:
        - name: "HENTO (testowe)"
          id: "hento-testowe"
          nip: "1111111111"
          token: "seed-token"
          host: "api-test.example"
    YAML
    Profile.config_file = @config_path
    @invoice_xml = <<~XML
      <fa:Faktura xmlns:fa="http://crd.gov.pl/wzor/2025/06/25/13775/">
        <fa:Fa>
          <fa:P_2>XML/1</fa:P_2>
        </fa:Fa>
        <fa:FaWiersz>
          <fa:NrWierszaFa>1</fa:NrWierszaFa>
          <fa:P_7>Pozycja XML</fa:P_7>
          <fa:P_8B>1</fa:P_8B>
          <fa:P_8A>szt</fa:P_8A>
        </fa:FaWiersz>
      </fa:Faktura>
    XML
    @invoice_list = [
      {
        ksefNumber: "KSEF-1",
        invoiceNumber: "FV/1/2026",
        issueDate: "2026-02-11",
        netAmount: "100.00",
        grossAmount: "123.00",
        currency: "PLN",
        invoiceType: "VAT",
        seller: {
          name: "Acme Sp. z o.o.",
          nip: "1234567890"
        }
      }
    ]
  end

  def teardown
    Profile.config_file = nil
    FileUtils.rm_f(@config_path)
    KsefLoginRequest.delete_all
    super
  end

  def test_invoice_list_replaces_placeholder_with_generated_summary
    stub_invoice_list_fetch
    stub_invoice_xml_fetch("KSEF-1")

    with_openai_configuration do
      stub_openai_summary("Pozycja XML")
      login_and_finalize_session!
      visit invoices_path

      assert_selector "tr[data-ksef-number='KSEF-1'] span", text: "Waiting for summary..."
      assert_selector "tr[data-ksef-number='KSEF-1'] span[data-summary-status='ready']", text: "Pozycja XML", wait: 10
    end
  end

  private

  def login_and_finalize_session!
    visit new_session_path
    click_on "HENTO (testowe)"
    assert_text "Authorizing with KSeF"

    login_request = KsefLoginRequest.find(current_url[%r{/sessions/(\d+)}, 1])
    login_request.complete_success!(
      access_token: "session-token",
      refresh_token: "refresh-token",
      valid_until: "2026-02-20T10:00:00Z",
      refresh_token_valid_until: "2026-02-21T10:00:00Z"
    )

    assert_text "Logged in successfully to KSeF", wait: 10
  end

  def stub_invoice_list_fetch
    stub_request(:post, invoice_query_api_url)
      .with(headers: { "Authorization" => "Bearer session-token" })
      .to_return(
        status: 200,
        body: { invoices: @invoice_list }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_invoice_xml_fetch(ksef_number)
    stub_request(:get, invoice_xml_api_url(ksef_number))
      .with(headers: { "Accept" => "application/xml", "Authorization" => "Bearer session-token" })
      .to_return(status: 200, body: @invoice_xml, headers: { "Content-Type" => "application/xml" })
  end

  def stub_openai_summary(summary)
    stub_request(:post, openai_responses_api_url)
      .to_return do
        sleep 0.25

        {
          status: 200,
          body: {
            output: [
              {
                type: "message",
                role: "assistant",
                content: [
                  {
                    type: "output_text",
                    text: summary,
                    annotations: []
                  }
                ]
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        }
      end
  end

  def invoice_query_api_url
    "https://api-test.example/v2/invoices/query/metadata?pageSize=100"
  end

  def invoice_xml_api_url(ksef_number)
    "https://api-test.example/v2/invoices/ksef/#{ksef_number}"
  end

  def openai_responses_api_url
    "https://api.openai.com/v1/responses"
  end

  def with_openai_configuration
    original_api_key = ENV["OPENAI_API_KEY"]
    original_model = ENV["OPENAI_MODEL"]

    ENV["OPENAI_API_KEY"] = "test-openai-key"
    ENV["OPENAI_MODEL"] = "gpt-5.4-mini"
    yield
  ensure
    ENV["OPENAI_API_KEY"] = original_api_key
    ENV["OPENAI_MODEL"] = original_model
  end
end

require "csv"

class InvoicesController < ApplicationController
  class InvoiceDownloadError < StandardError
    attr_reader :status

    def initialize(message, status: :bad_gateway)
      @status = status
      super(message)
    end
  end

  before_action :authenticate_session!
  before_action :build_filter, only: [ :index, :download_csv, :regenerate_summaries ]

  def index
    @invoices = @filter.valid? ? load_invoices(query_params: @filter.query_params) : []
    @invoice_summaries = preload_invoice_summaries(@invoices)
  end

  def download_csv
    unless @filter.valid?
      redirect_to invoices_path(@filter.request_params), alert: @filter.error
      return
    end

    invoices = load_invoices(query_params: @filter.query_params, redirect_on_error: true)
    return if performed?

    invoice_summaries = resolve_invoice_summaries(invoices)

    send_data invoices_to_csv(invoices, invoice_summaries: invoice_summaries),
      filename: "invoices-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8",
      disposition: "attachment"
  end

  def regenerate_summaries
    unless @filter.valid?
      redirect_to invoices_path(@filter.request_params), alert: @filter.error
      return
    end

    invoices = load_invoices(query_params: @filter.query_params, redirect_on_error: true)
    return if performed?

    cleared_count = clear_invoice_summaries(invoices)
    notice =
      if cleared_count.positive?
        "Cleared #{cleared_count} summaries. The list will regenerate them in the background."
      else
        "No cached summaries were found for the current list."
      end

    redirect_to invoices_path(@filter.request_params), notice: notice
  end

  def item_summary
    summary = summary_resolver.resolve(ksef_number: params[:id])
    render_summary_json(summary)
  rescue Ksef::InvoiceError => e
    render json: { error: "Failed to generate invoice summary: #{e.message}" }, status: invoice_error_status(e)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to save invoice summary: #{e.record.errors.full_messages.to_sentence}" }, status: :unprocessable_entity
  end

  def regenerate_item_summary
    clear_invoice_summary(params[:id])
    summary = summary_resolver.resolve(ksef_number: params[:id])
    render_summary_json(summary)
  rescue Ksef::InvoiceError => e
    render json: { error: "Failed to generate invoice summary: #{e.message}" }, status: invoice_error_status(e)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to save invoice summary: #{e.record.errors.full_messages.to_sentence}" }, status: :unprocessable_entity
  end

  def show
    begin
      @invoice = Ksef::Models::Invoice.find(ksef_number: params[:id], client: current_client)
    rescue => e
      redirect_to invoices_path, alert: "Invoice not found or error loading: #{e.message}"
    end
  end

  def xml
    xml_content = fetch_invoice_xml!(params[:id])
    render plain: xml_content, content_type: "application/xml"
  rescue InvoiceDownloadError => e
    render plain: e.message, status: e.status
  end


  def download
    ksef_number = params[:id]
    begin
      xml_content = fetch_invoice_xml!(ksef_number)
      send_data xml_content, filename: "#{ksef_number}.xml", type: "application/xml", disposition: "attachment"
    rescue InvoiceDownloadError => e
      redirect_to invoice_path(ksef_number), alert: "Failed to download XML: #{e.message}"
    end
  end

  private

  def build_filter
    @filter = Invoices::DateFilter.new(params)
  end

  def load_invoices(query_params:, redirect_on_error: false)
    Ksef::Models::Invoice.find_all(query_body: query_params, client: current_client)
  rescue Ksef::InvoiceError => e
    return handle_session_expired_error if session_expired_error?(e)

    handle_invoice_fetch_error(e, redirect_on_error: redirect_on_error)
  rescue => e
    handle_invoice_fetch_error(e, redirect_on_error: redirect_on_error)
  end

  def invoices_to_csv(invoices, invoice_summaries:)
    CSV.generate do |csv|
      csv << [
        "Invoice issue date",
        "Seller name",
        "Net total amount (excluding VAT)",
        "Total amount including VAT",
        "Currency",
        "Item summary"
      ]

      invoices.each do |invoice|
        csv << [
          invoice.issue_date,
          sanitize_csv_text_cell(invoice.seller_name),
          invoice.net_amount,
          invoice.gross_amount,
          invoice.currency,
          sanitize_csv_text_cell(invoice_summaries.fetch(invoice.ksef_number).summary)
        ]
      end
    end
  end

  def preload_invoice_summaries(invoices)
    return {} if invoices.empty?

    InvoiceItemSummary
      .for_host(current_client.host)
      .where(ksef_number: invoices.map(&:ksef_number))
      .index_by(&:ksef_number)
  end

  def resolve_invoice_summaries(invoices)
    summaries = preload_invoice_summaries(invoices)

    invoices.each do |invoice|
      summaries[invoice.ksef_number] ||= summary_resolver.resolve(ksef_number: invoice.ksef_number)
    end

    summaries
  end

  def clear_invoice_summaries(invoices)
    return 0 if invoices.empty?

    InvoiceItemSummary
      .for_host(current_client.host)
      .where(ksef_number: invoices.map(&:ksef_number))
      .delete_all
  end

  def clear_invoice_summary(ksef_number)
    InvoiceItemSummary
      .for_host(current_client.host)
      .where(ksef_number: ksef_number)
      .delete_all
  end

  def summary_resolver
    @summary_resolver ||= Invoices::ItemSummaryResolver.new(client: current_client)
  end

  def render_summary_json(summary)
    render json: {
      ksefNumber: summary.ksef_number,
      summary: summary.summary,
      source: summary.source
    }
  end

  def sanitize_csv_text_cell(value)
    return value if value.blank?
    return value unless value.match?(/\A[[:space:]]*[=+\-@]/)

    "'#{value}"
  end

  def fetch_invoice_xml!(ksef_number)
    response = current_client.get_xml("/invoices/ksef/#{CGI.escape(ksef_number)}")
    return response if response.is_a?(String)

    if response.is_a?(Hash)
      status = Integer(response["http_status"], exception: false)
      status = :bad_gateway if status.nil? || status < 400
      raise InvoiceDownloadError.new(response["error"] || "Failed to fetch invoice XML", status: status)
    end

    raise InvoiceDownloadError.new("Invalid XML invoice response")
  end

  def session_expired_error?(error)
    return true if [ 401, 403 ].include?(Integer(error.http_status, exception: false))

    error.message.to_s.match?(/\AHTTP (401|403)\z/)
  end

  def handle_session_expired_error
    reset_session
    redirect_to new_session_path, alert: "Session expired. Please log in again."
    []
  end

  def handle_invoice_fetch_error(error, redirect_on_error:)
    message = "Failed to fetch invoices: #{error.message}"

    if redirect_on_error
      redirect_to invoices_path(@filter.request_params), alert: message
    else
      flash.now[:alert] = message
    end

    []
  end

  def invoice_error_status(error)
    status = Integer(error.http_status, exception: false)
    return status if status && status >= 400

    :bad_gateway
  end
end

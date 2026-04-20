# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Openai
  class ResponsesClient
    API_URL = "https://api.openai.com/v1/responses"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    WRITE_TIMEOUT = 10

    Error = Class.new(StandardError)
    ConfigurationError = Class.new(Error)
    RequestError = Class.new(Error)
    ResponseError = Class.new(Error)

    def initialize(api_key: ENV["OPENAI_API_KEY"], model: ENV["OPENAI_MODEL"])
      @api_key = api_key.to_s.strip
      @model = model.to_s.strip
    end

    def configured?
      api_key.present? && model.present?
    end

    def generate_text(
      instructions:,
      input:,
      max_output_tokens: 32,
      temperature: 0.2,
      reasoning_effort: nil,
      verbosity: nil
    )
      raise ConfigurationError, "OPENAI_API_KEY and OPENAI_MODEL must be configured" unless configured?

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"] = "application/json"
      payload = {
        model: model,
        store: false,
        instructions: instructions,
        input: input,
        max_output_tokens: max_output_tokens,
        temperature: temperature,
        text: {
          format: {
            type: "text"
          }
        }
      }
      payload[:reasoning] = { effort: reasoning_effort } if reasoning_effort.present?
      payload[:text][:verbosity] = verbosity if verbosity.present?
      request.body = payload.to_json

      response = http.request(request)
      parsed = parse_json(response.body)

      unless response.is_a?(Net::HTTPSuccess)
        message = parsed.dig("error", "message") || parsed["error"] || "OpenAI request failed with HTTP #{response.code}"
        raise RequestError, message
      end

      output_text = extract_output_text(parsed)
      raise ResponseError, "OpenAI response did not contain text output" if output_text.blank?

      output_text
    rescue JSON::ParserError => e
      raise ResponseError, "OpenAI response was not valid JSON: #{e.message}"
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise RequestError, "OpenAI request failed: #{e.message}"
    end

    private

    attr_reader :api_key, :model

    def parse_json(body)
      JSON.parse(body.to_s)
    end

    def extract_output_text(payload)
      direct_text = payload["output_text"].to_s.strip
      return direct_text if direct_text.present?

      Array(payload["output"]).filter_map do |item|
        next unless item["type"] == "message"

        Array(item["content"]).filter_map do |content|
          next unless content["type"] == "output_text"

          content["text"].to_s
        end.join(" ").strip
      end.reject(&:blank?).join(" ").strip
    end
  end
end

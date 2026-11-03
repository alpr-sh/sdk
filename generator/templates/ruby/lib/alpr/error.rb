# frozen_string_literal: true

require "json"

module Alpr
  # A request the API refused.
  #
  # +code+ is the API's: invalid_credential, forbidden, not_found,
  # invalid_request, conflict, idempotency_conflict, body_too_large or
  # unavailable. +message+ is the API's explanation, +fields+ says, for
  # invalid_request, what is wrong with each field, and +retry_after+ is how
  # many seconds to wait on a 429.
  class Error < StandardError
    attr_reader :status, :code, :message, :fields, :retry_after

    def initialize(status, code, message = "", fields = {}, retry_after = nil)
      @status = status
      @code = code
      @message = message
      @fields = fields
      @retry_after = retry_after
      super(message.empty? ? "alpr: #{status} #{code}" : "alpr: #{status} #{code}: #{message}")
    end

    # What Ruby prints for an error nobody rescued: the status and code too.
    def detailed_message(highlight: false, **)
      highlight ? "\e[1m#{self} (#{self.class.name})\e[m" : "#{self} (#{self.class.name})"
    end

    # The error a response with a status of 300 or more is.
    def self.from_response(status, headers, body)
      data = begin
        loaded = JSON.parse(body.to_s.empty? ? "{}" : body)
        loaded.is_a?(Hash) ? loaded : {}
      rescue JSON::ParserError
        {} # A refusal without a JSON body is still a refusal.
      end
      retry_after = headers["retry-after"].to_s
      new(status, data["error"].to_s, data["message"].to_s, data["fields"] || {},
          retry_after.match?(/\A\d+\z/) ? retry_after.to_i : nil)
    end
  end
end

# frozen_string_literal: true

module Ai
  class ClaudeClient
    def initialize
      @client = Anthropic::Client.new(access_token: ENV.fetch('ANTHROPIC_API_KEY'))
      @model = ENV.fetch('CLAUDE_MODEL', 'claude-sonnet-4-20250514')
    end

    def call_claude(prompt)
      response = @client.messages(
        parameters: {
          model: @model,
          max_tokens: 4096,
          messages: [{ role: 'user', content: prompt }]
        }
      )

      response.dig('content', 0, 'text')
    end

    def parse_json_response(text)
      json_match = text.match(/```(?:json)?\s*\n?(.*?)\n?```/m)
      json_str = json_match ? json_match[1] : text

      JSON.parse(json_str)
    rescue JSON::ParserError => e
      Rails.logger.warn("[AiAnalyzer] Failed to parse JSON response: #{e.message}")
      nil
    end
  end
end

# frozen_string_literal: true

module Fingerprinters
  module Wordpress
    # Evaluates the core WordPress detection signatures. `fetch` is a callable taking a
    # site-relative path and returning a response or nil.
    class SignatureEvaluator
      def initialize(config, fetch)
        @config = config
        @fetch = fetch
      end

      def call(html)
        {
          generator_meta: generator_meta(html),
          wp_content_path: html_substring(html, 'wp_content_path'),
          wp_includes_path: html_substring(html, 'wp_includes_path'),
          wp_json_rest: wp_json,
          readme_html: body_contains('readme_html', 'WordPress'),
          wp_login: body_contains('wp_login', /wordpress/i)
        }.compact
      end

      private

      def generator_meta(html)
        match = html.match(Regexp.new(@config['generator_meta']['pattern'], Regexp::IGNORECASE))
        return nil unless match

        hit = { weight: weight('generator_meta') }
        hit[:version] = match[1] if match[1]
        hit
      end

      def html_substring(html, name)
        html.include?(@config[name]['pattern']) ? { weight: weight(name) } : nil
      end

      def wp_json
        response = @fetch.call(@config['wp_json_rest']['path'])
        return nil unless response&.success?

        wordpress_like_json?(JSON.parse(response.body.to_s)) ? { weight: weight('wp_json_rest') } : nil
      rescue JSON::ParserError
        nil
      end

      def body_contains(name, needle)
        response = @fetch.call(@config[name]['path'])
        return nil unless response&.status&.between?(200, 299)

        body = response.body.to_s
        matched = needle.is_a?(Regexp) ? body.match?(needle) : body.include?(needle)
        matched ? { weight: weight(name) } : nil
      end

      def wordpress_like_json?(data)
        return false unless data.is_a?(Hash)

        namespaces = data['namespaces']
        return true if namespaces.is_a?(Array) && namespaces.include?('wp/v2')

        %w[name description url home].count { |k| data.key?(k) } >= 2
      end

      def weight(name)
        @config.dig(name, 'weight').to_f
      end
    end
  end
end

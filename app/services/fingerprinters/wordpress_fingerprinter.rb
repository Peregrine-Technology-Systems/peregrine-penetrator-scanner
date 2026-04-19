# frozen_string_literal: true

module Fingerprinters
  class WordpressFingerprinter < FingerprinterBase
    CONFIG_PATH = Penetrator.root.join('config/fingerprints/wordpress/core.yml')

    def cms_name = 'wordpress'

    def detect
      base_url = target.url_list.first
      return empty_result if base_url.nil?

      uri = parse_uri(base_url)
      return empty_result if uri.nil?

      hits = evaluate_signatures(base_url, uri)
      confidence = [hits.values.sum { |h| h[:weight] }, 1.0].min

      result = { cms: cms_name, confidence:, components: [] }
      core_version = hits.dig(:generator_meta, :version)
      result[:core_version] = core_version if core_version
      result
    end

    private

    def evaluate_signatures(base_url, uri)
      html = fetch_body(base_url)
      {
        generator_meta: evaluate_generator_meta(html),
        wp_content_path: evaluate_html_substring(html, 'wp_content_path'),
        wp_includes_path: evaluate_html_substring(html, 'wp_includes_path'),
        wp_json_rest: evaluate_wp_json(uri),
        readme_html: evaluate_body_contains(uri, 'readme_html', 'WordPress'),
        wp_login: evaluate_body_contains(uri, 'wp_login', /wordpress/i)
      }.compact
    end

    def evaluate_generator_meta(html)
      match = html.match(Regexp.new(config['generator_meta']['pattern'], Regexp::IGNORECASE))
      return nil unless match

      hit = { weight: weight('generator_meta') }
      hit[:version] = match[1] if match[1]
      hit
    end

    def evaluate_html_substring(html, name)
      html.include?(config[name]['pattern']) ? { weight: weight(name) } : nil
    end

    def evaluate_wp_json(uri)
      response = http_get(build_url(uri, config['wp_json_rest']['path']))
      return nil unless response&.success?

      data = JSON.parse(response.body.to_s)
      wordpress_like_json?(data) ? { weight: weight('wp_json_rest') } : nil
    rescue JSON::ParserError
      nil
    end

    def evaluate_body_contains(uri, name, needle)
      response = http_get(build_url(uri, config[name]['path']))
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

    def fetch_body(url)
      response = http_get(url)
      response&.success? ? response.body.to_s : ''
    end

    def parse_uri(url)
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    def build_url(uri, path)
      port_part = uri.port == uri.default_port ? '' : ":#{uri.port}"
      "#{uri.scheme}://#{uri.host}#{port_part}#{path}"
    end

    def config
      @config ||= YAML.safe_load_file(CONFIG_PATH).fetch('signatures')
    end

    def weight(name)
      config.dig(name, 'weight').to_f
    end
  end
end

Fingerprinters::FingerprinterRegistry.register(Fingerprinters::WordpressFingerprinter)

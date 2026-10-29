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

      html = fetch_body(base_url)
      fetch = ->(path) { http_get(build_url(uri, path)) }
      hits = Wordpress::SignatureEvaluator.new(config, fetch).call(html)
      confidence = [hits.values.sum { |h| h[:weight] }, 1.0].min

      components = confidence >= MIN_CONFIDENCE ? Wordpress::ComponentEnumerator.new(html, fetch).call : []
      result = { cms: cms_name, confidence:, components: }
      core_version = hits.dig(:generator_meta, :version)
      result[:core_version] = core_version if core_version
      result
    end

    private

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
  end
end

Fingerprinters::FingerprinterRegistry.register(Fingerprinters::WordpressFingerprinter)

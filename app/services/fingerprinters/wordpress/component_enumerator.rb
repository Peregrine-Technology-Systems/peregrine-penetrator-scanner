# frozen_string_literal: true

module Fingerprinters
  module Wordpress
    # Passively lists plugins and themes referenced by a WordPress homepage (#1253).
    # `fetch` is a callable taking a site-relative path and returning a response or nil.
    class ComponentEnumerator
      SLUG_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
      REFERENCE = %r{/wp-content/(plugins|themes)/([^/"'\s?#<>)\\]{1,200})/}i
      # Bounds on extra GETs so a hostile page cannot make us request without limit.
      MAX_PLUGIN_FETCHES = 25
      MAX_THEME_FETCHES = 5
      MAX_COMPONENTS = 100
      CONFIDENCE = { none: 0.2, asset: 0.5, confirmed: 0.9 }.freeze

      def initialize(html, fetch)
        @html = html.to_s
        @fetch = fetch
      end

      def call
        budget = { 'plugins' => MAX_PLUGIN_FETCHES, 'themes' => MAX_THEME_FETCHES }
        references.first(MAX_COMPONENTS).map do |kind, slug|
          confirmed = budget[kind].positive? ? confirmed_version(kind, slug, budget) : nil
          build(kind, slug, confirmed)
        end
      end

      private

      def references
        pairs = @html.scan(REFERENCE).map { |kind, slug| [kind.downcase, slug.downcase] }
        pairs.select { |_, slug| slug.match?(SLUG_PATTERN) }.uniq
      end

      def confirmed_version(kind, slug, budget)
        budget[kind] -= 1
        response = @fetch.call(source_path(kind, slug))
        return nil unless response&.success?

        body = response.body
        kind == 'plugins' ? VersionInference.stable_tag(body) : VersionInference.style_version(body)
      end

      def source_path(kind, slug)
        file = kind == 'plugins' ? 'readme.txt' : 'style.css'
        "/wp-content/#{kind}/#{slug}/#{file}"
      end

      def build(kind, slug, confirmed)
        asset = VersionInference.asset_version(@html, kind, slug)
        level = confirmed ? :confirmed : (:asset if asset) || :none
        { kind: kind.chomp('s'), slug:, version: confirmed || asset, confidence: CONFIDENCE.fetch(level) }
      end
    end
  end
end

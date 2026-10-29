# frozen_string_literal: true

module Fingerprinters
  module Wordpress
    # Pure parsers that pull a version string out of passive evidence: a readme.txt
    # "Stable tag:", a theme style.css "Version:" header, or an asset "?ver=" query.
    # Values are accepted only when they look like a version, so hostile text is dropped.
    module VersionInference
      VERSION_PATTERN = /\A[0-9][0-9A-Za-z.+_-]{0,31}\z/
      STABLE_TAG = /^[ \t]*Stable tag:[ \t]*(\S+)/i
      STYLE_VERSION = /^[ \t*]*Version:[ \t]*(\S+)/i
      HEADER_WINDOW = 8192

      module_function

      def stable_tag(body)
        accept(body.to_s[STABLE_TAG, 1])
      end

      def style_version(body)
        accept(body.to_s[0, HEADER_WINDOW][STYLE_VERSION, 1])
      end

      # kind is 'plugins' or 'themes'. The slug must be followed by a slash so that
      # "foo" never matches "foobar".
      def asset_version(html, kind, slug)
        asset = %r{/wp-content/#{kind}/#{Regexp.escape(slug)}/[^"'\s<>]*?[?&;]ver=([^"'\s<>&;#]+)}i
        accept(html.to_s[asset, 1])
      end

      def accept(value)
        value if value&.match?(VERSION_PATTERN)
      end
    end
  end
end

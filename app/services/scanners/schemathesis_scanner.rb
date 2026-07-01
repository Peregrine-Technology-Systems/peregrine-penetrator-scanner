require 'net/http'
require 'shellwords'
require 'digest'

module Scanners
  # Unauthenticated, schema-driven API fuzzing via schemathesis (#1018).
  #
  # Black-box by construction: it discovers a publicly reachable OpenAPI schema at
  # well-known paths on the target (no credentials, no login) and fuzzes every
  # operation the schema declares. A schema-source URL is data, not a credential,
  # so this stays inside the fleet's no-authenticated-testing posture.
  #
  # If no schema is reachable unauthenticated, the probe is honestly NOT-APPLICABLE
  # (empty findings + a logged note) — it never fabricates a pass. An explicit
  # `schema_url:` in the profile's tool block overrides discovery (still just
  # tool_config, like nikto's `tuning:` — no orchestrator contract change).
  class SchemathesisScanner < ScannerBase
    EXECUTABLE = 'schemathesis'.freeze

    # Ordered by prevalence. First path that returns 200 with an OpenAPI/Swagger
    # document wins.
    WELL_KNOWN_SCHEMA_PATHS = %w[
      /openapi.json /swagger.json /v3/api-docs /openapi.yaml
      /swagger/v1/swagger.json /api-docs /q/openapi /api/openapi.json
    ].freeze

    def tool_name
      'schemathesis'
    end

    protected

    def execute
      all_findings = []
      any_schema = false

      target_urls.each do |url|
        schema_url = tool_config[:schema_url] || discover_schema(url)
        next unless schema_url

        any_schema = true
        output_file = output_dir.join("schemathesis_#{Digest::MD5.hexdigest(schema_url)}.xml")
        run_command(build_command(schema_url, output_file), timeout: tool_config[:timeout])
        all_findings.concat(parse_results(output_file))
      end

      logger.info("[#{tool_name}] No unauthenticated API schema reachable — NOT APPLICABLE (0 findings)") unless any_schema

      { success: true, findings: all_findings }
    end

    private

    def build_command(schema_url, output_file)
      rate = tool_config[:rate_limit] || '5/s'
      cmd = "#{EXECUTABLE} run #{Shellwords.escape(schema_url)}"
      cmd << " --report junit --report-junit-path #{output_file}"
      cmd << " --rate-limit #{Shellwords.escape(rate)}"
      cmd << " --max-failures #{tool_config[:max_failures] || 100}"
      cmd << " --workers #{tool_config[:workers] || 2}"
      cmd << " --request-timeout #{tool_config[:request_timeout] || 10}"
      # Non-zero exit on found failures is expected; we parse the report regardless.
      cmd
    end

    # Probes well-known schema paths on the target's origin. Returns the first URL
    # that answers 200 with a body that parses as an OpenAPI/Swagger document.
    # Any network error on a path is non-fatal — we just try the next one.
    def discover_schema(target_url)
      origin = origin_of(target_url)
      return nil unless origin

      WELL_KNOWN_SCHEMA_PATHS.each do |path|
        candidate = "#{origin}#{path}"
        return candidate if openapi_document?(candidate)
      end
      nil
    end

    def origin_of(url)
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP)

      port = uri.port && uri.default_port != uri.port ? ":#{uri.port}" : ''
      "#{uri.scheme}://#{uri.host}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    def openapi_document?(candidate)
      uri = URI.parse(candidate)
      body = fetch(uri)
      return false unless body

      looks_like_openapi?(body)
    rescue StandardError => e
      logger.debug("[#{tool_name}] schema probe #{candidate} failed: #{e.message}")
      false
    end

    def fetch(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 8, read_timeout: 8) do |http|
        resp = http.get(uri.request_uri)
        return nil unless resp.is_a?(Net::HTTPSuccess)

        resp.body
      end
    end

    # A cheap structural check — a real OpenAPI/Swagger doc declares its version at
    # the top level. Avoids a full parse and tolerates both JSON and YAML forms.
    def looks_like_openapi?(body)
      head = body[0, 4096].to_s
      head.match?(/["']?(openapi|swagger)["']?\s*[:=]/i)
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::SchemathesisParser.new(output_file).parse
    end
  end
end

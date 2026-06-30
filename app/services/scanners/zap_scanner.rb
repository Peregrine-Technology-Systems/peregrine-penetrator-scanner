require 'uri'
require 'timeout'

module Scanners
  # Drives OWASP ZAP natively via the daemon + HTTP API (no Docker).
  #
  # Replaces the Docker-era `zap-baseline.py`/`/zap/wrk` wrappers (which need
  # ZAP's docker/ python scripts on PATH — not present in the org-native image)
  # with the ZAP daemon, started via the baked `zap` shim (the image puts `zap`
  # on PATH → execs zap.sh; `zap.sh` itself is NOT on PATH — #4132 pilot caught
  # the wrong name). Java + ZAP are baked in.
  #
  #   baseline → access + spider + passive scan   (no active attack)
  #   full     → baseline + active scan
  #
  # The API's traditional JSON report (/OTHER/core/other/jsonreport/) is byte-for
  # byte the shape ResultParsers::ZapParser already consumes, so the parser is
  # unchanged.
  class ZapScanner < ScannerBase
    DAEMON_HOST = '127.0.0.1'.freeze
    DAEMON_PORT = 8090
    DAEMON_READY_TIMEOUT = 120
    POLL_INTERVAL = 2
    MODES = %w[baseline full].freeze

    class ZapError < StandardError; end

    def tool_name
      'zap'
    end

    protected

    def execute
      mode = tool_config[:mode] || 'baseline'
      raise ZapError, "Unknown ZAP mode: #{mode}" unless MODES.include?(mode)

      report_path = output_dir.join('zap_results.json')
      begin
        start_daemon!
        run_scan(mode)
        File.write(report_path, fetch_json_report)
      ensure
        shutdown_daemon
      end

      { success: true, findings: parse_results(report_path), output_file: report_path.to_s }
    rescue ZapError => e
      { success: false, error: e.message, findings: [] }
    end

    private

    def run_scan(mode)
      Timeout.timeout(tool_config[:timeout] || 600) do
        unique_origins(target_urls).each { |origin| scan_origin(origin, mode) }
      end
    rescue Timeout::Error
      raise ZapError, "ZAP scan timed out after #{tool_config[:timeout] || 600}s"
    end

    def scan_origin(origin, mode)
      api_get('/JSON/core/action/accessUrl/', url: origin)
      spider_id = api_get('/JSON/spider/action/scan/', url: origin)['scan']
      poll_until('/JSON/spider/view/status/', { scanId: spider_id }, 'status', '100')
      poll_until('/JSON/pscan/view/recordsToScan/', {}, 'recordsToScan', '0')
      return unless mode == 'full'

      ascan_id = api_get('/JSON/ascan/action/scan/', url: origin)['scan']
      poll_until('/JSON/ascan/view/status/', { scanId: ascan_id }, 'status', '100')
    end

    # --- daemon lifecycle ---------------------------------------------------

    def start_daemon!
      @daemon_pid = spawn_daemon
      deadline = monotonic + DAEMON_READY_TIMEOUT
      until daemon_ready?
        raise ZapError, 'ZAP daemon did not become ready' if monotonic > deadline

        sleep(POLL_INTERVAL)
      end
      logger.info("[zap] daemon ready on #{DAEMON_HOST}:#{DAEMON_PORT}")
    end

    def spawn_daemon
      Process.spawn(
        'zap', '-daemon', '-host', DAEMON_HOST, '-port', DAEMON_PORT.to_s,
        '-config', 'api.disablekey=true',
        '-config', 'api.addrs.addr.name=.*', '-config', 'api.addrs.addr.regex=true',
        %i[out err] => File::NULL, :pgroup => 0
      )
    end

    def daemon_ready?
      conn.get('/JSON/core/view/version/').success?
    rescue Faraday::Error
      false
    end

    def shutdown_daemon
      return unless @daemon_pid

      begin
        conn.get('/JSON/core/action/shutdown/')
      rescue Faraday::Error
        nil
      end
      kill_process(@daemon_pid)
    end

    # --- ZAP API ------------------------------------------------------------

    def conn
      @conn ||= Faraday.new(url: "http://#{DAEMON_HOST}:#{DAEMON_PORT}") do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.options.timeout = 30
      end
    end

    def api_get(path, params = {})
      resp = conn.get(path, params)
      raise ZapError, "ZAP API #{path} returned HTTP #{resp.status}" unless resp.success?

      resp.body
    end

    def fetch_json_report
      resp = conn.get('/OTHER/core/other/jsonreport/')
      raise ZapError, "ZAP report returned HTTP #{resp.status}" unless resp.success?

      resp.body.is_a?(String) ? resp.body : resp.body.to_json
    end

    def poll_until(path, params, key, target)
      loop do
        return if api_get(path, params)[key].to_s == target

        sleep(POLL_INTERVAL)
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def unique_origins(urls)
      urls.map { |url| URI.parse(url) }
          .map { |uri| "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless [80, 443].include?(uri.port)}" }
          .uniq
    end

    def parse_results(output_file)
      return [] unless File.exist?(output_file)

      ResultParsers::ZapParser.new(output_file).parse
    end
  end
end

require 'uri'

module Scanners
  class ZapScanner < ScannerBase
    def tool_name
      'zap'
    end

    protected

    def execute
      mode = tool_config[:mode] || 'baseline'
      zap_wrk = Pathname.new('/zap/wrk')
      report_name = 'zap_results.json'
      zap_output = zap_wrk.join(report_name)
      local_output = output_dir.join(report_name)
      all_findings = []

      # ZAP starts a full Java daemon per invocation — scan each unique
      # origin once (ZAP's spider handles path discovery internally).
      # Scanning individual paths would cause zombie processes (#625).
      unique_origins(target_urls).each do |origin|
        cmd = build_command(mode, origin, report_name)
        result = run_command(cmd, timeout: tool_config[:timeout])

        # ZAP returns 2 for warnings found (not an error)
        return { success: false, error: result[:stderr], findings: [] } unless result[:success] || result[:exit_code] == 2

        if File.exist?(zap_output)
          FileUtils.cp(zap_output.to_s, local_output.to_s)
          all_findings.concat(parse_results(local_output))
        end
      end

      { success: true, findings: all_findings, output_file: local_output.to_s }
    end

    private

    def build_command(mode, url, report_name)
      cmd = case mode
            when 'baseline'
              "zap-baseline.py -t #{Shellwords.escape(url)} -J #{report_name} -I"
            when 'full'
              "zap-full-scan.py -t #{Shellwords.escape(url)} -J #{report_name} -I"
            when 'api'
              "zap-api-scan.py -t #{Shellwords.escape(url)} -J #{report_name} -I"
            else
              raise ArgumentError, "Unknown ZAP mode: #{mode}"
            end

      cmd += " -z \"-config scanner.delayInMs=#{tool_config[:delay_ms]}\"" if tool_config[:delay_ms]

      cmd
    end

    def unique_origins(urls)
      urls.map { |url| URI.parse(url) }
          .map { |uri| "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless [80, 443].include?(uri.port)}" }
          .uniq
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::ZapParser.new(output_file).parse
    end
  end
end

module Scanners
  class ZapScanner < ScannerBase
    def tool_name
      'zap'
    end

    protected

    def execute
      mode = tool_config[:mode] || 'baseline'
      output_file = output_dir.join('zap_results.json')

      target_urls.each do |url|
        cmd = build_command(mode, url, output_file)
        result = run_command(cmd, timeout: tool_config[:timeout])

        return { success: false, error: result[:stderr], findings: [] } unless result[:success] || result[:exit_code] == 2 # ZAP returns 2 for warnings found
      end

      findings = parse_results(output_file)
      { success: true, findings:, output_file: output_file.to_s }
    end

    private

    def build_command(mode, url, output_file)
      case mode
      when 'baseline'
        "zap-baseline.py -t #{Shellwords.escape(url)} -J #{output_file} -I"
      when 'full'
        "zap-full-scan.py -t #{Shellwords.escape(url)} -J #{output_file} -I"
      when 'api'
        "zap-api-scan.py -t #{Shellwords.escape(url)} -J #{output_file} -I"
      else
        raise ArgumentError, "Unknown ZAP mode: #{mode}"
      end
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::ZapParser.new(output_file).parse
    end
  end
end

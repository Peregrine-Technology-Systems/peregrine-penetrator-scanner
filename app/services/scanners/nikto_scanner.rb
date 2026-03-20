require 'digest'

module Scanners
  class NiktoScanner < ScannerBase
    def tool_name
      'nikto'
    end

    protected

    def execute
      all_findings = []

      target_urls.each do |url|
        output_file = output_dir.join("nikto_#{Digest::MD5.hexdigest(url)}.json")
        cmd = build_command(url, output_file)
        run_command(cmd, timeout: tool_config[:timeout])

        findings = parse_results(output_file)
        all_findings.concat(findings)
      end

      { success: true, findings: all_findings }
    end

    private

    def build_command(url, output_file)
      cmd = "nikto -h #{Shellwords.escape(url)} -Format json -output #{output_file}"

      cmd += " -Tuning #{tool_config[:tuning]}" if tool_config[:tuning]
      cmd += " -Pause #{tool_config[:pause]}" if tool_config[:pause]

      cmd
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::NiktoParser.new(output_file).parse
    end
  end
end

module Scanners
  class DawnScanner < ScannerBase
    def tool_name
      'dawn'
    end

    protected

    def execute
      output_file = output_dir.join('dawn_results.json')
      cmd = "dawn --json -F #{output_file} #{Rails.root}"
      run_command(cmd, timeout: tool_config[:timeout] || 120)

      findings = parse_results(output_file)
      { success: true, findings: }
    end

    private

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::DawnParser.new(output_file).parse
    end
  end
end

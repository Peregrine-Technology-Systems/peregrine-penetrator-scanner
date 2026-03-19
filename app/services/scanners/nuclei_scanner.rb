module Scanners
  class NucleiScanner < ScannerBase
    def tool_name
      'nuclei'
    end

    protected

    def execute
      output_file = output_dir.join('nuclei_results.jsonl')
      urls_file = output_dir.join('urls.txt')

      File.write(urls_file, target_urls.join("\n"))

      cmd = build_command(urls_file, output_file)
      run_command(cmd, timeout: tool_config[:timeout])

      findings = parse_results(output_file)
      { success: true, findings:, output_file: output_file.to_s }
    end

    private

    def build_command(urls_file, output_file)
      cmd = "nuclei -l #{urls_file} -jsonl -o #{output_file} -silent"

      cmd += " -severity #{tool_config[:severity_filter]}" if tool_config[:severity_filter]

      tool_config[:templates].each { |t| cmd += " -t #{Shellwords.escape(t)}" } if tool_config[:templates].present?

      cmd += " -rate-limit #{tool_config[:rate_limit]}" if tool_config[:rate_limit]
      cmd += " -bulk-size #{tool_config[:bulk_size]}" if tool_config[:bulk_size]

      cmd
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::NucleiParser.new(output_file).parse
    end
  end
end

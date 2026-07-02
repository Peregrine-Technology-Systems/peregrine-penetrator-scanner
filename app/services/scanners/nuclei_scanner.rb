module Scanners
  class NucleiScanner < ScannerBase
    CMS_TEMPLATE_PATHS = {
      'wordpress' => %w[http/technologies/wordpress/ http/cves/wordpress/ http/vulnerabilities/wordpress/]
    }.freeze

    EXECUTABLE = 'nuclei'.freeze

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
      cmd = "#{EXECUTABLE} -l #{urls_file} -jsonl -o #{output_file} -silent"

      cmd += " -severity #{tool_config[:severity_filter]}" if tool_config[:severity_filter]

      templates = combined_templates
      templates.each { |t| cmd += " -t #{Shellwords.escape(t)}" } if templates.any?

      cmd += " -rate-limit #{tool_config[:rate_limit]}" if tool_config[:rate_limit]
      cmd += " -bulk-size #{tool_config[:bulk_size]}" if tool_config[:bulk_size]

      cmd
    end

    def combined_templates
      explicit = Array(tool_config[:templates])
      (explicit + auto_templates).uniq
    end

    def auto_templates
      return [] unless tool_config[:auto_templates]

      detected_cms = scan.summary&.dig('cms_inventory', 'cms')
      CMS_TEMPLATE_PATHS.fetch(detected_cms, [])
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::NucleiParser.new(output_file).parse
    end
  end
end

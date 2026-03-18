module Scanners
  class SqlmapScanner < ScannerBase
    def tool_name
      'sqlmap'
    end

    protected

    def execute
      output_dir_path = output_dir.join('sqlmap_output')
      all_findings = []

      injectable_urls = target_urls.select { |url| url.include?('?') }

      if injectable_urls.empty?
        logger.info('[sqlmap] No URLs with query parameters found, skipping')
        return { success: true, findings: [], skipped: true }
      end

      injectable_urls.each do |url|
        cmd = build_command(url, output_dir_path)
        run_command(cmd, timeout: tool_config[:timeout])
        findings = parse_results(output_dir_path, url)
        all_findings.concat(findings)
      end

      { success: true, findings: all_findings }
    end

    private

    def build_command(url, output_dir_path)
      level = tool_config[:level] || 1
      risk = tool_config[:risk] || 1

      "sqlmap -u #{Shellwords.escape(url)} --batch --level=#{level} --risk=#{risk} " \
        "--output-dir=#{output_dir_path} --forms --crawl=2 --threads=4"
    end

    def parse_results(output_dir_path, url)
      ResultParsers::SqlmapParser.new(output_dir_path, url).parse
    end
  end
end

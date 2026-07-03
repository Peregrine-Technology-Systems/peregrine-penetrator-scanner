module Scanners
  class SqlmapScanner < ScannerBase
    EXECUTABLE = 'sqlmap'.freeze

    # Wall-clock ceiling across the ENTIRE per-URL loop (#824). The loop runs sqlmap
    # once per injectable URL, each bounded only by the per-tool timeout — so N URLs ×
    # per-URL timeout is an unbounded worst case (100 × 1200s). This aggregate deadline
    # caps the total; overridable via tool_config[:aggregate_timeout].
    AGGREGATE_TIMEOUT_DEFAULT = 1800

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

      deadline = monotonic + aggregate_timeout
      injectable_urls.each_with_index do |url, index|
        remaining = deadline - monotonic
        if remaining <= 0
          # Loud, not silent: name how many URLs were dropped by the ceiling.
          logger.warn("[sqlmap] Aggregate timeout #{aggregate_timeout}s reached — " \
                      "skipping #{injectable_urls.length - index} remaining injectable URL(s)")
          break
        end

        cmd = build_command(url, output_dir_path)
        run_command(cmd, timeout: [per_url_timeout, remaining.ceil].min)
        findings = parse_results(output_dir_path, url)
        all_findings.concat(findings)
      end

      { success: true, findings: all_findings }
    end

    private

    def build_command(url, output_dir_path)
      # Numerics coerced to Integer, output path Shellwords-escaped: the command runs
      # via /bin/sh -c, so a config-supplied value with a shell metacharacter would
      # otherwise break or inject (#824). The URL is already escaped.
      level = (tool_config[:level] || 1).to_i
      risk = (tool_config[:risk] || 1).to_i
      threads = (tool_config[:threads] || 1).to_i
      delay = tool_config[:delay]

      cmd = "#{EXECUTABLE} -u #{Shellwords.escape(url)} --batch --level=#{level} --risk=#{risk} " \
            "--output-dir=#{Shellwords.escape(output_dir_path.to_s)} --forms --crawl=2 --threads=#{threads}"
      cmd += " --delay=#{delay.to_i}" if delay

      cmd
    end

    def aggregate_timeout
      (tool_config[:aggregate_timeout] || AGGREGATE_TIMEOUT_DEFAULT).to_i
    end

    def per_url_timeout
      (tool_config[:timeout] || 600).to_i
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def parse_results(output_dir_path, url)
      ResultParsers::SqlmapParser.new(output_dir_path, url).parse
    end
  end
end

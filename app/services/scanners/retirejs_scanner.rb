require 'digest'

module Scanners
  # Runs retire.js for JavaScript library vulnerability detection.
  # Fetch-then-scan: wget mirrors the target page + referenced JS to a temp dir,
  # retire.js scans the dir for known-vulnerable library versions.
  # Phase 3 (targeted). See #51.
  class RetirejsScanner < ScannerBase
    def tool_name
      'retirejs'
    end

    protected

    def execute
      all_findings = []

      target_urls.each do |url|
        js_dir = output_dir.join("js_#{Digest::MD5.hexdigest(url)}")
        output_file = output_dir.join("retire_#{Digest::MD5.hexdigest(url)}.json")
        fetch_target_js(url, js_dir)
        run_command(build_command(js_dir, output_file), timeout: tool_config[:timeout])
        all_findings.concat(parse_results(output_file, url))
      end

      { success: true, findings: all_findings }
    end

    private

    def fetch_target_js(url, js_dir)
      FileUtils.mkdir_p(js_dir)
      run_command(
        "timeout -k 10 55 wget --quiet --mirror --no-parent --accept '*.js,*.html' " \
        "--directory-prefix=#{js_dir} --no-host-directories " \
        "--timeout=30 --tries=2 #{Shellwords.escape(url)}",
        timeout: 60
      )
    rescue StandardError => e
      Penetrator.logger.warn("[RetirejsScanner] JS fetch failed for #{url}: #{e.message}")
    end

    def build_command(js_dir, output_file)
      scan_timeout = tool_config[:timeout] || 180
      # Shell timeout ensures the Node.js process tree is killed even if the
      # Ruby-level process group kill doesn't reach all grandchildren.
      "timeout -k 10 #{scan_timeout - 5} " \
        "retire --path #{js_dir} --outputformat json --outputpath #{output_file} --nocache --quiet"
    end

    def parse_results(output_file, url)
      return [] unless output_file.exist?

      ResultParsers::RetirejsParser.new(output_file, url).parse
    end
  end
end

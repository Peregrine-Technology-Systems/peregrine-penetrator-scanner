require 'digest'

module Scanners
  # Runs testssl.sh for TLS/SSL configuration analysis (protocols, ciphers,
  # certificate, known TLS vulnerabilities). Discovery-phase, one run per target
  # URL. Output normalized by ResultParsers::TestsslParser. See #48.
  class TestsslScanner < ScannerBase
    def tool_name
      'testssl'
    end

    protected

    def execute
      all_findings = []

      target_urls.each do |url|
        output_file = output_dir.join("testssl_#{Digest::MD5.hexdigest(url)}.json")
        run_command(build_command(url, output_file), timeout: tool_config[:timeout])
        all_findings.concat(parse_results(output_file))
      end

      { success: true, findings: all_findings }
    end

    private

    def build_command(url, output_file)
      # --quiet: no banner; --color 0: no ANSI in output; --jsonfile: flat JSON.
      # NOT --fast: that flag distorts output (cipher-by-cipher skipped, emits
      # cmdline/engine noise) — let it run the full, accurate check within timeout.
      cmd = "testssl.sh --jsonfile #{output_file} --quiet --color 0"
      cmd += " --severity #{tool_config[:severity]}" if tool_config[:severity]
      "#{cmd} #{Shellwords.escape(url)}"
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::TestsslParser.new(output_file).parse
    end
  end
end

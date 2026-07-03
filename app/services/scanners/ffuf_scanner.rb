require 'digest'

module Scanners
  class FfufScanner < ScannerBase
    EXECUTABLE = 'ffuf'.freeze

    def tool_name
      'ffuf'
    end

    protected

    def execute
      all_findings = []

      target_urls.each do |url|
        output_file = output_dir.join("ffuf_#{Digest::MD5.hexdigest(url)}.json")
        cmd = build_command(url, output_file)
        run_command(cmd, timeout: tool_config[:timeout])

        findings = parse_results(output_file)
        all_findings.concat(findings)
      end

      { success: true, findings: all_findings, discovered_urls: extract_discovered_urls(all_findings) }
    end

    private

    def build_command(url, output_file)
      fuzz_url = "#{url.chomp('/')}/FUZZ"
      wordlist = tool_config[:wordlist] || '/usr/share/seclists/Discovery/Web-Content/common.txt'
      # Numerics coerced to Integer, string paths Shellwords-escaped: the command is
      # a single string run via /bin/sh -c, so a config-supplied wordlist/extensions
      # path with a space or shell metacharacter would otherwise break or inject (#824).
      threads = (tool_config[:threads] || 40).to_i
      rate = (tool_config[:rate] || 10).to_i

      cmd = "#{EXECUTABLE} -u #{Shellwords.escape(fuzz_url)} -w #{Shellwords.escape(wordlist)} " \
            "-o #{Shellwords.escape(output_file.to_s)} " \
            "-of json -mc 200,201,301,302,403 -t #{threads} -rate #{rate} -s"

      cmd += " -e #{Shellwords.escape(tool_config[:extensions])}" if tool_config[:extensions]

      cmd
    end

    def parse_results(output_file)
      return [] unless output_file.exist?

      ResultParsers::FfufParser.new(output_file).parse
    end

    def extract_discovered_urls(findings)
      findings.pluck(:url).compact.uniq
    end
  end
end

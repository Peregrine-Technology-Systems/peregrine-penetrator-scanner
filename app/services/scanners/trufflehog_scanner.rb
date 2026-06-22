require 'digest'

module Scanners
  # Runs trufflehog for secret/credential detection in page source and fetched files.
  # Fetch-then-scan: wget mirrors the target to a temp dir, trufflehog scans the
  # filesystem for hardcoded secrets (API keys, private keys, tokens, etc.).
  # Phase 3 (targeted). See #50.
  class TrufflehogScanner < ScannerBase
    def tool_name
      'trufflehog'
    end

    protected

    def execute
      all_findings = []

      target_urls.each do |url|
        files_dir  = output_dir.join("files_#{Digest::MD5.hexdigest(url)}")
        output_file = output_dir.join("trufflehog_#{Digest::MD5.hexdigest(url)}.json")
        fetch_target_files(url, files_dir)
        run_command(build_command(files_dir, output_file), timeout: tool_config[:timeout])
        all_findings.concat(parse_results(output_file, url))
      end

      { success: true, findings: all_findings }
    end

    private

    def fetch_target_files(url, files_dir)
      FileUtils.mkdir_p(files_dir)
      run_command(
        "wget --quiet --mirror --no-parent --page-requisites " \
        "--directory-prefix=#{files_dir} --no-host-directories " \
        "--timeout=30 --tries=2 #{Shellwords.escape(url)}",
        timeout: 60
      )
    rescue StandardError => e
      Penetrator.logger.warn("[TrufflehogScanner] File fetch failed for #{url}: #{e.message}")
    end

    def build_command(files_dir, output_file)
      "trufflehog filesystem #{files_dir} --json --no-verification " \
      "> #{output_file} 2>/dev/null"
    end

    def parse_results(output_file, url)
      return [] unless output_file.exist?

      ResultParsers::TrufflehogParser.new(output_file, url).parse
    end
  end
end

module ResultParsers
  # Parses `amass subs` text output (one hostname per line, with a "FQDN:" header
  # and "Session Scope" preamble). Returns discovered_urls (not findings) — amass
  # is a subdomain discovery tool, not a vulnerability scanner. See #47.
  class AmassParser
    SKIP_PATTERNS = /\A(Session Scope|FQDN:|[\s]*\z)/i

    def initialize(output_file)
      @output_file = output_file
    end

    def parse
      lines = File.readlines(@output_file, chomp: true)
      urls = lines.reject { |l| l.match?(SKIP_PATTERNS) }.map { |h| "https://#{h.strip}" }
      { discovered_urls: urls }
    rescue Errno::ENOENT => e
      Penetrator.logger.error("[AmassParser] File not found: #{e.message}")
      { discovered_urls: [] }
    end
  end
end

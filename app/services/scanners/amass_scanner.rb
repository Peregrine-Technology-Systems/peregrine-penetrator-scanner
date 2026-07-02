require 'uri'

module Scanners
  # Runs amass v5 for passive subdomain enumeration.
  # Two-step: `amass enum` populates the OAM database, then `amass subs` extracts
  # results. Returns discovered_urls (not findings) — these feed into @discovered_urls
  # in ScanOrchestrator to expand the target surface for subsequent phases. See #47.
  class AmassScanner < ScannerBase
    EXECUTABLE = 'amass'.freeze

    def tool_name
      'amass'
    end

    protected

    def execute
      all_discovered = []

      target_domains.each do |domain|
        db_dir       = output_dir.join("oam_#{domain.gsub(/[^a-z0-9]/, '_')}")
        subs_file    = subs_output_file(domain)
        FileUtils.mkdir_p(db_dir)

        run_command(enum_command(domain, db_dir), timeout: tool_config[:timeout])
        run_command(subs_command(domain, db_dir, subs_file), timeout: 60)
        all_discovered.concat(parse_results(subs_file))
      end

      { success: true, findings: [], discovered_urls: all_discovered.uniq }
    end

    private

    def target_domains
      target_urls.filter_map do |url|
        URI.parse(url).host
      rescue StandardError
        nil
      end.uniq
    end

    def enum_command(domain, db_dir)
      "#{EXECUTABLE} enum -passive -d #{Shellwords.escape(domain)} -dir #{db_dir} -timeout 5"
    end

    def subs_command(domain, db_dir, subs_file)
      "#{EXECUTABLE} subs -d #{Shellwords.escape(domain)} -dir #{db_dir} > #{subs_file} 2>/dev/null"
    end

    def subs_output_file(domain)
      output_dir.join("amass_subs_#{domain.gsub(/[^a-z0-9]/, '_')}.txt")
    end

    def parse_results(subs_file)
      return [] unless subs_file.exist?

      ResultParsers::AmassParser.new(subs_file).parse.fetch(:discovered_urls, [])
    end
  end
end

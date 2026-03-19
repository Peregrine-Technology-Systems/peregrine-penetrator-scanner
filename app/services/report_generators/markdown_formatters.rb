module ReportGenerators
  module MarkdownFormatters
    private

    def report_version
      ENV.fetch('VERSION', nil) || git_commit_short || 'dev'
    end

    def git_commit_short
      `git rev-parse --short HEAD 2>/dev/null`.strip.presence
    end

    def format_date(time)
      time&.strftime('%B %d, %Y') || 'N/A'
    end

    def format_duration(seconds)
      return 'N/A' unless seconds

      s = seconds.to_i
      if s > 3600
        "#{s / 3600}h #{(s % 3600) / 60}m"
      elsif s > 60
        "#{s / 60}m #{s % 60}s"
      else
        "#{s}s"
      end
    end

    def format_epss(score)
      return '' unless score

      "#{(score * 100).round(1)}%"
    end

    def truncate_url(url, max_length)
      return '' if url.blank?

      url.length > max_length ? "#{url[0..max_length]}..." : url
    end

    def escape_pipes(text)
      return '' if text.blank?

      text.gsub('|', '\\|')
    end

    def sanitize(text)
      return '' if text.blank?

      text.to_s
          .gsub('|', '-')
          .gsub('\\n', ' ')
          .gsub("\n", ' ')
          .gsub(':(', '')
          .gsub(':)', '')
          .gsub(/[{}]/, '')
          .strip
          .truncate(100)
    end

    def sanitize_text(text)
      return '' if text.blank?

      text.to_s
          .gsub('\\n', ' ')
          .gsub("\n", ' ')
          .gsub(':(', '')
          .gsub(':)', '')
    end
  end
end

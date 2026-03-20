module ReportGenerators
  module MarkdownConverter
    private

    def markdown_to_html(markdown_text)
      if pandoc_available?
        convert_with_pandoc(markdown_text)
      else
        convert_basic(markdown_text)
      end
    end

    def pandoc_available?
      system('which pandoc > /dev/null 2>&1')
    end

    def convert_with_pandoc(markdown_text)
      require 'open3'
      stdout, _stderr, status = Open3.capture3(
        'pandoc', '--from=markdown', '--to=html5',
        '--highlight-style=tango',
        stdin_data: markdown_text
      )
      status.success? ? stdout : convert_basic(markdown_text)
    end

    def convert_basic(markdown_text)
      html = markdown_text.dup
      html = apply_markdown_replacements(html)
      html = convert_tables(html)
      wrap_plain_text_lines(html)
    end

    def apply_markdown_replacements(html)
      html.gsub!(/^---$/, '<hr>')
      html.gsub!(/^#### (.+)$/, '<h4>\1</h4>')
      html.gsub!(/^### (.+)$/, '<h3>\1</h3>')
      html.gsub!(/^## (.+)$/, '<h2>\1</h2>')
      html.gsub!(/^# (.+)$/, '<h1>\1</h1>')
      html.gsub!(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
      html.gsub!(/\*(.+?)\*/, '<em>\1</em>')
      html.gsub!(/`([^`]+)`/, '<code>\1</code>')
      html.gsub!(/```\n?(.*?)\n?```/m, '<pre><code>\1</code></pre>')
      html.gsub!(/^- (.+)$/, '<li>\1</li>')
      html
    end

    def wrap_plain_text_lines(html)
      lines = html.split("\n")
      lines.map do |line|
        stripped = line.strip
        if stripped.empty? || stripped.start_with?('<')
          line
        else
          "<p>#{line}</p>"
        end
      end.join("\n")
    end

    def convert_tables(html)
      lines = html.split("\n")
      result = []
      in_table = false
      header_done = false

      lines.each do |line|
        if line.strip =~ /^\|(.+)\|$/
          cells = line.strip.split('|').map(&:strip).reject(&:empty?)
          next if cells.all? { |c| c.match?(/^[-:]+$/) }

          in_table, header_done = process_table_row(cells, result, in_table, header_done)
        else
          if in_table
            result << '</tbody></table>'
            in_table = false
            header_done = false
          end
          result << line
        end
      end

      result << '</tbody></table>' if in_table
      result.join("\n")
    end

    def process_table_row(cells, result, in_table, header_done)
      unless in_table
        result << '<table>'
        in_table = true
        header_done = false
      end

      if header_done
        result << '<tr>'
        cells.each { |c| result << "<td>#{c}</td>" }
        result << '</tr>'
      else
        result << '<thead><tr>'
        cells.each { |c| result << "<th>#{c}</th>" }
        result << '</tr></thead><tbody>'
        header_done = true
      end

      [in_table, header_done]
    end
  end
end

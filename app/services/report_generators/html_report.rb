require 'erb'

module ReportGenerators
  class HtmlReport
    include Helpers

    def initialize(scan:, findings:, target:)
      @scan = scan
      @findings = findings
      @target = target
      @brand = parse_brand_config(target)
    end

    def generate
      md_generator = MarkdownReport.new(scan: @scan, findings: @findings, target: @target)
      md_content = md_generator.generate
      html_body = markdown_to_html(md_content)
      wrap_in_html(html_body)
    end

    def filename
      "scan_#{@scan.id}_report.html"
    end

    def content_type
      'text/html'
    end

    private

    def markdown_to_html(md)
      # Use pandoc if available for high-fidelity conversion
      if pandoc_available?
        convert_with_pandoc(md)
      else
        convert_basic(md)
      end
    end

    def pandoc_available?
      system('which pandoc > /dev/null 2>&1')
    end

    def convert_with_pandoc(md)
      require 'open3'
      stdout, _stderr, status = Open3.capture3(
        'pandoc', '--from=markdown', '--to=html5',
        '--highlight-style=tango',
        stdin_data: md
      )
      status.success? ? stdout : convert_basic(md)
    end

    def convert_basic(md)
      # Simple Markdown to HTML conversion for core elements
      html = md.dup

      # Horizontal rules (must come before other processing)
      html.gsub!(/^---$/, '<hr>')

      # Headers
      html.gsub!(/^#### (.+)$/, '<h4>\1</h4>')
      html.gsub!(/^### (.+)$/, '<h3>\1</h3>')
      html.gsub!(/^## (.+)$/, '<h2>\1</h2>')
      html.gsub!(/^# (.+)$/, '<h1>\1</h1>')

      # Bold
      html.gsub!(/\*\*(.+?)\*\*/, '<strong>\1</strong>')

      # Italic
      html.gsub!(/\*(.+?)\*/, '<em>\1</em>')

      # Inline code
      html.gsub!(/`([^`]+)`/, '<code>\1</code>')

      # Code blocks
      html.gsub!(/```\n?(.*?)\n?```/m, '<pre><code>\1</code></pre>')

      # Tables
      html = convert_tables(html)

      # List items
      html.gsub!(/^- (.+)$/, '<li>\1</li>')

      # Paragraphs for remaining plain text lines
      lines = html.split("\n")
      result = []
      lines.each do |line|
        stripped = line.strip
        if stripped.empty? || stripped.start_with?('<')
          result << line
        else
          result << "<p>#{line}</p>"
        end
      end

      result.join("\n")
    end

    def convert_tables(html)
      lines = html.split("\n")
      result = []
      in_table = false
      header_done = false

      lines.each do |line|
        if line.strip =~ /^\|(.+)\|$/
          cells = line.strip.split('|').map(&:strip).reject(&:empty?)

          # Skip separator rows
          if cells.all? { |c| c.match?(/^[-:]+$/) }
            next
          end

          unless in_table
            result << '<table>'
            in_table = true
            header_done = false
          end

          if !header_done
            result << '<thead><tr>'
            cells.each { |c| result << "<th>#{c}</th>" }
            result << '</tr></thead><tbody>'
            header_done = true
          else
            result << '<tr>'
            cells.each { |c| result << "<td>#{c}</td>" }
            result << '</tr>'
          end
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

    def wrap_in_html(body)
      company = @brand[:company_name]
      target_name = @target.name
      accent = @brand[:accent_color]

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Penetration Test Report &mdash; #{target_name} | #{company}</title>
          <style>
            *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
              color: #1e293b;
              background: #f1f5f9;
              line-height: 1.65;
              padding: 2rem;
            }
            .report {
              max-width: 960px;
              margin: 0 auto;
              background: #ffffff;
              box-shadow: 0 4px 6px rgba(0,0,0,0.05);
              padding: 3rem;
              border-radius: 8px;
            }
            h1 {
              font-size: 2.2rem;
              color: #0f172a;
              border-bottom: 3px solid #{accent};
              padding-bottom: 0.5rem;
              margin-bottom: 1.5rem;
            }
            h2 {
              font-size: 1.5rem;
              color: #0f172a;
              margin-top: 2.5rem;
              margin-bottom: 1rem;
              padding-bottom: 0.3rem;
              border-bottom: 1px solid #e2e8f0;
            }
            h3 {
              font-size: 1.15rem;
              color: #1e293b;
              margin-top: 1.5rem;
              margin-bottom: 0.75rem;
            }
            h4 {
              font-size: 1rem;
              color: #334155;
              margin-top: 1.25rem;
              margin-bottom: 0.5rem;
            }
            p { margin-bottom: 0.75rem; }
            strong { color: #0f172a; }
            code {
              font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
              font-size: 0.85em;
              background: #f1f5f9;
              padding: 0.15em 0.4em;
              border-radius: 4px;
              color: #334155;
            }
            pre {
              background: #0f172a;
              color: #e2e8f0;
              padding: 1rem;
              border-radius: 8px;
              overflow-x: auto;
              margin: 0.75rem 0;
              font-size: 0.82rem;
              line-height: 1.6;
            }
            pre code {
              background: none;
              padding: 0;
              color: inherit;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              margin: 0.75rem 0;
              font-size: 0.88rem;
            }
            thead th {
              background: #0f172a;
              color: #ffffff;
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.05em;
              font-size: 0.72rem;
              padding: 0.75rem 1rem;
              text-align: left;
            }
            tbody td {
              padding: 0.65rem 1rem;
              border-bottom: 1px solid #f1f5f9;
              vertical-align: top;
            }
            tbody tr:hover { background: #f8fafc; }
            hr {
              border: none;
              border-top: 1px solid #e2e8f0;
              margin: 2rem 0;
            }
            li {
              margin-left: 1.5rem;
              margin-bottom: 0.3rem;
            }
            .footer {
              margin-top: 3rem;
              padding-top: 1.5rem;
              border-top: 1px solid #e2e8f0;
              text-align: center;
              color: #94a3b8;
              font-size: 0.78rem;
            }
            @media print {
              body { background: #fff; padding: 0; }
              .report { box-shadow: none; max-width: 100%; }
            }
          </style>
        </head>
        <body>
          <div class="report">
            #{body}
            <div class="footer">
              <p>#{@brand[:footer_text]} &mdash; #{company}</p>
            </div>
          </div>
        </body>
        </html>
      HTML
    end
  end
end

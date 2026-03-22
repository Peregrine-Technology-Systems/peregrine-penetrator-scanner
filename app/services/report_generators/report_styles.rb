module ReportGenerators
  module ReportStyles
    include ComponentStyles

    private

    def report_css(accent_color)
      base_css(accent_color) + component_css
    end

    def base_css(accent_color)
      <<~CSS
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
          border-bottom: 3px solid #{accent_color};
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
      CSS
    end
  end
end

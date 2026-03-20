module ReportGenerators
  module ComponentStyles
    private

    def component_css
      <<~CSS
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
      CSS
    end
  end
end

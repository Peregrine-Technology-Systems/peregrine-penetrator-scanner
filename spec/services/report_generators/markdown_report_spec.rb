require 'sequel_helper'

RSpec.describe ReportGenerators::MarkdownReport do
  subject(:report) { described_class.new(scan:, findings:, target:) }

  let(:target) do
    create(:target, name: 'Test Corp',
                    urls: '["https://example.com"]',
                    brand_config: { 'company_name' => 'Acme Security', 'footer_text' => 'CONFIDENTIAL' })
  end
  let(:scan) do
    create(:scan, :completed, target:, profile: 'standard',
                              summary: {
                                'total_findings' => 3,
                                'by_severity' => { 'critical' => 1, 'high' => 1, 'medium' => 1, 'low' => 0, 'info' => 0 },
                                'executive_summary' => 'Critical vulnerabilities found requiring immediate attention.'
                              },
                              tool_statuses: { 'zap' => { 'status' => 'completed' }, 'nuclei' => { 'status' => 'completed' } })
  end
  let(:findings) do
    [
      create(:finding, scan:, source_tool: 'zap', severity: 'critical',
                       title: 'SQL Injection', url: 'https://example.com/login', parameter: 'username',
                       cwe_id: 'CWE-89', cve_id: 'CVE-2024-1234', cvss_score: 9.8, epss_score: 0.95,
                       kev_known_exploited: true,
                       evidence: { 'description' => 'SQL injection in login form' },
                       ai_assessment: { 'summary' => 'Confirmed SQL injection', 'recommendation' => 'Use parameterized queries' }),
      create(:finding, scan:, source_tool: 'nuclei', severity: 'high',
                       title: 'XSS Reflected', url: 'https://example.com/search', parameter: 'q',
                       cwe_id: 'CWE-79',
                       evidence: { 'desc' => 'Reflected XSS found' }),
      create(:finding, scan:, source_tool: 'nikto', severity: 'medium',
                       title: 'Missing Security Headers', url: 'https://example.com/',
                       evidence: 'No X-Frame-Options header')
    ]
  end

  describe '#generate' do
    let(:output) { report.generate }

    it 'produces a non-empty markdown string' do
      expect(output).to be_a(String)
      expect(output).not_to be_empty
    end

    it 'includes executive summary as Level 1 heading with version and risk level' do
      expect(output).to match(/^# Executive Summary$/m)
      expect(output).to include('Overall Risk Level')
      expect(output).to include('Version:')
    end

    it 'includes findings summary as Level 1 heading' do
      expect(output).to match(/^# Findings Summary$/m)
      expect(output).to include('SQL Injection')
      expect(output).to include('XSS Reflected')
    end

    it 'includes detailed findings as Level 1 heading' do
      expect(output).to match(/^# Detailed Findings$/m)
    end

    it 'includes individual findings as Level 2 headings' do
      expect(output).to match(/^## 1\. \[CRITICAL\] SQL Injection$/m)
    end

    it 'includes methodology as Level 1 heading' do
      expect(output).to match(/^# Test Methodology$/m)
      expect(output).to include('Scanning Phases')
      expect(output).to include('Tool Descriptions')
    end

    it 'includes appendix as Level 1 heading' do
      expect(output).to match(/^# Appendix$/m)
      expect(output).to include('Tool Versions')
      expect(output).to include('Scan Configuration')
      expect(output).to include('Disclaimer')
    end

    it 'includes page breaks' do
      expect(output).to include('\newpage')
    end
  end

  describe '#filename' do
    it 'returns a markdown filename with scan id' do
      expect(report.filename).to eq("scan_#{scan.id}_report.md")
    end
  end

  describe '#content_type' do
    it 'returns text/markdown' do
      expect(report.content_type).to eq('text/markdown')
    end
  end

  describe 'executive summary section' do
    let(:output) { report.generate }

    it 'displays risk level and version' do
      expect(output).to include('Overall Risk Level')
      expect(output).to include('Version:')
      expect(output).to include('Scan Duration:')
    end

    it 'calculates risk score and label' do
      # critical=1 (25), high=1 (15), medium=1 (8) = 48 => High
      expect(output).to include('High')
      expect(output).to include('48/100')
    end

    it 'includes scan duration' do
      expect(output).to include('Scan Duration')
    end

    it 'lists tools used' do
      expect(output).to include('Tools Executed')
      expect(output).to include('zap')
      expect(output).to include('nuclei')
    end

    it 'includes executive summary text when present' do
      expect(output).to include('Critical vulnerabilities found requiring immediate attention.')
    end

    context 'with critical risk score' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'standard',
                                  summary: { 'by_severity' => { 'critical' => 5 } })
      end
      let(:findings) do
        5.times.map do |i|
          create(:finding, scan:, source_tool: 'zap', severity: 'critical',
                           title: "Critical #{i}", url: "https://example.com/#{i}")
        end
      end

      it 'displays Critical risk label for high risk scores' do
        expect(output).to include('Critical')
      end
    end

    context 'with low risk score' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'standard',
                                  summary: { 'by_severity' => { 'info' => 2 } })
      end
      let(:findings) do
        [create(:finding, scan:, source_tool: 'nikto', severity: 'info',
                          title: 'Info Finding', url: 'https://example.com')]
      end

      it 'displays Low risk label' do
        expect(output).to include('Low')
      end
    end

    context 'with moderate risk score' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'standard',
                                  summary: { 'by_severity' => { 'high' => 1, 'low' => 1 } })
      end
      let(:findings) do
        [
          create(:finding, scan:, source_tool: 'zap', severity: 'high',
                           title: 'High Finding', url: 'https://example.com/a'),
          create(:finding, scan:, source_tool: 'zap', severity: 'low',
                           title: 'Low Finding', url: 'https://example.com/b')
        ]
      end

      it 'displays Moderate risk label' do
        # high=1 (15) + low=1 (3) = 18 => Moderate (16-40)
        expect(output).to include('Moderate')
      end
    end

    context 'with no executive summary' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'standard',
                                  summary: { 'by_severity' => {} })
      end
      let(:findings) { [] }

      it 'omits executive summary text' do
        expect(output).not_to include('requiring immediate attention')
      end
    end
  end

  describe 'findings summary section' do
    context 'with no findings' do
      let(:findings) { [] }
      let(:output) { report.generate }

      it 'omits the findings summary' do
        expect(output).not_to match(/^# Findings Summary$/m)
      end
    end

    context 'with findings having CWE IDs' do
      let(:output) { report.generate }

      it 'includes CWE links for findings with cwe_id' do
        expect(output).to include('CWE-89')
        expect(output).to include('cwe.mitre.org')
      end
    end

    context 'with findings that have URLs' do
      let(:output) { report.generate }

      it 'includes URL info' do
        expect(output).to include('https://example.com/login')
      end
    end
  end

  describe 'detailed findings section' do
    let(:output) { report.generate }

    it 'includes severity, URL, tool, parameter for each finding' do
      expect(output).to include('CRITICAL')
      expect(output).to include('`https://example.com/login`')
      expect(output).to include('`username`')
      expect(output).to include('zap')
    end

    it 'includes CVE link for findings with cve_id' do
      expect(output).to include('CVE-2024-1234')
      expect(output).to include('nvd.nist.gov')
    end

    it 'includes CVSS score' do
      expect(output).to include('9.8')
    end

    it 'includes EPSS score as percentage' do
      expect(output).to include('95.0%')
    end

    it 'includes KEV warning for actively exploited findings' do
      expect(output).to include('ACTIVELY EXPLOITED')
    end

    it 'includes evidence description' do
      expect(output).to include('SQL injection in login form')
    end

    it 'includes evidence desc field when description is absent' do
      expect(output).to include('Reflected XSS found')
    end

    it 'renders string evidence directly' do
      expect(output).to include('No X-Frame-Options header')
    end

    it 'includes AI assessment summary and recommendation' do
      expect(output).to include('Confirmed SQL injection')
      expect(output).to include('Use parameterized queries')
    end

    context 'with finding that has hash evidence without description/desc keys' do
      let(:findings) do
        [create(:finding, scan:, source_tool: 'ffuf', severity: 'low',
                          title: 'Hidden Path', url: 'https://example.com/admin',
                          evidence: { 'path' => '/admin', 'status_code' => '200' })]
      end

      it 'renders each evidence key-value pair' do
        expect(output).to include('Path')
        expect(output).to include('/admin')
        expect(output).to include('Status Code')
      end
    end

    context 'with finding that has string ai_assessment' do
      let(:findings) do
        [create(:finding, scan:, source_tool: 'zap', severity: 'medium',
                          title: 'Test Finding', url: 'https://example.com',
                          ai_assessment: 'This is a plain text assessment')]
      end

      it 'renders string ai_assessment directly' do
        expect(output).to include('This is a plain text assessment')
      end
    end

    context 'with no findings' do
      let(:findings) { [] }

      it 'omits detailed findings section' do
        expect(output).not_to match(/^# Detailed Findings$/m)
      end
    end

    context 'with more than 50 findings' do
      let(:findings) do
        55.times.map do |i|
          create(:finding, scan:, source_tool: 'nuclei', severity: 'info',
                           title: "Finding #{i}", url: "https://example.com/#{i}")
        end
      end

      it 'includes truncation notice' do
        expect(output).to include('Showing top 50 findings')
        expect(output).to include('5 additional findings available in JSON report')
      end
    end
  end

  describe 'appendix section' do
    let(:output) { report.generate }

    it 'includes scan configuration details' do
      expect(output).to include('Standard')
      expect(output).to include('example.com')
    end

    it 'includes tool execution status table' do
      expect(output).to include('Tool Execution Status')
      expect(output).to include('zap')
      expect(output).to include('completed')
    end

    it 'includes brand footer text' do
      expect(output).to include('CONFIDENTIAL')
    end

    it 'includes report ID' do
      expect(output).to include(scan.id.to_s)
    end

    context 'with no tool statuses' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'standard',
                                  summary: { 'by_severity' => {} }, tool_statuses: {})
      end
      let(:findings) { [] }

      it 'omits tool execution status table' do
        expect(output).not_to include('Tool Execution Status')
      end
    end
  end

  describe 'duration formatting' do
    context 'with nil duration' do
      let(:scan) do
        create(:scan, target:, profile: 'standard', status: 'completed',
                      summary: { 'by_severity' => {} })
      end
      let(:findings) { [] }

      it 'shows N/A for duration' do
        expect(report.generate).to include('N/A')
      end
    end

    context 'with duration over an hour' do
      let(:scan) do
        create(:scan, target:, profile: 'standard', status: 'completed',
                      started_at: 2.hours.ago, completed_at: Time.current,
                      summary: { 'by_severity' => {} })
      end
      let(:findings) { [] }

      it 'formats duration with hours and minutes' do
        output = report.generate
        expect(output).to match(/\dh \d+m/)
      end
    end

    context 'with duration under a minute' do
      let(:scan) do
        create(:scan, target:, profile: 'standard', status: 'completed',
                      started_at: 45.seconds.ago, completed_at: Time.current,
                      summary: { 'by_severity' => {} })
      end
      let(:findings) { [] }

      it 'formats duration in seconds' do
        output = report.generate
        expect(output).to match(/\d+s/)
      end
    end
  end
end

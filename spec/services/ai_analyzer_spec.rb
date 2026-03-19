require 'rails_helper'

RSpec.describe AiAnalyzer do
  let(:mock_anthropic_client) { instance_double(Anthropic::Client) }
  let(:analyzer) { described_class.new }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY').and_return('test-api-key')
    allow(ENV).to receive(:fetch).with('CLAUDE_MODEL', 'claude-sonnet-4-20250514').and_return('claude-sonnet-4-20250514')

    allow(Anthropic::Client).to receive(:new).and_return(mock_anthropic_client)
  end

  def mock_claude_response(text)
    { 'content' => [{ 'text' => text }] }
  end

  describe '#triage_findings' do
    let(:scan) { create(:scan, :running) }
    let(:target) { scan.target }
    let!(:findings) do
      [
        create(:finding, scan:, source_tool: 'zap', severity: 'high',
                         title: 'XSS in search', url: 'https://example.com/search', cwe_id: 'CWE-79'),
        create(:finding, scan:, source_tool: 'nuclei', severity: 'critical',
                         title: 'SQL Injection', url: 'https://example.com/api', cwe_id: 'CWE-89')
      ]
    end

    it 'sends findings to Claude and updates ai_assessment' do
      response_json = [
        {
          'false_positive_likelihood' => 'low',
          'business_impact' => 'Data theft possible',
          'priority' => 'immediate',
          'remediation' => 'Sanitize input',
          'attack_chain' => 'Chain with SQLi'
        },
        {
          'false_positive_likelihood' => 'low',
          'business_impact' => 'Full database compromise',
          'priority' => 'immediate',
          'remediation' => 'Use parameterized queries',
          'attack_chain' => 'Direct exploitation'
        }
      ]

      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response(response_json.to_json))

      analyzer.triage_findings(findings, target)

      findings.each(&:reload)
      expect(findings.first.ai_assessment['priority']).to eq('immediate')
      expect(findings.last.ai_assessment['remediation']).to eq('Use parameterized queries')
    end

    it 'handles JSON wrapped in markdown code blocks' do
      response_text = "```json\n[{\"false_positive_likelihood\":\"high\",\"business_impact\":\"None\",\"priority\":\"accept_risk\",\"remediation\":\"N/A\",\"attack_chain\":\"None\"}]\n```"
      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response(response_text))

      analyzer.triage_findings([findings.first], target)

      findings.first.reload
      expect(findings.first.ai_assessment['false_positive_likelihood']).to eq('high')
    end

    it 'handles API failures gracefully' do
      allow(mock_anthropic_client).to receive(:messages).and_raise(StandardError, 'API rate limit exceeded')

      expect { analyzer.triage_findings(findings, target) }.not_to raise_error
    end

    it 'handles invalid JSON response gracefully' do
      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response('not valid json'))

      expect { analyzer.triage_findings(findings, target) }.not_to raise_error
    end
  end

  describe '#generate_executive_summary' do
    let(:scan) do
      create(:scan, :completed, summary: {
               'total_findings' => 5,
               'by_severity' => { 'critical' => 1, 'high' => 2, 'medium' => 2 }
             })
    end

    before do
      create(:finding, scan:, source_tool: 'zap', severity: 'critical',
                       title: 'RCE Vulnerability', url: 'https://example.com/admin', duplicate: false)
    end

    it 'generates and saves executive summary' do
      summary_text = 'The overall security posture is concerning...'
      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response(summary_text))

      result = analyzer.generate_executive_summary(scan)

      expect(result).to eq(summary_text)
      scan.reload
      expect(scan.summary['executive_summary']).to eq(summary_text)
    end

    it 'merges summary with existing summary data' do
      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response('Executive summary here'))

      analyzer.generate_executive_summary(scan)

      scan.reload
      expect(scan.summary['total_findings']).to eq(5)
      expect(scan.summary['executive_summary']).to eq('Executive summary here')
    end

    it 'handles API failure gracefully and returns nil' do
      allow(mock_anthropic_client).to receive(:messages).and_raise(StandardError, 'API down')

      result = analyzer.generate_executive_summary(scan)

      expect(result).to be_nil
    end
  end

  describe '#analyze_scan' do
    let(:scan) do
      create(:scan, :completed, summary: {
               'total_findings' => 2,
               'by_severity' => { 'high' => 1, 'medium' => 1 }
             })
    end

    before do
      create(:finding, scan:, source_tool: 'zap', severity: 'high',
                       title: 'XSS', url: 'https://example.com', duplicate: false)
      create(:finding, scan:, source_tool: 'nuclei', severity: 'medium',
                       title: 'Info Disclosure', url: 'https://example.com', duplicate: false)
    end

    it 'triages findings and generates executive summary' do
      triage_response = [
        { 'false_positive_likelihood' => 'low', 'business_impact' => 'High', 'priority' => 'immediate', 'remediation' => 'Fix XSS', 'attack_chain' => 'N/A' },
        { 'false_positive_likelihood' => 'medium', 'business_impact' => 'Medium', 'priority' => 'short_term', 'remediation' => 'Fix disclosure', 'attack_chain' => 'N/A' }
      ]
      allow(mock_anthropic_client).to receive(:messages)
        .and_return(
          mock_claude_response(triage_response.to_json),
          mock_claude_response('Executive summary text')
        )

      analyzer.analyze_scan(scan)

      scan.reload
      expect(scan.summary['executive_summary']).to eq('Executive summary text')
    end
  end

  describe '#suggest_additional_tests' do
    let(:scan) { create(:scan, :running) }

    it 'returns suggestions from Claude' do
      suggestions = {
        'sqli_targets' => ['https://example.com/api/users?id=1'],
        'auth_targets' => ['https://example.com/admin'],
        'api_targets' => [],
        'misconfig_targets' => []
      }
      allow(mock_anthropic_client).to receive(:messages).and_return(mock_claude_response(suggestions.to_json))

      result = analyzer.suggest_additional_tests(scan, ['https://example.com/api/users'])

      expect(result['sqli_targets']).to include('https://example.com/api/users?id=1')
    end

    it 'returns empty hash on failure' do
      allow(mock_anthropic_client).to receive(:messages).and_raise(StandardError, 'API error')

      result = analyzer.suggest_additional_tests(scan, [])

      expect(result).to eq({})
    end
  end
end

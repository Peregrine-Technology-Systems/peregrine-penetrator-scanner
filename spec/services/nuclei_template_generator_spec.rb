require 'rails_helper'

RSpec.describe NucleiTemplateGenerator do
  let(:mock_client) { instance_double('Anthropic::Client') }
  let(:mock_messages) { instance_double('Anthropic::Client::Messages') }
  let(:generator) { described_class.new }

  let(:cve_details) do
    {
      'id' => 'CVE-2021-44228',
      'descriptions' => [{ 'lang' => 'en', 'value' => 'Log4j RCE' }],
      'metrics' => {
        'cvssMetricV31' => [{ 'cvssData' => { 'baseScore' => 10.0 } }]
      },
      'references' => [{ 'url' => 'https://example.com/advisory' }],
      'configurations' => [{
        'nodes' => [{
          'cpeMatch' => [{ 'vulnerable' => true, 'criteria' => 'cpe:2.3:a:apache:log4j:*' }]
        }]
      }]
    }
  end

  let(:valid_template_yaml) do
    <<~YAML
      id: cve-2021-44228
      info:
        name: Log4j RCE
        severity: critical
        author: ai-generated
    YAML
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY').and_return('test-api-key')
    allow(ENV).to receive(:fetch).with('CLAUDE_MODEL', 'claude-sonnet-4-20250514').and_return('claude-sonnet-4-20250514')

    allow(Anthropic::Client).to receive(:new).and_return(mock_client)
    allow(mock_client).to receive(:messages).and_return(mock_messages)
  end

  def mock_claude_response(text)
    content_block = instance_double('Anthropic::ContentBlock', text: text)
    instance_double('Anthropic::Response', content: [content_block])
  end

  describe '#generate_for_cve' do
    it 'generates and saves a valid YAML template' do
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response("```yaml\n#{valid_template_yaml}```"))

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)

      expect(result).to be_present
      expect(result).to end_with('.yaml')
      expect(File.exist?(result)).to be true

      content = File.read(result)
      parsed = YAML.safe_load(content)
      expect(parsed['id']).to eq('cve-2021-44228')
    ensure
      FileUtils.rm_f(result) if result
    end

    it 'fetches CVE details from NVD when not provided' do
      cve_service = instance_double(CveIntelligenceService)
      allow(CveIntelligenceService).to receive(:new).and_return(cve_service)
      allow(cve_service).to receive(:send).with(:fetch_nvd, 'CVE-2021-44228').and_return(cve_details)

      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response("```yaml\n#{valid_template_yaml}```"))

      result = generator.generate_for_cve('CVE-2021-44228')
      expect(result).to be_present
    ensure
      FileUtils.rm_f(result) if result
    end

    it 'returns nil when CVE details are not available' do
      # When no cve_details passed, it calls CveIntelligenceService to fetch
      cve_service = instance_double(CveIntelligenceService)
      allow(CveIntelligenceService).to receive(:new).and_return(cve_service)
      allow(cve_service).to receive(:send).with(:fetch_nvd, 'CVE-9999-99999').and_return(nil)

      result = generator.generate_for_cve('CVE-9999-99999')
      expect(result).to be_nil
    end

    it 'returns nil when generated template is invalid YAML' do
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response('not: [valid: yaml: {{'))

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)
      expect(result).to be_nil
    end

    it 'returns nil when template lacks required fields' do
      invalid_template = "name: test\ndescription: missing id and info\n"
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response("```yaml\n#{invalid_template}```"))

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)
      expect(result).to be_nil
    end

    it 'saves template with correct filename format' do
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response("```yaml\n#{valid_template_yaml}```"))

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)

      expect(File.basename(result)).to eq('cve_2021_44228.yaml')
    ensure
      FileUtils.rm_f(result) if result
    end

    it 'handles API errors gracefully' do
      allow(mock_messages).to receive(:create).and_raise(StandardError, 'API error')

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)
      expect(result).to be_nil
    end

    it 'extracts YAML from code blocks' do
      response_with_block = "Here is the template:\n```yaml\n#{valid_template_yaml}```\nDone."
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response(response_with_block))

      result = generator.generate_for_cve('CVE-2021-44228', cve_details)
      expect(result).to be_present
    ensure
      FileUtils.rm_f(result) if result
    end
  end

  describe '#generate_batch' do
    before do
      cve_service = instance_double(CveIntelligenceService)
      allow(CveIntelligenceService).to receive(:new).and_return(cve_service)
      allow(cve_service).to receive(:send).with(:fetch_nvd, anything).and_return(cve_details)
    end

    it 'generates templates for multiple CVEs' do
      allow(mock_messages).to receive(:create)
        .and_return(mock_claude_response("```yaml\n#{valid_template_yaml}```"))
      allow(generator).to receive(:sleep) # Skip rate limiting

      results = generator.generate_batch(['CVE-2021-44228'])

      expect(results.length).to eq(1)
      expect(results.first[:cve_id]).to eq('CVE-2021-44228')
      expect(results.first[:success]).to be true
    ensure
      results&.each { |r| FileUtils.rm_f(r[:template_path]) if r[:template_path] }
    end

    it 'reports failures in batch results' do
      allow(mock_messages).to receive(:create).and_raise(StandardError, 'API error')
      allow(generator).to receive(:sleep)

      results = generator.generate_batch(['CVE-2021-44228'])

      expect(results.first[:success]).to be false
      expect(results.first[:template_path]).to be_nil
    end

    it 'creates the templates directory' do
      templates_dir = Rails.root.join('custom_templates/nuclei')
      FileUtils.rm_rf(templates_dir)

      allow(mock_messages).to receive(:create).and_raise(StandardError, 'API error')
      allow(generator).to receive(:sleep)

      generator.generate_batch(['CVE-2021-44228'])

      expect(File.directory?(templates_dir)).to be true
    end
  end
end

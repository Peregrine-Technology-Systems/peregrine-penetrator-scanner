# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::WordpressFingerprinter do
  let(:target) { create(:target, urls: ['https://wp.example.com'].to_json) }
  let(:scan) { create(:scan, target:) }
  let(:detector) { described_class.new(scan) }
  let(:threshold) { Fingerprinters::FingerprinterBase::MIN_CONFIDENCE }

  let(:wp_html) do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="generator" content="WordPress 6.4.2">
          <link rel="stylesheet" href="/wp-content/themes/astra/style.css">
          <script src="/wp-includes/js/jquery.js"></script>
        </head>
        <body>Hello</body>
      </html>
    HTML
  end

  let(:plain_html) { '<html><body>Just a plain page</body></html>' }

  let(:wp_json_body) do
    JSON.dump(
      name: 'Test WP Site',
      description: 'Just another WordPress site',
      url: 'https://wp.example.com',
      home: 'https://wp.example.com',
      namespaces: %w[wp/v2 oembed/1.0]
    )
  end

  before do
    stub_request(:get, 'https://wp.example.com/wp-json/').to_return(status: 404)
    stub_request(:get, 'https://wp.example.com/readme.html').to_return(status: 404)
    stub_request(:get, 'https://wp.example.com/wp-login.php').to_return(status: 404)
  end

  describe '#cms_name' do
    it 'returns wordpress' do
      expect(detector.cms_name).to eq('wordpress')
    end
  end

  describe '#detect' do
    it 'detects WordPress with high confidence from generator meta and asset paths' do
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: wp_html)

      result = detector.detect
      expect(result[:cms]).to eq('wordpress')
      expect(result[:confidence]).to be >= 0.8
      expect(result[:core_version]).to eq('6.4.2')
      expect(result[:components]).to eq([])
    end

    it 'returns sub-threshold confidence for a plain HTML page' do
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: plain_html)

      result = detector.detect
      expect(result[:cms]).to eq('wordpress')
      expect(result[:confidence]).to be < threshold
      expect(result[:core_version]).to be_nil
    end

    it 'detects WordPress via the REST API when the generator meta is stripped' do
      stripped = wp_html.sub(/<meta[^>]*generator[^>]*>/, '')
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: stripped)
      stub_request(:get, 'https://wp.example.com/wp-json/')
        .to_return(status: 200, body: wp_json_body, headers: { 'Content-Type' => 'application/json' })

      result = detector.detect
      expect(result[:confidence]).to be >= threshold
      expect(result[:core_version]).to be_nil
    end

    it 'adds weight for a readme.html page that contains WordPress' do
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: plain_html)
      stub_request(:get, 'https://wp.example.com/readme.html')
        .to_return(status: 200, body: '<html>WordPress 6.x docs</html>')

      result = detector.detect
      expect(result[:confidence]).to be > 0.0
    end

    it 'does not count readme.html when the body does not mention WordPress' do
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: plain_html)
      stub_request(:get, 'https://wp.example.com/readme.html')
        .to_return(status: 200, body: '<html>Random content</html>')

      result = detector.detect
      expect(result[:confidence]).to eq(0.0)
    end

    it 'handles an empty target URL list' do
      allow(scan.target).to receive(:url_list).and_return([])
      expect(detector.detect).to eq(cms: 'wordpress', confidence: 0.0, components: [])
    end

    it 'does not raise when the root page is unreachable' do
      stub_request(:get, 'https://wp.example.com').to_raise(Faraday::ConnectionFailed.new('refused'))

      expect { detector.detect }.not_to raise_error
      expect(detector.detect[:confidence]).to eq(0.0)
    end

    it 'ignores malformed wp-json responses' do
      stub_request(:get, 'https://wp.example.com').to_return(status: 200, body: plain_html)
      stub_request(:get, 'https://wp.example.com/wp-json/')
        .to_return(status: 200, body: 'not json at all')

      result = detector.detect
      expect(result[:confidence]).to eq(0.0)
    end
  end

  describe 'registry registration' do
    # Registry state may be reset by other specs — reload the detector file to re-trigger
    # the module-level `FingerprinterRegistry.register(...)` call.
    it 'registers itself with the FingerprinterRegistry at load time' do
      Fingerprinters::FingerprinterRegistry.reset!
      load Penetrator.root.join('app/services/fingerprinters/wordpress_fingerprinter.rb').to_s

      expect(Fingerprinters::FingerprinterRegistry.detectors).to include(described_class)
    end
  end
end

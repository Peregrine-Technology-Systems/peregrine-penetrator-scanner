# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::Wordpress::SignatureEvaluator do
  let(:config) { YAML.safe_load_file(Fingerprinters::WordpressFingerprinter::CONFIG_PATH).fetch('signatures') }
  let(:resp_class) do
    Struct.new(:status, :body) { def success? = status.between?(200, 299) }
  end
  let(:responses) { {} }
  let(:requested) { [] }
  let(:fetch) do
    lambda do |path|
      requested << path
      responses[path]
    end
  end
  let(:evaluator) { described_class.new(config, fetch) }

  it 'returns no hits and tolerates nil responses for plain html' do
    expect(evaluator.call('<html></html>')).to eq({})
    expect(requested).to contain_exactly(config['wp_json_rest']['path'], config['readme_html']['path'],
                                         config['wp_login']['path'])
  end

  it 'ignores malformed wp-json bodies' do
    responses[config['wp_json_rest']['path']] = resp_class.new(200, 'not json')
    expect(evaluator.call('')).not_to have_key(:wp_json_rest)
  end

  it 'accepts wp-json with the wp/v2 namespace' do
    responses[config['wp_json_rest']['path']] = resp_class.new(200, '{"namespaces":["wp/v2"]}')
    expect(evaluator.call('')[:wp_json_rest][:weight]).to eq(config['wp_json_rest']['weight'].to_f)
  end

  it 'rejects wp-json that is not WordPress-like' do
    responses[config['wp_json_rest']['path']] = resp_class.new(200, '{"a":1}')
    expect(evaluator.call('')).not_to have_key(:wp_json_rest)
  end

  it 'counts readme.html only when it mentions WordPress and status is 2xx' do
    responses[config['readme_html']['path']] = resp_class.new(200, 'WordPress docs')
    responses[config['wp_login']['path']] = resp_class.new(404, 'wordpress')
    hits = evaluator.call('')
    expect(hits).to have_key(:readme_html)
    expect(hits).not_to have_key(:wp_login)
  end

  it 'extracts the generator version and html substring hits' do
    html = '<meta name="generator" content="WordPress 6.4.2"><a href="/wp-content/x"></a><i src="/wp-includes/a">'
    hits = evaluator.call(html)
    expect(hits.dig(:generator_meta, :version)).to eq('6.4.2')
    expect(hits).to include(:wp_content_path, :wp_includes_path)
  end
end

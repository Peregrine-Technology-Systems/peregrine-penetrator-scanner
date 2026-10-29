# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::Wordpress::ComponentEnumerator do
  let(:resp_class) do
    Struct.new(:status, :body) { def success? = status.between?(200, 299) }
  end
  let(:home) { File.read(Penetrator.root.join('spec/fixtures/wordpress/home.html')) }
  let(:requested) { [] }
  let(:responses) { {} }
  let(:fetch) do
    lambda do |path|
      requested << path
      responses[path]
    end
  end

  def enumerate(html = home) = described_class.new(html, fetch).call

  def find(list, kind, slug) = list.find { |c| c[:kind] == kind && c[:slug] == slug }

  it 'rejects traversal, encoded-slash and malformed slugs' do
    slugs = enumerate.map { |c| c[:slug] }
    expect(slugs).to contain_exactly('astra', 'contact-form-7', 'elementor', 'no-version-plugin')
  end

  it 'keeps a component whose readme fetch failed, with the asset version' do
    responses['/wp-content/plugins/contact-form-7/readme.txt'] = nil
    cf7 = find(enumerate, 'plugin', 'contact-form-7')
    expect(cf7).to include(version: '5.8.1')
  end

  it 'keeps a component when the readme returns an error status' do
    responses['/wp-content/plugins/contact-form-7/readme.txt'] = resp_class.new(500, 'boom')
    expect(find(enumerate, 'plugin', 'contact-form-7')[:version]).to eq('5.8.1')
  end

  it 'keeps a version-less component with nil version and the lowest confidence' do
    list = enumerate
    bare = find(list, 'plugin', 'no-version-plugin')
    expect(bare[:version]).to be_nil
    expect(bare[:confidence]).to eq(list.map { |c| c[:confidence] }.min)
  end

  it 'de-duplicates by kind and slug' do
    expect(enumerate.count { |c| c[:slug] == 'contact-form-7' }).to eq(1)
  end

  it 'lowercases slugs' do
    expect(find(enumerate, 'plugin', 'elementor')[:version]).to eq('3.18.0')
  end

  it 'prefers the readme Stable tag over the asset ver with higher confidence' do
    responses['/wp-content/plugins/contact-form-7/readme.txt'] = resp_class.new(200, "Stable tag: 5.9.3\n")
    cf7 = find(enumerate, 'plugin', 'contact-form-7')
    expect(cf7[:version]).to eq('5.9.3')
    expect(cf7[:confidence]).to be > find(enumerate, 'plugin', 'elementor')[:confidence]
  end

  it 'reads a theme version from style.css' do
    responses['/wp-content/themes/astra/style.css'] = resp_class.new(200, "/*\nVersion: 4.6.5\n*/")
    expect(find(enumerate, 'theme', 'astra')[:version]).to eq('4.6.5')
  end

  it 'caps the readme fetches for a page with many plugins' do
    html = (1..100).map { |i| "<script src=\"/wp-content/plugins/p#{i}/a.js\"></script>" }.join
    enumerate(html)
    max = described_class::MAX_PLUGIN_FETCHES
    expect(requested.size).to eq(max)
    expect(enumerate(html).size).to be <= described_class::MAX_COMPONENTS
  end

  it 'caps the style.css fetches for a page with many themes' do
    html = (1..50).map { |i| "<link href=\"/wp-content/themes/t#{i}/s.css\">" }.join
    enumerate(html)
    expect(requested.size).to eq(described_class::MAX_THEME_FETCHES)
  end

  it 'returns an empty list for html with no components' do
    expect(enumerate('<html></html>')).to eq([])
  end
end

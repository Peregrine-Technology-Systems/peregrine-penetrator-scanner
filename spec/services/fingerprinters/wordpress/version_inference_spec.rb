# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Fingerprinters::Wordpress::VersionInference do
  describe '.stable_tag' do
    it 'returns nil for non-version tags such as trunk' do
      expect(described_class.stable_tag("Stable tag: trunk\n")).to be_nil
    end

    it 'returns nil for hostile or oversize values' do
      expect(described_class.stable_tag("Stable tag: <script>alert(1)</script>\n")).to be_nil
      expect(described_class.stable_tag("Stable tag: 1#{'0' * 100}\n")).to be_nil
    end

    it 'returns nil for blank or nil bodies' do
      expect(described_class.stable_tag(nil)).to be_nil
      expect(described_class.stable_tag('')).to be_nil
    end

    it 'reads the Stable tag from a readme.txt' do
      body = File.read(Penetrator.root.join('spec/fixtures/wordpress/plugin_readme.txt'))
      expect(described_class.stable_tag(body)).to eq('5.9.3')
    end
  end

  describe '.style_version' do
    it 'returns nil when there is no Version header' do
      expect(described_class.style_version('body { color: red }')).to be_nil
    end

    it 'reads the Version header from a theme style.css' do
      body = File.read(Penetrator.root.join('spec/fixtures/wordpress/theme_style.css'))
      expect(described_class.style_version(body)).to eq('4.6.5')
    end

    it 'ignores a Version line beyond the header window' do
      body = "#{'x' * 9000}\nVersion: 9.9.9\n"
      expect(described_class.style_version(body)).to be_nil
    end
  end

  describe '.asset_version' do
    let(:html) do
      '<link href="/wp-content/plugins/foo/a.css?ver=1.2.3"><script src="/wp-content/plugins/foobar/a.js?ver=9.9"></script>' \
        '<link href="/wp-content/themes/foo/s.css?x=1&#038;ver=2.0">'
    end

    it 'returns nil when no asset for that slug carries a version' do
      expect(described_class.asset_version(html, 'plugins', 'missing')).to be_nil
    end

    it 'does not match a slug that merely shares a prefix' do
      expect(described_class.asset_version(html, 'plugins', 'foo')).to eq('1.2.3')
    end

    it 'distinguishes plugins from themes and handles encoded ampersands' do
      expect(described_class.asset_version(html, 'themes', 'foo')).to eq('2.0')
    end
  end
end

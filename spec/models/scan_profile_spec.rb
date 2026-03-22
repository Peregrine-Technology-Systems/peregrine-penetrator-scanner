require 'sequel_helper'

RSpec.describe ScanProfile do
  describe '.load' do
    it 'loads a valid profile from YAML' do
      profile = described_class.load('standard')

      expect(profile.name).to eq('standard')
      expect(profile.description).to be_present
      expect(profile.estimated_duration_minutes).to be_a(Integer)
    end

    it 'raises ArgumentError for unknown profile' do
      expect { described_class.load('nonexistent') }.to raise_error(ArgumentError, /Unknown scan profile/)
    end

    it 'populates phases from the YAML config' do
      profile = described_class.load('standard')

      expect(profile.phases).to be_an(Array)
      expect(profile.phases).not_to be_empty
      expect(profile.phases.first).to be_a(ScanProfile::Phase)
    end
  end

  describe '.available' do
    it 'returns a list of available profile names' do
      profiles = described_class.available

      expect(profiles).to include('quick', 'standard', 'thorough')
    end

    it 'returns strings without the .yml extension' do
      profiles = described_class.available

      profiles.each do |name|
        expect(name).not_to end_with('.yml')
      end
    end
  end

  describe '#tools_for_phase' do
    it 'returns tools for a known phase' do
      profile = described_class.load('standard')
      tools = profile.tools_for_phase('discovery')

      expect(tools).to be_an(Array)
      expect(tools).not_to be_empty
      expect(tools.first).to be_a(ScanProfile::ToolConfig)
    end

    it 'returns empty array for an unknown phase' do
      profile = described_class.load('standard')
      tools = profile.tools_for_phase('nonexistent_phase')

      expect(tools).to eq([])
    end

    it 'accepts symbol phase names via to_s conversion' do
      profile = described_class.load('standard')
      tools = profile.tools_for_phase(:discovery)

      expect(tools).not_to be_empty
    end
  end

  describe ScanProfile::Phase do
    it 'exposes name, tools, and parallel attributes' do
      profile = ScanProfile.load('standard')
      discovery_phase = profile.phases.find { |p| p.name == 'discovery' }

      expect(discovery_phase.name).to eq('discovery')
      expect(discovery_phase.parallel).to be true
      expect(discovery_phase.tools).to be_an(Array)
    end
  end

  describe ScanProfile::ToolConfig do
    it 'exposes the tool name' do
      profile = ScanProfile.load('standard')
      discovery_tools = profile.tools_for_phase('discovery')
      ffuf_config = discovery_tools.find { |t| t.tool == 'ffuf' }

      expect(ffuf_config.tool).to eq('ffuf')
    end

    it 'provides a default timeout of 600 when not specified' do
      config = described_class.new({ tool: 'test' })

      expect(config.timeout).to eq(600)
    end

    it 'uses the configured timeout when specified' do
      config = described_class.new({ tool: 'test', timeout: 300 })

      expect(config.timeout).to eq(300)
    end

    it 'delegates unknown methods to config hash via method_missing' do
      config = described_class.new({ tool: 'ffuf', threads: 40, wordlist: '/path/to/wordlist' })

      expect(config.threads).to eq(40)
      expect(config.wordlist).to eq('/path/to/wordlist')
    end

    it 'raises NoMethodError for truly unknown methods' do
      config = described_class.new({ tool: 'test' })

      expect { config.nonexistent_method }.to raise_error(NoMethodError)
    end

    it 'responds to methods backed by config' do
      config = described_class.new({ tool: 'ffuf', threads: 40 })

      expect(config.respond_to?(:threads)).to be true
      expect(config.respond_to?(:nonexistent)).to be false
    end
  end
end

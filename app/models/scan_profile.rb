class ScanProfile
  attr_reader :name, :description, :estimated_duration_minutes, :phases

  PROFILES_DIR = Rails.root.join('config/scan_profiles')

  def self.load(profile_name)
    path = PROFILES_DIR.join("#{profile_name}.yml")
    raise ArgumentError, "Unknown scan profile: #{profile_name}" unless path.exist?

    config = YAML.safe_load_file(path, symbolize_names: true)
    new(config)
  end

  def self.available
    Dir.glob(PROFILES_DIR.join('*.yml')).map { |f| File.basename(f, '.yml') }
  end

  def initialize(config)
    @name = config[:name]
    @description = config[:description]
    @estimated_duration_minutes = config[:estimated_duration_minutes]
    @phases = config[:phases].map { |p| Phase.new(p) }
  end

  def tools_for_phase(phase_name)
    phase = @phases.find { |p| p.name == phase_name.to_s }
    phase&.tools || []
  end

  class Phase
    attr_reader :name, :tools, :parallel

    def initialize(config)
      @name = config[:name]
      @parallel = config[:parallel] || false
      @tools = (config[:tools] || []).map { |t| ToolConfig.new(t) }
    end
  end

  class ToolConfig
    attr_reader :tool, :config

    def initialize(config)
      @tool = config[:tool]
      @config = config.except(:tool)
    end

    def timeout
      @config[:timeout] || 600
    end

    def method_missing(method, *args)
      @config.key?(method) ? @config[method] : super
    end

    def respond_to_missing?(method, include_private = false)
      @config.key?(method) || super
    end
  end
end

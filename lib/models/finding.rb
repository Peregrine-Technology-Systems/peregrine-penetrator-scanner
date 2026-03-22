# frozen_string_literal: true

class Finding < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  plugin :serialization, :json, :evidence, :ai_assessment

  many_to_one :scan

  SEVERITY_ORDER = Sequel.lit(
    "CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 " \
    "WHEN 'medium' THEN 2 WHEN 'low' THEN 3 WHEN 'info' THEN 4 END"
  ).freeze

  def before_create
    self.id ||= SecureRandom.uuid
    super
  end

  def before_validation
    generate_fingerprint
    super
  end

  def validate
    super
    validates_presence %i[source_tool title severity fingerprint]
    validates_includes %w[critical high medium low info], :severity
    validates_unique(:fingerprint) { |ds| ds.where(scan_id: scan_id) }
  end

  dataset_module do
    def by_severity
      order(Finding::SEVERITY_ORDER)
    end

    def non_duplicate
      where(duplicate: false)
    end

    def by_tool(tool)
      where(source_tool: tool)
    end
  end

  private

  def generate_fingerprint
    raw = "#{source_tool}:#{title}:#{url}:#{parameter}:#{cwe_id}"
    self.fingerprint = Digest::SHA256.hexdigest(raw)
  end
end

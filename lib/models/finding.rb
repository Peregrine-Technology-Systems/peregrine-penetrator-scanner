# frozen_string_literal: true

class Finding < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  plugin :serialization, :json, :evidence
  plugin :serialization, :json, :data

  many_to_one :scan

  SEVERITY_ORDER = Sequel.lit(
    "CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 " \
    "WHEN 'medium' THEN 2 WHEN 'low' THEN 3 WHEN 'info' THEN 4 END"
  ).freeze

  # Build a Finding from a probe output contract document (#971). The full
  # contract finding (probe/location/identifiers/scores/component/evidence/ext)
  # is stored verbatim in `data`; a few fields are promoted to columns for
  # indexing/validation. severity may be null in the contract (asset/info
  # findings) — the column defaults to 'info' while `data` keeps the true value.
  def self.from_contract(contract, scan_id:)
    doc = JSON.parse(JSON.generate(contract)) # deep string keys, matches reloaded form
    create(
      scan_id:,
      source_tool: doc['source_tool'],
      severity: doc['severity'] || 'info',
      title: doc['title'],
      finding_type: doc['finding_type'],
      data: doc
    )
  end

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
    validates_unique(:fingerprint) { |ds| ds.where(scan_id:) }
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

  # Domain-identity fingerprint. Prefers the contract document (the source of
  # truth); falls back to the flat columns for findings created without a
  # contract (e.g. the test factory).
  def generate_fingerprint
    self.fingerprint = if data.is_a?(Hash) && !data.empty?
                         fingerprint_from_contract
                       else
                         Digest::SHA256.hexdigest("#{source_tool}:#{title}:#{url}:#{parameter}:#{cwe_id}")
                       end
  end

  def fingerprint_from_contract
    loc = data['location'] || {}
    cwe = Array(data['identifiers']).find { |i| i['type'] == 'cwe' }
    raw = [data['title']&.downcase&.strip,
           "#{loc['host']}#{loc['url']}",
           loc['parameter']&.to_s&.downcase,
           cwe&.dig('value')].compact.join(':')
    Digest::SHA256.hexdigest(raw)
  end
end

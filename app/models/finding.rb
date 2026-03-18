class Finding < ApplicationRecord
  belongs_to :scan

  validates :source_tool, :title, :severity, :fingerprint, presence: true
  validates :severity, inclusion: { in: %w[critical high medium low info] }
  validates :fingerprint, uniqueness: { scope: :scan_id }

  serialize :evidence, coder: JSON
  serialize :ai_assessment, coder: JSON

  before_validation :generate_fingerprint

  scope :by_severity, lambda {
                        order(Arel.sql("CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 WHEN 'info' THEN 4 END"))
                      }
  scope :non_duplicate, -> { where(duplicate: false) }
  scope :by_tool, ->(tool) { where(source_tool: tool) }

  private

  def generate_fingerprint
    raw = "#{source_tool}:#{title}:#{url}:#{parameter}:#{cwe_id}"
    self.fingerprint = Digest::SHA256.hexdigest(raw)
  end
end

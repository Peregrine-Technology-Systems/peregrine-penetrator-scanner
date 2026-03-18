class Scan < ApplicationRecord
  belongs_to :target
  has_many :findings, dependent: :destroy
  has_many :reports, dependent: :destroy

  validates :profile, inclusion: { in: %w[quick standard thorough] }
  validates :status, inclusion: { in: %w[pending running completed failed cancelled] }

  serialize :tool_statuses, coder: JSON
  serialize :summary, coder: JSON

  scope :recent, -> { order(created_at: :desc) }
  scope :by_status, ->(status) { where(status:) }

  def duration
    return nil unless started_at && completed_at

    completed_at - started_at
  end

  def finding_counts
    findings.group(:severity).count
  end
end

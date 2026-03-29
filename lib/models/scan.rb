# frozen_string_literal: true

class Scan < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  plugin :serialization, :json, :tool_statuses, :summary

  many_to_one :target
  one_to_many :findings

  def before_create
    self.id ||= SecureRandom.uuid
    super
  end

  def before_validation
    self.status ||= 'pending' if new?
    super
  end

  def validate
    super
    validates_includes %w[quick standard thorough deep smoke smoke-test], :profile
    validates_includes %w[pending running completed failed cancelled], :status
  end

  dataset_module do
    def recent
      order(Sequel.desc(:created_at))
    end

    def by_status(status)
      where(status:)
    end
  end

  def duration
    return nil unless started_at && completed_at

    completed_at - started_at
  end

  def finding_counts
    findings_dataset.group_and_count(:severity).all.to_h { |r| [r[:severity], r[:count]] }
  end
end

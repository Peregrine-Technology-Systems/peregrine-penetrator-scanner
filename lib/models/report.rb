# frozen_string_literal: true

class Report < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :scan

  def before_create
    self.id ||= SecureRandom.uuid
    super
  end

  def validate
    super
    validates_includes %w[json markdown html pdf], :format
    validates_includes %w[pending generating completed failed], :status
  end

  def signed_url_valid?
    return false if signed_url_expires_at.blank?

    Time.current < signed_url_expires_at
  end
end

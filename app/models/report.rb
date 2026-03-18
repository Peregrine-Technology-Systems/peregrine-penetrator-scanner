class Report < ApplicationRecord
  belongs_to :scan

  validates :format, inclusion: { in: %w[json html pdf] }
  validates :status, inclusion: { in: %w[pending generating completed failed] }

  def signed_url_valid?
    return false if signed_url_expires_at.blank?

    Time.current < signed_url_expires_at
  end
end

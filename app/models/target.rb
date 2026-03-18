class Target < ApplicationRecord
  has_many :scans, dependent: :destroy

  validates :name, presence: true
  validates :urls, presence: true
  validates :auth_type, inclusion: { in: %w[none basic bearer cookie] }

  serialize :urls, coder: JSON
  serialize :auth_config, coder: JSON
  serialize :scope_config, coder: JSON
  serialize :brand_config, coder: JSON

  scope :active, -> { where(active: true) }

  def url_list
    return [] if urls.blank?

    urls.is_a?(Array) ? urls : JSON.parse(urls)
  rescue JSON::ParserError
    []
  end
end

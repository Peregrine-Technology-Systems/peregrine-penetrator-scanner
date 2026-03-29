# frozen_string_literal: true

class Target < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  plugin :serialization, :json, :urls, :auth_config, :scope_config, :brand_config, :ticket_config

  one_to_many :scans

  def before_create
    self.id ||= SecureRandom.uuid
    super
  end

  def before_validation
    self.auth_type ||= 'none' if new?
    super
  end

  def validate
    super
    validates_presence :name
    validates_presence :urls
    validates_includes %w[none basic bearer cookie], :auth_type
    validates_includes %w[github linear jira], :ticket_tracker, allow_nil: true
  end

  dataset_module do
    def active
      where(active: true)
    end
  end

  def ticketing_enabled?
    ticket_tracker.present? && ticket_config.present?
  end

  def url_list
    return [] if urls.blank?

    urls.is_a?(Array) ? urls : JSON.parse(urls)
  rescue JSON::ParserError
    []
  end
end

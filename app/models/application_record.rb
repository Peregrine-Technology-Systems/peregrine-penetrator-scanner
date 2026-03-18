class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  before_create :assign_uuid

  private

  def assign_uuid
    self.id ||= SecureRandom.uuid
  end
end

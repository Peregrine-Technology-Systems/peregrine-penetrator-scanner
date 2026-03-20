class AddTicketingToTargets < ActiveRecord::Migration[7.1]
  def change
    add_column :targets, :ticket_tracker, :string
    add_column :targets, :ticket_config, :text
  end
end

class CreateScans < ActiveRecord::Migration[7.1]
  def change
    create_table :scans, id: false do |t|
      t.string :id, limit: 36, primary_key: true
      t.string :target_id, limit: 36, null: false
      t.string :profile, null: false, default: "standard"
      t.string :status, null: false, default: "pending"
      t.text :tool_statuses, default: "{}"
      t.text :summary, default: "{}"
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message

      t.timestamps
    end

    add_index :scans, :target_id
    add_foreign_key :scans, :targets
  end
end

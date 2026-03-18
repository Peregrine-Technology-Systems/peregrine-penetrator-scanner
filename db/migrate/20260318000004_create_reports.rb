class CreateReports < ActiveRecord::Migration[7.1]
  def change
    create_table :reports, id: false do |t|
      t.string :id, limit: 36, primary_key: true
      t.string :scan_id, limit: 36, null: false
      t.string :format, null: false
      t.string :gcs_path
      t.text :signed_url
      t.datetime :signed_url_expires_at
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    add_index :reports, :scan_id
    add_foreign_key :reports, :scans
  end
end

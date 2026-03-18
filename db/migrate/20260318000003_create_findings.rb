class CreateFindings < ActiveRecord::Migration[7.1]
  def change
    create_table :findings, id: false do |t|
      t.string :id, limit: 36, primary_key: true
      t.string :scan_id, limit: 36, null: false
      t.string :source_tool, null: false
      t.string :severity, null: false, default: "info"
      t.string :title, null: false
      t.text :url
      t.string :parameter
      t.string :cwe_id
      t.text :evidence, default: "{}"
      t.string :fingerprint, null: false
      t.boolean :duplicate, default: false
      t.string :cve_id
      t.float :cvss_score
      t.float :epss_score
      t.boolean :kev_known_exploited, default: false
      t.text :ai_assessment

      t.timestamps
    end

    add_index :findings, :scan_id
    add_index :findings, :fingerprint
    add_foreign_key :findings, :scans
  end
end

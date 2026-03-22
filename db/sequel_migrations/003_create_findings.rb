# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:findings) do
      String :id, size: 36, primary_key: true
      String :scan_id, size: 36, null: false
      String :source_tool
      String :severity, default: 'info'
      String :title
      String :url, text: true
      String :parameter
      String :cwe_id
      String :evidence, text: true, default: '{}'
      String :fingerprint
      TrueClass :duplicate, default: false
      String :cve_id
      Float :cvss_score
      Float :epss_score
      TrueClass :kev_known_exploited, default: false
      String :ai_assessment, text: true
      DateTime :created_at
      DateTime :updated_at

      foreign_key [:scan_id], :scans
      index :scan_id
      index :fingerprint
    end
  end
end

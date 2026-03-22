# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:reports) do
      String :id, size: 36, primary_key: true
      String :scan_id, size: 36, null: false
      String :format
      String :gcs_path
      String :signed_url, text: true
      DateTime :signed_url_expires_at
      String :status, default: 'pending'
      DateTime :created_at
      DateTime :updated_at

      foreign_key [:scan_id], :scans
      index :scan_id
    end
  end
end

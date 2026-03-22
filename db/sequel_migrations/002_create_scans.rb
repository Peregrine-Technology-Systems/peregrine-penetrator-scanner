# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:scans) do
      String :id, size: 36, primary_key: true
      String :target_id, size: 36, null: false
      String :profile, default: 'standard'
      String :status, default: 'pending'
      String :tool_statuses, text: true, default: '{}'
      String :summary, text: true, default: '{}'
      DateTime :started_at
      DateTime :completed_at
      String :error_message, text: true
      DateTime :created_at
      DateTime :updated_at

      foreign_key [:target_id], :targets
      index :target_id
    end
  end
end

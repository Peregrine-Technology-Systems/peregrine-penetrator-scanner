# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:targets) do
      String :id, size: 36, primary_key: true
      String :name, null: false
      String :urls, text: true, null: false, default: '[]'
      String :auth_type, default: 'none'
      String :auth_config, text: true
      String :scope_config, text: true
      String :brand_config, text: true
      String :ticket_tracker
      String :ticket_config, text: true
      TrueClass :active, default: true
      DateTime :created_at
      DateTime :updated_at
    end
  end
end

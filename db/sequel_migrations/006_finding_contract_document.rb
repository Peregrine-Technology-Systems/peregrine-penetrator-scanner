# frozen_string_literal: true

Sequel.migration do
  # Probe output contract v2.0 (#971): each finding now carries the full contract
  # document in `data` (probe/location/identifiers/scores/component/evidence/ext).
  # The flat url/parameter/cwe_id/cve_id/cvss columns remain as nullable index
  # fallbacks but are no longer the source of truth — the exporter emits `data`.
  change do
    alter_table(:findings) do
      add_column :data, String, text: true
      add_column :finding_type, String
      add_index :finding_type
    end
  end
end

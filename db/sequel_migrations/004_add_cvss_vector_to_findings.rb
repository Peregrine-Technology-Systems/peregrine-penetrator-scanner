Sequel.migration do
  change do
    alter_table(:findings) do
      add_column :cvss_vector, String, text: true
    end
  end
end

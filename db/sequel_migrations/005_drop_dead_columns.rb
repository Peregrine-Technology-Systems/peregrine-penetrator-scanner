Sequel.migration do
  # Drop monolith-era columns the scanner never populates (#960):
  #   findings.ai_assessment — AI analysis moved to the reporter (v0.3.0); always empty here.
  #   targets.ticket_tracker / ticket_config — ticketing moved to the reporter; never used.
  change do
    alter_table(:findings) do
      drop_column :ai_assessment
    end
    alter_table(:targets) do
      drop_column :ticket_tracker
      drop_column :ticket_config
    end
  end
end

# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe ScanJobRunner do
  let(:runner) { described_class.new(profile:, target_name: 'example.com', target_urls: ['https://example.com']) }
  let(:mock_orchestrator) { instance_double(ScanOrchestrator, execute: nil) }
  let(:mock_exporter) { instance_double(ScanResultsExporter, export: 'gs://bucket/report.json') }
  let(:mock_audit) { instance_double(AuditLogger, scan_started: nil, scan_completed: nil, json_exported: nil) }
  let(:mock_completion_publisher) { instance_double(ScanCompletionPublisher, emit: nil) }

  before do
    allow(ScanOrchestrator).to receive(:new).and_return(mock_orchestrator)
    allow(ScanResultsExporter).to receive(:new).and_return(mock_exporter)
    allow(AuditLogger).to receive(:new).and_return(mock_audit)
    allow(ScanCompletionPublisher).to receive(:new).and_return(mock_completion_publisher)
    allow_any_instance_of(StorageService).to receive(:upload_json) # rubocop:disable RSpec/AnyInstance
  end

  context 'with a standard profile' do
    let(:profile) { 'standard' }

    it 'creates a target and scan, runs the orchestrator, and returns a passed result' do
      result = runner.call

      expect(result.scan).to be_a(Scan)
      expect(result.passed).to be(true)
      expect(mock_orchestrator).to have_received(:execute)
    end

    it 'exports full results, writes GCS completion status, and publishes the bus completion event' do
      runner.call

      expect(mock_exporter).to have_received(:export)
      expect(mock_completion_publisher).to have_received(:emit)
      expect(mock_audit).to have_received(:json_exported)
      expect(mock_audit).to have_received(:scan_completed)
    end

    it 'does not claim the bus publish happened when emit returns nil (disabled or failed)' do
      allow(mock_completion_publisher).to receive(:emit).and_return(nil)

      expect { runner.call }.to output(/NOT published to the bus.*status\.json.*durable fallback/).to_stdout
      expect { runner.call }.not_to output(/Published scan completion to the bus/).to_stdout
    end

    it 'reports the blob uri when emit returns one' do
      allow(mock_completion_publisher).to receive(:emit).and_return('blob-123')

      expect { runner.call }.to output(/Published scan completion to the bus \(blob-123\)/).to_stdout
      expect { runner.call }.not_to output(/NOT published/).to_stdout
    end

    it 'never fails the scan when the bus publish did not happen' do
      allow(mock_completion_publisher).to receive(:emit).and_return(nil)

      expect(runner.call.passed).to be(true)
    end

    it 'reuses an existing target by name rather than creating a duplicate' do
      create(:target, name: 'example.com', urls: ['https://example.com'].to_json)

      expect { runner.call }.to change(Scan, :count).by(1)
                                                    .and(change(Target, :count).by(0)) # rubocop:disable RSpec/ChangeByZero -- no `not_change` matcher in this RSpec version
    end
  end

  context 'with a smoke profile' do
    let(:profile) { 'smoke' }

    it 'skips the full export path and returns a Result reflecting the scan status' do
      result = runner.call

      expect(result.passed).to eq(result.scan.status == 'completed')
      expect(mock_exporter).to have_received(:export)
      expect(mock_completion_publisher).not_to have_received(:emit)
      expect(mock_audit).not_to have_received(:json_exported)
    end
  end
end

# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Penetrator do
  describe '.root' do
    it 'returns a Pathname' do
      expect(described_class.root).to be_a(Pathname)
    end
  end

  describe '.logger' do
    it 'returns a Logger' do
      expect(described_class.logger).to be_a(Logger)
    end
  end

  describe '.log_formatter (structured JSON logging, #887)' do
    let(:time) { Time.utc(2026, 6, 22, 22, 45, 32) }

    def format_line(severity, msg)
      described_class.send(:log_formatter).call(severity, time, nil, msg)
    end

    context 'when LOG_FORMAT is unset (local dev — behavior unchanged)' do
      it 'emits the human-readable line, not JSON' do
        line = format_line('INFO', '[ScanOrchestrator] Phase: targeted')
        expect(line).to eq("22:45:32 [INFO] [ScanOrchestrator] Phase: targeted\n")
      end
    end

    context 'when LOG_FORMAT=json' do
      around do |example|
        ENV['LOG_FORMAT'] = 'json'
        example.run
      ensure
        ENV.delete('LOG_FORMAT')
      end

      it 'emits one JSON object per line with severity, message, and ISO-8601 timestamp' do
        entry = JSON.parse(format_line('INFO', '[ScanOrchestrator] Phase: targeted'))
        expect(entry).to include(
          'severity' => 'INFO',
          'message' => '[ScanOrchestrator] Phase: targeted',
          'timestamp' => '2026-06-22T22:45:32Z'
        )
      end

      it 'maps Ruby WARN/FATAL to GCP Cloud Logging WARNING/CRITICAL' do
        expect(JSON.parse(format_line('WARN', 'x'))['severity']).to eq('WARNING')
        expect(JSON.parse(format_line('FATAL', 'x'))['severity']).to eq('CRITICAL')
        expect(JSON.parse(format_line('ERROR', 'x'))['severity']).to eq('ERROR')
      end

      context 'with scan context in the environment' do
        around do |example|
          ENV['SCAN_UUID'] = 'scan-abc123'
          ENV['SCAN_MODE'] = 'production'
          ENV['SCAN_PROFILE'] = 'quick'
          example.run
        ensure
          %w[SCAN_UUID SCAN_MODE SCAN_PROFILE].each { |k| ENV.delete(k) }
        end

        it 'includes scan_uuid, environment, and scan_profile fields' do
          entry = JSON.parse(format_line('INFO', 'hi'))
          expect(entry).to include('scan_uuid' => 'scan-abc123', 'environment' => 'production',
                                   'scan_profile' => 'quick')
        end
      end

      it 'omits scan context fields when the env vars are absent' do
        entry = JSON.parse(format_line('INFO', 'hi'))
        expect(entry.keys).to contain_exactly('severity', 'message', 'timestamp')
      end
    end
  end

  describe '.env' do
    it 'returns test in test environment' do
      expect(described_class.env).to eq('test')
    end
  end

  describe '.db' do
    it 'returns a Sequel database connection' do
      expect(described_class.db).to be_a(Sequel::SQLite::Database)
    end

    it 'has the targets table' do
      expect(described_class.db.table_exists?(:targets)).to be true
    end

    it 'has the scans table' do
      expect(described_class.db.table_exists?(:scans)).to be true
    end

    it 'has the findings table' do
      expect(described_class.db.table_exists?(:findings)).to be true
    end

    it 'runs in WAL journal mode' do
      mode = described_class.db.fetch('PRAGMA journal_mode').first[:journal_mode]
      expect(mode).to eq('wal')
    end

    it 'has a 5-second busy timeout for SQLite-level write retry' do
      timeout = described_class.db.fetch('PRAGMA busy_timeout').first[:timeout]
      expect(timeout).to eq(5000)
    end
  end
end

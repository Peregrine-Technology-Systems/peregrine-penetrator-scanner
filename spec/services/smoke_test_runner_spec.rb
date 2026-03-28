require 'sequel_helper'

RSpec.describe SmokeTestRunner do
  let(:target) { create(:target) }
  let(:scan) { create(:scan, target:, profile: 'smoke-test') }
  let(:runner) { described_class.new(scan) }

  describe '#run' do
    it 'creates 3 canned findings' do
      expect { runner.run }.to change { scan.findings_dataset.count }.by(3)
    end

    it 'marks scan as completed' do
      runner.run
      scan.refresh
      expect(scan.status).to eq('completed')
      expect(scan.completed_at).to be_present
    end

    it 'returns summary with smoke_test flag' do
      summary = runner.run
      expect(summary['smoke_test']).to be true
      expect(summary['total_findings']).to eq(3)
    end

    it 'includes severity breakdown' do
      summary = runner.run
      expect(summary['by_severity']).to include('medium' => 1, 'low' => 1, 'info' => 1)
    end

    it 'completes in under 30 seconds' do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      runner.run
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < 30
    end
  end
end

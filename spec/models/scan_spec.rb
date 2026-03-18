require 'rails_helper'

RSpec.describe Scan do
  describe 'validations' do
    it { is_expected.to validate_inclusion_of(:profile).in_array(%w[quick standard thorough]) }
    it { is_expected.to validate_inclusion_of(:status).in_array(%w[pending running completed failed cancelled]) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:target) }
    it { is_expected.to have_many(:findings).dependent(:destroy) }
    it { is_expected.to have_many(:reports).dependent(:destroy) }
  end

  describe 'scopes' do
    describe '.recent' do
      it 'orders scans by created_at descending' do
        old_scan = create(:scan, created_at: 2.days.ago)
        new_scan = create(:scan, created_at: 1.hour.ago)

        expect(described_class.recent).to eq([new_scan, old_scan])
      end
    end

    describe '.by_status' do
      it 'filters scans by status' do
        pending_scan = create(:scan, status: 'pending')
        create(:scan, :running)

        expect(described_class.by_status('pending')).to eq([pending_scan])
      end
    end
  end

  describe '#duration' do
    it 'returns nil when started_at is nil' do
      scan = build(:scan, started_at: nil, completed_at: Time.current)

      expect(scan.duration).to be_nil
    end

    it 'returns nil when completed_at is nil' do
      scan = build(:scan, started_at: Time.current, completed_at: nil)

      expect(scan.duration).to be_nil
    end

    it 'returns the difference in seconds between completed_at and started_at' do
      started = Time.current
      completed = started + 30.minutes
      scan = build(:scan, started_at: started, completed_at: completed)

      expect(scan.duration).to be_within(1).of(1800)
    end
  end

  describe '#finding_counts' do
    it 'returns findings grouped by severity' do
      scan = create(:scan)
      create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'XSS 1', url: 'https://a.com/1')
      create(:finding, scan:, severity: 'high', source_tool: 'zap', title: 'XSS 2', url: 'https://a.com/2')
      create(:finding, scan:, severity: 'medium', source_tool: 'nuclei', title: 'Info Leak', url: 'https://a.com/3')

      counts = scan.finding_counts

      expect(counts['high']).to eq(2)
      expect(counts['medium']).to eq(1)
    end

    it 'returns empty hash when no findings' do
      scan = create(:scan)

      expect(scan.finding_counts).to eq({})
    end
  end

  describe 'serialized attributes' do
    it 'serializes tool_statuses as JSON' do
      statuses = { 'zap' => { 'status' => 'completed' } }
      scan = create(:scan, tool_statuses: statuses)
      scan.reload

      expect(scan.tool_statuses).to eq(statuses)
    end

    it 'serializes summary as JSON' do
      summary = { 'total_findings' => 10, 'by_severity' => { 'high' => 3 } }
      scan = create(:scan, summary:)
      scan.reload

      expect(scan.summary).to eq(summary)
    end
  end
end

require 'sequel_helper'

RSpec.describe TicketingService do
  let(:target) { create(:target, :with_github_tickets) }
  let(:scan) { create(:scan, :completed, target:) }
  let(:github_api_url) { 'https://api.github.com/repos/test-org/test-repo/issues' }

  before do
    stub_const('ENV', ENV.to_h.merge('GITHUB_TOKEN' => 'ghp_test123'))
  end

  describe '#create_tickets' do
    context 'when ticketing is not configured' do
      let(:target) { create(:target) }

      it 'returns 0' do
        expect(described_class.new(scan).create_tickets).to eq(0)
      end
    end

    context 'when token env var is not set' do
      before { stub_const('ENV', ENV.to_h.except('GITHUB_TOKEN')) }

      it 'returns 0 and logs error' do
        expect(Penetrator.logger).to receive(:error).with(/Token env/)
        expect(described_class.new(scan).create_tickets).to eq(0)
      end
    end

    context 'with qualifying findings' do
      let!(:high_finding) do
        create(:finding, scan:, severity: 'high', title: 'XSS',
                         fingerprint: SecureRandom.hex(32))
      end

      let!(:info_finding) do
        create(:finding, scan:, severity: 'info', title: 'Server header',
                         fingerprint: SecureRandom.hex(32))
      end

      before do
        stub_request(:post, github_api_url)
          .to_return(status: 201,
                     body: { number: 1, html_url: 'https://github.com/test-org/test-repo/issues/1' }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'creates tickets for non-info findings' do
        result = described_class.new(scan).create_tickets

        expect(result).to eq(1)
        expect(WebMock).to have_requested(:post, github_api_url).once
      end

      it 'stamps finding evidence with ticket metadata' do
        described_class.new(scan).create_tickets
        high_finding.reload

        expect(high_finding.evidence['ticket_system']).to eq('github')
        expect(high_finding.evidence['ticket_ref']).to eq('test-org/test-repo#1')
        expect(high_finding.evidence['ticket_url']).to be_present
        expect(high_finding.evidence['ticket_pushed_at']).to be_present
      end

      it 'does not create tickets for info findings' do
        described_class.new(scan).create_tickets
        info_finding.reload

        expect(info_finding.evidence).not_to include('ticket_ref')
      end
    end

    context 'with duplicate findings' do
      let!(:finding) do
        create(:finding, scan:, severity: 'high', fingerprint: SecureRandom.hex(32),
                         duplicate: true)
      end

      it 'skips duplicates' do
        expect(described_class.new(scan).create_tickets).to eq(0)
      end
    end

    context 'when BigQuery has existing tickets' do
      let!(:finding) do
        create(:finding, scan:, severity: 'high')
      end

      before do
        allow(BigQueryLogger).to receive(:enabled?).and_return(true)
        dedup = instance_double(TicketingService::BigqueryDedup)
        allow(TicketingService::BigqueryDedup).to receive(:new).and_return(dedup)
        allow(dedup).to receive(:existing_tickets)
          .and_return({ finding.fingerprint => 'test-org/test-repo#99' })
      end

      it 'skips already-ticketed findings' do
        result = described_class.new(scan).create_tickets

        expect(result).to eq(0)
        expect(WebMock).not_to have_requested(:post, github_api_url)
      end
    end

    context 'when API fails for one finding' do
      before do
        create(:finding, scan:, severity: 'high', fingerprint: SecureRandom.hex(32))
        create(:finding, scan:, severity: 'medium', fingerprint: SecureRandom.hex(32))

        stub_request(:post, github_api_url)
          .to_return(
            { status: 422, body: '{}' },
            { status: 201,
              body: { number: 2, html_url: 'https://github.com/test-org/test-repo/issues/2' }.to_json,
              headers: { 'Content-Type' => 'application/json' } }
          )
      end

      it 'continues creating tickets for remaining findings' do
        result = described_class.new(scan).create_tickets
        expect(result).to eq(1)
      end
    end
  end
end

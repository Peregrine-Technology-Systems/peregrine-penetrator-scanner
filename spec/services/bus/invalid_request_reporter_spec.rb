# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::InvalidRequestReporter do
  let(:publisher) { instance_double(Bus::Publisher, publish: nil) }
  let(:payload) { Bus::ScanRequestPayload.new('job_id' => 'j1', 'transaction_id' => 't1') }

  before { allow(Penetrator.logger).to receive(:error) }

  it 'publishes scan.failed with the request identity, the reason and the problem' do
    described_class.new(publisher:).call(payload, 'missing target_url')

    expect(publisher).to have_received(:publish).with(
      Bus::ScanSubjects.terminal('failed'),
      hash_including(job_id: 'j1', transaction_id: 't1', state: 'failed',
                     reason: 'invalid_request', detail: 'missing target_url'),
      job_id: 'j1', status: 'failed'
    )
  end

  it 'drops absent identity fields rather than publishing nil keys' do
    described_class.new(publisher:).call(payload, 'missing target_url')

    expect(publisher).to have_received(:publish).with(anything, satisfy { |body| !body.key?(:environment) }, anything)
  end

  it 'logs the refusal at error level' do
    described_class.new(publisher:).call(payload, 'missing target_url')

    expect(Penetrator.logger).to have_received(:error).with(/job "j1".*missing target_url/)
  end
end

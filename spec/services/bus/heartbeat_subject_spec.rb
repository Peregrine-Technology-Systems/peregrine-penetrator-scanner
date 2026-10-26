# frozen_string_literal: true

require 'sequel_helper'

RSpec.describe Bus::HeartbeatSubject do
  it 'keys the per-instance heartbeat subject on the tp-id' do
    expect(described_class.for('tp-7')).to eq('peregrine.telemetry.tp.scanner.heartbeat.tp-7')
  end

  it 'is not the gem\'s tp-id-free scan heartbeat subject (a deliberate, tracked difference)' do
    expect(described_class.for('tp-7')).not_to eq(Peregrine::Bus::Subjects::Penetrator.scanner_heartbeat)
  end
end

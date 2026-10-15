# frozen_string_literal: true

# scanner#1202 (operator ruling 2026-10-14): CI steps publish nothing -- Pub/Sub is
# retired and Campfire gets failures and deploys from the scaler, not from the repo's
# pipelines. A publish to a deleted topic would also turn the pipeline red. This is the
# positive counterpart: it fails the day anyone reintroduces a CI-side publish.
RSpec.describe 'CI publishes nothing (#1202)' do # rubocop:disable RSpec/DescribeClass
  let(:root) { Pathname.new(File.expand_path('../..', __dir__)) }
  let(:workflows) { Dir[root.join('.woodpecker/*.{yaml,yml}')].sort }
  let(:ci_scripts) { Dir[root.join('scripts/woodpecker/**/*')].select { |f| File.file?(f) }.sort }

  def code_lines(path)
    File.readlines(path).reject { |l| l.strip.start_with?('#') }.join
  end

  it 'reads the workflows it is guarding (not vacuous)' do
    expect(workflows.map { |f| File.basename(f) }).to include('ci.yaml', 'promote.yaml', 'version-bump.yaml')
  end

  it 'has no notify-status step in any workflow' do
    offenders = workflows.select { |f| code_lines(f).include?('notify-status') }

    expect(offenders.map { |f| File.basename(f) }).to be_empty
  end

  it 'has no notify-status script left behind' do
    expect(root.join('scripts/woodpecker/notify-status.sh')).not_to exist
  end

  it 'has no pubsub publish or ci-events reference in any workflow or CI script' do
    offenders = (workflows + ci_scripts).select do |f|
      code_lines(f) =~ /pubsub\s+topics\s+publish|ci-events/
    end

    expect(offenders.map { |f| f.delete_prefix("#{root}/") }).to be_empty
  end
end

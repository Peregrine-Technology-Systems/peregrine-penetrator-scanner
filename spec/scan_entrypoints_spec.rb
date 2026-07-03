require 'spec_helper'

# Regression guard for #1077. #816 deleted the app-level notifier classes
# (NotificationService / SlackNotifier / SlackAlert) but left dangling call sites
# in the entrypoint scripts, so every *non-smoke* `bin/scan` run raised
# `NameError: uninitialized constant NotificationService` at the post-completion
# notify step — after results + completion were already written. The orchestrator
# e2e spec drives `ScanOrchestrator` directly and never executes the `bin/scan`
# script, so the dangling reference was invisible to CI until a real scan.
#
# These entrypoints must never reference a class that has been extracted/removed
# from this repo; scan-lifecycle signalling is carried by ScanCompletionPublisher
# (bus) + control/<uuid>/status.json (GCS), not a notifier.
RSpec.describe 'scan entrypoints have no dangling references to removed classes' do # rubocop:disable RSpec/DescribeClass
  removed_classes = %w[NotificationService SlackNotifier SlackAlert].freeze
  entrypoints = {
    'bin/scan' => File.expand_path('../bin/scan', __dir__),
    'lib/tasks/scan.rake' => File.expand_path('../lib/tasks/scan.rake', __dir__)
  }.freeze

  entrypoints.each do |name, path|
    removed_classes.each do |klass|
      it "#{name} does not reference #{klass} (removed in #816, guards #1077)" do
        expect(File.read(path)).not_to include(klass)
      end
    end
  end
end

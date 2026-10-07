# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Drives the REAL sourced helper the way test.sh/lint.sh do (set -euo pipefail,
# then `.`), with a fake gcloud on PATH — asserts what the caller observes (#1206).
RSpec.describe 'scripts/woodpecker/lib/git-dep-auth.sh' do # rubocop:disable RSpec/DescribeClass
  let(:lib) { File.expand_path('../../scripts/woodpecker/lib/git-dep-auth.sh', __dir__) }
  let(:bin) { Dir.mktmpdir }
  let(:gcloud_log) { File.join(bin, 'gcloud.log') }

  def fake_gcloud(exit_code:, output: '')
    path = File.join(bin, 'gcloud')
    File.write(path, "#!/bin/sh\necho \"$@\" >> #{gcloud_log}\nprintf '%s' '#{output}'\nexit #{exit_code}\n")
    File.chmod(0o755, path)
  end

  def source_lib(env)
    script = "set -euo pipefail; . #{lib}; echo \"VAR=${BUNDLE_RUBYGEMS__PKG__GITHUB__COM:-}\""
    base = { 'PATH' => "#{bin}:/usr/bin:/bin", 'GH_PACKAGES_TOKEN' => nil, 'CI' => nil }
    Open3.capture3(base.merge(env), 'bash', '-c', script)
  end

  it 'uses the agent-hook-exported GH_PACKAGES_TOKEN without calling gcloud' do
    fake_gcloud(exit_code: 0, output: 'from-sm')
    out, _err, status = source_lib('GH_PACKAGES_TOKEN' => 'hook-tok')

    expect(status).to be_success
    expect(out).to include('VAR=x-access-token:hook-tok')
    expect(File.exist?(gcloud_log)).to be(false)
  end

  it 'falls back to Secret Manager in peregrine-production, never the decommissioned ci-runners-de' do
    fake_gcloud(exit_code: 0, output: 'from-sm')
    out, _err, status = source_lib({})

    expect(status).to be_success
    expect(out).to include('VAR=x-access-token:from-sm')
    expect(File.read(gcloud_log)).to include('--project=peregrine-production')
    expect(File.read(gcloud_log)).not_to include('ci-runners-de')
  end

  it 'fails loud in CI when no token can be obtained, naming the secret and project' do
    fake_gcloud(exit_code: 1)
    _out, err, status = source_lib('CI' => 'woodpecker')

    expect(status).not_to be_success
    expect(err).to include('peregrine-packages-read').and include('peregrine-production')
  end

  it 'warns but does not abort local dev when no token can be obtained' do
    fake_gcloud(exit_code: 1)
    out, err, status = source_lib({})

    expect(status).to be_success
    expect(out).to include('VAR=')
    expect(out).not_to include('x-access-token')
    expect(err).to include('WARN')
  end
end

# frozen_string_literal: true

RSpec.describe 'promote.sh' do # rubocop:disable RSpec/DescribeClass
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:script) { File.read(File.join(project_root, 'scripts/woodpecker/promote.sh')) }

  it 'requests a reviewer for manual (staging→main) PRs' do
    expect(script).to include('requested_reviewers')
  end

  it 'does not request a reviewer for auto-merge PRs' do
    # The reviewer request should only be in the else (manual) branch
    auto_block = script[/if \[ "\$MODE" = "auto" \].*?else/m]
    expect(auto_block).not_to include('requested_reviewers')
  end

  it 'derives the reviewer from the repo owner, not hardcoded' do
    expect(script).not_to match(/reviewers.*amalc/)
  end

  it 'uses the correct repo path' do
    expect(script).to include('Peregrine-Technology-Systems/peregrine-penetrator-scanner')
  end

  it 'guards every GitHub API read/write through gh_api(), not a bare curl|jq (#1153)' do
    expect(script).to include('gh_api()')
    # No remaining call site should still parse a bare `curl | jq` response —
    # every jq-consuming call must go through the retry-guarded helper.
    expect(script).not_to match(/curl -s(?! --compressed)[^\n]*\|\s*jq/)
  end

  it 'retries on non-JSON gh_api response instead of hard-failing (#1153)' do
    expect(script).not_to match(/gh_api\(\).*?\breturn 1\b/m)
    expect(script).to include('jq -e . >/dev/null 2>&1')
  end
end

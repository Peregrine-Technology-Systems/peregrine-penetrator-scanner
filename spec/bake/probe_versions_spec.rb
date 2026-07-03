require 'sequel_helper'

# Silent-OK guard for the #821 pin: .bake/probe-versions.txt (the SOC 2 traceability
# manifest) and the *_VERSION variables in .bake/install.sh (what actually gets
# installed) must agree. If they drift — someone bumps the install but not the
# manifest, or vice versa — the manifest lies about what shipped; this fails loudly
# instead of letting the record silently disagree with reality.
# tool name in the manifest => the install.sh variable that pins it
BAKE_PIN_MAP = {
  'nikto' => 'NIKTO_VERSION',
  'retire' => 'RETIRE_VERSION',
  'schemathesis' => 'SCHEMATHESIS_VERSION'
}.freeze

RSpec.describe 'bake probe version pins (#821)' do # rubocop:disable RSpec/DescribeClass
  let(:install_sh) { Penetrator.root.join('.bake/install.sh').read }
  let(:manifest) { Penetrator.root.join('.bake/probe-versions.txt').read }

  def install_var(name)
    install_sh[/^#{name}="([^"]+)"/, 1]
  end

  def manifest_version(tool)
    line = manifest.lines.find { |l| l =~ /^#{Regexp.escape(tool)}\s/ }
    line&.split(/\s+/)&.at(1)
  end

  BAKE_PIN_MAP.each do |tool, var|
    it "pins #{tool} to the same version in install.sh (#{var}) and probe-versions.txt" do
      from_install = install_var(var)
      from_manifest = manifest_version(tool)

      expect(from_install).to be_a(String).and(be_present), "#{var} not found in .bake/install.sh"
      expect(from_manifest).to be_a(String).and(be_present), "#{tool} not found in probe-versions.txt"
      expect(from_manifest).to eq(from_install),
                               "#{tool}: manifest says #{from_manifest.inspect} but install.sh #{var} is #{from_install.inspect}"
    end
  end

  it 'installs the pinned versions (no unpinned bare installs of the pinned tools)' do
    # Positive broken-state counterpart: assert the install actually USES the vars,
    # so a future edit back to a bare `apt-get install nikto` / `npm i -g retire`
    # (unpinned) trips this.
    expect(install_sh).to include('"nikto=${NIKTO_VERSION}"')
    expect(install_sh).to include('"retire@${RETIRE_VERSION}"')
    expect(install_sh).to include('"schemathesis==${SCHEMATHESIS_VERSION}"')
  end
end

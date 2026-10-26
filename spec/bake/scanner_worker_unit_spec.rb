# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'yaml'

# scanner#1209: the baked image must ship an enable-able
# scanner-worker.service. These drive the REAL artifacts (the unit file, the
# preflight and render scripts as subprocesses, install.sh/verify.sh text) and
# assert what the boot sequence will observe. What they cannot prove is that
# systemd accepts the unit on the image: that is infra's resize canary.
RSpec.describe 'scanner-worker.service bake contract (#1209)' do # rubocop:disable RSpec/DescribeClass
  let(:root) { Pathname.new(File.expand_path('../..', __dir__)) }
  let(:unit_path) { root.join('config/systemd/scanner-worker.service') }
  let(:preflight) { root.join('.bake/worker-preflight.rb').to_s }
  let(:render) { root.join('.bake/render-unit.rb').to_s }
  let(:required_env) do
    { 'NATS_URL' => 'tls://connect.ngs.global:4222', 'BUS_BUCKET' => 'b',
      'BUS_KEYSET_PROJECT' => 'p', 'GOOGLE_CLOUD_PROJECT' => 'p', 'GCS_BUCKET' => 'r',
      'APP_ENV' => 'production' }
  end

  # key => [values], per section; repeated keys (ExecStartPre) keep every value.
  def parse_unit(text)
    section = nil
    text.each_line.with_object(Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }) do |line, acc|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      if (m = line.match(/\A\[(\w+)\]\z/))
        section = m[1]
      else
        key, value = line.split('=', 2)
        acc[section][key] << value
      end
    end
  end

  def unit
    parse_unit(unit_path.read)
  end

  def run_ruby(script, *args, env: {})
    Open3.capture3(env, RbConfig.ruby, script, *args, unsetenv_others: true)
  end

  describe 'the unit file' do
    it 'exists and is enable-able (WantedBy=multi-user.target)' do
      expect(unit_path).to exist
      expect(unit['Install']['WantedBy']).to eq(['multi-user.target'])
    end

    it 'reads the env file infra writes, and does NOT tolerate it being absent' do
      expect(unit['Service']['EnvironmentFile']).to eq(['/etc/peregrine/scanner.env'])
    end

    it 'starts the existing worker entrypoint and runs the preflight first' do
      expect(unit['Service']['ExecStart']).to eq(['/opt/app/.bake/run.sh'])
      expect(unit['Service']['ExecStartPre'].join).to include('worker-preflight.rb')
      expect(unit['Service']['WorkingDirectory']).to eq(['/opt/app'])
    end

    it 'fails loud on misconfiguration (bounded restarts) and does not restart a clean idle exit' do
      service = unit['Service']
      expect(service['Restart']).to eq(['on-failure'])
      expect(service['StartLimitBurst']).not_to be_empty
      expect(service['StartLimitIntervalSec']).not_to be_empty
    end

    it 'drains on SIGTERM and waits at least as long as the longest scan profile' do
      longest = Dir[root.join('config/scan_profiles/*.yml')].filter_map do |f|
        YAML.safe_load_file(f)['estimated_duration_minutes']
      end.max
      stop = unit['Service']['TimeoutStopSec'].first.to_i

      expect(unit['Service']['KillSignal']).to eq(['SIGTERM'])
      expect(stop).to be >= (longest * 60)
    end

    it 'carries the placeholder install.sh must resolve (no baked-in guess of where ruby lives)' do
      expect(unit_path.read).to include('@RUBY_BIN_DIR@')
    end
  end

  describe '.bake/worker-preflight.rb' do
    it 'exits non-zero and names EVERY missing variable when the env is empty' do
      _out, err, status = run_ruby(preflight, env: {})

      expect(status).not_to be_success
      required_env.each_key { |name| expect(err).to include(name) }
    end

    it 'treats a blank value as missing' do
      _out, err, status = run_ruby(preflight, env: required_env.merge('BUS_BUCKET' => '  '))

      expect(status).not_to be_success
      expect(err).to include('BUS_BUCKET')
    end

    # The scanner reads APP_ENV, never RACK_ENV (#1243). Unset, a production worker would
    # derive the dev grammar token and listen on a subject nothing publishes to.
    it 'refuses to start when APP_ENV is unset, rather than defaulting to the dev subject' do
      _out, err, status = run_ruby(preflight, env: required_env.except('APP_ENV'))

      expect(status).not_to be_success
      expect(err).to include('APP_ENV')
    end

    it 'passes when every required variable is set' do
      _out, _err, status = run_ruby(preflight, env: required_env)

      expect(status).to be_success
    end
  end

  describe '.bake/render-unit.rb' do
    let(:dest) { File.join(Dir.mktmpdir, 'scanner-worker.service') }

    it 'writes the unit with the real ruby dir substituted and no placeholder left' do
      _out, _err, status = run_ruby(render, unit_path.to_s, dest, '/opt/rubies/ruby-4.0.5/bin')

      expect(status).to be_success
      expect(File.read(dest)).to include('/opt/rubies/ruby-4.0.5/bin')
      expect(File.read(dest)).not_to include('@RUBY_BIN_DIR@')
    end

    it 'fails (and writes nothing) when the ruby dir is blank, rather than shipping a broken PATH' do
      _out, err, status = run_ruby(render, unit_path.to_s, dest, '')

      expect(status).not_to be_success
      expect(err).to include('ruby bin dir is blank')
      expect(File.exist?(dest)).to be(false)
    end

    it 'fails when the template has no placeholder to substitute (the edit would be a silent no-op)' do
      bare = File.join(Dir.mktmpdir, 'bare.service')
      File.write(bare, "[Service]\nExecStart=/bin/true\n")
      _out, err, status = run_ruby(render, bare, dest, '/x/bin')

      expect(status).not_to be_success
      expect(err).to include('no @RUBY_BIN_DIR@ placeholder')
    end
  end

  describe 'bake wiring' do
    let(:install_sh) { root.join('.bake/install.sh').read }
    let(:verify_sh) { root.join('.bake/verify.sh').read }

    it 'install.sh renders the unit into /etc/systemd/system but does NOT enable it (infra boot script does)' do
      expect(install_sh).to include('render-unit.rb')
      expect(install_sh).to include('/etc/systemd/system/scanner-worker.service')
      executable = install_sh.lines.reject { |l| l.strip.start_with?('#') }.join
      expect(executable).not_to match(/systemctl\s+enable/)
    end

    it 'verify.sh asserts the installed unit, its env file contract, no leftover placeholder and a real ruby+bundle' do
      expect(verify_sh).to include('/etc/systemd/system/scanner-worker.service')
      expect(verify_sh).to include('EnvironmentFile=/etc/peregrine/scanner.env')
      expect(verify_sh).to include('@RUBY_BIN_DIR@') # checked for ABSENCE in the installed unit
      expect(verify_sh).to include('-x "$UNIT_RUBY_DIR/ruby"')
      expect(verify_sh).to include('-x "$UNIT_RUBY_DIR/bundle"')
    end
  end
end

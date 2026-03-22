require 'sequel_helper'

RSpec.describe ScannerBase do
  let(:scan) { create(:scan, :running) }

  # Create a concrete subclass for testing
  let(:test_scanner_class) do
    Class.new(ScannerBase) do
      def tool_name
        'test_scanner'
      end

      protected

      def execute
        { success: true, findings: [] }
      end
    end
  end

  let(:failing_scanner_class) do
    Class.new(ScannerBase) do
      def tool_name
        'failing_scanner'
      end

      protected

      def execute
        { success: false, error: 'scan failed', findings: [] }
      end
    end
  end

  let(:exception_scanner_class) do
    Class.new(ScannerBase) do
      def tool_name
        'exception_scanner'
      end

      protected

      def execute
        raise StandardError, 'unexpected error'
      end
    end
  end

  describe '#run' do
    it 'updates tool status to running then completed on success' do
      scanner = test_scanner_class.new(scan)
      scanner.run

      scan.reload
      statuses = scan.tool_statuses
      expect(statuses['test_scanner']['status']).to eq('completed')
    end

    it 'returns the execute result on success' do
      scanner = test_scanner_class.new(scan)
      result = scanner.run

      expect(result[:success]).to be true
      expect(result[:findings]).to eq([])
    end

    it 'updates tool status to failed when execute returns failure' do
      scanner = failing_scanner_class.new(scan)
      scanner.run

      scan.reload
      statuses = scan.tool_statuses
      expect(statuses['failing_scanner']['status']).to eq('failed')
      expect(statuses['failing_scanner']['error']).to eq('scan failed')
    end

    it 'handles exceptions and updates status to failed' do
      scanner = exception_scanner_class.new(scan)
      result = scanner.run

      expect(result[:success]).to be false
      expect(result[:error]).to eq('unexpected error')

      scan.reload
      statuses = scan.tool_statuses
      expect(statuses['exception_scanner']['status']).to eq('failed')
    end

    it 'logs scan start and completion' do
      scanner = test_scanner_class.new(scan)

      expect(Penetrator.logger).to receive(:info).with(/Starting scan for/)
      expect(Penetrator.logger).to receive(:info).with(/Completed successfully/)

      scanner.run
    end

    it 'logs errors on failure' do
      scanner = failing_scanner_class.new(scan)

      expect(Penetrator.logger).to receive(:info).with(/Starting scan/)
      expect(Penetrator.logger).to receive(:error).with(/Failed: scan failed/)

      scanner.run
    end
  end

  describe '#tool_name' do
    it 'raises NotImplementedError on the base class' do
      scanner = described_class.new(scan)

      expect { scanner.tool_name }.to raise_error(NotImplementedError, /Subclass must implement/)
    end
  end

  describe '#run_command' do
    let(:scanner) { test_scanner_class.new(scan) }

    it 'executes a shell command and returns output' do
      mock_stdin = instance_double(IO, close: nil)
      mock_stdout = instance_double(IO, read: "hello\n")
      mock_stderr = instance_double(IO, read: '')
      status = instance_double(Process::Status, exitstatus: 0, success?: true)
      mock_wait_thr = double(pid: 12_345, value: status) # rubocop:disable RSpec/VerifiedDoubles

      allow(Open3).to receive(:popen3).and_yield(mock_stdin, mock_stdout, mock_stderr, mock_wait_thr)
      allow(scanner).to receive(:start_heartbeat).and_return(nil)

      result = scanner.send(:run_command, 'echo hello')

      expect(result[:stdout].strip).to eq('hello')
      expect(result[:success]).to be true
      expect(result[:exit_code]).to eq(0)
    end

    it 'returns failure for non-existent commands' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'nonexistent_command_xyz_123')

      result = scanner.send(:run_command, 'nonexistent_command_xyz_123')

      expect(result[:success]).to be false
      expect(result[:exit_code]).to eq(127)
    end

    it 'uses the configured timeout from tool_config' do
      scanner_with_timeout = test_scanner_class.new(scan, { timeout: 10 })

      mock_stdin = instance_double(IO, close: nil)
      mock_stdout = instance_double(IO, read: 'output')
      mock_stderr = instance_double(IO, read: '')
      status = instance_double(Process::Status, exitstatus: 0, success?: true)
      mock_wait_thr = double(pid: 12_345, value: status) # rubocop:disable RSpec/VerifiedDoubles

      allow(Open3).to receive(:popen3).and_yield(mock_stdin, mock_stdout, mock_stderr, mock_wait_thr)
      allow(scanner_with_timeout).to receive(:start_heartbeat).and_return(nil)

      expect(Timeout).to receive(:timeout).with(10).and_yield

      scanner_with_timeout.send(:run_command, 'echo test')
    end
  end

  describe '#target_urls' do
    it "returns the target's url_list" do
      scan.target.update!(urls: '["https://example.com", "https://test.com"]')
      scanner = test_scanner_class.new(scan)

      expect(scanner.send(:target_urls)).to eq(['https://example.com', 'https://test.com'])
    end
  end

  describe '#output_dir' do
    it 'creates and returns a scan-specific output directory' do
      scanner = test_scanner_class.new(scan)
      dir = scanner.send(:output_dir)

      expect(dir.to_s).to include("tmp/scans/#{scan.id}/test_scanner")
      expect(File.directory?(dir)).to be true
    end
  end
end

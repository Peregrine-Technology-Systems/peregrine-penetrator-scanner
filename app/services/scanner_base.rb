require 'open3'
require 'shellwords'

class ScannerBase
  attr_reader :scan, :tool_config, :logger

  def initialize(scan, tool_config = {})
    @scan = scan
    @tool_config = tool_config
    @logger = Rails.logger
  end

  def run
    update_status('running')
    logger.info("[#{tool_name}] Starting scan for #{scan.target.name}")

    result = execute

    if result[:success]
      update_status('completed')
      logger.info("[#{tool_name}] Completed successfully")
    else
      update_status('failed', result[:error])
      logger.error("[#{tool_name}] Failed: #{result[:error]}")
    end

    result
  rescue StandardError => e
    update_status('failed', e.message)
    logger.error("[#{tool_name}] Exception: #{e.message}")
    { success: false, error: e.message, findings: [] }
  end

  def tool_name
    raise NotImplementedError, 'Subclass must implement #tool_name'
  end

  protected

  def execute
    raise NotImplementedError, 'Subclass must implement #execute'
  end

  def run_command(command, timeout: nil)
    timeout ||= tool_config[:timeout] || 600
    logger.info("[#{tool_name}] Running: #{command}")

    pid = nil
    stdout = ''
    stderr = ''
    status = nil

    Open3.popen3(command) do |_stdin, out, err, wait_thr|
      pid = wait_thr.pid
      _stdin.close

      heartbeat = start_heartbeat(pid)

      begin
        Timeout.timeout(timeout) do
          stdout = out.read
          stderr = err.read
          status = wait_thr.value
        end
      rescue Timeout::Error
        Process.kill('TERM', pid) rescue nil
        sleep(1)
        Process.kill('KILL', pid) rescue nil
        return { stdout: stdout, stderr: "Command timed out after #{timeout}s", exit_code: -1, success: false }
      ensure
        heartbeat&.kill
      end
    end

    {
      stdout: stdout,
      stderr: stderr,
      exit_code: status&.exitstatus,
      success: status&.success? || false
    }
  rescue Errno::ENOENT => e
    { stdout: '', stderr: "Command not found: #{e.message}", exit_code: 127, success: false }
  end

  def target_urls
    scan.target.url_list
  end

  def output_dir
    dir = Rails.root.join('tmp', 'scans', scan.id, tool_name)
    FileUtils.mkdir_p(dir)
    dir
  end

  private

  def start_heartbeat(pid)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Thread.new do
      loop do
        sleep(60)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        minutes = (elapsed / 60).floor
        seconds = (elapsed % 60).floor
        begin
          Process.kill(0, pid)
          logger.info("[#{tool_name}] Still running... (elapsed: #{minutes}m #{seconds}s)")
        rescue Errno::ESRCH
          break
        end
      end
    end
  end

  def update_status(status, error = nil)
    statuses = scan.tool_statuses || {}
    statuses[tool_name] = { status:, updated_at: Time.current.iso8601, error: }.compact
    scan.update!(tool_statuses: statuses)
  end
end

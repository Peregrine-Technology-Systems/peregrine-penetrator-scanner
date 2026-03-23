class SmokeChecker
  REQUIRED_TOOLS = %w[zap.sh nuclei sqlmap ffuf nikto].freeze
  REQUIRED_SECRETS = %w[GCS_BUCKET GOOGLE_CLOUD_PROJECT].freeze

  def initialize(scan)
    @scan = scan
    @results = {}
  end

  def run
    check_tools
    check_secrets
    check_gcs
    build_summary
  end

  def passed?
    @results.values.all? { |r| r[:status] == 'pass' }
  end

  attr_reader :results

  private

  def check_tools
    missing = REQUIRED_TOOLS.reject { |tool| tool_available?(tool) }
    @results[:tools] = if missing.empty?
                         { status: 'pass', detail: "All #{REQUIRED_TOOLS.length} tools available" }
                       else
                         { status: 'fail', detail: "Missing: #{missing.join(', ')}" }
                       end
  end

  def check_secrets
    missing = REQUIRED_SECRETS.reject { |key| ENV[key].present? }
    @results[:secrets] = if missing.empty?
                           { status: 'pass', detail: "All #{REQUIRED_SECRETS.length} secrets accessible" }
                         else
                           { status: 'fail', detail: "Missing: #{missing.join(', ')}" }
                         end
  end

  def check_gcs
    storage = StorageService.new
    test_path = "smoke-test/#{@scan.id}/smoke.txt"
    test_content = "smoke-#{Time.current.to_i}"

    local_path = write_temp_file(test_content)
    storage.upload(local_path, test_path, content_type: 'text/plain')
    @results[:gcs] = { status: 'pass', detail: "Write succeeded: #{test_path}" }
  rescue StandardError => e
    @results[:gcs] = { status: 'fail', detail: e.message }
  ensure
    FileUtils.rm_f(local_path) if local_path
  end

  def build_summary
    {
      'smoke_test' => true,
      'total_findings' => 0,
      'checks' => @results.transform_values { |r| r[:status] },
      'passed' => passed?,
      'by_severity' => {}
    }
  end

  def tool_available?(tool)
    system("which #{tool} > /dev/null 2>&1")
  end

  def write_temp_file(content)
    dir = Penetrator.root.join('tmp', 'smoke')
    FileUtils.mkdir_p(dir)
    path = dir.join('smoke.txt')
    File.write(path, content)
    path.to_s
  end
end

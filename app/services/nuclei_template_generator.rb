class NucleiTemplateGenerator
  TEMPLATES_DIR = Rails.root.join('custom_templates/nuclei')

  def initialize
    @client = Anthropic::Client.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'))
    @model = ENV.fetch('CLAUDE_MODEL', 'claude-sonnet-4-20250514')
    @nvd = CveClients::NvdClient.new(nil)
  end

  def generate_for_cve(cve_id, cve_details = nil)
    cve_details ||= CveIntelligenceService.new.send(:fetch_nvd, cve_id)
    return nil unless cve_details

    yaml_content = extract_yaml(call_claude(build_prompt(cve_id, cve_details)))
    return nil unless valid_template?(cve_id, yaml_content)

    save_template(cve_id, yaml_content)
  rescue StandardError => e
    Rails.logger.error("[NucleiTemplateGen] Failed for #{cve_id}: #{e.message}")
    nil
  end

  def generate_batch(cve_ids)
    FileUtils.mkdir_p(TEMPLATES_DIR)

    results = cve_ids.map do |cve_id|
      path = generate_for_cve(cve_id)
      sleep(1)
      { cve_id:, template_path: path, success: path.present? }
    end

    successful = results.count { |r| r[:success] }
    Rails.logger.info("[NucleiTemplateGen] Generated #{successful}/#{cve_ids.length} templates")
    results
  end

  private

  def build_prompt(cve_id, cve_details)
    <<~PROMPT
      You are a security researcher who writes Nuclei vulnerability detection templates.

      Generate a Nuclei YAML template for this CVE:

      CVE ID: #{cve_id}
      Description: #{@nvd.extract_description(cve_details)}
      CVSS Score: #{@nvd.extract_cvss(cve_details)}
      Affected Products: #{@nvd.extract_affected_products(cve_details).take(10).join(', ')}
      References: #{@nvd.extract_references(cve_details).pluck(:url).take(5).join(', ')}

      The template should:
      1. Follow Nuclei template format v2
      2. Include proper metadata (id, info block with name, author, severity, description, reference, tags)
      3. Have accurate matchers (status codes, body content, headers, regex where needed)
      4. Use variables and payloads where appropriate
      5. Include classification (cve-id, cwe-id, cvss-metrics, cvss-score)

      Return ONLY the YAML template, no explanation.
    PROMPT
  end

  def valid_template?(cve_id, yaml_content)
    return false unless yaml_content

    parsed = YAML.safe_load(yaml_content)
    return true if parsed.is_a?(Hash) && parsed['id'] && parsed['info']

    Rails.logger.warn("[NucleiTemplateGen] Invalid template structure for #{cve_id}")
    false
  end

  def call_claude(prompt)
    response = @client.messages.create(model: @model, max_tokens: 4096,
                                       messages: [{ role: 'user', content: prompt }])
    response.content.first.text
  end

  def extract_yaml(text)
    text.match(/```(?:ya?ml)?\s*\n(.*?)\n```/m)&.then { |m| m[1] } || text.strip
  end

  def save_template(cve_id, content)
    FileUtils.mkdir_p(TEMPLATES_DIR)
    filename = "#{cve_id.downcase.gsub('-', '_')}.yaml"
    path = TEMPLATES_DIR.join(filename)
    File.write(path, content)
    Rails.logger.info("[NucleiTemplateGen] Saved template: #{path}")
    path.to_s
  end
end

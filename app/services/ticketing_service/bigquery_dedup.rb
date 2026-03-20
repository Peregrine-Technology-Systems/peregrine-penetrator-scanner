class TicketingService
  class BigqueryDedup
    def initialize(scan_mode: nil)
      @scan_mode = scan_mode || ENV.fetch('SCAN_MODE', 'dev')
      @table_name = "scan_findings_#{@scan_mode}"
    end

    def existing_tickets(site, fingerprints)
      return {} if fingerprints.empty?

      client = Google::Cloud::Bigquery.new
      dataset = client.dataset(BigQueryLogger::DATASET_ID)
      return {} unless dataset

      table = dataset.table(@table_name)
      return {} unless table

      query_existing(client, fingerprints, site)
    rescue StandardError => e
      Rails.logger.error("[BigqueryDedup] Query failed: #{e.message}")
      {}
    end

    private

    def query_existing(client, fingerprints, site)
      sql = <<~SQL.squish
        SELECT DISTINCT fingerprint, ticket_ref
        FROM `#{BigQueryLogger::DATASET_ID}.#{@table_name}`
        WHERE site = @site
          AND fingerprint IN UNNEST(@fingerprints)
          AND ticket_ref IS NOT NULL
      SQL

      results = client.query(sql, params: { site:, fingerprints: })
      results.each_with_object({}) { |row, hash| hash[row[:fingerprint]] = row[:ticket_ref] }
    end
  end
end

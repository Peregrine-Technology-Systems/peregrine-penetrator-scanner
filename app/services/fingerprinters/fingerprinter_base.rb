# frozen_string_literal: true

module Fingerprinters
  class FingerprinterBase
    MIN_CONFIDENCE = 0.5
    HTTP_TIMEOUT = 5
    HTTP_OPEN_TIMEOUT = 3

    attr_reader :scan, :target, :logger

    def initialize(scan)
      @scan = scan
      @target = scan.target
      @logger = Penetrator.logger
    end

    def detect
      raise NotImplementedError, 'Subclass must implement #detect'
    end

    def cms_name
      raise NotImplementedError, 'Subclass must implement #cms_name'
    end

    protected

    def empty_result
      { cms: cms_name, confidence: 0.0, components: [] }
    end

    def http_get(url)
      connection.get(url)
    rescue StandardError => e
      logger.debug("[#{cms_name}] GET #{url} failed: #{e.message}")
      nil
    end

    def http_head(url)
      connection.head(url)
    rescue StandardError => e
      logger.debug("[#{cms_name}] HEAD #{url} failed: #{e.message}")
      nil
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = HTTP_TIMEOUT
        f.options.open_timeout = HTTP_OPEN_TIMEOUT
        f.headers['User-Agent'] = 'Peregrine-Penetrator/1.0 (fingerprinter)'
      end
    end
  end
end

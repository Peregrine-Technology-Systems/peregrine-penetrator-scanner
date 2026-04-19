# frozen_string_literal: true

module Fingerprinters
  class FingerprinterRegistry
    def self.detectors
      @detectors ||= [GenericFingerprinter]
    end

    def self.register(detector_class)
      return if detectors.include?(detector_class)

      # Prepend so more-specific detectors run before the Generic fallback.
      @detectors = [detector_class] + detectors
    end

    def self.reset!
      @detectors = [GenericFingerprinter]
    end

    def initialize(scan)
      @scan = scan
    end

    def detect
      self.class.detectors.each do |detector_class|
        result = safely_detect(detector_class)
        return stamp(result) if result && result[:confidence].to_f >= FingerprinterBase::MIN_CONFIDENCE
      end

      stamp(GenericFingerprinter.new(@scan).detect)
    end

    private

    def safely_detect(detector_class)
      detector_class.new(@scan).detect
    rescue StandardError => e
      Penetrator.logger.warn("[FingerprinterRegistry] #{detector_class.name} raised: #{e.message}")
      nil
    end

    def stamp(result)
      result.merge(detected_at: Time.current.iso8601)
    end
  end
end

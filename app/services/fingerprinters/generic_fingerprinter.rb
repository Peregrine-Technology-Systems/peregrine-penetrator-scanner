# frozen_string_literal: true

module Fingerprinters
  class GenericFingerprinter < FingerprinterBase
    def detect
      empty_result
    end

    def cms_name
      'unknown'
    end
  end
end

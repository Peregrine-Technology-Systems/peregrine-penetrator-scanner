# frozen_string_literal: true

require 'net/http'
require 'openssl'

# Answers "can this target be reached?" for the scan preflight, not "is it trusted?" (#1267).
# An untrusted certificate (self-signed, expired, wrong name) is a finding about the target,
# not a reason to refuse to scan it, so a certificate-verification failure is logged and the
# check is repeated without verifying the chain. Everything else still fails: DNS errors,
# refused or timed-out connections, and handshake failures that are not about the certificate.
# Reachability only: the scan tools make their own TLS decisions.
class TargetReachability
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 10

  def initialize(url, logger: Penetrator.logger)
    @uri = URI.parse(url)
    @url = url
    @logger = logger
  end

  def call
    head(verify: true)
  rescue OpenSSL::SSL::SSLError => e
    raise unless e.message.include?('certificate verify failed')

    @logger.warn("[Preflight] Untrusted certificate for #{@url}: #{e.message}. " \
                 'Reachable, so scanning continues; an untrusted certificate is a finding, not unreachability.')
    head(verify: false)
  end

  private

  def head(verify:)
    options = { use_ssl: @uri.scheme == 'https', open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT }
    options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE if options[:use_ssl] && !verify
    Net::HTTP.start(@uri.host, @uri.port, **options) { |http| http.head(@uri.path.empty? ? '/' : @uri.path) }
  end
end

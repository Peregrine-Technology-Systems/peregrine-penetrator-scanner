# frozen_string_literal: true

require 'sequel_helper'
require 'openssl'
require 'socket'

# Real sockets, not stubs: the defect (#1267) is about what a TLS handshake does with a
# certificate the client does not trust, which a stubbed HTTP layer cannot reproduce.
RSpec.describe TargetReachability do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:servers) { [] }
  let(:threads) { [] }

  after do
    servers.each(&:close)
    threads.each(&:kill)
  end

  def self_signed_context
    key = OpenSSL::PKey::RSA.new(2048)
    name = OpenSSL::X509::Name.parse('/CN=localhost')
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = name
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    OpenSSL::SSL::SSLContext.new.tap do |ctx|
      ctx.cert = cert
      ctx.key = key
    end
  end

  def serve(tls:)
    tcp = TCPServer.new('127.0.0.1', 0)
    server = tls ? OpenSSL::SSL::SSLServer.new(tcp, self_signed_context) : tcp
    servers << tcp
    threads << Thread.new { answer_forever(server) }
    tcp.addr[1]
  end

  # A closed listener raises IOError; that ends the thread. Any other per-connection failure
  # (a client that aborts its handshake on an untrusted certificate) just waits for the next.
  def answer_forever(server)
    loop do
      client = server.accept
      client.readpartial(1024)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.close
    rescue IOError
      break
    rescue StandardError
      next
    end
  end

  def closed_port
    tcp = TCPServer.new('127.0.0.1', 0)
    port = tcp.addr[1]
    tcp.close
    port
  end

  it 'reaches a target whose certificate is self-signed, and says so' do
    port = serve(tls: true)

    expect { described_class.new("https://127.0.0.1:#{port}", logger:).call }.not_to raise_error
    expect(logger).to have_received(:warn).with(/untrusted certificate.*certificate verify failed/i)
  end

  it 'does not warn for a plain http target' do
    port = serve(tls: false)

    described_class.new("http://127.0.0.1:#{port}", logger:).call

    expect(logger).not_to have_received(:warn)
  end

  it 'still fails when nothing is listening' do
    expect { described_class.new("https://127.0.0.1:#{closed_port}", logger:).call }
      .to raise_error(Errno::ECONNREFUSED)
  end

  it 'still fails when an https URL points at a port that does not speak TLS' do
    port = serve(tls: false)

    expect { described_class.new("https://127.0.0.1:#{port}", logger:).call }
      .to raise_error(OpenSSL::SSL::SSLError)
  end
end

# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require 'timeout'

# Runs a real `nats-server -js` on a free port with a throwaway store dir (scanner#1276).
# A missing binary raises: the bus transaction spec FAILS rather than skips (arch#1319).
module NatsServerHelper
  class NatsServerMissing < StandardError; end

  STREAM_PREFIX = 'peregrine'

  attr_reader :nats_url

  def with_nats_server
    binary = ENV.fetch('NATS_SERVER_BIN', 'nats-server')
    raise NatsServerMissing, "#{binary} not found on PATH; the bus transaction test requires it" unless on_path?(binary)

    Dir.mktmpdir('nats-js') do |store|
      port = free_port
      pid = Process.spawn(binary, '-js', '-sd', store, '-p', port.to_s, out: File::NULL, err: File::NULL)
      begin
        wait_for_port(port)
        @nats_url = "nats://127.0.0.1:#{port}"
        yield @nats_url
      ensure
        Process.kill('TERM', pid)
        Process.wait(pid)
      end
    end
  end

  # One stream per plane (stream names are derived by NatsTransport), and a competing-consumer
  # durable per subject, created through the transport's own create_durable.
  def provision_stream_and_durables(client, transport, subjects)
    subjects.each do |subject|
      stream = transport.stream_name(subject)
      begin
        client.stream_info(stream)
      rescue NATS::JetStream::Error::NotFound
        client.add_stream(name: stream, subjects: ["#{subject.split('.').first(2).join('.')}.>"])
      end
      transport.create_durable(subject, subscription: :consumer, deliver_policy: 'all')
    end
  end

  private

  def on_path?(binary)
    return File.executable?(binary) if binary.include?('/')

    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, binary)) }
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1].tap { server.close }
  end

  def wait_for_port(port)
    Timeout.timeout(10) do
      loop do
        TCPSocket.new('127.0.0.1', port).close
        break
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
  end
end

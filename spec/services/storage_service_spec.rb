require 'sequel_helper'

RSpec.describe StorageService do
  let(:service) { described_class.new }

  describe '#upload' do
    context 'when GCS is not configured (local fallback)' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return(nil)
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('pentest-reports')
      end

      it 'copies the file to local storage' do
        # Create a temp source file
        source = Tempfile.new(['test', '.json'])
        source.write('test content')
        source.close

        result = service.upload(source.path, 'scans/test.json')

        dest_path = Penetrator.root.join('storage/reports/scans/test.json').to_s
        expect(File.exist?(dest_path)).to be true
        expect(File.read(dest_path)).to eq('test content')
        expect(result[:path]).to eq('scans/test.json')
        expect(result[:url]).to eq("file://#{dest_path}")
      ensure
        source&.unlink
        FileUtils.rm_f(dest_path)
      end

      it 'creates intermediate directories' do
        source = Tempfile.new(['test', '.pdf'])
        source.write('pdf data')
        source.close

        service.upload(source.path, 'deep/nested/path/report.pdf')

        dest_path = Penetrator.root.join('storage/reports/deep/nested/path/report.pdf').to_s
        expect(File.exist?(dest_path)).to be true
      ensure
        source&.unlink
        FileUtils.rm_rf(Penetrator.root.join('storage/reports/deep'))
      end
    end

    context 'when GCS is configured' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }
      let(:mock_bucket) { instance_double(gcs_storage_class) }
      let(:mock_file) { instance_double(gcs_storage_class, public_url: 'https://storage.googleapis.com/bucket/file') }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return('my-project')
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        # Stub require to prevent loading the real gem
        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)

        stub_const('Google::Cloud::Storage', gcs_storage_class)

        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(mock_bucket)
        allow(mock_bucket).to receive(:create_file).and_return(mock_file)
      end

      it 'uploads to GCS' do
        result = service.upload('/tmp/test.json', 'remote/test.json', content_type: 'application/json')

        expect(mock_bucket).to have_received(:create_file).with('/tmp/test.json', 'remote/test.json', content_type: 'application/json')
        expect(result[:url]).to eq('https://storage.googleapis.com/bucket/file')
      end
    end

    context 'when GCS_BUCKET is set but GOOGLE_CLOUD_PROJECT is unset (BigQuery off)' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }
      let(:mock_bucket) { instance_double(gcs_storage_class) }
      let(:mock_file) { instance_double(gcs_storage_class, public_url: 'https://storage.googleapis.com/bucket/file') }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return(nil)
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)
        stub_const('Google::Cloud::Storage', gcs_storage_class)
        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(mock_bucket)
        allow(mock_bucket).to receive(:create_file).and_return(mock_file)
      end

      # Silent-OK positive counterpart for #942: GCS upload must depend on
      # GCS_BUCKET alone. Without GOOGLE_CLOUD_PROJECT (BigQuery off), a scan
      # must STILL export to GCS — never silently to local disk that the
      # ephemeral VM loses on exit while reporting completed.
      it 'uploads to GCS and does NOT fall back to local storage' do
        source = Tempfile.new(['test', '.json'])
        source.write('content')
        source.close

        result = service.upload(source.path, 'scans/bqoff.json')

        expect(mock_bucket).to have_received(:create_file)
          .with(source.path, 'scans/bqoff.json', content_type: 'application/octet-stream')
        expect(result[:url]).to eq('https://storage.googleapis.com/bucket/file')

        dest_path = Penetrator.root.join('storage/reports/scans/bqoff.json').to_s
        expect(File.exist?(dest_path)).to be false
      ensure
        source&.unlink
        FileUtils.rm_f(dest_path)
      end
    end

    context 'when GCS is configured but the upload fails' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }
      let(:mock_bucket) { instance_double(gcs_storage_class) }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return('my-project')
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)

        stub_const('Google::Cloud::Storage', gcs_storage_class)
        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(mock_bucket)
        allow(mock_bucket).to receive(:create_file).and_raise(RuntimeError, 'permission denied')
      end

      # Silent-OK counterpart: a configured-GCS upload that fails must RAISE
      # loudly, never silently fall back to a local path that's lost on the
      # ephemeral VM's exit while the scan still reports completed (#784).
      it 'raises a clear error and does NOT fall back to local storage' do
        source = Tempfile.new(['test', '.json'])
        source.write('content')
        source.close

        expect { service.upload(source.path, 'scans/fail.json') }
          .to raise_error(%r{GCS upload to 'my-bucket/scans/fail.json' failed.*permission denied})

        dest_path = Penetrator.root.join('storage/reports/scans/fail.json').to_s
        expect(File.exist?(dest_path)).to be false
      ensure
        source&.unlink
        FileUtils.rm_f(dest_path)
      end
    end
  end

  describe '#signed_url' do
    context 'when GCS is not configured (local fallback)' do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return(nil)
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('pentest-reports')
      end

      it 'returns a file:// URL' do
        url = service.signed_url('scans/report.pdf')
        expected = Penetrator.root.join('storage/reports/scans/report.pdf').to_s
        expect(url).to eq("file://#{expected}")
      end
    end

    context 'when GCS is configured' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }
      let(:mock_bucket) { instance_double(gcs_storage_class) }
      let(:mock_file) { instance_double(gcs_storage_class) }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return('my-project')
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)

        stub_const('Google::Cloud::Storage', gcs_storage_class)

        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(mock_bucket)
        allow(mock_bucket).to receive(:file).and_return(mock_file)
        allow(mock_file).to receive(:signed_url).and_return('https://storage.googleapis.com/signed-url')
      end

      it 'returns a signed URL from GCS' do
        url = service.signed_url('remote/test.pdf', expires_in: 1.day)

        expect(mock_file).to have_received(:signed_url).with(expires: 1.day.to_i, method: 'GET')
        expect(url).to eq('https://storage.googleapis.com/signed-url')
      end
    end

    context 'when GCS is configured but the signed-url op fails' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }
      let(:mock_bucket) { instance_double(gcs_storage_class) }
      let(:mock_file) { instance_double(gcs_storage_class) }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return('my-project')
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)

        stub_const('Google::Cloud::Storage', gcs_storage_class)
        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(mock_bucket)
        allow(mock_bucket).to receive(:file).and_return(mock_file)
        allow(mock_file).to receive(:signed_url).and_raise(RuntimeError, 'denied')
      end

      # No silent file:// fallback when GCS is configured — surface the failure.
      it 'raises rather than silently returning a local file:// URL' do
        expect { service.signed_url('scans/report.pdf') }.to raise_error(/denied/)
      end
    end
  end
end

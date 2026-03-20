require 'rails_helper'

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

        dest_path = Rails.root.join('storage/reports/scans/test.json').to_s
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

        dest_path = Rails.root.join('storage/reports/deep/nested/path/report.pdf').to_s
        expect(File.exist?(dest_path)).to be true
      ensure
        source&.unlink
        FileUtils.rm_rf(Rails.root.join('storage/reports/deep'))
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

    context 'when GCS is configured but bucket is inaccessible' do
      let(:gcs_storage_class) { Class.new }
      let(:mock_storage) { instance_double(gcs_storage_class) }

      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).with('GOOGLE_CLOUD_PROJECT').and_return('my-project')
        allow(ENV).to receive(:[]).with('GCS_BUCKET').and_return('my-bucket')
        allow(ENV).to receive(:fetch).with('GCS_BUCKET', 'pentest-reports').and_return('my-bucket')

        allow(service).to receive(:require).with('google/cloud/storage').and_return(true)

        stub_const('Google::Cloud::Storage', gcs_storage_class)
        allow(Google::Cloud::Storage).to receive(:new).and_return(mock_storage)
        allow(mock_storage).to receive(:bucket).and_return(nil)
      end

      it 'falls back to local storage and logs a warning' do
        source = Tempfile.new(['test', '.json'])
        source.write('fallback content')
        source.close

        expect(Rails.logger).to receive(:warn).with(/GCS bucket.*inaccessible.*falling back to local/)
        result = service.upload(source.path, 'scans/fallback.json')

        dest_path = Rails.root.join('storage/reports/scans/fallback.json').to_s
        expect(File.exist?(dest_path)).to be true
        expect(result[:path]).to eq('scans/fallback.json')
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
        expected = Rails.root.join('storage/reports/scans/report.pdf').to_s
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
  end
end

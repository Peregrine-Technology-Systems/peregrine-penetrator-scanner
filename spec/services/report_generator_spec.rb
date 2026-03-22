require 'sequel_helper'

RSpec.describe ReportGenerator do
  subject(:generator) { described_class.new(scan) }

  let(:target) { create(:target, name: 'Test Target') }
  let(:scan) { create(:scan, :completed, target:) }
  let!(:finding) do
    create(:finding,
           scan:,
           source_tool: 'zap',
           severity: 'high',
           title: 'XSS Vulnerability',
           url: 'https://example.com/search',
           parameter: 'q',
           cwe_id: 'CWE-79',
           duplicate: false)
  end

  describe '#generate' do
    context 'with JSON format' do
      let(:storage_service) { instance_double(StorageService) }

      before do
        allow(StorageService).to receive(:new).and_return(storage_service)
        allow(storage_service).to receive_messages(upload: true, signed_url: 'https://storage.example.com/signed-url')
      end

      it 'creates a report record' do
        expect { generator.generate('json') }.to change(Report, :count).by(1)
      end

      it 'generates valid JSON content' do
        report = generator.generate('json')

        expect(report.format).to eq('json')
        expect(report.status).to eq('completed')
        expect(report.signed_url).to eq('https://storage.example.com/signed-url')
      end

      it 'uploads the report to storage' do
        expect(storage_service).to receive(:upload).with(
          anything,
          %r{reports/.*/.*\.json},
          content_type: 'application/json'
        )

        generator.generate('json')
      end

      it 'sets signed_url_expires_at to 7 days from now' do
        before = 7.days.from_now
        report = generator.generate('json')
        after = 7.days.from_now

        expect(report.signed_url_expires_at).to be_between(before, after)
      end
    end

    context 'with HTML format' do
      let(:storage_service) { instance_double(StorageService) }

      before do
        allow(StorageService).to receive(:new).and_return(storage_service)
        allow(storage_service).to receive_messages(upload: true, signed_url: 'https://storage.example.com/signed-html')
      end

      it 'generates an HTML report' do
        report = generator.generate('html')

        expect(report.format).to eq('html')
        expect(report.status).to eq('completed')
      end
    end

    context 'with unknown format' do
      it 'raises an error due to format validation' do
        expect { generator.generate('csv') }.to raise_error(Sequel::ValidationFailed, /format/i)
      end
    end

    context 'when storage upload fails' do
      before do
        storage_service = instance_double(StorageService)
        allow(StorageService).to receive(:new).and_return(storage_service)
        allow(storage_service).to receive(:upload).and_raise(StandardError, 'Upload failed')
      end

      it 'marks the report as failed' do
        report = generator.generate('json')

        expect(report.status).to eq('failed')
      end
    end
  end

  describe 'JSON report content' do
    it 'includes metadata, summary, and findings' do
      json_content = generator.send(:generate_json)
      data = JSON.parse(json_content)

      expect(data['metadata']['target']).to eq('Test Target')
      expect(data['metadata']['profile']).to eq('standard')
      expect(data['findings']).to be_an(Array)
      expect(data['findings'].length).to eq(1)
      expect(data['findings'].first['title']).to eq('XSS Vulnerability')
      expect(data['findings'].first['severity']).to eq('high')
    end

    it 'excludes duplicate findings' do
      create(:finding, scan:, duplicate: true, source_tool: 'nuclei',
                       title: 'XSS Duplicate', url: 'https://example.com/other', severity: 'high')

      json_content = generator.send(:generate_json)
      data = JSON.parse(json_content)

      expect(data['findings'].length).to eq(1)
      titles = data['findings'].pluck('title')
      expect(titles).not_to include('XSS Duplicate')
    end

    it 'includes scan duration in seconds' do
      json_content = generator.send(:generate_json)
      data = JSON.parse(json_content)

      expect(data['metadata']['duration_seconds']).to be_a(Integer)
    end
  end
end

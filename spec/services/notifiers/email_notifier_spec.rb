require 'rails_helper'

RSpec.describe Notifiers::EmailNotifier do
  subject(:notifier) { described_class.new(scan) }

  let(:target) { create(:target, name: 'Test App') }
  let(:scan) do
    create(:scan, :completed, target:, profile: 'standard',
                              summary: {
                                'total_findings' => 5,
                                'by_severity' => { 'critical' => 1, 'high' => 2, 'medium' => 1, 'low' => 1, 'info' => 0 }
                              })
  end

  describe '.configured?' do
    it 'returns true when SMTP_HOST is set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SMTP_HOST').and_return('mail.example.com')
      expect(described_class.configured?).to be true
    end

    it 'returns false when SMTP_HOST is not set' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SMTP_HOST').and_return(nil)
      expect(described_class.configured?).to be false
    end
  end

  describe '#build_email_html' do
    let(:html) { notifier.build_email_html('Test App', scan.summary) }

    it 'includes the target name' do
      expect(html).to include('Test App')
    end

    it 'includes the scan profile' do
      expect(html).to include('standard')
    end

    it 'includes total findings count' do
      expect(html).to include('5')
    end

    it 'includes all severity rows' do
      expect(html).to include('Critical')
      expect(html).to include('High')
      expect(html).to include('Medium')
      expect(html).to include('Low')
      expect(html).to include('Info')
    end

    it 'includes severity counts' do
      expect(html).to include('>1<')  # critical count
      expect(html).to include('>2<')  # high count
    end

    it 'produces valid HTML structure' do
      expect(html).to include('<h2>')
      expect(html).to include('<table')
      expect(html).to include('</table>')
    end

    context 'with empty severity data' do
      let(:scan) do
        create(:scan, :completed, target:, profile: 'quick',
                                  summary: { 'total_findings' => 0, 'by_severity' => {} })
      end

      it 'defaults missing severity counts to 0' do
        expect(html).to include('0')
      end
    end
  end

  describe '#smtp_settings' do
    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('SMTP_HOST', 'mail.authsmtp.com').and_return('smtp.example.com')
      allow(ENV).to receive(:fetch).with('SMTP_PORT', '2525').and_return('587')
      allow(ENV).to receive(:fetch).with('SMTP_USERNAME', nil).and_return('user@example.com')
      allow(ENV).to receive(:fetch).with('SMTP_PASSWORD', nil).and_return('secret123')
    end

    it 'returns correct address' do
      expect(notifier.smtp_settings[:address]).to eq('smtp.example.com')
    end

    it 'converts port to integer' do
      expect(notifier.smtp_settings[:port]).to eq(587)
    end

    it 'includes authentication method' do
      expect(notifier.smtp_settings[:authentication]).to eq(:login)
    end

    it 'enables STARTTLS' do
      expect(notifier.smtp_settings[:enable_starttls_auto]).to be true
    end
  end

  describe '#send_notification' do
    let(:mail_double) { instance_double(Mail::Message) }
    let!(:pdf_report) do
      create(:report, scan:, format: 'pdf', status: 'completed', gcs_path: 'test_report.pdf')
    end

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('SMTP_HOST', 'mail.authsmtp.com').and_return('smtp.test.com')
      allow(ENV).to receive(:fetch).with('SMTP_PORT', '2525').and_return('25')
      allow(ENV).to receive(:fetch).with('SMTP_USERNAME', nil).and_return(nil)
      allow(ENV).to receive(:fetch).with('SMTP_PASSWORD', nil).and_return(nil)
      allow(ENV).to receive(:fetch).with('SMTP_FROM', 'pentest@peregrine-tech.com').and_return('from@test.com')
      allow(ENV).to receive(:fetch).with('NOTIFICATION_EMAIL', 'security@peregrine-tech.com').and_return('to@test.com')

      allow(Mail::Message).to receive(:new).and_return(mail_double)
      allow(mail_double).to receive(:delivery_method)
      allow(mail_double).to receive(:deliver)
      allow(mail_double).to receive(:add_file)
    end

    it 'builds and delivers the email' do
      allow(Mail).to receive(:new).and_return(mail_double)
      expect(mail_double).to receive(:delivery_method).with(:smtp, hash_including(address: 'smtp.test.com'))
      expect(mail_double).to receive(:deliver)

      notifier.send_notification
    end

    context 'when PDF report file exists' do
      before do
        report_dir = Penetrator.root.join('storage/reports')
        FileUtils.mkdir_p(report_dir)
        File.write(report_dir.join('test_report.pdf'), 'fake-pdf')
      end

      after do
        FileUtils.rm_f(Penetrator.root.join('storage/reports/test_report.pdf'))
      end

      it 'attaches the PDF report' do
        allow(Mail).to receive(:new).and_return(mail_double)
        expect(mail_double).to receive(:add_file).with(hash_including(filename: 'scan_report.pdf'))
        expect(mail_double).to receive(:delivery_method)
        expect(mail_double).to receive(:deliver)

        notifier.send_notification
      end
    end

    context 'when PDF report does not exist' do
      it 'does not attach any file' do
        allow(Mail).to receive(:new).and_return(mail_double)
        allow(mail_double).to receive(:delivery_method)
        allow(mail_double).to receive(:deliver)
        # add_file should not be called since the file doesn't exist on disk
        # (the report record exists but the file doesn't)

        notifier.send_notification

        expect(mail_double).not_to have_received(:add_file)
      end
    end
  end
end

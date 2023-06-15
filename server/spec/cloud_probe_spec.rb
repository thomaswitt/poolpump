# spec/cloud_probe_spec.rb

require 'spec_helper'
require 'tools/cloud_probe'

RSpec.describe CloudProbe do
  describe '.extract_data' do
    it 'unwraps the saved-envelope shape (taken_at + envelope.data)' do
      snap = { 'taken_at' => 't', 'rtu_id' => '1', 'envelope' => { 'data' => { 'switch' => 1 } } }
      expect(described_class.extract_data(snap)).to eq('switch' => 1)
    end

    it 'unwraps the raw cloud-response shape (top-level data)' do
      snap = { 'resultCode' => 1, 'data' => { 'switch' => 0 } }
      expect(described_class.extract_data(snap)).to eq('switch' => 0)
    end

    it 'falls through to the snapshot itself if neither key is present' do
      snap = { 'switch' => 1 }
      expect(described_class.extract_data(snap)).to eq('switch' => 1)
    end
  end

  describe '.diff_data' do
    it 'returns empty changed/only_a/only_b when both sides are identical' do
      h = { 'switch' => 1, 'pa10' => 28.0 }
      expect(described_class.diff_data(h, h.dup)).to eq(changed: {}, only_a: {}, only_b: {})
    end

    it 'reports value changes per common key' do
      a = { 'switch' => 0, 'model' => 4, 'pa10' => 28.0 }
      b = { 'switch' => 1, 'model' => 4, 'pa10' => 28.5 }
      out = described_class.diff_data(a, b)
      expect(out[:changed]).to eq('switch' => [0, 1], 'pa10' => [28.0, 28.5])
      expect(out[:only_a]).to be_empty
      expect(out[:only_b]).to be_empty
    end

    it 'reports keys that exist only in one side' do
      a = { 'switch' => 1, 'extra_a' => 'x' }
      b = { 'switch' => 1, 'extra_b' => 'y' }
      out = described_class.diff_data(a, b)
      expect(out[:changed]).to be_empty
      expect(out[:only_a]).to eq('extra_a' => 'x')
      expect(out[:only_b]).to eq('extra_b' => 'y')
    end
  end

  describe '.render_diff' do
    it 'returns "(no differences)" when nothing differs' do
      expect(described_class.render_diff({ changed: {}, only_a: {}, only_b: {} })).to eq('(no differences)')
    end

    it 'shows the changed section with old → new values' do
      diff = { changed: { 'switch' => [0, 1] }, only_a: {}, only_b: {} }
      out = described_class.render_diff(diff)
      expect(out).to include('CHANGED (1):')
      expect(out).to include('switch')
      expect(out).to include('0 → 1')
    end

    it 'shows ONLY IN sections when keys diverge' do
      diff = { changed: {}, only_a: { 'foo' => 'x' }, only_b: { 'bar' => 'y' } }
      out = described_class.render_diff(diff, label_a: 'before.json', label_b: 'after.json')
      expect(out).to include('ONLY IN before.json')
      expect(out).to include('foo = "x"')
      expect(out).to include('ONLY IN after.json')
      expect(out).to include('bar = "y"')
    end
  end

  describe '.summarize' do
    it 'flags a nil-data envelope as OFFLINE (the real-world offline case)' do
      out = described_class.summarize('resultCode' => 0, 'data' => nil)
      expect(out).to include('OFFLINE')
      expect(out).to include('resultCode=0')
    end

    it 'flags an empty-data envelope as OFFLINE' do
      out = described_class.summarize('resultCode' => 0, 'data' => {})
      expect(out).to include('OFFLINE')
    end

    it 'shows interesting fields when data is present' do
      out = described_class.summarize('data' => { 'switch' => 1, 'model' => 2, 'pa10' => 28.5, 'unrelated' => 99 })
      expect(out).to include('ONLINE')
      expect(out).to include('fields=4')
      expect(out).to include('switch=1')
      expect(out).to include('pa10=28.5')
      expect(out).not_to include('unrelated=99')
    end
  end

  describe '.format_epoch_ms' do
    it 'decodes a millisecond epoch to UTC ISO-ish string' do
      expect(described_class.format_epoch_ms(1_759_150_277_912)).to eq('2025-09-29 12:51:17 UTC')
    end

    it 'returns nil for nil input' do
      expect(described_class.format_epoch_ms(nil)).to be_nil
    end
  end

  describe '.find_device' do
    let(:envelope) do
      {
        'data' => [
          { 'rtuId' => 11_111, 'rtuName' => 'Other' },
          { 'rtuId' => 30_516_970, 'rtuName' => 'Poolpump' },
        ],
      }
    end

    it 'matches by rtu_id (string-tolerant)' do
      expect(described_class.find_device(envelope, rtu_id: '30516970')['rtuName']).to eq('Poolpump')
      expect(described_class.find_device(envelope, rtu_id: 30_516_970)['rtuName']).to eq('Poolpump')
    end

    it 'returns nil when no device matches' do
      expect(described_class.find_device(envelope, rtu_id: '99999999')).to be_nil
    end

    it 'tolerates a nil/missing data array' do
      expect(described_class.find_device({}, rtu_id: '1')).to be_nil
      expect(described_class.find_device({ 'data' => nil }, rtu_id: '1')).to be_nil
    end
  end

  describe '.summarize_view' do
    it 'renders the device registry block with a human-readable last_seen' do
      device = {
        'rtuName' => 'PoolPump',
        'rtuCode' => '001122334455',
        'rtuType' => 'CONDITIONER_1',
        'modelName' => 'Pool Machine',
        'onlineState' => 0,
        'endRtuTime' => 1_759_150_277_912,
        'updateDate' => 1_716_284_929_064,
      }
      out = described_class.summarize_view(device)
      expect(out).to include('rtuName    : "PoolPump"')
      expect(out).to include('OFFLINE')
      expect(out).to include('2025-09-29 12:51:17 UTC')
      expect(out).to include('2024-05-21 09:48:49 UTC')
    end

    it 'returns a clear placeholder when no device record was found' do
      expect(described_class.summarize_view(nil)).to include('no device record')
    end
  end

  describe '.DEFAULT_BASELINE_DIR (must point under repo-root _data/, gitignored)' do
    it 'resolves above the server/ tree' do
      expect(described_class::DEFAULT_BASELINE_DIR).to end_with('/_data/cloud-baselines')
      expect(described_class::DEFAULT_BASELINE_DIR).not_to include('/server/_data/')
      # And — critically — it must live INSIDE the repo, not its parent.
      expect(described_class::DEFAULT_BASELINE_DIR).to include('/poolpump/_data/')
    end
  end

  describe '.env!' do
    it 'raises CredentialsMissing when POOLPUMP_CLOUD_EMAIL is unset' do
      stub_const('ENV', ENV.to_h.reject { |k, _| k.start_with?('POOLPUMP_CLOUD_') })
      expect { described_class.env! }.to raise_error(CloudProbe::CredentialsMissing, /POOLPUMP_CLOUD_EMAIL/)
    end

    it 'returns the credential bundle when all required vars are present' do
      stub_const('ENV', {
        'POOLPUMP_CLOUD_EMAIL' => 'a@b.c',
        'POOLPUMP_CLOUD_PASSWORD' => 'pw',
        'POOLPUMP_CLOUD_RTU_ID' => '42',
      })
      out = described_class.env!
      expect(out).to include(email: 'a@b.c', password: 'pw', rtu_id: '42')
      expect(out[:host]).to eq(CloudProbe::DEFAULT_HOST)
    end
  end
end

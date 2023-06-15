# spec/reprovision_spec.rb

require 'spec_helper'
require 'tools/reprovision'

RSpec.describe Reprovision do
  describe '.parse_at_response' do
    it 'extracts the value from a simple +ok=' do
      expect(described_class.parse_at_response("+ok=MyWifi\r\n\r\n", 'AT+WSSSID')).to eq('MyWifi')
    end

    it 'returns "" for a bare +ok (set commands)' do
      expect(described_class.parse_at_response("+ok\r\n\r\n", 'AT+WMODE=STA')).to eq('')
    end

    it 'preserves comma-separated values verbatim' do
      raw = "+ok=TCP,Client,502,www.fzdbiology.com\r\n\r\n"
      expect(described_class.parse_at_response(raw, 'AT+NETP')).to eq('TCP,Client,502,www.fzdbiology.com')
    end

    it 'raises ModuleError on +ERR' do
      expect { described_class.parse_at_response("+ERR=-1\r\n\r\n", 'AT+FOO') }.to raise_error(Reprovision::ModuleError, /AT\+FOO.*-1/)
    end

    it 'raises ModuleError on garbage' do
      expect { described_class.parse_at_response('garbage', 'AT+VER') }.to raise_error(Reprovision::ModuleError, /unexpected response/)
    end
  end

  describe '.commission (AP-mode bootstrap — one-shot WMODE+SSID+PSK+NETP+reboot)' do
    let(:plan_calls) { [] }

    # FakeSession replaces Reprovision::Session for these tests so we never
    # touch the network. Records every command via Session#send and returns
    # synthesised echoes that make the verify steps pass.
    fake_session_class = Class.new do
      def initialize(plan_calls, error_for: nil)
        @plan_calls = plan_calls
        @error_for = error_for # { cmd => return_value_or_:raise }
      end

      def send(cmd, **_)
        @plan_calls << cmd
        raise Reprovision::Timeout, 'expected — module rebooting' if cmd == 'AT+Z'
        return @error_for[cmd] if @error_for && @error_for.key?(cmd)
        return '' if cmd.include?('=') # SET form

        last_set = @plan_calls.reverse.find { |c| c.start_with?("#{cmd}=") }
        last_set ? last_set.split('=', 2).last : ''
      end

      def close; end
    end

    before do
      allow(Reprovision).to receive(:require_recent_snapshot!).and_return({})
      allow(Reprovision::Session).to receive(:new) { fake_session_class.new(plan_calls) }
    end

    it 'sends WSSSID, WSKEY, NETP, WMODE (in iOS-app order) THEN verifies all THEN AT+Z' do
      Reprovision.commission('10.10.100.254',
                             ssid: 'MyWifi', psk: 'mypassword',
                             server_hostname: '192.168.0.99', port: 5020)
      expect(plan_calls).to eq(%w[
                                 AT+WSSSID=MyWifi
                                 AT+WSKEY=WPA2PSK,AES,mypassword
                                 AT+NETP=TCP,Client,5020,192.168.0.99
                                 AT+WMODE=STA
                                 AT+WSSSID
                                 AT+WSKEY
                                 AT+NETP
                                 AT+WMODE
                                 AT+Z
                               ])
    end

    it 'aborts BEFORE AT+Z if any verify mismatches (brick protection)' do
      # Make AT+WSKEY read-back return a different value than what we wrote.
      bad = { 'AT+WSKEY' => 'WPA2PSK,AES,WRONG_VALUE_THAT_DOES_NOT_MATCH' }
      allow(Reprovision::Session).to receive(:new) { fake_session_class.new(plan_calls, error_for: bad) }
      expect {
        Reprovision.commission('10.10.100.254',
                               ssid: 'MyWifi', psk: 'mypassword',
                               server_hostname: '192.168.0.99', port: 5020)
      }.to raise_error(Reprovision::Error, /verify failed for AT\+WSKEY/)
      expect(plan_calls).not_to include('AT+Z')
    end

    it 'uses default port 502 when not specified' do
      Reprovision.commission('10.10.100.254', ssid: 'X', psk: 'Y', server_hostname: 'host')
      expect(plan_calls).to include('AT+NETP=TCP,Client,502,host')
    end
  end

  describe '.semantic_equal? (P2 — verify is case-insensitive on protocol/mode fields)' do
    it 'AT+NETP — same content with different casing on protocol/mode is equal' do
      expect(described_class.semantic_equal?('AT+NETP',
                                             'TCP,CLIENT,5020,192.168.1.42',
                                             'TCP,Client,5020,192.168.1.42')).to be(true)
    end

    it 'AT+NETP — DNS hostname case differences are ignored' do
      expect(described_class.semantic_equal?('AT+NETP',
                                             'TCP,CLIENT,8080,WWW.FZDBIOLOGY.COM',
                                             'tcp,client,8080,www.fzdbiology.com')).to be(true)
    end

    it 'AT+NETP — different port is NOT equal' do
      expect(described_class.semantic_equal?('AT+NETP',
                                             'TCP,CLIENT,5020,192.168.1.42',
                                             'TCP,CLIENT,5021,192.168.1.42')).to be(false)
    end

    it 'AT+NETP — different host is NOT equal' do
      expect(described_class.semantic_equal?('AT+NETP',
                                             'TCP,CLIENT,5020,192.168.1.42',
                                             'TCP,CLIENT,5020,192.168.1.99')).to be(false)
    end

    it 'AT+WMODE — case-insensitive match' do
      expect(described_class.semantic_equal?('AT+WMODE', 'STA', 'sta')).to be(true)
      expect(described_class.semantic_equal?('AT+WMODE', 'STA', 'AP')).to be(false)
    end

    it 'AT+WMODE — requesting STA is satisfied by APSTA (DOTELS-SWP keeps AP up)' do
      expect(described_class.semantic_equal?('AT+WMODE', 'STA', 'APSTA')).to be(true)
      expect(described_class.semantic_equal?('AT+WMODE', 'sta', 'apsta')).to be(true)
    end

    it 'AT+WMODE — requesting AP is NOT satisfied by APSTA (would leak STA)' do
      expect(described_class.semantic_equal?('AT+WMODE', 'AP', 'APSTA')).to be(false)
    end

    it 'AT+WMODE — requesting APSTA requires APSTA (STA alone is not enough)' do
      expect(described_class.semantic_equal?('AT+WMODE', 'APSTA', 'STA')).to be(false)
    end

    it 'AT+WSSSID — case-sensitive (SSIDs and PSKs are intentionally exact)' do
      expect(described_class.semantic_equal?('AT+WSSSID', 'MyWifi', 'MyWifi')).to be(true)
      expect(described_class.semantic_equal?('AT+WSSSID', 'MyWifi', 'MYWIFI')).to be(false)
    end

    it 'returns false when either side is nil' do
      expect(described_class.semantic_equal?('AT+NETP', nil, 'x')).to be(false)
      expect(described_class.semantic_equal?('AT+NETP', 'x', nil)).to be(false)
    end
  end

  describe '.DEFAULT_SNAPSHOT_DIR (P1 — must point under repo-root _data/, gitignored)' do
    it 'resolves above the server/ tree' do
      expect(described_class::DEFAULT_SNAPSHOT_DIR).to end_with('/_data/snapshots')
      expect(described_class::DEFAULT_SNAPSHOT_DIR).not_to include('/server/_data/')
    end
  end

  describe '.render_snapshot' do
    let(:snap) do
      {
        'taken_at' => '2026-04-29T17:50:00Z',
        'module_ip' => '192.168.0.42',
        'settings' => {
          'AT+VER' => 'V2.7.1',
          'AT+WSSSID' => 'MyWifi',
          'AT+WSKEY' => 'WPA2PSK,AES,supersecret',
          'AT+NETP' => 'TCP,CLIENT,502,www.fzdbiology.com',
          'AT+WAKEY' => 'WPA2PSK,AES,softap-pass',
          'AT+WEBU' => 'admin,my-web-pass',
        },
      }
    end

    it 'masks WSKEY by default' do
      out = described_class.render_snapshot(snap)
      expect(out).to include('WPA2PSK,AES,***')
      expect(out).not_to include('supersecret')
    end

    it 'reveals WSKEY when --reveal' do
      out = described_class.render_snapshot(snap, reveal: true)
      expect(out).to include('supersecret')
    end

    it 'masks the AT+WAKEY (SoftAP password) by default' do
      out = described_class.render_snapshot(snap)
      expect(out).not_to include('softap-pass')
    end

    it 'masks the AT+WEBU password (segment 1, NOT segment 2 like the WPA keys)' do
      out = described_class.render_snapshot(snap)
      expect(out).to include('admin,***')
      expect(out).not_to include('my-web-pass')
    end

    it 'reveals AT+WEBU under --reveal' do
      out = described_class.render_snapshot(snap, reveal: true)
      expect(out).to include('admin,my-web-pass')
    end

    it 'shows the snapshot timestamp and IP' do
      out = described_class.render_snapshot(snap)
      expect(out).to include('192.168.0.42')
      expect(out).to include('2026-04-29T17:50:00Z')
    end
  end
end

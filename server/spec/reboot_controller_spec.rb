# spec/reboot_controller_spec.rb

require 'spec_helper'
require 'poolpump/reboot_controller'

RSpec.describe Poolpump::RebootController do
  # FakeUDPSocket records sends so we can assert wire bytes without touching
  # the real network.
  let(:sent) { [] }
  let(:fake_sock_class) do
    Class.new do
      def initialize(sent_log) = (@sent = sent_log)
      def connect(_ip, _port); end
      def send(bytes, _flags) = @sent << bytes
      def close; end
    end
  end

  let(:ctrl) do
    described_class.new(
      device_ip:    '10.0.0.42',
      cooldown_sec: 60,
      daily_limit:  3,
      logger:       ->(_msg) { },
    )
  end

  before do
    captured_sent = sent
    cls = fake_sock_class
    allow(UDPSocket).to receive(:new) { cls.new(captured_sent) }
    # Skip real sleeps in send_reboot_sequence! so tests stay fast.
    allow(ctrl).to receive(:sleep)
  end

  describe '#reboot!' do
    it 'sends the HF-A11ASSISTHREAD handshake then AT+Z double-send + AT+Q double-send' do
      result = ctrl.reboot!(reason: 'test')
      expect(result).to eq(ok: true, reason: nil)
      expect(sent).to eq([
                          'HF-A11ASSISTHREAD'.b,
                          "AT+Z\r".b,
                          "AT+Z\r".b,
                          "AT+Q\r".b,
                          "AT+Q\r".b,
                        ])
    end

    it 'rejects subsequent attempts inside the cooldown window' do
      expect(ctrl.reboot!(reason: 'first')).to eq(ok: true, reason: nil)
      sent.clear
      result = ctrl.reboot!(reason: 'second-too-soon')
      expect(result).to eq(ok: false, reason: 'cooldown')
      expect(sent).to be_empty
    end

    it 'rejects past the daily cap (3 in this spec) even if cooldown is bypassed' do
      no_cooldown = described_class.new(
        device_ip:    '10.0.0.42',
        cooldown_sec: 0,
        daily_limit:  3,
        logger:       ->(_msg) { },
      )
      allow(no_cooldown).to receive(:sleep)
      3.times { |i| expect(no_cooldown.reboot!(reason: "n#{i}")[:ok]).to be(true) }
      result = no_cooldown.reboot!(reason: 'over-limit')
      expect(result).to eq(ok: false, reason: 'daily-cap')
    end

    it 'reports send-error when the UDP socket raises' do
      raising_sock = Class.new do
        def initialize(*); end
        def connect(*); end
        def send(*) = raise Errno::EHOSTUNREACH, 'host down'
        def close; end
      end
      allow(UDPSocket).to receive(:new) { raising_sock.new }
      result = ctrl.reboot!(reason: 'will-fail')
      expect(result).to eq(ok: false, reason: 'send-error')
    end
  end

  describe '#stats' do
    it 'reports the configured device IP, attempt count, and limits' do
      ctrl.reboot!(reason: 'test')
      stats = ctrl.stats
      expect(stats).to include(
        device_ip:    '10.0.0.42',
        attempts_today: 1,
        cooldown_sec: 60,
        daily_limit:  3,
      )
      expect(stats[:last_attempt_ago_sec]).to be_a(Numeric).and(be >= 0)
    end

    it 'reports zero attempts and nil last_attempt before any reboot' do
      stats = ctrl.stats
      expect(stats[:attempts_today]).to eq(0)
      expect(stats[:last_attempt_ago_sec]).to be_nil
    end
  end
end

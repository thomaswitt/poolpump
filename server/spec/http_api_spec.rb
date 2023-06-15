# spec/http_api_spec.rb

require 'spec_helper'
require 'rack'
require 'rack/mock'
require 'async'
require 'async/promise'
require 'poolpump/pump_session'
require 'poolpump/http_api'

# Minimal session double — fulfills the surface HttpApi calls.
class FakeSession
  attr_accessor :snapshot_data, :next_result, :enqueue_raises

  def initialize
    @snapshot_data = {}
    @next_result = { ok: true }
    @enqueue_raises = nil
  end

  def snapshot; @snapshot_data end

  def enqueue(_cmd, deadline: 3.0)
    raise @enqueue_raises if @enqueue_raises

    p = Async::Promise.new
    p.resolve(@next_result)
    p
  end

  def healthz; { connected: true, queue_depth: 0 } end
end

RSpec.describe Poolpump::HttpApi do
  let(:session) { FakeSession.new }
  let(:app) { described_class.new(session: session) }

  def call_app(method, path, body: nil)
    Sync do
      env = Rack::MockRequest.env_for(path, method: method, input: body)
      status, headers, body_iter = app.call(env)
      [status, headers, body_iter.is_a?(Array) ? body_iter.join : body_iter.to_a.join]
    end
  end

  describe 'GET /' do
    it 'returns 500 with the legacy "terminal not online" shape when snapshot is empty' do
      status, _h, body = call_app('GET', '/')
      json = JSON.parse(body)
      expect(status).to eq(500)
      expect(json).to include(
        'resultCode' => 0,
        'result' => 'error',
        'message' => Poolpump::HttpApi::LEGACY_GENERIC_ERR_MSG,
      )
    end

    it 'returns the 14-field semantic snapshot when telemetry has arrived' do
      session.snapshot_data = {
        switch: 1, model: 4, function: 0, autotemp: 27.0, heattemp: 28.0,
        cooltemp: 18.0, pa10: 30, ap3: 28, ap2: 22, pa15: 0, ap8: 0,
        pb11: 0, pa13: 0,
      }
      status, _h, body = call_app('GET', '/')
      json = JSON.parse(body)
      expect(status).to eq(200)
      expect(json.keys).to eq(%w[
                             SWITCHED_ON COMPRESSOR_RATE TEMP_AMBIENT TEMP_OUTLET TEMP_INLET
                             TEMP_TARGET TEMP_TARGET_AUTO TEMP_TARGET_COOL BOOST SILENCE
                             STATUS_WATERPUMP STATUS_MODE STATUS_MALFUNC STATUS_OPERATION
                             AC_VOLTAGE MOTOR_CURRENT_A DC_LINK_VOLTAGE_V DC_LINK_CURRENT_A COMPRESSOR_LOAD_PCT MAX_INPUT_W
                           ])
      expect(json['TEMP_INLET']).to eq(30)
      expect(json['STATUS_MALFUNC']).to eq('none')
    end
  end

  describe 'POST /' do
    %w[on off mode-boost mode-auto].each do |verb|
      it "accepts #{verb} and returns resultCode:1 with verb + post-exec snapshot" do
        session.snapshot_data = {
          switch: 1, model: 4, function: 0, autotemp: 27.0, heattemp: 28.0,
          cooltemp: 18.0, pa10: 30, ap3: 28, ap2: 22, pa15: 0, ap8: 0,
          pb11: 0, pa13: 0,
        }
        status, _h, body = call_app('POST', '/', body: verb)
        json = JSON.parse(body)
        expect(status).to eq(200)
        expect(json).to include('resultCode' => 1, 'result' => 'ok', 'verb' => verb)
        # Snapshot is attached so callers can verify the change took effect
        # without a second HTTP round-trip.
        expect(json['snapshot']).to include('TEMP_INLET' => 30)
      end
    end

    it 'accepts settemp NN and includes the verb in the response' do
      status, _h, body = call_app('POST', '/', body: 'settemp 28')
      json = JSON.parse(body)
      expect(status).to eq(200)
      expect(json).to include('verb' => 'settemp 28', 'resultCode' => 1)
    end

    it 'returns 400 with the LEGACY invalid-verb message for unknown verbs' do
      status, _h, body = call_app('POST', '/', body: 'frobulate')
      json = JSON.parse(body)
      expect(status).to eq(400)
      expect(json).to include(
        'resultCode' => 0,
        'result' => 'error',
        'message' => Poolpump::HttpApi::LEGACY_INVALID_VERB_MSG,
      )
      expect(json['reason']).to match(/parse-error/)
    end

    it 'returns 500 with legacy generic-error message + reason on echo-timeout' do
      session.next_result = { ok: false, reason: 'echo-timeout' }
      status, _h, body = call_app('POST', '/', body: 'on')
      json = JSON.parse(body)
      expect(status).to eq(500)
      expect(json).to include(
        'resultCode' => 0,
        'result' => 'error',
        'message' => Poolpump::HttpApi::LEGACY_GENERIC_ERR_MSG,
        'reason' => 'echo-timeout',
        'verb' => 'on',
      )
    end

    it 'returns 503 sessionstale (legacy shape + reason) when no module is connected' do
      session.enqueue_raises = Poolpump::PumpSession::SessionStale.new('no module connected')
      status, _h, body = call_app('POST', '/', body: 'on')
      json = JSON.parse(body)
      expect(status).to eq(503)
      expect(json).to include(
        'resultCode' => 0,
        'result' => 'error',
        'reason' => 'sessionstale',
      )
    end

    it 'returns 503 queuefull when the bounded queue is saturated' do
      session.enqueue_raises = Poolpump::PumpSession::QueueFull.new('queue at limit')
      status, _h, body = call_app('POST', '/', body: 'on')
      expect(status).to eq(503)
      expect(JSON.parse(body)['reason']).to eq('queuefull')
    end
  end

  describe 'GET /healthz' do
    it 'returns the session.healthz hash as JSON' do
      status, _h, body = call_app('GET', '/healthz')
      expect(status).to eq(200)
      expect(JSON.parse(body)).to include('connected' => true)
    end

    it 'includes nested reboot stats when a reboot_controller is configured' do
      ctrl = double('RebootController', stats: { device_ip: '10.0.0.42', attempts_today: 0 })
      app = described_class.new(session: session, reboot_controller: ctrl)
      Sync do
        env = Rack::MockRequest.env_for('/healthz', method: 'GET')
        _s, _h, body_iter = app.call(env)
        json = JSON.parse(body_iter.is_a?(Array) ? body_iter.join : body_iter.to_a.join)
        expect(json['reboot']).to eq('device_ip' => '10.0.0.42', 'attempts_today' => 0)
      end
    end
  end

  describe 'POST /reboot' do
    it 'returns 503 when no reboot_controller is configured' do
      status, _h, body = call_app('POST', '/reboot')
      json = JSON.parse(body)
      expect(status).to eq(503)
      expect(json).to include('result' => 'error', 'reason' => 'no-reboot-controller')
    end

    it 'returns 200 with verb=reboot + reboot stats on success' do
      ctrl = double('RebootController',
                    reboot!: { ok: true, reason: nil },
                    stats:   { device_ip: '10.0.0.42', attempts_today: 1 })
      app = described_class.new(session: session, reboot_controller: ctrl)
      Sync do
        env = Rack::MockRequest.env_for('/reboot', method: 'POST')
        status, _h, body_iter = app.call(env)
        json = JSON.parse(body_iter.is_a?(Array) ? body_iter.join : body_iter.to_a.join)
        expect(status).to eq(200)
        expect(json).to include('resultCode' => 1, 'verb' => 'reboot')
        expect(json['reboot']).to eq('device_ip' => '10.0.0.42', 'attempts_today' => 1)
      end
    end

    it 'returns 429 when the reboot_controller rejects with cooldown' do
      ctrl = double('RebootController',
                    reboot!: { ok: false, reason: 'cooldown' },
                    stats:   { device_ip: '10.0.0.42', attempts_today: 1 })
      app = described_class.new(session: session, reboot_controller: ctrl)
      Sync do
        env = Rack::MockRequest.env_for('/reboot', method: 'POST')
        status, _h, body_iter = app.call(env)
        json = JSON.parse(body_iter.is_a?(Array) ? body_iter.join : body_iter.to_a.join)
        expect(status).to eq(429)
        expect(json['reason']).to eq('cooldown')
      end
    end

    it 'returns 429 when the reboot_controller rejects with daily-cap' do
      ctrl = double('RebootController',
                    reboot!: { ok: false, reason: 'daily-cap' },
                    stats:   { device_ip: '10.0.0.42', attempts_today: 6 })
      app = described_class.new(session: session, reboot_controller: ctrl)
      Sync do
        env = Rack::MockRequest.env_for('/reboot', method: 'POST')
        status, _h, _body = app.call(env)
        expect(status).to eq(429)
      end
    end

    it 'returns 502 when the reboot_controller raises send-error' do
      ctrl = double('RebootController',
                    reboot!: { ok: false, reason: 'send-error' },
                    stats:   { device_ip: '10.0.0.42', attempts_today: 0 })
      app = described_class.new(session: session, reboot_controller: ctrl)
      Sync do
        env = Rack::MockRequest.env_for('/reboot', method: 'POST')
        status, _h, _body = app.call(env)
        expect(status).to eq(502)
      end
    end
  end

  describe '404 path' do
    it 'returns the legacy error shape for unknown paths' do
      status, _h, body = call_app('GET', '/nope')
      json = JSON.parse(body)
      expect(status).to eq(404)
      expect(json).to include('resultCode' => 0, 'result' => 'error')
    end
  end
end

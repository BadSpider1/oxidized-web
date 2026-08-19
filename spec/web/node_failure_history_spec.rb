require_relative '../spec_helper'

# Protocol stand-ins whose class basename is the connection method label the
# module records (mirrors Oxidized::SSH / Oxidized::Telnet).
module FakeProto
  # Empty doubles whose only role is to carry a protocol-shaped class name.
  class SSH; end # rubocop:disable Lint/EmptyClass
  class Telnet; end # rubocop:disable Lint/EmptyClass
end

# Minimal stand-in for Oxidized::Node exposing only what the module wraps: a
# #run_input that (like the core) sets err_type/err_reason and returns false on
# a failed attempt, true on success.
class FakeFailNode
  attr_accessor :err_type, :err_reason

  def initialize
    @program = []
  end

  # queue of outcomes consumed one per run_input call
  def program(outcomes)
    @program = outcomes
  end

  # mirrors the core Node#run_input name/return contract (true/false)
  def run_input(_input) # rubocop:disable Naming/PredicateMethod
    outcome = @program.shift || { ok: true }
    if outcome[:ok]
      true
    else
      @err_type   = outcome[:type]
      @err_reason = outcome[:reason]
      false
    end
  end
end
FakeFailNode.prepend(Oxidized::API::NodeFailureHistory)

describe Oxidized::API::NodeFailureHistory do
  after do
    # reset the global retention size so tests do not leak into each other
    Oxidized::API::NodeFailureHistory.instance_variable_set(:@max, nil)
  end

  it 'is prepended onto the real Oxidized::Node' do
    _(Oxidized::Node.include?(Oxidized::API::NodeFailureHistory)).must_equal true
  end

  it 'records one entry per failed connection method, tagged with the protocol' do
    node = FakeFailNode.new
    node.program([
                   { ok: false, type: 'Net::SSH::AuthenticationFailed', reason: 'Authentication failed' },
                   { ok: false, type: 'Errno::ECONNREFUSED', reason: 'Connection refused' }
                 ])

    node.run_input(FakeProto::SSH.new)
    node.run_input(FakeProto::Telnet.new)

    history = node.failure_history
    _(history.length).must_equal 2

    _(history[0][:input]).must_equal 'SSH'
    _(history[0][:err_type]).must_equal 'Net::SSH::AuthenticationFailed'
    _(history[0][:err_reason]).must_equal 'Authentication failed'
    _(history[0][:time]).must_be_instance_of Time

    _(history[1][:input]).must_equal 'Telnet'
    _(history[1][:err_type]).must_equal 'Errno::ECONNREFUSED'
    _(history[1][:err_reason]).must_equal 'Connection refused'
  end

  it 'does not record successful attempts' do
    node = FakeFailNode.new
    node.program([{ ok: true }])

    node.run_input(FakeProto::SSH.new)

    _(node.failure_history).must_be_empty
  end

  it 'keeps at most NodeFailureHistory.max entries (newest kept)' do
    Oxidized::API::NodeFailureHistory.max = 3
    node = FakeFailNode.new
    node.program(Array.new(5) { |i| { ok: false, type: "Err#{i}", reason: "reason #{i}" } })

    5.times { node.run_input(FakeProto::SSH.new) }

    history = node.failure_history
    _(history.length).must_equal 3
    # the three most recent (Err2, Err3, Err4) survive, oldest first
    _(history.map { |h| h[:err_type] }).must_equal %w[Err2 Err3 Err4]
  end

  it 'returns a snapshot that cannot mutate the internal history' do
    node = FakeFailNode.new
    node.program([{ ok: false, type: 'X', reason: 'y' }])
    node.run_input(FakeProto::SSH.new)

    snapshot = node.failure_history
    snapshot << { input: 'injected' }

    _(node.failure_history.length).must_equal 1
  end

  describe '.max=' do
    it 'falls back to the default for non-positive values' do
      Oxidized::API::NodeFailureHistory.max = 0
      _(Oxidized::API::NodeFailureHistory.max).must_equal Oxidized::API::NodeFailureHistory::DEFAULT_MAX

      Oxidized::API::NodeFailureHistory.max = -5
      _(Oxidized::API::NodeFailureHistory.max).must_equal Oxidized::API::NodeFailureHistory::DEFAULT_MAX
    end
  end
end

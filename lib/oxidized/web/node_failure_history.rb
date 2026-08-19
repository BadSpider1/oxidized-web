# frozen_string_literal: true

module Oxidized
  module API
    # Records *why* a node's backup failed, at connection-method granularity.
    #
    # Problem
    # -------
    # The Oxidized core keeps only the single most recent error on a Node
    # (`err_type` / `err_reason`) and overwrites it on every failed connection
    # attempt.  A node configured to try SSH and then Telnet therefore only
    # ever exposes the *Telnet* error through the API, even though both the SSH
    # and the Telnet attempt failed – the SSH error is lost before the web
    # layer can ever observe it.
    #
    # Solution
    # --------
    # This module is prepended to +Oxidized::Node+ and wraps the core
    # per-input backup attempt (+#run_input+).  Whenever an attempt does not
    # succeed it records one entry – tagged with the timestamp, the connection
    # method (SSH, Telnet, …), and the error class and message the core just
    # set – so the web UI can show a short history such as:
    #
    #   2026-08-19 10:00:01  SSH     Net::SSH::AuthenticationFailed  Authentication failed
    #   2026-08-19 10:00:02  Telnet  Errno::ECONNREFUSED             Connection refused
    #
    # The history is kept in memory on the Node object (bounded to
    # {NodeFailureHistory.max} entries, newest last) and is not persisted, so
    # it resets when the node list is reloaded from the source or when Oxidized
    # restarts.
    module NodeFailureHistory
      # Default number of failure entries retained per node.
      DEFAULT_MAX = 10

      class << self
        # Number of failure entries retained per node.  Configurable through
        # the web extension configuration (`max_failures`).
        # @return [Integer]
        def max
          @max ||= DEFAULT_MAX
        end

        # @param value [#to_i] new retention size; non-positive values reset to
        #   {DEFAULT_MAX}.
        def max=(value)
          value = value.to_i
          @max = value.positive? ? value : DEFAULT_MAX
        end
      end

      # Set up the per-node history storage.  Runs before the core initializer
      # body via +super+ so every Node – however it is constructed – gets the
      # instance variables.
      def initialize(*)
        super
        @failure_history = []
        @failure_history_mutex = Mutex.new
      end

      # A thread-safe snapshot of the recorded failures, oldest first.  Safe to
      # call from the web (Puma) thread while the poller thread records new
      # failures.
      #
      # @return [Array<Hash>] each entry is
      #   +{ time: Time, input: String, err_type: String, err_reason: String }+
      def failure_history
        return [] unless @failure_history_mutex

        @failure_history_mutex.synchronize { @failure_history.dup }
      end

      # Wrap the core's per-input backup attempt.  When the attempt does not
      # succeed the core has just set +err_type+/+err_reason+ for *this* input,
      # so record a failure entry tagged with the input's protocol before the
      # next input in the sequence overwrites them.
      def run_input(input)
        result = super
        record_input_failure(input) unless result
        result
      end

      private

      def record_input_failure(input)
        # Defensive: a Node built by a path that bypassed our prepended
        # #initialize would have no storage; never raise from the poller.
        return unless @failure_history_mutex

        entry = {
          time: Time.now.utc,
          input: protocol_name(input),
          err_type: err_type.to_s,
          err_reason: err_reason.to_s
        }.freeze

        @failure_history_mutex.synchronize do
          @failure_history.push(entry)
          @failure_history.shift while @failure_history.size > NodeFailureHistory.max
        end
      end

      # Human-friendly connection-method label, e.g. "SSH" or "Telnet".
      def protocol_name(input)
        klass = input.is_a?(Class) ? input : input.class
        name  = klass.name.to_s
        name.split('::').last || name
      rescue StandardError
        'unknown'
      end
    end
  end
end

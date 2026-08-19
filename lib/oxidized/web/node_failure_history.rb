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
    #
    # Storage is created lazily (see {#failure_history_mutex}) rather than in a
    # prepended +#initialize+ on purpose: the Oxidized core builds every Node
    # (Nodes.new) *before* it requires oxidized-web and this module is
    # prepended (see oxidized/core.rb).  A prepended initializer would therefore
    # never run for those already-constructed nodes – exactly the nodes the
    # worker polls – so their failures would never be recorded.  Lazy creation
    # makes the feature work regardless of construction order.
    module NodeFailureHistory
      # Default number of failure entries retained per node.
      DEFAULT_MAX = 10

      # Guards the one-time creation of each node's per-instance storage.  A
      # single process-wide lock is fine: it is only contended the very first
      # time a given node records or reads its history.
      STORAGE_LOCK = Mutex.new

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

      # A thread-safe snapshot of the recorded failures, oldest first.  Safe to
      # call from the web (Puma) thread while the poller thread records new
      # failures.
      #
      # @return [Array<Hash>] each entry is
      #   +{ time: Time, input: String, err_type: String, err_reason: String }+
      def failure_history
        failure_history_mutex.synchronize { @failure_history.dup }
      end

      # Wrap the core's per-input backup attempt.  When the attempt fails the
      # core has usually just set +err_type+/+err_reason+ for *this* input, so
      # record a failure entry tagged with the input's protocol before the next
      # input in the sequence overwrites them.
      #
      # The core can, however, return false *without* setting a fresh error
      # (e.g. +input.connect+ returns false via the +connect && get+
      # short-circuit, or an unexpected crash with no crash directory
      # configured returns early).  In that case the still-set error belongs to
      # a *previous* input, so we must not attribute it to this one — we compare
      # the error before and after the attempt and only record it when it
      # actually changed.
      def run_input(input)
        before_type   = err_type
        before_reason = err_reason
        result = super
        unless result
          changed = err_type != before_type || err_reason != before_reason
          record_input_failure(input, changed ? err_type : nil, changed ? err_reason : nil)
        end
        result
      end

      private

      # Lazily create (once) and return this node's history mutex.  Because the
      # module may have been prepended after the node was constructed, the
      # instance variables cannot be assumed to exist; create them under a
      # process-wide lock the first time they are needed.  The array is assigned
      # before the mutex so any thread that sees a non-nil mutex also sees the
      # array.
      def failure_history_mutex
        existing = @failure_history_mutex
        return existing if existing

        NodeFailureHistory::STORAGE_LOCK.synchronize do
          @failure_history ||= []
          @failure_history_mutex ||= Mutex.new
        end
      end

      def record_input_failure(input, type, reason)
        entry = {
          time: Time.now.utc,
          input: protocol_name(input),
          err_type: type.to_s,
          err_reason: reason.to_s
        }.freeze

        failure_history_mutex.synchronize do
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

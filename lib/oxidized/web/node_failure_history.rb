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
    # Storage
    # -------
    # The history is kept in a process-wide registry keyed by node *name*, not
    # on the Node object itself.  This is deliberate:
    #   * The Oxidized core builds every Node (Nodes.new) *before* it requires
    #     oxidized-web and prepends this module, and it rebuilds every Node from
    #     scratch on a source/reload (Nodes#update_nodes), copying only stats
    #     and the last job across.  Anything stored on the Node instance would
    #     be lost on every reload (and so would the core's err_type), leaving a
    #     still-failing host with an empty history.
    #   * A registry keyed by name survives node-object churn, so the history a
    #     node accumulated keeps growing across reloads.
    # It is still in-memory only, so it resets when the Oxidized process
    # restarts, and it is bounded to {NodeFailureHistory.max} entries per node.
    module NodeFailureHistory
      # Default number of failure entries retained per node.
      DEFAULT_MAX = 10

      # Guards the shared registry.
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

        # Append a failure entry for +node_name+, trimming to {max}.
        def record(node_name, entry)
          return if node_name.nil?

          key = node_name.to_s
          STORAGE_LOCK.synchronize do
            @store ||= {}
            list = (@store[key] ||= [])
            list.push(entry)
            list.shift while list.size > max
          end
        end

        # @return [Array<Hash>] a snapshot (dup) of the failures recorded for
        #   +node_name+, oldest first.
        def history_for(node_name)
          STORAGE_LOCK.synchronize do
            @store ||= {}
            (@store[node_name.to_s] || []).dup
          end
        end

        # Discard all recorded history (used by tests).
        def reset_store!
          STORAGE_LOCK.synchronize { @store = {} }
        end
      end

      # A thread-safe snapshot of this node's recorded failures, oldest first.
      #
      # @return [Array<Hash>] each entry is
      #   +{ time: Time, input: String, err_type: String, err_reason: String }+
      def failure_history
        NodeFailureHistory.history_for(name)
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
          entry = {
            time: Time.now.utc,
            input: protocol_name(input),
            err_type: changed ? err_type.to_s : '',
            err_reason: changed ? err_reason.to_s : ''
          }.freeze
          NodeFailureHistory.record(name, entry)
        end
        result
      end

      private

      # Human-friendly connection-method label, e.g. "SSH" or "Telnet".
      def protocol_name(input)
        klass = input.is_a?(Module) ? input : input.class
        name  = klass.name.to_s
        name.split('::').last || name
      rescue StandardError
        'unknown'
      end
    end
  end
end

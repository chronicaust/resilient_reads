module ResilientReads
  # Prepended onto the database adapter (e.g. PostgreSQLAdapter, Mysql2Adapter, TrilogyAdapter).
  # Intercepts raw_execute and routes SELECT queries to a healthy replica
  # when inside a distribute_reads block.  Writes always pass through to
  # the primary connection.
  #
  # Uses *args/**kwargs to stay compatible across Rails versions:
  #   Rails 7.1/7.2: raw_execute(sql, name, async:, allow_retry:, materialize_transactions:)
  #   Rails 8.0+:    raw_execute(sql, name, binds, prepare:, async:, allow_retry:, materialize_transactions:, batch:)
  module AdapterPatch
    # Query names that should never be routed to a replica. These are
    # schema introspection or internal bookkeeping queries that run during
    # model loading and connection setup.
    SKIP_NAMES = Set.new(%w[SCHEMA EXPLAIN TRANSACTION]).freeze

    # SQL clauses that acquire locks and must execute on the primary,
    # even though the statement starts with SELECT.
    LOCKING_CLAUSE_PATTERN = /\b(FOR\s+(UPDATE|NO\s+KEY\s+UPDATE|SHARE|KEY\s+SHARE)|LOCK\s+IN\s+SHARE\s+MODE)\b/i

    def raw_execute(sql, *args, **kwargs)
      ctx = Thread.current[:resilient_reads_context]
      name = args.first

      if ctx &&
         ctx[:distributing] &&
         !ctx[:on_replica] &&
         !ctx[:routing] &&
         !ctx[:stick_to_primary] &&
         !skip_replica_routing?(sql, name) &&
         open_transactions.zero?

        execute_on_replica(sql, ctx, *args, **kwargs)
      else
        if ctx && ctx[:distributing] && !ctx[:on_replica]
          adapter_write = write_query?(sql)

          if adapter_write || ResilientReads.write_query?(sql)
            # Sticky writes: after any DML write inside a distribute_reads
            # block, all subsequent reads stay on primary for the rest of
            # the block.  This prevents stale-read → conflicting-write
            # chains that cause MySQL/InnoDB deadlocks, especially with
            # transactionless writes like update_column that don't bump
            # open_transactions.
            #
            # Only adapter-detected writes (DML/DDL) trigger sticky —
            # transaction commands (BEGIN/COMMIT) are handled by the
            # open_transactions guard instead.
            if ResilientReads.config.sticky_writes && adapter_write
              ctx[:stick_to_primary] = true
            end
            ResilientReads.log_query("primary", sql, name, reason: "write query")
          elsif ctx[:stick_to_primary]
            ResilientReads.log_query("primary", sql, name, reason: "sticky write")
          end
        end
        super(sql, *args, **kwargs)
      end
    end

    private

    # Queries that must stay on the primary: writes, transaction
    # commands, schema introspection, and locking reads.
    #
    # We check *both* the adapter's write_query? (which knows about
    # adapter-specific DDL/DML) and ResilientReads' own WRITE_PATTERN
    # (which catches transaction commands like BEGIN/COMMIT/SET that
    # some adapters classify as reads).
    def skip_replica_routing?(sql, name)
      return true if name && SKIP_NAMES.include?(name)
      return true if write_query?(sql)
      return true if ResilientReads.write_query?(sql)
      return true if locking_query?(sql)
      false
    end

    # Detects SELECT statements that acquire row/table locks
    # (e.g. SELECT ... FOR UPDATE, LOCK IN SHARE MODE).  These must
    # execute on the primary — a read-only replica cannot acquire locks.
    def locking_query?(sql)
      LOCKING_CLAUSE_PATTERN.match?(sql)
    end

    def execute_on_replica(sql, ctx, *args, **kwargs)
      # Ensure the primary adapter is connected.  If all prior reads
      # were routed to replicas, the primary connection was never
      # materialized.  For PostgreSQL this avoids a nil @type_map
      # (cast_result → get_oid_type → NoMethodError).  For MySQL/Trilogy
      # it keeps the primary connection alive so the first write after
      # many reads doesn't hit a stale/timed-out socket.
      connect! unless connected?

      replica = ResilientReads.replica_pool.next_healthy

      unless replica
        ResilientReads.log_query("primary", sql, args.first, reason: "no healthy replicas")
        return execute_on_primary(sql, ctx, *args, **kwargs)
      end

      # Optional lag check — uses cached value to avoid querying on every request.
      if ResilientReads.config.max_lag
        lag = replica.cached_lag
        if lag && lag > ResilientReads.config.max_lag
          if ResilientReads.config.lag_failover
            ResilientReads.log_query("primary", sql, args.first, reason: "replica '#{replica.name}' lag #{lag.round(1)}s > max #{ResilientReads.config.max_lag}s")
            return execute_on_primary(sql, ctx, *args, **kwargs)
          else
            raise TooMuchLag, "Replication lag is #{lag.round(1)}s (max #{ResilientReads.config.max_lag}s)"
          end
        end
      end

      # Re-entrancy guard: prevent recursive routing when the replica
      # connection is being established (its init queries should not
      # be routed again).
      ctx[:on_replica] = true
      ctx[:routing] = true
      begin
        ResilientReads.log_query(replica.name, sql, args.first)
        result = replica.connection.raw_execute(sql, *args, **kwargs)
        ctx[:routing] = false
        result
      rescue ActiveRecord::ConnectionNotEstablished,
        ActiveRecord::StatementInvalid,
        ActiveRecord::ConnectionFailed => e
        ctx[:routing] = false
        raise unless connection_level_error?(e)

        ResilientReads.replica_pool.mark_unhealthy(replica)
        ResilientReads.log(:warn, "Replica '#{replica.name}' failed (#{e.class}), trying next")

        # One retry on a different replica
        retry_replica = ResilientReads.replica_pool.next_healthy
        if retry_replica
          begin
            ctx[:routing] = true
            ResilientReads.log_query(retry_replica.name, sql, args.first, reason: "retry after '#{replica.name}' failed")
            result = retry_replica.connection.raw_execute(sql, *args, **kwargs)
            ctx[:routing] = false
            return result
          rescue => retry_err
            ctx[:routing] = false
            ResilientReads.replica_pool.mark_unhealthy(retry_replica)
            ResilientReads.log(:warn, "Retry replica '#{retry_replica.name}' also failed: #{retry_err.message}")
          end
        end

        if ResilientReads.config.failover
          ResilientReads.log_query("primary", sql, args.first, reason: "all replicas exhausted")
          execute_on_primary(sql, ctx, *args, **kwargs)
        else
          raise NoHealthyReplica, "No healthy replicas available and failover is disabled"
        end
      ensure
        ctx[:on_replica] = false
        ctx[:routing] = false
        replica&.release_connection rescue nil
      end
    end

    def execute_on_primary(sql, ctx, *args, **kwargs)
      ctx[:distributing] = false
      raw_execute(sql, *args, **kwargs)
    ensure
      ctx[:distributing] = true
    end

    def connection_level_error?(error)
      case error
      when ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed
        true
      when ActiveRecord::StatementInvalid
        cause = error.cause
        cause.is_a?(PG::Error) ||
          cause.is_a?(IOError) ||
          cause.is_a?(Errno::ETIMEDOUT) ||
          cause.is_a?(Errno::ECONNRESET) ||
          cause.is_a?(Errno::EPIPE) ||
          cause.is_a?(Errno::ECONNREFUSED) ||
          (defined?(PG::ConnectionBad) && cause.is_a?(PG::ConnectionBad)) ||
          (defined?(Trilogy::Error) && cause.is_a?(Trilogy::Error)) ||
          (defined?(Mysql2::Error) && cause.is_a?(Mysql2::Error))
      else
        false
      end
    end
  end
end
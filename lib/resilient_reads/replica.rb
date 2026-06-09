module ResilientReads
  class Replica
    attr_reader :name, :connection_class

    def initialize(name, connection_class)
      @name = name.to_s
      @connection_class = connection_class
      @healthy = true
      @failure_count = 0
      @last_check_at = nil
      @last_lag = nil
      @last_lag_check_at = nil
      @mutex = Mutex.new
    end

    def healthy?
      @mutex.synchronize { @healthy }
    end

    def mark_healthy!
      @mutex.synchronize do
        was_unhealthy = !@healthy
        @healthy = true
        @failure_count = 0
        @last_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ResilientReads.log(:info, "Replica '#{@name}' recovered") if was_unhealthy
      end
    end

    def mark_unhealthy!
      @mutex.synchronize do
        was_healthy = @healthy
        @healthy = false
        @failure_count += 1
        @last_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ResilientReads.log(:warn, "Replica '#{@name}' marked unhealthy (failure ##{@failure_count})") if was_healthy
      end
    end

    def failure_count
      @mutex.synchronize { @failure_count }
    end

    # Returns the cached lag value if still fresh, otherwise queries the
    # replica for the current replication lag.  The TTL is controlled by
    # +ResilientReads.config.lag_check_interval+ (default 5 s).
    def cached_lag
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ttl = ResilientReads.config.lag_check_interval

      @mutex.synchronize do
        if @last_lag_check_at && (now - @last_lag_check_at) < ttl
          return @last_lag
        end
      end

      lag = LagChecker.lag_for(self)

      @mutex.synchronize do
        @last_lag = lag
        @last_lag_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      lag
    end

    # Invalidate the cached lag so the next call to +cached_lag+ re-queries.
    def invalidate_lag_cache!
      @mutex.synchronize do
        @last_lag_check_at = nil
        @last_lag = nil
      end
    end

    def connection
      @connection_class.connection
    end

    def connection_pool
      @connection_class.connection_pool
    end

    def release_connection
      @connection_class.connection_pool.release_connection
    end

    # Verify the replica is reachable. Returns true/false and updates health.
    def check_health!
      @connection_class.connection.execute("SELECT 1")
      mark_healthy!
      true
    rescue => e
      mark_unhealthy!
      ResilientReads.log(:debug, "Health check failed for '#{@name}': #{e.message}")
      false
    ensure
      release_connection rescue nil
    end
  end
end

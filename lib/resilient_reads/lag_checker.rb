module ResilientReads
  module LagChecker
    # Returns the replication lag in seconds for a replica.
    # Supports PostgreSQL and MySQL/MariaDB.
    # Returns 0 when the replica is fully caught up, nil on error.
    def self.lag_for(replica)
      conn = replica.connection
      adapter_name = conn.adapter_name.downcase

      if adapter_name.include?("postgresql")
        lag_for_postgresql(conn)
      elsif adapter_name.include?("mysql") || adapter_name.include?("trilogy")
        lag_for_mysql(conn)
      else
        ResilientReads.log(:debug, "Lag check not supported for adapter '#{adapter_name}'")
        nil
      end
    rescue => e
      ResilientReads.log(:debug, "Lag check failed for '#{replica.name}': #{e.message}")
      nil
    ensure
      replica.release_connection rescue nil
    end

    # Convenience: check replication lag using the default reading connection.
    def self.replication_lag
      replica = ResilientReads.replica_pool.next_healthy
      return nil unless replica

      lag_for(replica)
    end

    private

    def self.lag_for_postgresql(conn)
      result = conn.execute(<<~SQL)
        SELECT CASE
          WHEN pg_last_wal_receive_lsn() IS NULL THEN NULL
          WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
          ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())::float
        END AS lag
      SQL
      lag = result.first&.fetch("lag", nil)
      lag&.to_f
    end

    def self.lag_for_mysql(conn)
      result = conn.execute("SHOW REPLICA STATUS")
      # MySQL 8.0.22+ uses SHOW REPLICA STATUS

      row = if result.respond_to?(:first)
              result.first
      elsif result.respond_to?(:to_a)
              result.to_a.first
      end

      return nil unless row

      # Seconds_Behind_Master / Seconds_Behind_Source (MySQL 8.0.22+)
      lag =
        if row.is_a?(Hash)
              row["Seconds_Behind_Source"]
        elsif row.respond_to?(:[])
              row["Seconds_Behind_Source"]
        end

      lag&.to_f
    rescue => e
      ResilientReads.log(:debug, "MySQL lag check failed: #{e.message}")
      nil
    end
  end
end

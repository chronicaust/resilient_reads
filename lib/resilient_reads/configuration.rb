module ResilientReads
  class Configuration
    # When true, all reads are distributed to replicas by default (via middleware).
    attr_accessor :by_default

    # When true, ActiveRecord::Relation returned from distribute_reads blocks
    # are automatically loaded to ensure execution on the replica.
    attr_accessor :eager_load

    # Load balancing strategy: :round_robin or :random
    attr_accessor :balancing_strategy

    # Seconds between background health checks on replicas.
    attr_accessor :health_check_interval

    # Maximum acceptable replication lag in seconds. nil = no check.
    attr_accessor :max_lag

    # Seconds to cache the lag check result per replica. Prevents querying
    # the replica for lag on every single read. Default: 5.
    attr_accessor :lag_check_interval

    # When true and max_lag is set, queries fall back to primary instead of raising.
    attr_accessor :lag_failover

    # When true, queries fall back to primary if no healthy replicas are available.
    # When false, raises ResilientReads::NoHealthyReplica.
    attr_accessor :failover

    # Logger instance. Defaults to Rails.logger when available.
    attr_accessor :logger

    # When true, logs which connection (primary / replica name) handled each
    # query routed through the adapter patch.
    # Set to false to silence per-query routing logs.
    attr_accessor :log_query_routing

    # Log level for per-query routing messages. Defaults to :info so messages
    # appear in standard Rails development/production logs.
    # Set to :debug if the output is too noisy.
    attr_accessor :log_query_level

    # Explicit list of replica database config names (symbols).
    # Example: [:replica, :replica2, :replica3]
    # When nil, replicas are auto-detected from database.yml.
    attr_accessor :replicas

    # When true and replicas is nil, auto-detect replica configs from database.yml.
    attr_accessor :auto_detect_replicas

    # Regex pattern for auto-detecting replica config names.
    # Only configs matching this pattern AND having replica: true are used.
    attr_accessor :replica_pattern

    # Seconds to keep using primary after a write (read-your-own-write protection).
    attr_accessor :primary_delay

    # Hash of default options for distribute_reads blocks.
    attr_accessor :default_options

    # When true, caches SQL pattern-matching results (write_query? /
    # skip_replica_routing?) in an in-memory LRU cache so the regex
    # doesn't run on every identical query string.
    attr_accessor :query_cache_enabled

    # Maximum number of entries in the SQL pattern cache.
    attr_accessor :query_cache_max_size

    # When true (default), a write inside a distribute_reads block causes
    # all subsequent reads in the same block to go to primary.  This
    # prevents stale-read → conflicting-write chains that cause deadlocks,
    # especially with transactionless writes like update_column.
    attr_accessor :sticky_writes

    def initialize
      @by_default = false
      @eager_load = false
      @balancing_strategy = :round_robin
      @health_check_interval = 30
      @max_lag = nil
      @lag_check_interval = 5
      @lag_failover = false
      @failover = true
      @logger = nil
      @log_query_routing = true
      @log_query_level = :info
      @replicas = nil
      @auto_detect_replicas = true
      @replica_pattern = /\Areplica\d*\z/
      @primary_delay = 2
      @default_options = {}
      @query_cache_enabled = true
      @query_cache_max_size = 10_000
      @sticky_writes = true
    end
  end
end
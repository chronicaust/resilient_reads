require "active_support"
require "active_record"

require_relative "resilient_reads/version"
require_relative "resilient_reads/configuration"
require_relative "resilient_reads/replica"
require_relative "resilient_reads/replica_pool"
require_relative "resilient_reads/health_checker"
require_relative "resilient_reads/lag_checker"
require_relative "resilient_reads/query_cache"
require_relative "resilient_reads/adapter_patch"
require_relative "resilient_reads/middleware"
require_relative "resilient_reads/active_job_extension"

module ResilientReads
  class TooMuchLag < StandardError; end
  class NoHealthyReplica < StandardError; end

  # SQL patterns that indicate a write operation (PostgreSQL + MySQL/MariaDB).
  WRITE_PATTERN = /\A\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE|LOCK\s+TABLE|SET\s|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|COPY\s|REPLACE\s|LOAD\s+DATA|CALL\s)/i

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def replica_pool
      @replica_pool ||= ReplicaPool.new
    end

    def health_checker
      @health_checker
    end

    # -------------------------------------------------------------------
    # Core entry point — wraps a block so read queries go to a replica.
    # -------------------------------------------------------------------
    def run(**options, &block)
      opts = config.default_options.merge(options)

      # Explicit primary override
      if opts[:primary]
        return block.call
      end

      # No replicas configured — just run on primary.
      if replica_pool.empty? || !replica_pool.any_healthy?
        if opts.fetch(:failover, config.failover)
          return block.call
        else
          raise NoHealthyReplica, "No healthy replicas available"
        end
      end

      prev_ctx = Thread.current[:resilient_reads_context]
      Thread.current[:resilient_reads_context] = {
        distributing: true,
        on_replica: false,
        routing: false,
        stick_to_primary: false,
        options: opts
      }

      begin
        result = block.call
        if config.eager_load && result.is_a?(ActiveRecord::Relation) && !result.loaded?
          result = result.load
        end
        result
      ensure
        Thread.current[:resilient_reads_context] = prev_ctx
        replica_pool.release_all_connections
      end
    end

    # Are we currently inside a distribute_reads block?
    def distributing?
      ctx = Thread.current[:resilient_reads_context]
      ctx && ctx[:distributing]
    end

    # Convenience: get current replication lag (seconds).
    def replication_lag
      LagChecker.replication_lag
    end

    def query_cache
      @query_cache ||= QueryCache.new(
        max_size: config.query_cache_max_size
      )
    end

    def write_query?(sql)
      if config.query_cache_enabled
        query_cache.fetch(sql) { |s| WRITE_PATTERN.match?(s) }
      else
        WRITE_PATTERN.match?(sql)
      end
    end

    # Clear cached SQL pattern results.
    def bust_query_cache!
      @query_cache&.clear!
    end

    def log(level, message)
      logger = config.logger
      return unless logger

      # logger.public_send(level, "[ResilientReads] #{message}")
    rescue
      # Never let logging break query flow.
    end

    # Per-query routing log.  Only emits when config.log_query_routing is true.
    # Uses config.log_query_level (default :info) so messages are visible in
    # standard Rails development/production logs.
    #
    # Output example:
    #   [ResilientReads] → replica 'replica1' | User Load | SELECT "users".* …
    #   [ResilientReads] → primary (write query) | User Create | INSERT INTO …
    def log_query(connection_name, sql, query_name = nil, reason: nil)
      return unless config.log_query_routing

      logger = config.logger
      return unless logger

      label = if connection_name == "primary"
                reason ? "primary (#{reason})" : "primary"
      else
                reason ? "replica '#{connection_name}' (#{reason})" : "replica '#{connection_name}'"
      end

      truncated_sql = sql.length > 120 ? "#{sql[0, 120]}…" : sql
      parts = [ "[ResilientReads] → #{label}" ]
      parts << query_name if query_name && !query_name.empty?
      parts << truncated_sql.gsub(/\s+/, " ").strip
      logger.public_send(config.log_query_level, parts.join(" | "))
    rescue
      # Never let logging break query flow.
    end

    # ---------------------------------------------------------------
    # Setup helpers (called from Railtie or manually in non-Rails apps)
    # ---------------------------------------------------------------

    def setup_replicas!
      names = replica_config_names

      if names.empty?
        log(:info, "No replica configs detected (pattern: #{config.replica_pattern.inspect}). All reads will use primary.")
        return
      end

      names.each do |name|
        klass = build_replica_class(name)
        replica = Replica.new(name, klass)
        replica_pool.add(replica)
      end

      # Initial health probe — failures are non-fatal.
      replica_pool.each do |r|
        r.check_health!
      rescue => e
        log(:warn, "Initial health check for '#{r.name}' failed: #{e.message}")
      end

      log(:info, "Configured #{replica_pool.size} replica(s): #{names.join(', ')} " \
                 "(#{replica_pool.healthy_count} healthy)")
    end

    def patch_adapter!
      patched = []
      if defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(AdapterPatch)
        patched << "PostgreSQLAdapter"
      end
      if defined?(ActiveRecord::ConnectionAdapters::Mysql2Adapter)
        ActiveRecord::ConnectionAdapters::Mysql2Adapter.prepend(AdapterPatch)
        patched << "Mysql2Adapter"
      end
      if defined?(ActiveRecord::ConnectionAdapters::TrilogyAdapter)
        ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(AdapterPatch)
        patched << "TrilogyAdapter"
      end

      log(:debug, "Patched adapters: #{patched.join(', ')}") if patched.any?
    end

    def start_health_checker!
      return if replica_pool.empty?

      @health_checker = HealthChecker.new(
        replica_pool,
        interval: config.health_check_interval
      )
      @health_checker.start
    end

    def stop_health_checker!
      @health_checker&.stop
    end

    def restart_health_checker!
      stop_health_checker!
      start_health_checker!
    end

    private

    def replica_config_names
      if config.replicas
        Array(config.replicas).map(&:to_sym)
      elsif config.auto_detect_replicas
        detect_replicas
      else
        []
      end
    end

    def detect_replicas
      env = defined?(Rails) ? Rails.env : ENV.fetch("RAILS_ENV", "development")
      # include_hidden: true is required because Rails hides replica configs
      # by default (they have database_tasks: false).
      configs = ActiveRecord::Base.configurations.configs_for(env_name: env, include_hidden: true)
      detected = configs.select { |c| c.replica? && c.name.to_s.match?(config.replica_pattern) }
                        .map { |c| c.name.to_sym }
      log(:debug, "detect_replicas: found #{configs.size} configs, #{detected.size} matched replica pattern")
      detected
    end

    # Creates an abstract AR class with its own connection pool pointing
    # at the given replica database config.  This avoids touching the
    # main ApplicationRecord pool.
    def build_replica_class(name)
      klass = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
      end
      class_name = "ReplicaConnection#{name.to_s.camelize}"
      const_set(class_name, klass) unless const_defined?(class_name)

      begin
        klass.establish_connection(name)
      rescue => e
        log(:warn, "Could not establish connection for replica '#{name}': #{e.message}")
      end

      klass
    end
  end
end

# -----------------------------------------------------------------------
# Global helper — available everywhere just like the original gem.
# -----------------------------------------------------------------------
module ResilientReadsGlobal
  def distribute_reads(**options, &block)
    ResilientReads.run(**options, &block)
  end

  def resilient_reads(**options, &block)
    ResilientReads.run(**options, &block)
  end
end

Object.include ResilientReadsGlobal

# Backward-compatible constant so existing initializers using
# DistributeReads.eager_load = true etc. still work.
module DistributeReads
  class TooMuchLag < ResilientReads::TooMuchLag; end

  class << self
    def eager_load=(val)
      ResilientReads.config.eager_load = val
    end

    def eager_load
      ResilientReads.config.eager_load
    end

    def by_default=(val)
      ResilientReads.config.by_default = val
    end

    def by_default
      ResilientReads.config.by_default
    end

    def default_options=(val)
      ResilientReads.config.default_options = val
    end

    def default_options
      ResilientReads.config.default_options
    end

    def logger=(val)
      ResilientReads.config.logger = val
    end

    def logger
      ResilientReads.config.logger
    end

    def replication_lag
      ResilientReads.replication_lag
    end
  end
end

# ActiveJob integration
ActiveSupport.on_load(:active_job) do
  include ResilientReads::ActiveJobExtension
end

# Railtie auto-loads when Rails is present.
require_relative "resilient_reads/railtie" if defined?(Rails::Railtie)

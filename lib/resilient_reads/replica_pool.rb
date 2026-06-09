module ResilientReads
  class ReplicaPool
    attr_reader :replicas

    def initialize
      @replicas = []
      @mutex = Mutex.new
      @rr_index = 0
    end

    def add(replica)
      @mutex.synchronize { @replicas << replica }
    end

    def size
      @replicas.size
    end

    def empty?
      @replicas.empty?
    end

    # Select the next healthy replica using the configured strategy.
    # Returns nil when no healthy replica is available.
    def next_healthy
      @mutex.synchronize do
        healthy = @replicas.select(&:healthy?)
        return nil if healthy.empty?

        case ResilientReads.config.balancing_strategy
        when :round_robin
          idx = @rr_index % healthy.size
          @rr_index += 1
          healthy[idx]
        when :random
          healthy.sample
        else
          healthy.first
        end
      end
    end

    def any_healthy?
      @replicas.any?(&:healthy?)
    end

    def healthy_count
      @replicas.count(&:healthy?)
    end

    def mark_unhealthy(replica)
      replica.mark_unhealthy!
    end

    def check_all_health!
      @replicas.each(&:check_health!)
    end

    def release_all_connections
      @replicas.each do |r|
        r.release_connection rescue nil
      end
    end

    def each(&block)
      @replicas.each(&block)
    end
  end
end

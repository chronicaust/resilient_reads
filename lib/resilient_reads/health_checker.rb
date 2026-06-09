module ResilientReads
  # Background thread that periodically verifies replica reachability.
  # Unhealthy replicas are re-checked so they can be restored to the pool
  # once they recover.
  class HealthChecker
    def initialize(replica_pool, interval:)
      @replica_pool = replica_pool
      @interval = interval
      @thread = nil
      @running = false
    end

    def start
      return if @replica_pool.empty?

      # Prevent duplicate threads — stop any existing thread first.
      stop if @running || @thread&.alive?

      @running = true
      @thread = Thread.new { run_loop }
      @thread.name = "resilient_reads_health"
      @thread.abort_on_exception = false
      @thread.report_on_exception = false
    end

    def stop
      @running = false
      @thread&.wakeup rescue nil
      @thread&.join(5) rescue nil
      @thread = nil
    end

    def running?
      @running && @thread&.alive?
    end

    private

    def run_loop
      while @running
        sleep @interval
        check_all
      end
    rescue => e
      ResilientReads.log(:error, "Health checker crashed: #{e.message}")
      retry if @running
    end

    def check_all
      @replica_pool.each do |replica|
        replica.check_health!
      end
    rescue => e
      ResilientReads.log(:error, "Health check cycle error: #{e.message}")
    end
  end
end

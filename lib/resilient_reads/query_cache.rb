require "digest"

module ResilientReads
  # Caches SQL pattern-matching results (read vs write classification) so
  # the regex does not need to run on every identical query string.
  #
  # Mirrors the caching concept from active_record_proxy_adapters but is
  # simpler — we only cache the boolean result of +write_query?+ and
  # +skip_replica_routing?+ keyed by the SQL string.
  #
  # Thread-safe via a Mutex around the internal Hash. Uses an LRU eviction
  # strategy when the cache exceeds +max_size+.
  class QueryCache
    DEFAULT_MAX_SIZE = 10_000

    attr_reader :max_size, :key_prefix

    def initialize(max_size: DEFAULT_MAX_SIZE, key_prefix: "rr_")
      @max_size = max_size
      @key_prefix = key_prefix
      @store = {}
      @mutex = Mutex.new
      @hits = 0
      @misses = 0
    end

    # Fetch a cached value or compute it from the block.
    # The block receives the SQL and should return the value to cache.
    #
    #   cache.fetch(sql) { |s| ResilientReads.write_query?(s) }
    #
    def fetch(sql)
      key = cache_key(sql)

      @mutex.synchronize do
        if @store.key?(key)
          @hits += 1
          # Move to end (most recently used)
          value = @store.delete(key)
          @store[key] = value
          return value
        end
      end

      value = yield(sql)

      @mutex.synchronize do
        @misses += 1
        @store[key] = value
        evict! if @store.size > @max_size
      end

      value
    end

    def size
      @mutex.synchronize { @store.size }
    end

    def stats
      @mutex.synchronize { { hits: @hits, misses: @misses, size: @store.size } }
    end

    def clear!
      @mutex.synchronize do
        @store.clear
        @hits = 0
        @misses = 0
      end
    end

    private

    def cache_key(sql)
      "#{@key_prefix}#{Digest::SHA2.hexdigest(sql)}"
    end

    # Evict the oldest 25% of entries when over capacity.
    def evict!
      evict_count = @store.size / 4
      evict_count = 1 if evict_count < 1
      evict_count.times { @store.shift }
    end
  end
end

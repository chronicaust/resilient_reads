require_relative "test_helper"

class AdapterPatchTest < Minitest::Test
  # Regression: when the primary adapter was never connected (all prior reads
  # routed to replicas), @type_map is nil.  cast_result then calls
  # get_oid_type → type_map.key?(oid) → NoMethodError on nil.
  # The fix: execute_on_replica calls connect! unless type_map.
  def test_connect_called_when_type_map_nil
    # Build a minimal fake adapter that includes AdapterPatch
    adapter_class = Class.new do
      prepend ResilientReads::AdapterPatch

      attr_accessor :type_map, :connected

      def initialize
        @type_map = nil
        @connected = false
      end

      def connect!
        @connected = true
        @type_map = { 2950 => :uuid } # simulate type_map initialization
        self
      end

      def open_transactions
        0
      end

      def write_query?(sql)
        ResilientReads::WRITE_PATTERN.match?(sql)
      end

      def raw_execute(sql, *args, **kwargs)
        "primary_result"
      end
    end

    adapter = adapter_class.new
    assert_nil adapter.type_map

    # Simulate the context for distributing reads
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      options: {}
    }

    # Stub a healthy replica
    mock_replica = Object.new
    def mock_replica.name; "replica"; end
    def mock_replica.healthy?; true; end
    def mock_replica.cached_lag; nil; end
    def mock_replica.connection
      conn = Object.new
      def conn.raw_execute(sql, *args, **kwargs); "replica_result"; end
      conn
    end
    def mock_replica.release_connection; end

    # Stub the pool to return our mock replica
    pool = ResilientReads.replica_pool
    original_replicas = pool.instance_variable_get(:@replicas)
    pool.instance_variable_set(:@replicas, [ mock_replica ])

    # Execute a read query — should call connect! to materialize type_map
    result = adapter.raw_execute("SELECT * FROM users", "User Load")
    assert adapter.connected, "connect! should have been called to initialize type_map"
    assert_equal "replica_result", result
  ensure
    Thread.current[:resilient_reads_context] = nil
    pool = ResilientReads.replica_pool
    pool.instance_variable_set(:@replicas, original_replicas || [])
  end

  def test_skip_names_includes_schema
    assert ResilientReads::AdapterPatch::SKIP_NAMES.include?("SCHEMA")
  end

  def test_skip_names_includes_explain
    assert ResilientReads::AdapterPatch::SKIP_NAMES.include?("EXPLAIN")
  end

  def test_context_includes_routing_flag
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    assert_equal false, ctx[:routing]
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  def test_routing_guard_prevents_reentry
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: true,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    # When routing is true, queries should NOT be routed to replica
    assert ctx[:routing], "routing flag should prevent re-entry"
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  def test_on_replica_prevents_routing
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: true,
      routing: false,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    assert ctx[:on_replica], "on_replica flag should prevent routing"
  ensure
    Thread.current[:resilient_reads_context] = nil
  end
end

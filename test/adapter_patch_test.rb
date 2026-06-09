require_relative "test_helper"

class AdapterPatchTest < Minitest::Test
  # Regression: when the primary adapter was never connected (all prior reads
  # routed to replicas), the primary may be uninitialized.
  # For PostgreSQL: @type_map is nil → cast_result → NoMethodError.
  # For MySQL/Trilogy: stale primary socket → hang on first write.
  # The fix: execute_on_replica calls connect! unless connected?.
  def test_connect_called_when_not_connected
    adapter_class = Class.new do
      prepend ResilientReads::AdapterPatch

      attr_accessor :is_connected

      def initialize
        @is_connected = false
      end

      def connected?
        @is_connected
      end

      def connect!
        @is_connected = true
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
    refute adapter.connected?

    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: false,
      options: {}
    }

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

    pool = ResilientReads.replica_pool
    original_replicas = pool.instance_variable_get(:@replicas)
    pool.instance_variable_set(:@replicas, [ mock_replica ])

    result = adapter.raw_execute("SELECT * FROM users", "User Load")
    assert adapter.connected?, "connect! should have been called to initialize primary"
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
      stick_to_primary: false,
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
      stick_to_primary: false,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    assert ctx[:routing], "routing flag should prevent re-entry"
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  def test_on_replica_prevents_routing
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: true,
      routing: false,
      stick_to_primary: false,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    assert ctx[:on_replica], "on_replica flag should prevent routing"
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  # --- Sticky writes ---

  def test_stick_to_primary_flag_initialized_false
    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: false,
      options: {}
    }
    ctx = Thread.current[:resilient_reads_context]
    assert_equal false, ctx[:stick_to_primary]
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  def test_sticky_writes_sets_flag_on_write
    adapter_class = build_tracking_adapter
    adapter = adapter_class.new

    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: false,
      options: {}
    }

    ResilientReads.config.sticky_writes = true
    adapter.raw_execute("UPDATE users SET name = 'test'", "User Update")

    ctx = Thread.current[:resilient_reads_context]
    assert ctx[:stick_to_primary], "stick_to_primary should be true after a write"
  ensure
    Thread.current[:resilient_reads_context] = nil
    ResilientReads.config.sticky_writes = true
  end

  def test_sticky_writes_disabled_does_not_set_flag
    adapter_class = build_tracking_adapter
    adapter = adapter_class.new

    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: false,
      options: {}
    }

    ResilientReads.config.sticky_writes = false
    adapter.raw_execute("UPDATE users SET name = 'test'", "User Update")

    ctx = Thread.current[:resilient_reads_context]
    refute ctx[:stick_to_primary], "stick_to_primary should remain false when sticky_writes is disabled"
  ensure
    Thread.current[:resilient_reads_context] = nil
    ResilientReads.config.sticky_writes = true
  end

  def test_stick_to_primary_prevents_replica_routing
    adapter_class = build_tracking_adapter
    adapter = adapter_class.new

    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: true,
      options: {}
    }

    # Even a SELECT should go to primary when stick_to_primary is set
    adapter.raw_execute("SELECT * FROM users", "User Load")
    assert_includes adapter.executed_on_primary, "SELECT * FROM users"
  ensure
    Thread.current[:resilient_reads_context] = nil
  end

  # --- Locking reads ---

  def test_locking_clause_pattern_matches_for_update
    assert ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users FOR UPDATE")
  end

  def test_locking_clause_pattern_matches_for_share
    assert ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users FOR SHARE")
  end

  def test_locking_clause_pattern_matches_lock_in_share_mode
    assert ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users LOCK IN SHARE MODE")
  end

  def test_locking_clause_pattern_matches_for_no_key_update
    assert ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users FOR NO KEY UPDATE")
  end

  def test_locking_clause_pattern_matches_for_key_share
    assert ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users FOR KEY SHARE")
  end

  def test_locking_clause_pattern_does_not_match_normal_select
    refute ResilientReads::AdapterPatch::LOCKING_CLAUSE_PATTERN.match?("SELECT * FROM users WHERE id = 1")
  end

  def test_locking_read_routed_to_primary
    adapter_class = build_tracking_adapter
    adapter = adapter_class.new

    pool = ResilientReads.replica_pool
    original_replicas = pool.instance_variable_get(:@replicas)
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
    pool.instance_variable_set(:@replicas, [ mock_replica ])

    Thread.current[:resilient_reads_context] = {
      distributing: true,
      on_replica: false,
      routing: false,
      stick_to_primary: false,
      options: {}
    }

    adapter.raw_execute("SELECT * FROM users FOR UPDATE", "User Load")
    assert_includes adapter.executed_on_primary, "SELECT * FROM users FOR UPDATE"
  ensure
    Thread.current[:resilient_reads_context] = nil
    pool.instance_variable_set(:@replicas, original_replicas || [])
  end

  private

  # Builds a fake adapter class that tracks which queries hit primary
  def build_tracking_adapter
    Class.new do
      prepend ResilientReads::AdapterPatch

      attr_reader :executed_on_primary

      def initialize
        @executed_on_primary = []
      end

      def connected?
        true
      end

      def connect!
        self
      end

      def open_transactions
        0
      end

      def write_query?(sql)
        ResilientReads::WRITE_PATTERN.match?(sql)
      end

      def raw_execute(sql, *args, **kwargs)
        @executed_on_primary << sql
        "primary_result"
      end
    end
  end
end
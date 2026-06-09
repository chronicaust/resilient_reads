require_relative "test_helper"

class LagCacheTest < Minitest::Test
  def setup
    @mock_class = Class.new do
      def connection; self; end
      def connection_pool; self; end
      def release_connection; end
      def execute(_sql); [ { "lag" => "0.5" } ]; end
      def adapter_name; "PostgreSQL"; end
    end.new

    @replica = ResilientReads::Replica.new(:test_replica, @mock_class)
    ResilientReads.config.lag_check_interval = 5
  end

  def test_invalidate_lag_cache
    # Populate cache
    @replica.instance_variable_set(:@last_lag, 1.5)
    @replica.instance_variable_set(:@last_lag_check_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    @replica.invalidate_lag_cache!
    assert_nil @replica.instance_variable_get(:@last_lag)
    assert_nil @replica.instance_variable_get(:@last_lag_check_at)
  end

  def test_cached_lag_returns_cached_value_within_ttl
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @replica.instance_variable_set(:@last_lag, 2.0)
    @replica.instance_variable_set(:@last_lag_check_at, now)

    # Should return cached value without calling LagChecker
    lag = @replica.cached_lag
    assert_equal 2.0, lag
  end

  def test_lag_check_interval_config_default
    config = ResilientReads::Configuration.new
    assert_equal 5, config.lag_check_interval
  end

  def test_lag_check_interval_configurable
    ResilientReads.config.lag_check_interval = 10
    assert_equal 10, ResilientReads.config.lag_check_interval
  ensure
    ResilientReads.config.lag_check_interval = 5
  end
end

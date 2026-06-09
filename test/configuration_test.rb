require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @config = ResilientReads::Configuration.new
  end

  def test_defaults
    assert_equal false, @config.by_default
    assert_equal false, @config.eager_load
    assert_equal :round_robin, @config.balancing_strategy
    assert_equal 30, @config.health_check_interval
    assert_nil @config.max_lag
    assert_equal false, @config.lag_failover
    assert_equal true, @config.failover
    assert_nil @config.logger
    assert_equal true, @config.log_query_routing
    assert_equal :info, @config.log_query_level
    assert_nil @config.replicas
    assert_equal true, @config.auto_detect_replicas
    assert_equal 2, @config.primary_delay
    assert_equal({}, @config.default_options)
    assert_equal true, @config.sticky_writes
  end

  def test_sticky_writes_configurable
    @config.sticky_writes = false
    assert_equal false, @config.sticky_writes
  end

  def test_log_query_routing_can_be_disabled
    @config.log_query_routing = false
    assert_equal false, @config.log_query_routing
  end

  def test_configure_block
    ResilientReads.configure do |c|
      c.by_default = true
      c.eager_load = true
      c.balancing_strategy = :random
      c.max_lag = 5
    end

    assert_equal true, ResilientReads.config.by_default
    assert_equal true, ResilientReads.config.eager_load
    assert_equal :random, ResilientReads.config.balancing_strategy
    assert_equal 5, ResilientReads.config.max_lag
  ensure
    # Reset for other tests
    ResilientReads.instance_variable_set(:@config, ResilientReads::Configuration.new)
  end
end
require_relative "test_helper"

class BackwardCompatTest < Minitest::Test
  def setup
    ResilientReads.instance_variable_set(:@config, ResilientReads::Configuration.new)
  end

  def test_distribute_reads_module_exists
    assert defined?(DistributeReads)
  end

  def test_eager_load_delegates
    DistributeReads.eager_load = true
    assert_equal true, ResilientReads.config.eager_load
  ensure
    DistributeReads.eager_load = false
  end

  def test_by_default_delegates
    DistributeReads.by_default = true
    assert_equal true, ResilientReads.config.by_default
  ensure
    DistributeReads.by_default = false
  end

  def test_default_options_delegates
    DistributeReads.default_options = { max_lag: 3 }
    assert_equal({ max_lag: 3 }, ResilientReads.config.default_options)
  ensure
    DistributeReads.default_options = {}
  end

  def test_distribute_reads_global_method
    assert respond_to?(:distribute_reads)
  end

  def test_resilient_reads_global_method
    assert respond_to?(:resilient_reads)
  end

  def test_too_much_lag_error
    assert DistributeReads::TooMuchLag < ResilientReads::TooMuchLag
  end

  def test_distribute_reads_with_empty_pool_returns_block_value
    result = distribute_reads { 42 }
    assert_equal 42, result
  end

  def test_distribute_reads_primary_returns_block_value
    result = distribute_reads(primary: true) { "hello" }
    assert_equal "hello", result
  end
end

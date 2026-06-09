require_relative "test_helper"

class QueryCacheTest < Minitest::Test
  def setup
    @cache = ResilientReads::QueryCache.new(max_size: 5)
  end

  def test_caches_result
    result = @cache.fetch("SELECT 1") { |_| :read }
    assert_equal :read, result

    # Second call returns cached value without calling block
    block_called = false
    result2 = @cache.fetch("SELECT 1") { |_| block_called = true; :different }
    assert_equal :read, result2
    refute block_called
  end

  def test_different_queries_cached_separately
    @cache.fetch("SELECT 1") { |_| :read }
    @cache.fetch("INSERT INTO foo") { |_| :write }

    assert_equal 2, @cache.size
  end

  def test_stats_tracks_hits_and_misses
    @cache.fetch("SELECT 1") { |_| :read }
    @cache.fetch("SELECT 1") { |_| :read }
    @cache.fetch("SELECT 2") { |_| :read }

    stats = @cache.stats
    assert_equal 1, stats[:hits]
    assert_equal 2, stats[:misses]
    assert_equal 2, stats[:size]
  end

  def test_evicts_when_over_max_size
    6.times { |i| @cache.fetch("query_#{i}") { |_| :read } }

    # max_size is 5, so eviction should have removed oldest entries
    assert @cache.size <= 5
  end

  def test_clear_resets_cache
    @cache.fetch("SELECT 1") { |_| :read }
    @cache.clear!

    assert_equal 0, @cache.size
    stats = @cache.stats
    assert_equal 0, stats[:hits]
    assert_equal 0, stats[:misses]
  end

  def test_write_query_uses_cache_when_enabled
    ResilientReads.config.query_cache_enabled = true
    # Clear any prior cache state
    ResilientReads.bust_query_cache!

    assert ResilientReads.write_query?("INSERT INTO foo VALUES (1)")
    refute ResilientReads.write_query?("SELECT * FROM foo")

    # Verify cache was populated
    assert ResilientReads.query_cache.size > 0
  ensure
    ResilientReads.config.query_cache_enabled = true
  end

  def test_write_query_bypasses_cache_when_disabled
    ResilientReads.config.query_cache_enabled = false
    ResilientReads.bust_query_cache!

    assert ResilientReads.write_query?("INSERT INTO foo VALUES (1)")
    assert_equal 0, ResilientReads.query_cache.size
  ensure
    ResilientReads.config.query_cache_enabled = true
  end

  def test_bust_query_cache
    ResilientReads.config.query_cache_enabled = true
    ResilientReads.write_query?("SELECT 1")

    ResilientReads.bust_query_cache!
    assert_equal 0, ResilientReads.query_cache.size
  ensure
    ResilientReads.config.query_cache_enabled = true
  end
end

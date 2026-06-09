require_relative "test_helper"

class ReplicaPoolTest < Minitest::Test
  def setup
    @pool = ResilientReads::ReplicaPool.new
  end

  def test_empty_pool
    assert @pool.empty?
    assert_equal 0, @pool.size
    assert_nil @pool.next_healthy
    refute @pool.any_healthy?
  end

  def test_add_and_select
    r1 = mock_replica("replica1", healthy: true)
    r2 = mock_replica("replica2", healthy: true)
    @pool.add(r1)
    @pool.add(r2)

    assert_equal 2, @pool.size
    refute @pool.empty?
    assert @pool.any_healthy?
  end

  def test_round_robin_selection
    ResilientReads.config.balancing_strategy = :round_robin

    r1 = mock_replica("r1", healthy: true)
    r2 = mock_replica("r2", healthy: true)
    r3 = mock_replica("r3", healthy: true)
    @pool.add(r1)
    @pool.add(r2)
    @pool.add(r3)

    selections = 6.times.map { @pool.next_healthy.name }
    assert_equal %w[r1 r2 r3 r1 r2 r3], selections
  ensure
    ResilientReads.config.balancing_strategy = :round_robin
  end

  def test_skips_unhealthy
    r1 = mock_replica("r1", healthy: true)
    r2 = mock_replica("r2", healthy: false)
    @pool.add(r1)
    @pool.add(r2)

    assert_equal 1, @pool.healthy_count
    5.times { assert_equal "r1", @pool.next_healthy.name }
  end

  def test_returns_nil_when_all_unhealthy
    r1 = mock_replica("r1", healthy: false)
    @pool.add(r1)

    assert_nil @pool.next_healthy
    refute @pool.any_healthy?
  end

  def test_round_robin_with_many_replicas
    ResilientReads.config.balancing_strategy = :round_robin

    replicas = (1..10).map { |i| mock_replica("r#{i}", healthy: true) }
    replicas.each { |r| @pool.add(r) }

    assert_equal 10, @pool.size

    # 30 queries should cycle through all 10 replicas evenly (3 times each)
    selections = 30.times.map { @pool.next_healthy.name }
    expected = (1..10).map { |i| "r#{i}" } * 3
    assert_equal expected, selections
  end

  def test_round_robin_adjusts_when_replica_becomes_unhealthy
    ResilientReads.config.balancing_strategy = :round_robin

    r1 = mock_replica("r1", healthy: true)
    r2 = mock_replica("r2", healthy: true)
    r3 = mock_replica("r3", healthy: true)
    @pool.add(r1)
    @pool.add(r2)
    @pool.add(r3)

    # r2 goes down — should only rotate between r1 and r3
    r2.healthy_val = false
    assert_equal 2, @pool.healthy_count

    selections = 6.times.map { @pool.next_healthy.name }
    assert_equal %w[r1 r3 r1 r3 r1 r3], selections
  ensure
    ResilientReads.config.balancing_strategy = :round_robin
  end

  def test_random_strategy
    ResilientReads.config.balancing_strategy = :random

    r1 = mock_replica("r1", healthy: true)
    r2 = mock_replica("r2", healthy: true)
    @pool.add(r1)
    @pool.add(r2)

    selections = 20.times.map { @pool.next_healthy.name }
    assert_includes selections, "r1"
    assert_includes selections, "r2"
  ensure
    ResilientReads.config.balancing_strategy = :round_robin
  end

  private

  MockReplica = Struct.new(:name, :healthy_val, keyword_init: true) do
    def healthy?; healthy_val; end
    def release_connection; end
  end

  def mock_replica(name, healthy:)
    MockReplica.new(name: name, healthy_val: healthy)
  end
end

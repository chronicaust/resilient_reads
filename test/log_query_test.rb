require_relative "test_helper"
require "logger"
require "stringio"

class LogQueryTest < Minitest::Test
  def setup
    @output = StringIO.new
    @logger = Logger.new(@output, level: Logger::DEBUG)
    @logger.formatter = proc { |_sev, _dt, _prog, msg| "#{msg}\n" }
    @original_logger = ResilientReads.config.logger
    @original_routing = ResilientReads.config.log_query_routing
    @original_level = ResilientReads.config.log_query_level
    ResilientReads.config.logger = @logger
    ResilientReads.config.log_query_routing = true
    ResilientReads.config.log_query_level = :info
  end

  def teardown
    ResilientReads.config.logger = @original_logger
    ResilientReads.config.log_query_routing = @original_routing
    ResilientReads.config.log_query_level = @original_level
  end

  def test_logs_replica_query
    ResilientReads.log_query("replica1", 'SELECT * FROM users', "User Load")

    output = @output.string
    assert_includes output, "[ResilientReads]"
    assert_includes output, "replica 'replica1'"
    assert_includes output, "User Load"
    assert_includes output, "SELECT * FROM users"
  end

  def test_logs_primary_query
    ResilientReads.log_query("primary", 'INSERT INTO users (name) VALUES ($1)', "User Create", reason: "write query")

    output = @output.string
    assert_includes output, "primary (write query)"
    assert_includes output, "INSERT INTO users"
  end

  def test_logs_primary_fallback_with_reason
    ResilientReads.log_query("primary", 'SELECT 1', nil, reason: "no healthy replicas")

    output = @output.string
    assert_includes output, "primary (no healthy replicas)"
  end

  def test_logs_replica_with_reason
    ResilientReads.log_query("replica2", 'SELECT 1', "Health Check", reason: "retry after 'replica1' failed")

    output = @output.string
    assert_includes output, "replica 'replica2' (retry after 'replica1' failed)"
  end

  def test_truncates_long_sql
    long_sql = "SELECT " + "a, " * 100 + "b FROM users"
    ResilientReads.log_query("replica1", long_sql, "User Load")

    output = @output.string
    assert_includes output, "…"
    refute_includes output, long_sql
  end

  def test_no_logging_when_disabled
    ResilientReads.config.log_query_routing = false
    ResilientReads.log_query("replica1", 'SELECT * FROM users', "User Load")

    assert_empty @output.string
  end

  def test_no_logging_without_logger
    ResilientReads.config.logger = nil
    ResilientReads.log_query("replica1", 'SELECT * FROM users', "User Load")

    assert_empty @output.string
  end

  def test_log_query_level_default_is_info
    assert_equal :info, ResilientReads::Configuration.new.log_query_level
  end

  def test_respects_custom_log_query_level
    ResilientReads.config.log_query_level = :warn
    ResilientReads.log_query("replica1", 'SELECT 1', "Test")

    # Logger at DEBUG level should still capture :warn messages
    assert_includes @output.string, "replica 'replica1'"
  end
end

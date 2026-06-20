# frozen_string_literal: true

require "test_helper"

class TestResilientReads < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ResilientReads::VERSION
  end

  def test_write_query_detects_transaction_commands
    assert ResilientReads.write_query?("BEGIN")
    assert ResilientReads.write_query?("COMMIT")
    assert ResilientReads.write_query?("ROLLBACK")
    assert ResilientReads.write_query?("SET search_path TO public")
    refute ResilientReads.write_query?("SELECT 1")
  end
end

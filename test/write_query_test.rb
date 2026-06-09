require_relative "test_helper"

class WriteQueryTest < Minitest::Test
  def test_select_is_not_write
    refute ResilientReads.write_query?("SELECT * FROM users")
    refute ResilientReads.write_query?("  SELECT count(*) FROM orders")
    refute ResilientReads.write_query?("select 1")
    refute ResilientReads.write_query?("WITH cte AS (SELECT 1) SELECT * FROM cte")
    refute ResilientReads.write_query?("EXPLAIN SELECT * FROM users")
    refute ResilientReads.write_query?("SHOW server_version")
  end

  def test_insert_is_write
    assert ResilientReads.write_query?("INSERT INTO users (name) VALUES ('test')")
    assert ResilientReads.write_query?("  insert into users (name) values ('test')")
  end

  def test_update_is_write
    assert ResilientReads.write_query?("UPDATE users SET name = 'test'")
    assert ResilientReads.write_query?("  update users set name = 'test'")
  end

  def test_delete_is_write
    assert ResilientReads.write_query?("DELETE FROM users WHERE id = 1")
  end

  def test_ddl_is_write
    assert ResilientReads.write_query?("CREATE TABLE foo (id int)")
    assert ResilientReads.write_query?("ALTER TABLE foo ADD COLUMN bar text")
    assert ResilientReads.write_query?("DROP TABLE foo")
    assert ResilientReads.write_query?("TRUNCATE users")
  end

  def test_transaction_commands_are_write
    assert ResilientReads.write_query?("BEGIN")
    assert ResilientReads.write_query?("COMMIT")
    assert ResilientReads.write_query?("ROLLBACK")
    assert ResilientReads.write_query?("SAVEPOINT active_record_1")
    assert ResilientReads.write_query?("RELEASE SAVEPOINT active_record_1")
  end

  def test_set_is_write
    assert ResilientReads.write_query?("SET search_path TO public")
  end

  def test_mysql_replace_is_write
    assert ResilientReads.write_query?("REPLACE INTO users (id, name) VALUES (1, 'test')")
  end

  def test_mysql_load_data_is_write
    assert ResilientReads.write_query?("LOAD DATA INFILE '/tmp/data.csv' INTO TABLE users")
  end

  def test_mysql_call_is_write
    assert ResilientReads.write_query?("CALL my_stored_procedure()")
  end

  def test_mysql_show_is_not_write
    refute ResilientReads.write_query?("SHOW TABLES")
    refute ResilientReads.write_query?("SHOW SLAVE STATUS")
    refute ResilientReads.write_query?("SHOW VARIABLES LIKE 'read_only'")
  end

  def test_describe_is_not_write
    refute ResilientReads.write_query?("DESCRIBE users")
    refute ResilientReads.write_query?("DESC users")
  end
end

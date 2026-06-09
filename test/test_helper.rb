require "minitest/autorun"
require "active_record"
require "resilient_reads"

# Minimal test setup — no real DB needed for unit tests.
# Integration tests that need a DB should be run inside the Rails app.

# Resilient Reads

Distribute database reads across multiple replicas in Rails with **automatic load balancing**, **health checking**, and **graceful failover** to primary.

Drop-in replacement for [distribute_reads](https://github.com/ankane/distribute_reads) that adds:

- **Multiple replica support** with round-robin or random load balancing across any number of replicas
- **Graceful failover** — if a replica goes down, reads automatically fall back to primary. No boot crash.
- **Health monitoring** — background thread periodically re-checks unhealthy replicas and restores them
- **Per-query logging** — see exactly which connection (primary / replica name) handled each query
- **No proxy adapter needed** — works with the standard `postgresql`, `mysql2`, or `trilogy` adapters
- **Rails 7.1+ compatible** — works with Rails 7.1, 7.2, and 8.0+
- **Query pattern caching** — caches SQL read/write classification results in an LRU cache to avoid repeated regex matching
- **Lag check caching** — replication lag results are cached per-replica with a configurable TTL (default 5s) to avoid querying lag on every read
- **Backward compatible** — `distribute_reads { }` and `DistributeReads.by_default = true` still work

## Installation

Add to your Gemfile:

```ruby
gem "resilient_reads"
```

Remove any previous read-distribution gems:

```ruby
# Remove these:
# gem "distribute_reads"
# gem "active_record_proxy_adapters"
```

## Configuration

### database.yml

Use the **standard adapter** (`postgresql`, `mysql2`, or `trilogy`) for all connections. Mark replicas with `replica: true`:

```yaml
default: &default
  adapter: postgresql
  pool: 5

production:
  primary:
    <<: *default
    host: primary-db.example.com
    database: myapp_production
  replica:
    <<: *default
    host: replica1.example.com
    database: myapp_production
    replica: true
  replica2:
    <<: *default
    host: replica2.example.com
    database: myapp_production
    replica: true
  replica3:
    <<: *default
    host: replica3.example.com
    database: myapp_production
    replica: true
```

You can add as many replicas as you want — they are auto-detected by matching config names against `/replica\d*/` with `replica: true`. Or list them explicitly:

```ruby
config.replicas = [:replica, :replica2, :replica3]
```

### Initializer

```ruby
# config/initializers/resilient_reads.rb
ResilientReads.configure do |config|
  config.by_default = true             # Route all reads to replicas
  config.eager_load = true             # Auto-load lazy relations in blocks
  config.balancing_strategy = :round_robin  # :round_robin or :random
  config.health_check_interval = 30    # Seconds between health checks
  config.max_lag = nil                 # Max replication lag (seconds), nil to skip
  config.lag_failover = true           # Use primary when lag exceeds max
  config.failover = true               # Fall back to primary when replicas are down
  config.primary_delay = 2             # Seconds to use primary after a write
  config.log_query_routing = true      # Log which connection handled each query
  config.lag_check_interval = 5        # Seconds to cache lag check per replica
  config.query_cache_enabled = true    # Cache SQL pattern matching results
  config.query_cache_max_size = 10_000 # Max entries in the query cache
  config.sticky_writes = true          # After a write, reads stay on primary for the block
end
```

### Model

Keep your existing `connects_to` — the gem works alongside it:

```ruby
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  connects_to database: { writing: :primary, reading: :replica }
end
```

## Usage

### Explicit blocks

```ruby
distribute_reads { User.count }   # Reads from a healthy replica

distribute_reads do
  User.find_each do |user|
    user.orders_count = user.orders.count  # replica (SELECT)
    user.save!                             # primary (INSERT/UPDATE)
  end
end
```

### Options

```ruby
distribute_reads(primary: true) { ... }          # Force primary
distribute_reads(max_lag: 3) { ... }             # Override max lag
distribute_reads(max_lag: 3, lag_failover: true)  # Fallback on high lag
distribute_reads(failover: false) { ... }         # Raise if no replicas
```

### Jobs

```ruby
class ReportJob < ApplicationJob
  distribute_reads

  def perform
    # All reads go to replicas
  end
end
```

### By default

When `config.by_default = true`, a Rack middleware automatically wraps
GET/HEAD requests so all reads hit replicas. After a write (POST/PUT/etc),
reads stay on primary for `primary_delay` seconds (read-your-own-write).

## Query Routing Log

When `config.log_query_routing = true` (the default), every routed query is logged with the connection it used:

```
[ResilientReads] → replica 'replica' | User Load | SELECT "users".* FROM "users" WHERE …
[ResilientReads] → replica 'replica2' | Order Load | SELECT "orders".* FROM "orders" …
[ResilientReads] → primary (write query) | User Update | UPDATE "users" SET "name" = …
[ResilientReads] → primary (no healthy replicas) | User Load | SELECT "users".* …
```

This makes it easy to verify that load balancing is working and which replica handled each query. Set `config.log_query_routing = false` to disable.

## Query Pattern Caching

When `config.query_cache_enabled = true` (the default), the gem caches the result of SQL pattern matching (whether a query is a read or write) in an in-memory LRU cache. This avoids running the regex on every identical query string.

```ruby
# View cache stats
ResilientReads.query_cache.stats  # => { hits: 1234, misses: 56, size: 56 }

# Clear the cache manually
ResilientReads.bust_query_cache!
```

Disable with `config.query_cache_enabled = false`.

## Lag Check Caching

When `config.max_lag` is set, replication lag is checked for each replica. To avoid querying the replica for lag on **every single read**, the lag value is cached per-replica for `config.lag_check_interval` seconds (default 5). This means the actual lag query runs at most once every 5 seconds per replica, not on every read.

```ruby
config.lag_check_interval = 10  # Cache lag result for 10 seconds
```

## How it works

1. **Adapter-level interception** — the gem prepends on the database adapter's
   `raw_execute`. SELECT queries inside a `distribute_reads` block are routed to
   a healthy replica connection; writes pass through to the primary. Supports
   PostgreSQL, MySQL2, and Trilogy adapters.

2. **Separate connection pools** — each replica has its own ActiveRecord connection
   pool (via a lightweight abstract class). Pools are lazy: no actual DB connection
   until the first query, so replicas can be unavailable at boot without crashing.

3. **Health checking** — a background thread periodically runs `SELECT 1` against
   each replica. Unhealthy replicas are removed from rotation and restored once
   they recover.

4. **Load balancing** — round-robin (default) or random selection across healthy
   replicas. Works with any number of replicas.

5. **Replication lag** — supports PostgreSQL WAL-based lag detection and MySQL
   `SHOW REPLICA STATUS` / `Seconds_Behind_Master` lag checking. Lag values are
   cached per-replica with a configurable TTL to avoid per-query overhead.

6. **Query pattern caching** — SQL read/write classification results are cached
   in an LRU cache (configurable max size) to avoid repeated regex matching.

## Migrating from distribute_reads

1. Replace `gem "distribute_reads"` with `gem "resilient_reads"`
2. In `database.yml`, change `adapter: postgresql_proxy` to `adapter: postgresql`
3. Your existing initializer (`DistributeReads.by_default = true` etc.) will
   continue to work via the backward-compatibility shim
4. Optionally convert to the new `ResilientReads.configure` block
5. Add extra replicas to `database.yml` — they're auto-detected

## License

MIT

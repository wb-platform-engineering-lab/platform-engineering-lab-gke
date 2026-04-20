# ADR-012: Redis Cache-Aside Pattern

## Status

Accepted

## Context

CoverLine's member portal serves repeated lookups of member data that is expensive to fetch from PostgreSQL. A caching layer reduces database load and improves response time. The pattern chosen determines how the cache is populated and invalidated.

## Decision

Implement Redis as a cache using the cache-aside (lazy loading) pattern: the application checks Redis first, falls back to PostgreSQL on a miss, then writes the result to Redis with a TTL.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Cache-aside (lazy loading) | Application controls cache; only requested data is cached; simple to implement | Cache miss penalty on first access; application code must handle both paths |
| Write-through | Cache always consistent with DB on writes | All writes pay cache latency; cache filled with data that may never be read |
| Read-through | Cache manages its own population | Requires cache to understand data model; adds abstraction layer |

## Consequences

- Cache TTL must be tuned per data type — member profiles expire in 5 minutes; static reference data can be 1 hour.
- Cache stampede is possible on a cold start (many simultaneous misses hitting the database) — mitigated by low replica count in the lab.
- Redis data is not persisted (lab uses `persistence.enabled=false`) — cache is warm-started on each pod restart.
- The application gracefully degrades if Redis is unavailable: catches Redis exceptions and falls back to the database.

"""
Phase 8b — Database Scaling: Cache-Aside Pattern
=================================================
Phase 4 introduced a 30-second Redis cache on GET /claims (all claims).
This worked at 5,000 members. At 300,000 members the cache is too coarse:
  - Invalidating the entire cache on every POST /claims causes cache stampedes
  - 30s TTL means stale data for members who just submitted a claim
  - No per-member granularity — every cache miss loads all 8M rows

Phase 8b refines the pattern:
  - Cache per member_id with a 5-minute TTL
  - Write-through invalidation on POST /claims (only the affected member's key)
  - Separate cache key for aggregate dashboard data (lower TTL, less critical)
  - Background warm-up for the top 1000 most active members

This file shows the cache-aside logic used in the backend Flask app.
"""

import json
import redis
import psycopg2
from functools import wraps
from typing import Optional

# ---------------------------------------------------------------------------
# Connection setup (credentials injected by Vault — Phase 3)
# ---------------------------------------------------------------------------
redis_client = redis.Redis(
    host="redis-master",
    port=6379,
    decode_responses=True,
    socket_timeout=0.1,          # 100ms timeout — never let Redis slow the app
    socket_connect_timeout=0.1,
)

db = psycopg2.connect(
    host="pgbouncer",            # Phase 8b: backend connects to PgBouncer, not PostgreSQL directly
    port=5432,
    dbname="coverline",
    user="coverline",
    password="...",              # from Vault
)


# ---------------------------------------------------------------------------
# Cache key schema
# ---------------------------------------------------------------------------
def claims_key(member_id: int) -> str:
    """Per-member cache key. Invalidated on every write for this member."""
    return f"claims:member:{member_id}"


def dashboard_key() -> str:
    """Aggregate dashboard stats. Lower invalidation frequency, 60s TTL."""
    return "claims:dashboard:summary"


# ---------------------------------------------------------------------------
# Cache-aside: GET /claims/<member_id>
# ---------------------------------------------------------------------------
def get_claims(member_id: int) -> list[dict]:
    """
    Cache-aside pattern:
      1. Try Redis. If hit → return immediately (no DB touch).
      2. If miss → query PostgreSQL. Write result to Redis. Return.

    The DB query targets the read replica for SELECT workloads.
    """
    cache_key = claims_key(member_id)

    # 1. Cache lookup
    try:
        cached = redis_client.get(cache_key)
        if cached:
            return json.loads(cached)           # Cache HIT
    except redis.RedisError:
        pass                                    # Redis down → fall through to DB

    # 2. Cache miss — query the read replica
    with db.cursor() as cur:
        cur.execute(
            """
            SELECT id, member_id, amount, description, status, created_at
            FROM claims
            WHERE member_id = %s
            ORDER BY created_at DESC
            LIMIT 100
            """,
            (member_id,),
        )
        rows = cur.fetchall()

    claims = [
        {
            "id": r[0],
            "member_id": r[1],
            "amount": float(r[2]),
            "description": r[3],
            "status": r[4],
            "created_at": r[5].isoformat(),
        }
        for r in rows
    ]

    # 3. Write to cache — 5-minute TTL
    try:
        redis_client.setex(cache_key, 300, json.dumps(claims))
    except redis.RedisError:
        pass                                    # Cache write failure is not fatal

    return claims                               # Cache MISS, served from DB


# ---------------------------------------------------------------------------
# Write-through invalidation: POST /claims
# ---------------------------------------------------------------------------
def create_claim(member_id: int, amount: float, description: str) -> dict:
    """
    Write to PostgreSQL primary (via PgBouncer), then invalidate the
    cache for this member. Next GET will re-populate from DB.

    Do NOT write the new claim into Redis directly (write-through) —
    this causes consistency issues when multiple pods write concurrently.
    Invalidate and let the next read re-populate (cache-aside).
    """
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO claims (member_id, amount, description, status)
            VALUES (%s, %s, %s, 'pending')
            RETURNING id, created_at
            """,
            (member_id, amount, description),
        )
        claim_id, created_at = cur.fetchone()
        db.commit()

    # Invalidate — next GET /claims/<member_id> will hit the DB and re-cache
    try:
        redis_client.delete(claims_key(member_id))
        redis_client.delete(dashboard_key())    # dashboard totals are also stale
    except redis.RedisError:
        pass

    return {"id": claim_id, "member_id": member_id, "created_at": created_at.isoformat()}


# ---------------------------------------------------------------------------
# Dashboard aggregate (longer TTL — eventual consistency acceptable)
# ---------------------------------------------------------------------------
def get_dashboard_summary() -> dict:
    """
    Dashboard summary: total claims, total amount, breakdown by status.
    Expensive aggregate query — cache for 60 seconds.
    Stale by up to 60s is acceptable for a dashboard display.
    """
    cache_key = dashboard_key()

    try:
        cached = redis_client.get(cache_key)
        if cached:
            return json.loads(cached)
    except redis.RedisError:
        pass

    with db.cursor() as cur:
        cur.execute(
            """
            SELECT
                status,
                COUNT(*)            AS count,
                SUM(amount)         AS total_amount
            FROM claims
            WHERE created_at > NOW() - INTERVAL '90 days'
            GROUP BY status
            """
        )
        rows = cur.fetchall()

    summary = {
        row[0]: {"count": row[1], "total_amount": float(row[2] or 0)}
        for row in rows
    }

    try:
        redis_client.setex(cache_key, 60, json.dumps(summary))
    except redis.RedisError:
        pass

    return summary


# ---------------------------------------------------------------------------
# Cache warm-up: pre-populate the top 1000 most active members at startup
# ---------------------------------------------------------------------------
def warm_cache_top_members(limit: int = 1000) -> None:
    """
    Called once at pod startup (or via a Kubernetes Job before a traffic spike).
    Prevents cache stampede when all pods restart simultaneously and every
    first request hits the DB cold.
    """
    with db.cursor() as cur:
        cur.execute(
            """
            SELECT member_id, COUNT(*) AS claim_count
            FROM claims
            WHERE created_at > NOW() - INTERVAL '30 days'
            GROUP BY member_id
            ORDER BY claim_count DESC
            LIMIT %s
            """,
            (limit,),
        )
        top_members = [row[0] for row in cur.fetchall()]

    for member_id in top_members:
        get_claims(member_id)   # populates Redis as a side effect

    print(f"Cache warm-up complete: {len(top_members)} members pre-loaded")


# ---------------------------------------------------------------------------
# Cache hit rate monitoring (expose as a Prometheus metric)
# ---------------------------------------------------------------------------
def cache_hit_rate() -> Optional[float]:
    """
    Redis INFO stats → cache hit rate.
    Scrape this and alert if it drops below 80%.
    Below 80% means most requests are hitting the DB — cache is not effective.
    """
    try:
        info = redis_client.info("stats")
        hits = info.get("keyspace_hits", 0)
        misses = info.get("keyspace_misses", 0)
        total = hits + misses
        if total == 0:
            return None
        return round(hits / total * 100, 1)
    except redis.RedisError:
        return None

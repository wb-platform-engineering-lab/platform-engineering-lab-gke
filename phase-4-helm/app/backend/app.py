import os
import json
import psycopg2
import redis
from flask import Flask, jsonify, request
from prometheus_flask_exporter import PrometheusMetrics

app = Flask(__name__)
metrics = PrometheusMetrics(app, default_labels={"service": "coverline-backend"})

# PostgreSQL connection
def get_db():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", 5432),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )

# Redis connection
def get_cache():
    return redis.Redis(
        host=os.environ["REDIS_HOST"],
        port=int(os.environ.get("REDIS_PORT", 6379)),
        decode_responses=True,
    )

# Create table on startup
def init_db():
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS claims (
                id SERIAL PRIMARY KEY,
                member_id VARCHAR(50) NOT NULL,
                amount NUMERIC(10,2) NOT NULL,
                description TEXT,
                status VARCHAR(20) DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT NOW()
            )
        """)
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        app.logger.error(f"DB init failed: {e}")

@app.before_request
def before_first_request():
    if not getattr(app, "_db_initialized", False):
        init_db()
        app._db_initialized = True

@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "backend"})

@app.route("/claims", methods=["GET"])
def get_claims():
    cache = get_cache()
    cached = cache.get("claims:all")
    if cached:
        return jsonify({"source": "cache", "claims": json.loads(cached)})

    conn = get_db()
    cur = conn.cursor()
    cur.execute("SELECT id, member_id, amount, description, status, created_at::text FROM claims ORDER BY created_at DESC LIMIT 50")
    rows = cur.fetchall()
    cur.close()
    conn.close()

    claims = [
        {"id": r[0], "member_id": r[1], "amount": float(r[2]), "description": r[3], "status": r[4], "created_at": r[5]}
        for r in rows
    ]
    cache.setex("claims:all", 30, json.dumps(claims))
    return jsonify({"source": "db", "claims": claims})

@app.route("/claims", methods=["POST"])
def create_claim():
    data = request.get_json()
    if not data or not data.get("member_id") or not data.get("amount"):
        return jsonify({"error": "member_id and amount are required"}), 400

    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO claims (member_id, amount, description) VALUES (%s, %s, %s) RETURNING id",
        (data["member_id"], data["amount"], data.get("description", ""))
    )
    claim_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()

    get_cache().delete("claims:all")
    return jsonify({"id": claim_id, "status": "pending"}), 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
# capstone verification Fri Apr 17 16:42:01 CEST 2026
# test
# test
# test
# capstone

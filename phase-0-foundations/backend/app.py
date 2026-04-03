from flask import Flask, jsonify

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": "backend"})

@app.route("/data")
def data():
    return jsonify({"message": "Hello from Python backend!", "items": ["item1", "item2", "item3"]})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

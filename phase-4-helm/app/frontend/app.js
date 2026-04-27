const express = require("express");
// Built-in fetch is available globally in Node 18+ — no package needed.

const app = express();
const BACKEND_URL = process.env.BACKEND_URL || "http://localhost:5000";

app.use(express.json());

app.get("/health", (req, res) => {
  res.json({ status: "ok", service: "frontend" });
});

app.get("/", async (req, res) => {
  try {
    const response = await fetch(`${BACKEND_URL}/claims`);
    const data = await response.json();
    res.json({ service: "coverline-frontend", claims: data.claims, source: data.source });
  } catch (err) {
    res.status(500).json({ error: "Could not reach backend", detail: err.message });
  }
});

app.post("/claims", async (req, res) => {
  try {
    const response = await fetch(`${BACKEND_URL}/claims`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(req.body),
    });
    const data = await response.json();
    res.status(response.status).json(data);
  } catch (err) {
    res.status(500).json({ error: "Could not reach backend", detail: err.message });
  }
});

app.listen(3000, () => console.log("Frontend running on port 3000"));

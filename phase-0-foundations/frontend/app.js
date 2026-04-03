const express = require("express");
const fetch = require("node-fetch");

const app = express();
const BACKEND_URL = process.env.BACKEND_URL || "http://localhost:5000";

app.get("/health", (req, res) => {
  res.json({ status: "ok", service: "frontend" });
});

app.get("/", async (req, res) => {
  try {
    const response = await fetch(`${BACKEND_URL}/data`);
    const data = await response.json();
    res.json({ frontend: "ok", backend_response: data });
  } catch (err) {
    res.status(500).json({ error: "Could not reach backend", detail: err.message });
  }
});

app.listen(3000, () => console.log("Frontend running on port 3000"));

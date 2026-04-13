import express from "express";

const app = express();

app.get("/health", (req, res) => {
  res.status(200).json({ ok: true });
});

app.listen(3001, "0.0.0.0", () => {
  console.log("Test Express server listening on http://0.0.0.0:3001");
});
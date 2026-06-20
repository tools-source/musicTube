const assert = require("node:assert/strict");
const test = require("node:test");
const { createServer, validateCurationPayload } = require("../server");

async function withServer(options, action) {
  const server = createServer(options);
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  try {
    await action(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}

test("curation payloads are bounded and sanitized", () => {
  const payload = validateCurationPayload({
    operation: "seed",
    signals: { topArtists: ["  Artist  ", 42], recentSearches: ["Song"] }
  });
  assert.deepEqual(payload.signals.topArtists, ["Artist"]);
  assert.deepEqual(payload.signals.recentSearches, ["Song"]);
});

test("AI route is unavailable without a server credential", async () => {
  await withServer({ apiKey: "" }, async baseURL => {
    const response = await fetch(`${baseURL}/api/curate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation: "seed", signals: {} })
    });
    assert.equal(response.status, 503);
  });
});

test("AI route rejects oversized payloads without dropping the connection", async () => {
  await withServer({ apiKey: "test", providerFetch: async () => new Response() }, async baseURL => {
    const response = await fetch(`${baseURL}/api/curate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation: "seed",
        signals: { recentSearches: ["x".repeat(33 * 1024)] }
      })
    });
    assert.equal(response.status, 413);
  });
});

test("AI route filters provider output to known candidate IDs", async () => {
  const providerFetch = async () => new Response(JSON.stringify({
    choices: [{ message: { content: JSON.stringify({ order: ["known", "injected"], blurb: "A good fit" }) } }]
  }), { status: 200 });

  await withServer({ apiKey: "test", providerFetch }, async baseURL => {
    const response = await fetch(`${baseURL}/api/curate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation: "rerank",
        signals: {},
        candidates: [
          { id: "known", title: "One", artist: "Artist" },
          { id: "second", title: "Two", artist: "Artist" }
        ]
      })
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { order: ["known"], blurb: "A good fit" });
  });
});

test("health and static responses include hardened headers", async () => {
  await withServer({}, async baseURL => {
    const response = await fetch(`${baseURL}/health`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    assert.equal(response.headers.get("cache-control"), "no-store");
  });
});

test("static server never exposes repository source or configuration", async () => {
  await withServer({}, async baseURL => {
    const sourceResponse = await fetch(`${baseURL}/MusicTube/Resources/Secrets.xcconfig`);
    const gitResponse = await fetch(`${baseURL}/.git/config`);
    assert.equal(sourceResponse.status, 403);
    assert.equal(gitResponse.status, 403);
  });
});

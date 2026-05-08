/**
 * TipTour Proxy Worker
 *
 * Thin Cloudflare Worker that brokers credentials for the Gemini Live
 * voice backend and provides a multilingual label matcher. The Gemini
 * key is stored as a Cloudflare secret — the app never bakes it in.
 *
 * Routes:
 *   GET  /gemini-live-key       → returns the Gemini API key so the app
 *                                  can open a direct WebSocket to Gemini
 *                                  Live. Cloudflare can't proxy Gemini's
 *                                  WebSocket, so trusted clients get the
 *                                  raw key — to be replaced once Google
 *                                  ships ephemeral tokens for v1beta.
 *   POST /match-label           → multilingual label matcher used by the
 *                                  in-app ElementResolver fallback.
 */

interface Env {
  GEMINI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET") {
      if (url.pathname === "/gemini-live-key") {
        return handleGeminiLiveKey(env);
      }
      return new Response("Method not allowed", { status: 405 });
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/match-label") {
        return await handleMatchLabel(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

/**
 * /match-label
 *
 * Body: { query: string, candidates: string[] }
 *
 * Returns the candidate label that best matches `query` semantically,
 * or null if nothing's a confident match. Used as a multilingual
 * fallback when the in-app AccessibilityTreeResolver can't find a
 * direct match because the LLM passed a label in the user's spoken
 * language while the AX tree has labels in the UI's display language
 * (e.g. user said "guardar" but the AX tree has "Save").
 *
 * Tiny prompt + tiny output → uses gemini-2.5-flash-lite for sub-300ms
 * latency. The whole point is "ask the model to bridge a translation
 * miss," not deep reasoning.
 */
async function handleMatchLabel(request: Request, env: Env): Promise<Response> {
  const { query, candidates } = await request.json() as {
    query: string;
    candidates: string[];
  };

  if (!query || !Array.isArray(candidates) || candidates.length === 0) {
    return new Response(JSON.stringify({ match: null }), {
      headers: { "content-type": "application/json" },
    });
  }

  // Cap candidates we feed the model — AX trees can have hundreds of
  // labels and we only need a focused list for the model to choose from.
  const cappedCandidates = candidates.slice(0, 80);

  const prompt = [
    `The user wants to find a UI element matching this label: "${query}"`,
    `Here are the labels actually present in the UI's accessibility tree (one per line):`,
    cappedCandidates.map((c) => `- ${c}`).join("\n"),
    ``,
    `Which one matches the user's intent?`,
    `The query may be in a different language than the candidates (e.g. query is Spanish, candidates are English).`,
    `Match by MEANING, not by string similarity.`,
    ``,
    `Reply with JSON only: { "match": "<exact candidate label>" } if there's a clear match, or { "match": null } if there isn't.`,
    `Use the EXACT spelling and casing from the candidate list.`,
  ].join("\n");

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=${env.GEMINI_API_KEY}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0.0,
          maxOutputTokens: 128,
          responseMimeType: "application/json",
        },
      }),
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/match-label] Gemini error ${response.status}: ${errorBody}`);
    return new Response(JSON.stringify({ match: null }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Returns the Gemini API key so the app can open a direct WebSocket
 * to the Gemini Live API. Cloudflare Workers can't cleanly proxy
 * WebSocket traffic to Google's endpoint, so the app connects directly.
 *
 * SECURITY NOTE: This endpoint exposes the raw API key to any client
 * that hits it. For production, replace this with Gemini's ephemeral
 * token API (v1alpha) once it's stable, or add a shared-secret header
 * the app must send.
 */
function handleGeminiLiveKey(env: Env): Response {
  if (!env.GEMINI_API_KEY) {
    return new Response(
      JSON.stringify({ error: "GEMINI_API_KEY not configured" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }
  return new Response(
    JSON.stringify({ apiKey: env.GEMINI_API_KEY }),
    { headers: { "content-type": "application/json", "cache-control": "no-cache" } }
  );
}

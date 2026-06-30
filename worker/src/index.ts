/**
 * ILearn Proxy Worker
 *
 * Proxies requests to the Claude API so the app never ships with a raw
 * API key. The key is stored as a Cloudflare secret.
 *
 * Abuse protections (so a leaked Worker URL can't run up the Anthropic bill):
 *   - Shared-secret auth: callers must send `Authorization: Bearer <PROXY_AUTH_TOKEN>`
 *   - Model allowlist: only the models the app actually uses are permitted
 *   - Output cap: `max_tokens` is clamped server-side
 *   - Optional per-client rate limiting via a Cloudflare rate-limit binding
 *
 * Routes:
 *   POST /chat  → Anthropic Messages API (streaming)
 *
 * Secrets (set with `npx wrangler secret put <NAME>`):
 *   ANTHROPIC_API_KEY  — your Anthropic key (never shipped in the app)
 *   PROXY_AUTH_TOKEN   — shared secret the app must present. Set the SAME value
 *                        in the app with:
 *                        defaults write com.ilearn.app workerAuthToken "<token>"
 */

interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

interface Env {
  ANTHROPIC_API_KEY: string;
  PROXY_AUTH_TOKEN: string;
  // Present only if the rate-limit binding is enabled in wrangler.toml.
  RATE_LIMITER?: RateLimitBinding;
}

// Only the models the app actually offers. Rejecting anything else stops a
// caller from requesting a pricier model than the app ever uses.
const ALLOWED_MODELS = new Set<string>([
  "claude-haiku-4-5",
  "claude-sonnet-4-6",
]);

// Hard ceiling on output tokens, whatever the client asks for.
const MAX_OUTPUT_TOKENS = 2048;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonError(String(error), 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

/**
 * Verifies the request carries the shared secret as a bearer token.
 * Fails closed if the Worker has no PROXY_AUTH_TOKEN configured, and compares
 * in length-constant time so the token can't be guessed byte-by-byte by timing.
 */
function isAuthorized(request: Request, env: Env): boolean {
  if (!env.PROXY_AUTH_TOKEN) {
    return false;
  }
  const presented = request.headers.get("authorization") || "";
  const expected = `Bearer ${env.PROXY_AUTH_TOKEN}`;
  if (presented.length !== expected.length) {
    return false;
  }
  let mismatch = 0;
  for (let i = 0; i < presented.length; i++) {
    mismatch |= presented.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return mismatch === 0;
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  // 1. Require the shared secret. Without this, anyone who finds the URL can
  //    spend your Anthropic balance.
  if (!isAuthorized(request, env)) {
    return jsonError("Unauthorized", 401);
  }

  // 2. Optional per-client rate limiting (enabled via the RATE_LIMITER binding
  //    in wrangler.toml). Keyed by client IP.
  if (env.RATE_LIMITER) {
    const clientKey = request.headers.get("cf-connecting-ip") || "unknown";
    const { success } = await env.RATE_LIMITER.limit({ key: clientKey });
    if (!success) {
      return jsonError("Rate limit exceeded", 429);
    }
  }

  // 3. Validate + clamp the request body before forwarding upstream.
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonError("Invalid JSON body", 400);
  }

  const requestedModel = typeof payload.model === "string" ? payload.model : "";
  if (!ALLOWED_MODELS.has(requestedModel)) {
    return jsonError(`Model not allowed: ${requestedModel}`, 400);
  }

  const requestedMaxTokens =
    typeof payload.max_tokens === "number" ? payload.max_tokens : MAX_OUTPUT_TOKENS;
  payload.max_tokens = Math.min(Math.max(1, requestedMaxTokens), MAX_OUTPUT_TOKENS);

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

function jsonError(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

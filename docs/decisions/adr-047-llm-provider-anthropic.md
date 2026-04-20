# ADR-047: Anthropic Claude as LLM Provider

## Status

Accepted

## Context

Phase 12 builds an AI-powered claims triage agent for CoverLine. The agent needs an LLM API that supports tool use (function calling), multi-turn conversation, and is reliable enough for a production-grade lab demonstration. Multiple providers were evaluated.

## Decision

Use the Anthropic Claude API (`claude-3-5-sonnet`) as the LLM backend. The Python SDK (`anthropic`) is used directly without a framework abstraction layer.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Anthropic Claude | Strong tool use, large context window (200k tokens), good instruction following, Python SDK well-maintained | Paid API (no permanent free tier); Anthropic-specific API format |
| OpenAI GPT-4o | Widely documented, familiar API format | Paid, comparable pricing; less focus on long-document analysis |
| Gemini (Google) | GCP-native integration, Vertex AI managed | More complex authentication (Vertex vs AI Studio); less mature tool use |
| Local model (Ollama) | Free, no data leaves the lab | Insufficient quality for production-quality triage decisions; requires GPU nodes |

## Consequences

- `ANTHROPIC_API_KEY` is stored as a Kubernetes Secret and injected via Vault (consistent with ADR-029).
- Model selection (`claude-3-5-sonnet-20241022`) is pinned in the application config — prevents silent capability changes on new model releases.
- API calls are metered — cost per triage run is approximately $0.002–0.01 depending on claim complexity.
- Guardrails (confidence gate, circuit breaker, input sanitisation) are implemented in the application layer, not delegated to the provider (see Phase 12 Challenge 6).

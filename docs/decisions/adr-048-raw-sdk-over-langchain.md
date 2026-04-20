# ADR-048: Raw Anthropic SDK over LangChain

## Status

Accepted

## Context

Phase 12's claims triage agent requires an agentic loop with tool use. LangChain and similar frameworks (LlamaIndex, Haystack) provide abstractions over the raw LLM API. The decision is whether to use a framework or call the LLM SDK directly.

## Decision

Use the `anthropic` Python SDK directly. Implement the agentic loop (tool dispatch, multi-turn conversation, circuit breaker) explicitly in application code rather than relying on a framework abstraction.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Raw Anthropic SDK | Explicit control over every token, prompt, and tool call; no hidden behaviour; easier to debug; no framework version lock-in | More boilerplate; must implement conversation management manually |
| LangChain | Rapid prototyping, pre-built agents and chains, many integrations | Abstractions hide LLM calls — hard to debug; framework updates can silently change agent behaviour; adds ~50 transitive dependencies |
| LlamaIndex | Strong document indexing and RAG pipelines | Better for retrieval use cases than agentic tool-use loops |

## Consequences

- The agentic loop is ~40 lines of explicit Python — every engineer can read and understand exactly what happens each turn.
- Guardrails (circuit breaker, confidence gate, input sanitisation) are implemented as plain functions around the SDK call — no framework integration needed.
- Migrating to a different LLM provider requires changing the client initialisation and message format — ~10 lines of code, not a framework migration.
- Tool definitions are plain Python dicts matching the Anthropic tool schema — no `@tool` decorator magic to reason about.

---
name: evaluator
description: Placeholder. The evaluator runs on a different vendor's model, not as a Claude subagent.
tools: Read
---

Do not run this subagent for scoring.

The designer's evaluator must never share a context window or a model family
with the work it grades, so it runs on an OpenAI model, outside this
workspace. Until that runtime exists, the lead asks a human or the critic for
judgement and records in the journal that no evaluator score was available.

If you were spawned anyway, reply with exactly: "evaluator not configured:
scoring runs on a separate OpenAI-model runtime." and stop.

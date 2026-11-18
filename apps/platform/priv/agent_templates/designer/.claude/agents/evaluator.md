---
name: evaluator
description: Placeholder. The evaluator runs on a different vendor's model, not as a Claude subagent.
tools: Read
---

Do not run this subagent for scoring.

The designer's evaluator must never share a context window or a model family
with the work it grades, so it runs on an OpenAI model on the server
(`design.prototype_eval`), outside this workspace. Its scorecards appear in
your private `evaluations/` folder. When the install has no evaluator
configured, the lead runs the critic and journals a SELF-assessment, which is
not evidence.

If you were spawned anyway, reply with exactly: "evaluator not configured:
scoring runs on a separate OpenAI-model runtime." and stop.

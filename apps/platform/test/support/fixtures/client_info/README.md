# `client_info` join payloads, captured from the real plugins

Each JSON file is copied byte-for-byte from the join payload captured in the
plugin PR that implemented the build contract
(`Platform.Agents.AgentRuntime.client_build_status/1` documents that
contract). JSON has no comments, so the provenance lives here. Do not edit a
fixture by hand. If a plugin's payload changes, re-capture it and update the
source line.

| File | Source repo | Captured at commit | From |
| --- | --- | --- | --- |
| `claude_channel.json` | Startup-Suite/claude-code-suite-channel | 90ae8781eefcc63f383e43c8de905a3fd5dcbf68 (squash-merged as 85e499f47f579868afda64ec93ced00b28fe06ad) | PR #26, "Reported": real `src/` loaded from another cwd and joined twice, identical payloads |
| `claude_channel_unresolved.json` | Startup-Suite/claude-code-suite-channel | same | PR #26, "Unresolved": `src/` copied to a dir with no `.git`, `SUITE_CHANNEL_BUILD` unset |
| `openclaw.json` | Startup-Suite/openclaw-suite-channel | 0a809b0d53d19fbf742012133acf9d1601245d10 (squash-merged as 098cfec6fdc464cfedfc086a543cfaf885c7a4cf) | PR #30, "Reported": compiled dist with the prebuild `build-info.json` stamp |
| `openclaw_unresolved.json` | Startup-Suite/openclaw-suite-channel | same | PR #30, "Unresolved": the same dist copied without `build-info.json` |

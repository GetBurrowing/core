# Original-project recovery

Stage 3 distinguishes three measurements: selected-profile readiness, lossless
source-project availability, and accepted production completion. The first does
not establish either of the latter two.

The serving host initially had no mapping for clip
`01a18600-7076-7000-9194-80a4cc5daefd`. The original producer's ClipMap, read under
its lock, binds that clip to candidate `c8bedfe6da`. Its original upload receipt
independently binds the same candidate, clip and previous file. Supported project
info reports nine candidates, four approved, five proposed, five alternates,
explicit local privacy and required approval. The original supported review
export pins 2403.01–2456.88 seconds and EDL `0a205a8821195c92`.

The actual CLI has project info but no project import/export/relocate command.
Finalize resolves the recorded absolute source path and can fall back to a cut
candidate if it is missing. Do not accept that fallback as an original-source
render. Process/resume can relocate a same-content source, but changed configuration
can invalidate selection; it is not used for this recovery.

Preserve the whole original project and source bytes. Verify archive members
before extraction (no absolute paths, traversal or unsafe symlinks), use a new
private directory, and verify all transferred hashes. Keep the original source
at its recorded POSIX path through a persistent read-only container bind. This
preserves internal references without editing project manifests or generating
candidates. The private operator location is supplied separately; it must never
appear in product copy or sanitized receipts. Keep the original delivery outside
finalization output because finalize may prune outputs.

Quiesce idle polling and acquire the actual runner state lock for service/mapping
changes. Preserve the quadlet backup and existing image, environment and mounts.
After the bind is live, verify original source SHA256 inside the serving container
and supported project-info/review identities. Then add only the verified mapping
through `ClipMap.put` under `runner_lock`; never hand-edit state.json. Do not change
the closed failed job or forge an enqueue, claim or attribution.

## Authorized local render before human retry

`validate_original_render.py` runs real CLI subprocesses on the serving host.
Supply the actual installed helper, selected USER profile, transferred project,
original source **at its recorded path**, exact selected music bytes and a private
output directory. Do not point it at a delivered video. It verifies source/music/
helper hashes before any CLI call, makes a fresh disposable byte-copy of the
complete original project inside the private output directory, and runs every
review/apply/finalize operation on that copy. The output directory must be outside
the canonical mapped project, and an existing validation copy is never overwritten.
The canonical mapping and original project's review/final tree stay pristine.
It requires the exact original candidate and
bounds, runs deep doctor for selected and combined profiles, and uses only supported
profile import, review export/apply and finalize. Its disposable USER profile
combines karaoke, the selected music at -12 dB and disabled closing video. It calls
neither process/transcription nor any MCP/job/upload/approval/publish tool.

```
python3 validate_original_render.py --project "$ORIGINAL_PROJECT" \
  --source "$RECORDED_ORIGINAL_SOURCE" --music "$VERIFIED_SELECTED_MUSIC" \
  --helper "$INSTALLED_HELPER" --profile "$SELECTED_USER_PROFILE" \
  --clip-bin "$CLIP_BIN" --output-dir "$PRIVATE_VALIDATION_OUTPUT"
```

The script requires a fresh target MP4 and full decode and writes a content-free
receipt with hashes, dimensions, duration and selected/effective doctor summaries.
It removes only its own temporary profile via supported profile-path lookup.
Inspect first/middle/last frames, temporal karaoke and audible speech/music before
declaring this local validation passed. The receipt explicitly says
`production_completion: false`. A real fresh human-enqueued job must still exercise
the persisted `social_clip_job_source(asset="music")`, claim/progress/upload/complete
flow on the serving worker. Only accepted completion with verified fresh output
establishes production recovery. No approval, scheduling or publication is allowed.

## Verified transfer identities

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| Entire original project tar | 211496960 | eed934eb2d3fb030f8a6d482b74cb06cec3542d16eb9a64ed00489291c303386 |
| Original source part 00 | 350000000 | 178c647d77d1ee7ac0b06e4a5318675486eff5b4bfbaaa145cf2bb630f22861b |
| Original source part 01 | 276773717 | ec8f82cdd6f8ec05282571cdc94aac2447e65210efa0ba0ef0bd8b3192f27ed9 |
| Concatenated original source | 626773717 | a56d9f934de436211d92c2e9a5688cd9b6c8f0c52527d25c6c3d3b7f5fd66d91 |
| Selected audio file 01a18eb0-ce90-7000-a470-ed04b1ba9a14 | 1457360 | 5966eb0b7347ee5fb4f3012742d8aac84d39c99798c633ef4bd766e783c7610b |

These are transfer measurements, not a render/completion receipt. The original
immutable base is `01a18600-7078-7000-9dce-b0fff3735c03`; previous file SHA256 is
`e26c2d84b8597aa7aa5f55696ad1c04aefbfec171e7f4df37b294e09158adb91`.
Refresh current base/revision/next_rev immediately before a human retry.

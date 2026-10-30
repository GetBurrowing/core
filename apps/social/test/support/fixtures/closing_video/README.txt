Closing-video TEST ONLY integration fixture (task 01a18ab6).

No media checked into Git. The generator creates an animated red A/blue B closing
video with visible TEST ONLY text and a 997 Hz tone, a 440 Hz source and a 773 Hz
music bed. It must never be described or selected as the real HTC logo asset.

Use the installed compatible clip Python environment (clip_agent, numpy, Pillow),
not merely a binary that reports version0.9.0. Config must expose outro.path and
outro.audio, music and headline-review/1. Extract the canonical registered
burrow-clip-runner helper, verify its current skill digest, then run:

python apps/social/priv/scripts/clip_closing_video_fixture.py \
  --helper /private/runner/clip_runner.py --clip /compatible/bin/clip \
  --tool-source /compatible/htc-clip-tool --output /private/test-only-closing

The harness seeds deterministic transcript/proposal data, then executes real
process/resume, review/apply and helper finalize. No live model is required. The
fixture never approves a Burrow clip or publishes. The helper consumes only
exported review.toml; internal manifest writes are restricted to fixture setup.
The evidence receipt identifies executable, imported source, revision and hash.
Seven outputs cover two clip identities, A keep/mute, replacement B, disabled,
headline, caption and music rerenders. Decoded frames prove a single36-frame
suffix, caption/headline cutoff, identifiable final frames and duration within
one frame. FFT tone measurements check kept/muted closing and preserved source.
PNG seam/end frames and receipt.json are local evidence; no signed URL is saved.

The canonical runner patch is an audit artifact of the centrally registered skill,
not a second maintained helper. It uses zero-context unified hunks to avoid blank
context lines being flagged as trailing whitespace. Verify the before/after hashes
in runner-release-receipt.json when applying it to an extracted skill snapshot.

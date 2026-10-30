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

For the browser/ClipJobs integration seed, use a private test database that has
already run the Social migrations and fixtures. From apps/social run:

CLOSING_FIXTURE_ROOT=/private/test-only-closing \
CLOSING_FIXTURE_STORAGE_ROOT=/private/test-only-blobs \
CLOSING_FIXTURE_MANIFEST=/private/test-only-identities.json \
PLATFORM_TEST_DATABASE=platform_test_closing_private MIX_ENV=test \
mix run --no-start priv/scripts/clip_closing_video_fixture.exs

The browser server must use the same chat_attachments_root as the seed's private
storage root. The seed creates a fresh TEST ONLY show with two pending clips
using real A/keep and A/mute outputs, then saves B/mute as the next default. It
writes identities with mode0600, never a session cookie or signed URL. It does
not approve clips or create publication jobs. Browser authentication belongs to
the rig's normal dev-login/session fixture, outside this durable script.

The canonical runner patch is an audit artifact of the centrally registered skill,
not a second maintained helper. It uses zero-context unified hunks to avoid blank
context lines being flagged as trailing whitespace. Verify the before/after hashes
in runner-release-receipt.json when applying it to an extracted skill snapshot.

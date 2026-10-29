Deterministic upload/runner-protocol fixtures, task 01a17e37-97c2.

source.mp4 is a black 320x180 H264/yuv420p MP4 (10 fps, 35 s).
one/two/three.mp4 are prerecorded 0.3 s MP4s with white DejaVuSans
17px centered headlines on navy/darkgreen/maroon backgrounds:
  The demo finally worked
  We fixed the wrong button
  The tiny bug won again
The same literal is in each MP4's title metadata. The E2E pins the whole
file SHA256 independently, not only metadata or a success receipt.

Generated once with ffmpeg lavfi color, drawtext, libx264, -an,
-pix_fmt yuv420p, -metadata title=..., -movflags +faststart.
Tests need no ffmpeg, local model or network. The fake protocol peer uses
real Files storage, signed URL verification and authenticated job tools.
It does NOT prove actual CLI command execution or production availability.
The canonical skill's separate fake-CLI three-pick test pins exact
review.toml headlines, process-once, prepare/apply/verify/finalize order,
three completed renders, privacy and no publisher calls. Its actual helper
headline-forwarding omission is the second mutation; no runner ships in core.

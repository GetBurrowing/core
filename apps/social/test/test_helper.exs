# Social's tests run on core's test harness, unchanged: the same ExUnit
# exclusions, sandbox mode, org seeding and module preload core's own
# `mix test` runs (ADR 0055). Required, not copied, so the two cannot drift.
Code.require_file("../../platform/test/test_helper.exs", __DIR__)

# Social 5/7: the real-ffmpeg renderer tests run only where this node can
# burn captions (ffmpeg + ffprobe with libass, and the bundled font). CI's
# image has no ffmpeg, so they are skipped there. APPEND to core's exclude
# list: ExUnit.configure replaces it.
case Platform.Social.Toolchain.capabilities() do
  :ok ->
    :ok

  {:error, reason} ->
    IO.puts("[social test_helper] :ffmpeg tests excluded: #{reason}")
    ExUnit.configure(exclude: (ExUnit.configuration()[:exclude] || []) ++ [:ffmpeg])
end

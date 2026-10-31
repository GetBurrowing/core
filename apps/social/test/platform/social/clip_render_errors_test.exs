defmodule Platform.Social.ClipRenderErrorsTest do
  use ExUnit.Case, async: true
  alias Platform.Social.ClipRenderErrors

  test "exact model preflight uses actionable safe copy" do
    assert ClipRenderErrors.message("CLIP_DOCTOR_FIX: doctor failed (model:base.en)") ==
             "Render could not start because the runner's transcription model is not ready. Ask the render operator to finish setup, then try Render preview again. Your previous video is unchanged."

    assert ClipRenderErrors.message(
             "CLIP_DOCTOR_FIX: doctor failed (binary:ffmpeg,model:large-v3)"
           ) ==
             "Render could not start because the runner's transcription model is not ready. Ask the render operator to finish setup, then try Render preview again. Your previous video is unchanged."
  end

  test "only allowlisted source, music and capability codes receive specific guidance" do
    assert ClipRenderErrors.message("APPEARANCE_PROJECT_MISSING: project_info failed") ==
             "Render could not find the original project or source. Ask the render operator to restore its mapping, then try Render preview again. Your previous video is unchanged."

    assert ClipRenderErrors.message("MUSIC_DOWNLOAD_FAILED: music failed") ==
             "Render could not use the selected music. Choose an available song or ask the render operator to check the audio, then try Render preview again. Your previous video is unchanged."

    assert ClipRenderErrors.message("CAPTION_CLI_UNSUPPORTED: captions failed") ==
             "Render could not start because the runner needs setup. Ask the render operator to check readiness, then try Render preview again. Your previous video is unchanged."
  end

  test "unknown and malformed diagnostics never disclose content or guess a source failure" do
    for error <- [
          nil,
          %{},
          42,
          "",
          "SOURCE_MISSING_EVIL: /private/movie.mp4",
          "Traceback /home/private token=sk-secret CLIP_DOCTOR_FIX: doctor failed (model:base.en)",
          "CLIP_DOCTOR_FIX: doctor failed (model:/private/sk-secret)",
          "CLIP_DOCTOR_FIX: doctor failed (model:base.en)\nTraceback secret",
          "https://signed.invalid/movie.mp4?token=sk-secret"
        ] do
      assert ClipRenderErrors.message(error) ==
               "Render failed. Try Render preview again. If it fails again, ask the render operator to check the job. Your previous video is unchanged."
    end
  end

  test "untrusted details behind known codes are discarded" do
    assert ClipRenderErrors.message(%{
             error: "MUSIC_DOWNLOAD_FAILED: /private/music.wav?token=sk-secret\nTraceback"
           }) ==
             "Render could not use the selected music. Choose an available song or ask the render operator to check the audio, then try Render preview again. Your previous video is unchanged."
  end

  test "verified reframe backend check uses setup guidance without guessing source or exposing details" do
    assert ClipRenderErrors.message("CLIP_DOCTOR_FIX: doctor failed (reframe-backend)") ==
             "Render could not start because the runner needs setup. Ask the render operator to check readiness, then try Render preview again. Your previous video is unchanged."

    assert ClipRenderErrors.message(
             "CLIP_DOCTOR_FIX: doctor failed (reframe-backend:/private/token)"
           ) ==
             "Render failed. Try Render preview again. If it fails again, ask the render operator to check the job. Your previous video is unchanged."
  end
end

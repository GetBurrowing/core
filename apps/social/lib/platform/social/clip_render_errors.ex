defmodule Platform.Social.ClipRenderErrors do
  @moduledoc "Allowlisted render failure guidance. Runner diagnostics never reach product copy."

  @unchanged "Your previous video is unchanged."
  @model "Render could not start because the runner's transcription model is not ready. Ask the render operator to finish setup, then try Render preview again."
  @setup "Render could not start because the runner needs setup. Ask the render operator to check readiness, then try Render preview again."
  @source "Render could not find the original project or source. Ask the render operator to restore its mapping, then try Render preview again."
  @music "Render could not use the selected music. Choose an available song or ask the render operator to check the audio, then try Render preview again."
  @unknown "Render failed. Try Render preview again. If it fails again, ask the render operator to check the job."
  @source_codes ~w(APPEARANCE_PROJECT_MISSING PROJECT_NOT_FOUND SOURCE_MISSING SOURCE_UNAVAILABLE SOURCE_FILE_NO_DOWNLOAD HEADLINE_SOURCE_MISSING)
  @music_codes ~w(MUSIC_ASSET_INVALID MUSIC_URL_INVALID MUSIC_DOWNLOAD_SIZE MUSIC_DOWNLOAD_FAILED MUSIC_GAIN_INVALID)
  @setup_codes ~w(CLIP_DOCTOR CLIP_DOCTOR_FIX CLIP_NOT_INSTALLED CLIP_VERSION_UNKNOWN CLIP_TOO_OLD SOURCE_NEEDS_YTDLP CAPTION_CLI_UNSUPPORTED CAPTION_CONTRACT_UNSUPPORTED MUSIC_CLI_UNSUPPORTED CLOSING_CLI_UNSUPPORTED HEADLINE_CLI_UNSUPPORTED HEADLINE_PRIVACY_EXPORT_REFUSED HEADLINE_CAPTION_STYLE_UNSUPPORTED)
  @model_checks ~w(model:tiny model:tiny.en model:base model:base.en model:small model:small.en model:medium model:medium.en model:large-v1 model:large-v2 model:large-v3 model:large-v3-turbo model:ggml-silero-v5.1.2.bin)
  @setup_checks ~w(profile binary:ffmpeg binary:ffprobe binary:whisper-cli hdr brain brain-model brain-local reframe-backend memory proxy plaintext-keys inbox disk show-placeholder)

  @doc "Return safe guidance from a persisted job or a stable code; never interpolate diagnostics."
  def message(%{error: error}), do: message(error)
  def message(%{code: code}), do: message(code)

  def message(error) when is_binary(error) do
    guidance =
      cond do
        model_failure?(error) -> @model
        String.starts_with?(error, "CLIP_DOCTOR_FIX:") and not valid_doctor?(error) -> @unknown
        code(error) in @source_codes -> @source
        code(error) in @music_codes -> @music
        code(error) in @setup_codes -> @setup
        true -> @unknown
      end

    guidance <> " " <> @unchanged
  end

  def message(_), do: @unknown <> " " <> @unchanged

  defp code(error) do
    case String.split(error, ": ", parts: 2) do
      [code] -> code
      [code, _] -> code
    end
  end

  defp valid_doctor?(error) do
    case Regex.run(~r/\ACLIP_DOCTOR_FIX: doctor failed \(([^\r\n()]+)\)\z/, error) do
      [_, checks] ->
        Enum.all?(String.split(checks, ","), &(&1 in @model_checks or &1 in @setup_checks))

      _ ->
        false
    end
  end

  defp model_failure?(error) do
    case Regex.run(~r/\ACLIP_DOCTOR_FIX: doctor failed \(([^\r\n()]+)\)\z/, error) do
      [_, checks] ->
        checks = String.split(checks, ",")

        Enum.all?(checks, &(&1 in @model_checks or &1 in @setup_checks)) and
          Enum.any?(checks, &(&1 in @model_checks))

      _ ->
        false
    end
  end
end

defmodule Platform.Meetings.Config do
  @moduledoc """
  Runtime configuration for the meetings subsystem.

  Loaded from `priv/meetings.yml` (see `priv/meetings.yml.example`). If the
  file is missing or unreadable, a minimal default is used that disables
  summary generation — meetings still run, segments still persist, but no
  LLM call is made.

  This module is intentionally read-on-demand (not cached in a GenServer)
  so that tweaking the YAML during development takes effect immediately
  without a restart.
  """

  @default_summary %{
    provider: :none,
    model: nil,
    base_url: nil,
    api_key_env: nil,
    max_tokens: 2048,
    temperature: 0.3
  }

  @doc "Returns the resolved `:summary` config as a map with atom keys."
  def summary do
    load()
    |> Map.get("summary", %{})
    |> normalize_summary()
  end

  @doc "True if a summary provider other than `:none` is configured."
  def summary_enabled? do
    summary().provider != :none
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp load do
    case path() do
      nil ->
        %{}

      file ->
        case YamlElixir.read_from_file(file) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end
    end
  end

  defp path do
    file = Application.app_dir(:platform, "priv/meetings.yml")
    if File.exists?(file), do: file, else: nil
  end

  defp normalize_summary(map) when is_map(map) do
    @default_summary
    |> Map.merge(%{
      provider: parse_provider(map["provider"]),
      model: map["model"],
      base_url: map["base_url"],
      api_key_env: map["api_key_env"],
      max_tokens: map["max_tokens"] || @default_summary.max_tokens,
      temperature: map["temperature"] || @default_summary.temperature
    })
  end

  defp normalize_summary(_), do: @default_summary

  defp parse_provider(nil), do: :none
  defp parse_provider(p) when is_atom(p), do: p
  defp parse_provider(p) when is_binary(p), do: String.to_atom(p)
end

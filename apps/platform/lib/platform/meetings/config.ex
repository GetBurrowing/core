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

  ## Injected config (test env)

  `priv/meetings.yml` is gitignored, so whether it exists — and which
  provider it names — varies per machine. Reading it from a test run makes
  the outcome a function of the host: a developer with a local Ollama
  configured gets a real HTTP call (and an `:econnrefused`) where CI, which
  has no such file, gets `provider: :none`. Tests must not depend on
  unmanaged disk state.

  Setting `config :platform, :meetings_summary, %{...}` short-circuits the
  YAML read entirely — the injected map is normalized and returned as-is
  and no filesystem access happens. `config/test.exs` sets this to the
  provider-less default so the suite is hermetic regardless of what is on
  the box. Production leaves the key unset and reads the YAML as before.
  """

  @default_summary %{
    provider: :none,
    model: nil,
    base_url: nil,
    api_key_env: nil,
    max_tokens: 2048,
    temperature: 0.3
  }

  @doc """
  Returns the resolved `:summary` config as a map with atom keys.

  When `:meetings_summary` is set in application config the YAML file is
  never read (see the "Injected config" section in the moduledoc).
  """
  def summary do
    case Application.fetch_env(:platform, :meetings_summary) do
      {:ok, injected} when is_map(injected) ->
        Map.merge(@default_summary, atomize_summary(injected))

      _ ->
        load()
        |> Map.get("summary", %{})
        |> normalize_summary()
    end
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

  # Injected config may use either atom or string keys (config/*.exs
  # naturally produces atoms; a test setting it dynamically may not).
  # Unknown keys are dropped so an injected map can't smuggle in fields
  # the YAML path would never produce.
  defp atomize_summary(map) do
    known = Map.keys(@default_summary)

    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = if is_binary(k), do: safe_key(k, known), else: k

      if key in known do
        Map.put(acc, key, if(key == :provider, do: parse_provider(v), else: v))
      else
        acc
      end
    end)
  end

  defp safe_key(k, known) do
    Enum.find(known, fn atom -> Atom.to_string(atom) == k end)
  end

  defp parse_provider(nil), do: :none
  defp parse_provider(p) when is_atom(p), do: p
  defp parse_provider(p) when is_binary(p), do: String.to_atom(p)
end

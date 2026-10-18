defmodule Platform.Agents.Voice do
  @moduledoc """
  What Burrow knows about an agent's voice, and how that reaches the runtime.

  Task 01a03f4f. Two pieces of per-agent state, plus the resolution that puts
  both into the `meeting_join` payload a voice worker consumes.

  ## The seam is a value, not a vendor

  Harper asked for ElevenLabs "but also a different provider if we want", so
  nothing here names a vendor except as a string in `known_providers/0`.
  Selection lives in `agents.voice_config`, a jsonb map mirroring
  `agents.model_config`:

      %{"provider" => "elevenlabs", "voice_id" => "21m00Tcm4TlvDq8ikWAM",
        "model" => "eleven_turbo_v2_5"}

  Adding a provider is one entry in `@known_providers` — no migration, no new
  column, no module to implement in core.

  ## Core does not synthesize audio, and deliberately so

  There is no HTTP adapter in this module and no `synthesize/3` callback. The
  suite-voice worker already owns TTS behind its own `TTS_BACKEND` seam
  (`openai` by default, `elevenlabs` one option among them); a second seam in
  core would be a duplicate of it that no caller needs. Core's job is to know
  which voice an agent uses and hand that to the worker. `@known_providers`
  is therefore kept string-identical to the worker's `KNOWN_BACKENDS`, so a
  stored `"provider"` passes through to `TTS_BACKEND` unchanged rather than
  needing a translation table that could drift.

  No ElevenLabs API key exists on this deployment yet. Nothing in this module
  requires one: storing a voice id, validating it, and dispatching it are all
  key-free. The key is needed only by the worker, at synthesis time.

  ## Personality extends the workspace files rather than competing with them

  An agent already has versioned per-agent markdown in
  `agent_workspace_files` — `SOUL.md`, `IDENTITY.md`, `AGENTS.md` and friends,
  written by `Platform.Agents.MemoryContext.upsert_workspace_file/4` and
  editable today in Control Center's agent detail. `Platform.Agents.QuickAgent`
  already points agents at "SOUL.md and IDENTITY.md for your personality and
  voice".

  So the ticket's "short personality markdown" is a new KEY in that table,
  `VOICE.md`, and not a new column on `agents`. That reuses the existing
  editor, versioning and staleness check, and — more importantly — avoids a
  second field competing with `SOUL.md` for the same question.

  `VOICE.md` is scoped narrower than `SOUL.md` on purpose: it is the
  spoken-register instruction ("how you sound out loud, in a live meeting"),
  where `SOUL.md` is who the agent is everywhere. The ticket's separate
  registers for voice vs. chat vs. task card are the same idea, and the other
  two are NOT built here — see "Not built" below.

  ## Not built here, and why

  * **The reply-style / length discipline.** The ticket calls this the real
    work and the acceptance bar. It is a prompt-and-truncation problem in the
    reply path, not a storage problem, and nothing in this module enforces a
    cap on `VOICE.md`. Deliberately left: a silent truncation here would look
    like enforcement and be none.
  * **The self-provisioned response bank.** Rendering 10-20 WAVs per agent at
    federation requires a working TTS key, and the ticket's own acceptance
    check is "assert non-trivial duration and non-silent audio per file" —
    unmeasurable without one. Storing a `provider`/`voice_id` is the input
    that step will read; it is not that step.
  """

  alias Platform.Agents.{Agent, MemoryContext}

  @typedoc "A resolved, normalised voice selection, or `nil` when unset."
  @type config :: %{String.t() => String.t()} | nil

  # String-identical to suite-voice's `config.KNOWN_BACKENDS`. A value here is
  # sent verbatim as the worker's `TTS_BACKEND`, so the two lists drifting is
  # the failure this comment exists to prevent.
  @known_providers ~w(openai elevenlabs)

  @personality_file_key "VOICE.md"

  @doc """
  Providers a `voice_config` may name.

  A closed list on purpose: a typo'd provider should fail the changeset at
  write time rather than reach the worker and fail there, where nobody in
  Burrow would see it.
  """
  @spec known_providers() :: [String.t()]
  def known_providers, do: @known_providers

  @doc """
  The `agent_workspace_files` key holding an agent's spoken-register markdown.
  """
  @spec personality_file_key() :: String.t()
  def personality_file_key, do: @personality_file_key

  @doc """
  The agent's voice selection, normalised, or `nil` when it has none.

  `nil` rather than `%{}` so a caller putting this in a payload sends an
  unmistakable "this agent has no voice" rather than an empty map a worker
  might read as a partially-configured one.
  """
  @spec config_for(Agent.t()) :: config()
  def config_for(%Agent{voice_config: voice_config}), do: normalize(voice_config)

  @doc """
  The agent's `VOICE.md`, trimmed, or `nil` when absent or blank.

  Blank collapses to `nil` for the same reason as `config_for/1`: an empty
  string in the payload would be a producer that produced nothing, which is
  indistinguishable downstream from the field never having been wired up.
  """
  @spec personality_for(Agent.t()) :: String.t() | nil
  def personality_for(%Agent{id: agent_id}) do
    case MemoryContext.get_workspace_file(agent_id, @personality_file_key) do
      %{content: content} when is_binary(content) -> blank_to_nil(String.trim(content))
      _ -> nil
    end
  end

  @doc """
  Validate `:voice_config` on an agent changeset.

  Empty is always valid — an agent without a voice is the default state, not a
  degraded one, exactly as `avatar_url` is. A NON-empty map must name a known
  provider and a non-blank `voice_id`, because a half-set selection is the
  case that reaches the worker and fails silently there.
  """
  @spec validate_config(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_config(changeset) do
    case Ecto.Changeset.get_field(changeset, :voice_config) do
      nil ->
        changeset

      config when is_map(config) and map_size(config) == 0 ->
        changeset

      config when is_map(config) ->
        changeset
        |> validate_provider(stringify(Map.get(config, "provider") || Map.get(config, :provider)))
        |> validate_voice_id(stringify(Map.get(config, "voice_id") || Map.get(config, :voice_id)))

      _other ->
        Ecto.Changeset.add_error(changeset, :voice_config, "must be a map")
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp validate_provider(changeset, provider) when provider in @known_providers, do: changeset

  defp validate_provider(changeset, nil),
    do: Ecto.Changeset.add_error(changeset, :voice_config, "provider is required")

  defp validate_provider(changeset, provider) do
    Ecto.Changeset.add_error(
      changeset,
      :voice_config,
      "provider #{inspect(provider)} is not one of #{Enum.join(@known_providers, ", ")}"
    )
  end

  defp validate_voice_id(changeset, voice_id) when is_binary(voice_id), do: changeset

  defp validate_voice_id(changeset, _voice_id),
    do: Ecto.Changeset.add_error(changeset, :voice_config, "voice_id is required")

  defp normalize(config) when is_map(config) and map_size(config) > 0 do
    provider = stringify(Map.get(config, "provider") || Map.get(config, :provider))
    voice_id = stringify(Map.get(config, "voice_id") || Map.get(config, :voice_id))
    model = stringify(Map.get(config, "model") || Map.get(config, :model))

    if is_nil(provider) or is_nil(voice_id) do
      nil
    else
      %{"provider" => provider, "voice_id" => voice_id}
      |> maybe_put("model", model)
    end
  end

  defp normalize(_config), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(value) when is_binary(value), do: blank_to_nil(String.trim(value))
  defp stringify(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stringify(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end

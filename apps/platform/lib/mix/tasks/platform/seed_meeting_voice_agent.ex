defmodule Mix.Tasks.Platform.SeedMeetingVoiceAgent do
  @moduledoc """
  Seed the single, distinct "Burrow" persona (task 01a0d4a0-6570
  stage 2) and wire it into Core using ONLY already-shipped mechanisms — no
  new Core plumbing, no migration.

    * `Platform.Federation.register_voice_runtime/3` (the same primitive
      `mix platform.voice_runtime` wraps) mints its voice/"mouth"
      `agent_runtimes` row. The actual STT/LLM/TTS loop, barge-in, and VAD
      run in the separate Python service built in stage 1
      (`services/meeting-voice-agent/`); this task only tells Core the row
      exists and what it may do.
    * `Platform.Agents.MemoryContext.upsert_workspace_file/4` writes its
      `SOUL.md` / `IDENTITY.md` / `VOICE.md` — the same workspace-file path
      every other agent's identity goes through.
    * `agents.voice_config` (jsonb) and `access_runtime_profiles.tool_profile`
      (array) are pure data columns; no migration needed for either.

  ## Usage

      mix platform.seed_meeting_voice_agent --owner <email>

  `--owner` names the Burrow user the minted voice runtime (and its auth
  token) is registered under — the same requirement
  `Federation.register_voice_runtime/3` already has.

  ## Idempotent

  Safe to re-run:

    * the agent is looked up by its fixed slug (`"meeting-assistant"`)
      rather than inserted unconditionally;
    * its voice runtime row is identified by `metadata["role"] == "voice"`
      (the marker `register_voice_runtime/3` always writes) and reused
      rather than duplicated;
    * workspace files, `voice_config`, `client_info.features`, and
      `tool_profile` are all re-applied on every run, so a rerun
      self-heals drift instead of leaving a second agent or a second mouth
      row behind.

  A raw auth token is only ever generated (and printed) the first time the
  voice runtime row is created — exactly like `mix platform.voice_runtime`,
  a rerun that reuses the existing row does not mint (and cannot print) a
  new one.

  ## `kind` stays `"native"`, not `"external"`

  Stage 3's text hand-off — posting a long answer into the meeting's chat
  space instead of speaking it at length — is implemented by the stage-1
  Python service calling Burrow's existing `send_media`/chat MCP tool
  directly, over ITS OWN registered runtime (the `messaging` bundle granted
  below), not by Core dispatching an HTTP call INTO the service. `kind:
  "external"` (with `endpoint_kind`/`base_url`/`model`) is for an agent
  whose BRAIN Core reaches by calling out to an HTTP endpoint; this persona
  has no such inbound entrypoint to call — its brain and mouth both live
  inside the stage-1 `AgentSession` process, reached only via the voice
  runtime connection this task registers. So `kind` is left at its default,
  `"native"`, and no `base_url`/`endpoint_kind`/`model` is set.

  ## `tool_profile`

  Scoped to what a single-purpose meeting assistant actually calls, per
  a live test run: `messaging` (for the `post_to_meeting_chat`
  hand-off's `send_media`, plus `react`) and `context_read` (for
  `space_get_context`, the "tool call" e2e case, plus `space_get_messages`/
  `space_search_messages`/`canvas_get`/`canvas_list`/`principal_search` —
  all read-only).

  Round 3 (task 01a0d4a0 stage 5) DROPPED `space` and `memory`, both
  present in stage 2's original grant. Neither bundle can be narrowed any
  finer than dropping it outright — `Platform.Federation.ToolAuthorization`
  authorizes per BUNDLE, not per tool name, so keeping a bundle at all for
  one read tool inside it (e.g. `space_list`) grants everything else in
  that bundle too. Concretely, dropping them refuses:

    * `space` — `space_create`, `space_leave`, `dm_create` (all writes a
      voice-only persona that never manages spaces or opens DMs has no
      business holding), plus `space_list`/`space_list_agents` (reads this
      persona doesn't need either — it always knows its own space_id from
      the LiveKit job metadata now, task 01a0d4a0 stage 5 item 3, not by
      enumerating spaces).
    * `memory` — `memory_create`/`memory_delete`/`memory_rename`/
      `memory_str_replace`/`memory_insert` (writes) and `memory_search`/
      `memory_view`/`org_memory_*` (reads this persona has no use for — its
      own SOUL/IDENTITY/VOICE files are loaded at boot via
      `MemoryContext.upsert_workspace_file/4` above, never through this MCP
      surface).

  Still explicitly NOT granted: `task`, `plan`, `review` — this persona
  does not manage tasks, plans, or reviews. Also not granted (and not asked
  for by the stage): `canvas` (the WRITE bundle — `canvas_create`/
  `canvas_patch`/etc.; `context_read` already grants the read-only
  `canvas_get`/`canvas_list`), `files`, `federation`, `skill`, `attachment`,
  `meetings`, `mail` — it has no file work, does not administer runtimes or
  skills, handles no attachments, sends no mail, and its presence in a room
  is a raw LiveKit participant driven by the stage-1 process rather than an
  MCP `meetings` bundle tool call.
  """

  use Mix.Task

  alias Platform.Accounts.User
  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.{Agent, MemoryContext}
  alias Platform.Federation
  alias Platform.Repo

  @shortdoc "Seed the Burrow persona and its voice runtime"

  @usage "Usage: mix platform.seed_meeting_voice_agent --owner <email>"

  @agent_slug "meeting-assistant"
  @agent_name "Burrow"

  # The LiveKit `agent_name` `services/meeting-voice-agent`'s worker
  # registers itself under (`WorkerOptions(agent_name: config.worker_agent_name)`
  # in `agent.py`, defaulting from `MVA_WORKER_AGENT_NAME` in `config.py` to
  # this exact string). Stamped into this runtime's
  # `metadata["client_info"]["livekit_agent_name"]` (task 01a0d4a0) so
  # `Platform.Meetings.dispatch_meeting_join/3` can route an invite through
  # LiveKit's own Agent Dispatch API instead of the `RuntimeChannel`
  # presence check that this Python worker — a job-shaped livekit-agents
  # process, not a persistent Core client — never satisfies. If either
  # side's default ever changes, they must change together.
  @livekit_agent_name "meeting-voice-agent"

  @tool_profile ~w(messaging context_read)

  # Informational only (moduledoc note in Platform.Agents.Voice) — actual
  # synthesis happens in services/meeting-voice-agent's TTS client, pointed
  # at the install's speaches Kokoro-82M. "openai" is the closest of the two
  # `Platform.Agents.Voice.known_providers/0` entries: speaches serves an
  # OpenAI-compatible TTS API, and this deployment has no ElevenLabs key.
  # `voice_id`/`model` mirror services/meeting-voice-agent's own
  # MVA_TTS_VOICE / MVA_TTS_MODEL defaults so this row and the service agree.
  @voice_config %{
    "provider" => "openai",
    "voice_id" => "af_heart",
    "model" => "kokoro"
  }

  @soul_md """
  You are Burrow — a distinct, single-purpose persona whose \
  only job is to be a helpful, real-time voice participant in Burrow \
  meetings. You are not a task manager, a planner, or a reviewer: you have \
  no task, plan, or review tools, and you don't create or track work items. \
  You listen, you help conversationally, and you get out of the way.
  """

  @identity_md """
  Name: Burrow.

  What you are: a dedicated voice participant, built on the \
  meeting-voice-agent livekit-agents runtime \
  (services/meeting-voice-agent/), separate from a general agent's usual \
  text-dispatch brain. You join meetings, listen continuously, and answer \
  by voice using the install's local STT/TTS and the wave LLM endpoint.

  What you are not: a general-purpose assistant. You don't manage tasks, \
  epics, plans, or reviews — those tools are not in your surface. If \
  someone needs that kind of help, say so plainly and let a human or \
  another agent pick it up.
  """

  @voice_md """
  Speak briefly — one or two sentences per turn. This is a live \
  conversation, not a written reply.

  If interrupted, stop immediately and listen; whoever spoke over you has \
  the floor.

  For anything long, multi-part, out of scope for a spoken answer, or \
  better read than heard — a plan, a detailed explanation, a list — give \
  ONE short spoken acknowledgement (for example "I'll drop the details in \
  chat") and then call post_to_meeting_chat exactly once with the full \
  answer. Do not speak the long answer aloud, and do not try a different \
  tool as a substitute hand-off path. If post_to_meeting_chat itself \
  returns an error, say briefly that you couldn't post it and stop there — \
  never retry the hand-off with another tool, and never use a mail or \
  email tool for any purpose in a meeting.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [owner: :string])

    abort_on_bad_args!(rest, invalid)

    owner_email = opts[:owner] || Mix.raise("--owner is required\n\n#{@usage}")

    Mix.Task.run("app.start")

    owner = resolve_owner!(owner_email)

    {:ok, %{agent: agent, runtime: runtime, raw_token: raw_token}} = seed!(owner)

    Mix.shell().info(
      """
      Burrow seeded
        agent_id:        #{agent.id}
        agent_slug:      #{agent.slug}
        runtime_id:      #{runtime.runtime_id}
        tool_profile: #{Enum.join(RuntimeProfiles.tool_profile(runtime), ", ")}\
      """ <> token_line(raw_token)
    )

    :ok
  end

  @doc """
  The idempotent seed itself, split out from `run/1` so tests (and any
  future caller) can invoke it directly without going through Mix/CLI/env
  plumbing.

  Returns `{:ok, %{agent: agent, runtime: runtime, raw_token: raw_token | nil}}`.
  `raw_token` is `nil` whenever an existing voice runtime row was reused
  instead of minted — the token is only ever generated (and returned) at
  creation time, exactly as `Federation.register_voice_runtime/3` itself
  only returns one on the call that activates a new row.
  """
  @spec seed!(User.t()) ::
          {:ok,
           %{
             agent: Agent.t(),
             runtime: Platform.Agents.AgentRuntime.t(),
             raw_token: String.t() | nil
           }}
  def seed!(%User{} = owner) do
    agent = find_or_create_agent!()
    write_workspace_files!(agent)
    agent = ensure_voice_config!(agent)
    {runtime, raw_token} = ensure_voice_runtime!(owner, agent)

    {:ok, %{agent: agent, runtime: runtime, raw_token: raw_token}}
  end

  defp token_line(nil) do
    "\n  (voice runtime already existed — no new token minted or shown)"
  end

  defp token_line(raw_token) do
    "\n  token:           #{raw_token}\n" <>
      "  WARNING: the token is shown once and will not be shown again; only its hash is stored."
  end

  # Scoped to the NULL workspace (IS NULL): the row the insert below would
  # collide with. An unscoped slug lookup raised Ecto.MultipleResultsError as
  # soon as two workspaces shared the slug (task 01a0e77c).
  defp find_or_create_agent! do
    case Platform.Agents.SlugLookup.resolve(@agent_slug, workspace_id: nil) do
      {:error, :not_found} ->
        %Agent{}
        |> Agent.changeset(%{slug: @agent_slug, name: @agent_name, status: "active"})
        |> Repo.insert()
        |> unwrap!("insert Burrow agent")

      {:ok, %Agent{} = agent} ->
        agent

      {:error, :ambiguous_slug} ->
        Mix.raise(
          "more than one agent has slug #{inspect(@agent_slug)} with no workspace; " <>
            "refusing to pick one. Resolve the duplicate (or address the agent by UUID) and rerun"
        )
    end
  end

  defp write_workspace_files!(agent) do
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "SOUL.md", @soul_md)
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "IDENTITY.md", @identity_md)
    {:ok, _} = MemoryContext.upsert_workspace_file(agent.id, "VOICE.md", @voice_md)
    :ok
  end

  defp ensure_voice_config!(agent) do
    if agent.voice_config == @voice_config do
      agent
    else
      agent
      |> Agent.changeset(%{voice_config: @voice_config})
      |> Repo.update()
      |> unwrap!("set Burrow voice_config")
    end
  end

  defp ensure_voice_runtime!(owner, agent) do
    case find_existing_voice_runtime(agent) do
      nil ->
        {:ok, runtime, raw_token} =
          Federation.register_voice_runtime(owner.id, agent, %{
            metadata: %{"client_info" => voice_client_info()}
          })

        {:ok, _profile} = RuntimeProfiles.set_tool_profile(runtime, @tool_profile)
        {runtime, raw_token}

      %Platform.Agents.AgentRuntime{} = existing ->
        {:ok, runtime} =
          Federation.update_metadata(existing, %{
            "client_info" => voice_client_info()
          })

        {:ok, _profile} = RuntimeProfiles.set_tool_profile(runtime, @tool_profile)
        {runtime, nil}
    end
  end

  # `livekit_agent_name` sits alongside `features` deliberately: both are
  # read out of the same `metadata["client_info"]` map by
  # `Platform.Meetings` (`capability_from_metadata/1` for the feature list,
  # the task 01a0d4a0 `livekit_dispatch_agent_name/1` for this key), and
  # `Federation.update_metadata/2` replaces `"client_info"` wholesale on
  # every call — so a rerun that only set `features` here would silently
  # drop this key on the second run.
  defp voice_client_info do
    %{"features" => ["meeting_voice"], "livekit_agent_name" => @livekit_agent_name}
  end

  # Identity marker, not a capability check: `register_voice_runtime/3`
  # always stamps `metadata["role"] == "voice"` regardless of declared
  # features, so this is the stable way to find "the mouth row THIS task
  # provisioned" across reruns even before/after `client_info.features` is
  # (re)applied.
  defp find_existing_voice_runtime(agent) do
    agent
    |> Federation.voice_runtimes_for_agent()
    |> Enum.find(&(&1.metadata["role"] == "voice"))
  end

  defp resolve_owner!(email) do
    Repo.get_by(User, email: email) ||
      Mix.raise("Unknown owner #{inspect(email)} — no user has that email")
  end

  defp unwrap!({:ok, result}, _what), do: result

  defp unwrap!({:error, changeset}, what),
    do: Mix.raise("Could not #{what}: #{inspect(changeset.errors)}")

  defp abort_on_bad_args!([], []), do: :ok

  defp abort_on_bad_args!(rest, invalid) do
    Mix.raise(
      "unrecognised arguments: " <>
        Enum.map_join(rest ++ Enum.map(invalid, &elem(&1, 0)), " ", &inspect/1) <>
        "\n\n#{@usage}"
    )
  end
end

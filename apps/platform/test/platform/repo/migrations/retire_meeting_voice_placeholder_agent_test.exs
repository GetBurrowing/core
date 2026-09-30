defmodule Platform.Repo.Migrations.RetireMeetingVoicePlaceholderAgentTest do
  @moduledoc """
  Coverage for `20260927120000_retire_meeting_voice_placeholder_agent`
  (task 01a0e47c stage 1).

  Models the deployed-shaped defect directly: build a "Meeting Voice"
  agent + runtime the way the ad hoc prod row was actually shaped (an
  active, federated agent with its own runtime declaring the
  `meeting_voice` feature — no separate voice "mouth" row, unlike
  `meeting-assistant`), confirm it shows up exactly where Harper's mistaken
  invite came from (`Chat.list_agents_for_picker/0`, and therefore
  `MeetingLive.invitable_roster/1`'s "outsiders" list for a brand-new
  meeting space), run the migration's `up/0`, and assert it is gone from
  both — plus that `meeting-assistant` and `agentvoice` are each left
  completely alone.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.RetireMeetingVoicePlaceholderAgent

  # Migration files live under `priv/repo/migrations/` and are not on the
  # compile path — walk up from `test/platform/repo/migrations/<this>.exs`
  # to the `apps/platform/` app root, then descend into
  # `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260927120000_retire_meeting_voice_placeholder_agent.exs"
                  ])

  setup do
    # `mix test` runs `ecto.migrate` in the same VM, which compiles every
    # migration file — so the module is normally already loaded. Load it
    # ourselves when it is not, so a syntax error in the migration surfaces
    # here rather than as a full-suite compile break at deploy time.
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp owner! do
    n = unique()

    Repo.insert!(%Platform.Accounts.User{
      email: "meeting-voice-retire-test-#{n}@example.com",
      name: "Retire Test Owner #{n}",
      oidc_sub: "oidc-mv-retire-#{n}"
    })
  end

  # The deployed-shaped placeholder: an ACTIVE, native agent whose
  # `runtime_type` is "external" (so it classifies `:fed_conversational`,
  # matching the live prod row found via `principal_search`), with exactly
  # one runtime row of its own declaring `meeting_voice` — no separate
  # voice "mouth" row, unlike `meeting-assistant`.
  defp seed_placeholder! do
    owner = owner!()

    agent =
      Repo.insert!(
        Agent.changeset(%Agent{}, %{
          slug: "meeting-voice",
          name: "Meeting Voice",
          status: "active",
          runtime_type: "external"
        })
      )

    runtime =
      Repo.insert!(
        AgentRuntime.changeset(%AgentRuntime{}, %{
          runtime_id: "meeting-voice-moon-test-#{unique()}",
          owner_user_id: owner.id,
          agent_id: agent.id,
          status: "active",
          metadata: %{"client_info" => %{"features" => ["meeting_voice"]}}
        })
      )

    {:ok, agent} =
      agent
      |> Agent.changeset(%{runtime_id: runtime.id})
      |> Repo.update()

    %{agent: agent, runtime: runtime}
  end

  # A fresh chat space, the same shape `Meetings.create_meeting/1` mints
  # per meeting (task 01a05553) — no membership, so the invite roster's
  # "outsiders" branch (`Chat.list_agents_for_picker/0`) is the only thing
  # that can offer any agent here.
  defp fresh_meeting_space! do
    n = unique()

    Repo.insert!(%Chat.Space{
      kind: "meeting",
      name: "Retire-test meeting space #{n}",
      slug: "retire-test-meeting-space-#{n}"
    })
  end

  describe "up/0 against a deployed-shaped Meeting Voice placeholder row" do
    test "the placeholder is offered before the migration runs (positive control)" do
      %{agent: agent} = seed_placeholder!()
      space = fresh_meeting_space!()

      picker_slugs = Chat.list_agents_for_picker() |> Enum.map(& &1.slug)
      assert "meeting-voice" in picker_slugs

      invitable_names =
        space.id
        |> PlatformWeb.MeetingLive.invitable_agents([])
        |> Enum.map(& &1.name)

      assert "Meeting Voice" in invitable_names,
             "positive control failed — the fixture must reproduce Harper's mistaken-invite " <>
               "shape before the migration can be shown to fix it"

      # Sanity: the fixture matches the live row's classification.
      assert Platform.Agents.Kind.classify(agent) == :fed_conversational
    end

    test "archives the agent, so it is gone from the picker and every fresh meeting's invite list" do
      %{agent: agent} = seed_placeholder!()
      space = fresh_meeting_space!()

      assert :ok = @migration_module.up()

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.status == "archived"

      refute "meeting-voice" in Enum.map(Chat.list_agents_for_picker(), & &1.slug)

      invitable_names =
        space.id
        |> PlatformWeb.MeetingLive.invitable_agents([])
        |> Enum.map(& &1.name)

      refute "Meeting Voice" in invitable_names

      invite_rows = PlatformWeb.MeetingLive.invite_rows(space.id, [])

      refute Enum.any?(invite_rows, &(&1.agent.name == "Meeting Voice")),
             "the string \"Meeting Voice\" must not appear anywhere in the invite list, " <>
               "not merely be unclickable"
    end

    test "revokes the placeholder's runtime (status + cleared token hash), leaving an audit trail" do
      %{agent: agent, runtime: runtime} = seed_placeholder!()

      {:ok, runtime} =
        runtime
        |> AgentRuntime.changeset(%{auth_token_hash: AgentRuntime.hash_token("some-raw-token")})
        |> Repo.update()

      assert is_binary(runtime.auth_token_hash)

      assert :ok = @migration_module.up()

      reloaded_runtime = Repo.get!(AgentRuntime, runtime.id)
      assert reloaded_runtime.status == "revoked"
      assert is_nil(reloaded_runtime.auth_token_hash)

      reloaded_agent = Repo.get!(Agent, agent.id)

      assert %{"retired_at" => at, "retired_by" => by, "retired_reason" => reason} =
               reloaded_agent.metadata["retired"]

      assert is_binary(at)
      assert by =~ "01a0e47c"
      assert reason =~ "Dalton"
      assert reason =~ "Harper"
    end

    test "is idempotent — a second up/0 against the migrated rows changes nothing" do
      %{agent: agent, runtime: runtime} = seed_placeholder!()

      assert :ok = @migration_module.up()
      first_agent = Repo.get!(Agent, agent.id)
      first_runtime = Repo.get!(AgentRuntime, runtime.id)

      assert :ok = @migration_module.up()
      second_agent = Repo.get!(Agent, agent.id)
      second_runtime = Repo.get!(AgentRuntime, runtime.id)

      assert second_agent.status == first_agent.status
      assert second_agent.metadata == first_agent.metadata

      assert second_agent.updated_at == first_agent.updated_at,
             "a rerun must skip an already-archived row rather than re-writing it"

      assert second_runtime.status == first_runtime.status

      assert second_runtime.updated_at == first_runtime.updated_at,
             "a rerun must skip an already-revoked runtime rather than re-writing it"
    end

    test "does not touch the meeting-assistant agent (the correctly-renamed persona)" do
      owner = owner!()

      assistant =
        Repo.insert!(
          Agent.changeset(%Agent{}, %{
            slug: "meeting-assistant",
            name: "Burrow",
            status: "active"
          })
        )

      {:ok, assistant_runtime, _token} = Federation.register_voice_runtime(owner.id, assistant)

      seed_placeholder!()

      assert :ok = @migration_module.up()

      reloaded_assistant = Repo.get!(Agent, assistant.id)
      assert reloaded_assistant.status == "active"
      assert reloaded_assistant.metadata["retired"] == nil

      reloaded_runtime = Repo.get!(AgentRuntime, assistant_runtime.id)
      assert reloaded_runtime.status == "active"
    end

    test "does not touch agentvoice (a separate, older, pre-existing voice agent, out of scope)" do
      agentvoice =
        Repo.insert!(
          Agent.changeset(%Agent{}, %{
            slug: "agentvoice",
            name: "AgentVoice",
            status: "active",
            runtime_type: "external"
          })
        )

      seed_placeholder!()

      assert :ok = @migration_module.up()

      reloaded = Repo.get!(Agent, agentvoice.id)
      assert reloaded.status == "active"
      assert reloaded.metadata["retired"] == nil
    end
  end

  describe "up/0 when no matching row exists" do
    test "is a no-op and creates nothing" do
      before_count =
        Repo.aggregate(from(a in Agent, where: a.slug == "meeting-voice"), :count)

      assert before_count == 0

      assert :ok = @migration_module.up()

      after_count =
        Repo.aggregate(from(a in Agent, where: a.slug == "meeting-voice"), :count)

      assert after_count == 0
    end
  end
end

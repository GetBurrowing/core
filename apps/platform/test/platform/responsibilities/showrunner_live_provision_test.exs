defmodule Platform.Responsibilities.ShowrunnerLiveProvisionTest do
  @moduledoc """
  Provisioning the showrunner on a RUNNING node (task 01a1eaf6 stage 4 review
  fix).

  The e2e reviewer found that `Platform.Showrunner.provision/1` on a live node
  left the Router's `event_topics` bucket holding its boot-time copy of the
  `showrunner.post_show` row, which had no space, so completing the show
  meeting was refused (`:no_space_configured`) until a restart, with only a
  log line to show for it.

  Here the Router is started (`start_supervised!/1`) BEFORE provisioning, from
  a row with no space, exactly as on a node that booted before the operator
  ran the mix task. The meeting is then completed through the real publisher,
  `Platform.Meetings.PubSub.broadcast_meeting_finished/2`, and the dispatch is
  observed through the Router's own `[:platform, :responsibility, *]`
  telemetry. No restart, no `Process.sleep`: `:sys.get_state/1` is the barrier.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.RuntimeProfile
  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Inbox.Item
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ShowrunnerPostShow, as: PostShow
  alias Platform.Responsibilities.Handlers.ShowrunnerRecordingPrep, as: Prep
  alias Platform.Responsibilities.Router
  alias Platform.Showrunner
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Config
  alias Platform.Showrunner.Episode
  alias Platform.ShowrunnerSocialFixture
  alias Platform.Tenancy

  @key "showrunner.post_show"

  setup do
    :ok = ShowrunnerSocialFixture.register()

    user = World.create_user!()
    World.plain_member!(user, Tenancy.get_org_by_slug!("globex"))

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "showrunner-#{System.unique_integer([:positive])}",
        name: "Showrunner",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    runtime!(agent, user, ["context_read", "social"])

    {:ok, space} =
      Chat.create_space(%{
        name: "How to Computer",
        slug: "htc-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "HTC #{System.unique_integer([:positive])}",
        repo_url: "https://example.com/htc"
      })

    # The boot-time row: registered by the registry, never configured.
    [spec] = PostShow.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    assert Config.read(row).space_id == nil

    attach_telemetry()

    %{
      agent: Repo.get!(Agent, agent.id),
      user: user,
      space: space,
      attrs: %{
        agent_id: agent.id,
        space_id: space.id,
        project_id: project.id,
        escalate_user_id: user.id
      }
    }
  end

  # ── fixtures ──

  defp runtime!(agent, owner, modules) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "showrunner-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: modules,
      restricted_permissions: RuntimeProfiles.translated_permissions(modules)
    })

    agent |> Ecto.Changeset.change(runtime_id: runtime.id) |> Repo.update!()
  end

  defp start_router do
    name = Module.concat([Router, "ShowrunnerLive#{System.unique_integer([:positive])}"])
    pid = start_supervised!({Router, name: name, check_interval_ms: :timer.hours(24)})
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp attach_telemetry do
    test_pid = self()
    handler_id = "showrunner-live-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:platform, :responsibility, :fired], [:platform, :responsibility, :failed]],
        fn [_, _, outcome], _measurements, %{key: key} = metadata, _ ->
          if key == @key, do: send(test_pid, {:post_show, outcome, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # A board at Record whose logistics name the show's meeting room.
  defp board_at_record!(%{agent: agent, space: space, user: user}, room) do
    {:ok, episode} = Episode.new(number: 7, title: "The 3% rule for backups")

    episode =
      Enum.reduce_while(tl(Episode.stages()), episode, fn next, ep ->
        ep =
          if ep.stage == :run_sheet do
            {:ok, ep} =
              Episode.put_run_sheet(ep, [
                %{
                  "id" => "seg-1",
                  "starts_at_s" => 0,
                  "ends_at_s" => 600,
                  "name" => "Cold open",
                  "talking_points" => %{"host" => "Open dry."},
                  "callback_episode" => nil,
                  "stat_cards" => []
                }
              ])

            ep
          else
            ep
          end

        if ep.stage == :record do
          {:halt, ep}
        else
          {:ok, ep} = Episode.advance(ep, next)
          {:cont, ep}
        end
      end)

    {:ok, bctx} = Board.context(space.id, agent, user.id)
    {:ok, canvas} = Board.create(bctx, episode, %{"week" => "2026-W47"})
    on_exit(fn -> CanvasServer.stop(canvas.id) end)

    {:ok, episode, document} = Board.read(canvas)

    {:ok, _} =
      Board.write(
        bctx,
        canvas,
        Board.put_meta(document, Prep.meta_key(), %{
          "meeting_space_id" => room.space_id,
          "room_name" => room.room_id
        }),
        episode
      )

    canvas
  end

  defp escalations(user) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and like(i.title, "Showrunner needs you%") and
            is_nil(i.dismissed_at)
      )
    )
  end

  # ── tests ──

  test "provisioning a running node takes effect live: completing the show meeting dispatches post_show",
       ctx do
    router = start_router()

    # The Router booted from the unconfigured row.
    [booted] = Enum.filter(:sys.get_state(router).by_trigger.event_topics, &(&1.key == @key))
    assert Config.read(booted).space_id == nil

    assert {:ok, %{role: :assigned}} = Showrunner.provision(ctx.attrs)
    _ = :sys.get_state(router)

    room = %{
      room_id: "htc-ep-7-#{System.unique_integer([:positive])}",
      space_id: Ecto.UUID.generate()
    }

    board_at_record!(ctx, room)

    :ok =
      Platform.Meetings.PubSub.broadcast_meeting_finished(room.room_id, %{
        room_id: room.room_id,
        space_id: room.space_id,
        transcript_id: Ecto.UUID.generate()
      })

    _ = :sys.get_state(router)

    assert_received {:post_show, :fired, %{dispatch_kind: :native}}
    refute_received {:post_show, :failed, _}
  end

  test "a refusal for a missing space raises one Needs-you item to the escalate user, not just a log line",
       ctx do
    assert {:ok, _} = Showrunner.provision(ctx.attrs)

    # An operator later clears the show space; the escalate user stays.
    row = Responsibilities.get_by_key(@key)
    {:ok, config} = Config.to_trigger(row.trigger_config, %{space_id: nil})
    {:ok, _} = Responsibilities.update_responsibility(row, %{trigger_config: config})

    for _ <- 1..2 do
      assert {:error, {:context_gather_refused, :no_space_configured}} =
               Router.fire(@key, %{kind: :manual})
    end

    assert [item] = escalations(ctx.user)
    assert item.title =~ "isn't set up"
  end
end

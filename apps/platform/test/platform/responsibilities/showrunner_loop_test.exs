defmodule Platform.Responsibilities.ShowrunnerLoopTest do
  @moduledoc """
  The second half of the showrunner's weekly loop (task 01a1eaf6 stage 4):
  `showrunner.recording_prep`, `showrunner.post_show` and `showrunner.retro`,
  driven through their provider callbacks against a real space, board,
  calendar, meeting, inbox and journal.

  The `social` tool bundle is `Platform.ShowrunnerSocialFixture`, a test-only
  extension with that bundle name: core never names the real Social module.
  Whether the agent can reach it is decided by its runtime's EFFECTIVE tools,
  so the fixtures build a real runtime, profile and owner.

  Seams are arguments (`opts[:now]`, `opts[:busy]`, `opts[:fire]`), never app
  config.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Access.RuntimeProfile
  alias Platform.Access.RuntimeProfiles
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Calendar.AgentAccess
  alias Platform.Calendar.Consent
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Variant
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Inbox.Item
  alias Platform.Meetings.Meeting
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ShowrunnerPostShow, as: PostShow
  alias Platform.Responsibilities.Handlers.ShowrunnerRecordingPrep, as: Prep
  alias Platform.Responsibilities.Handlers.ShowrunnerRetro, as: Retro
  alias Platform.Responsibilities.Handlers.ShowrunnerRunSheet, as: RunSheet
  alias Platform.Responsibilities.Providers.Showrunner, as: Provider
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Config
  alias Platform.Showrunner.Episode
  alias Platform.Showrunner.SocialBundle
  alias Platform.ShowrunnerSocialFixture
  alias Platform.Tenancy

  setup do
    :ok = ShowrunnerSocialFixture.register()
    :ok = Seeds.seed_defaults(only_keys: ["showrunner"])

    user = member!()
    agent = agent!()
    {:ok, _} = Roles.assign_role("showrunner", agent.id)

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "How to Computer #{System.unique_integer([:positive])}",
        repo_url: "https://example.com/htc"
      })

    space = space!()
    join!(space, "agent", agent.id)
    join!(space, "user", user.id)

    rows =
      for handler <- [Prep, PostShow, Retro], into: %{} do
        [spec] = handler.register()
        {:ok, row} = Responsibilities.upsert_by_key(spec)

        {:ok, config} =
          Config.to_trigger(row.trigger_config, %{
            space_id: space.id,
            project_id: project.id,
            escalate_user_id: user.id
          })

        {:ok, row} = Responsibilities.update_responsibility(row, %{trigger_config: config})
        {handler, row}
      end

    test_pid = self()

    fire = fn key, meta ->
      send(test_pid, {:fired, key, meta})
      {:ok, :observed}
    end

    %{
      agent: agent,
      user: user,
      space: space,
      project: project,
      rows: rows,
      opts: [fire: fire]
    }
  end

  # ── fixtures ──

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Tenancy.get_org_by_slug!("globex"))
    user
  end

  defp agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "showrunner-#{System.unique_integer([:positive])}",
      name: "Showrunner",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  # A real runtime with `modules` in its profile, owned by `owner`, linked
  # as the agent's runtime.
  defp runtime!(agent, %User{} = owner, modules) do
    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "showrunner-#{System.unique_integer([:positive])}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Showrunner"
      })

    Repo.insert!(%RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: modules,
      restricted_permissions: RuntimeProfiles.translated_permissions(modules)
    })

    agent |> Ecto.Changeset.change(runtime_id: runtime.id) |> Repo.update!()
    runtime
  end

  defp with_social!(%{agent: agent, user: user}),
    do: runtime!(agent, user, ["context_read", "social"])

  defp without_social!(%{agent: agent, user: user}),
    do: runtime!(agent, user, ["context_read"])

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "How to Computer",
        slug: "htc-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp join!(space, type, id) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp segment(id, from, to) do
    %{
      "id" => id,
      "starts_at_s" => from,
      "ends_at_s" => to,
      "name" => "Segment #{id}",
      "talking_points" => %{"host" => "Open dry.", "co-host" => "Bring the number."},
      "callback_episode" => nil,
      "stat_cards" => [%{"text" => "3% test restores", "source_url" => "https://example.com/s"}]
    }
  end

  # A board at `stage` with a three-segment run sheet and nothing open.
  defp board!(%{agent: agent, space: space, user: user}, stage) do
    {:ok, episode} = Episode.new(number: 7, title: "The 3% rule for backups")

    episode =
      Enum.reduce_while(Episode.stages() |> tl(), episode, fn next, ep ->
        ep =
          if ep.stage == :run_sheet do
            {:ok, ep} =
              Episode.put_run_sheet(ep, [
                segment("seg-1", 0, 600),
                segment("seg-2", 600, 1500),
                segment("seg-3", 1500, 2400)
              ])

            ep
          else
            ep
          end

        if ep.stage == stage do
          {:halt, ep}
        else
          {:ok, ep} = Episode.advance(ep, next)
          {:cont, ep}
        end
      end)

    {:ok, bctx} = Board.context(space.id, agent, user.id)
    {:ok, canvas} = Board.create(bctx, episode, %{"week" => "2026-W47"})
    on_exit(fn -> CanvasServer.stop(canvas.id) end)
    canvas
  end

  defp put_logistics!(%{agent: agent, space: space, user: user}, canvas, values) do
    {:ok, bctx} = Board.context(space.id, agent, user.id)
    {:ok, episode, document} = Board.read(canvas)

    {:ok, _} =
      Board.write(bctx, canvas, Board.put_meta(document, Prep.meta_key(), values), episode)
  end

  defp escalations(user) do
    Repo.all(
      from(i in Item,
        where: i.user_id == ^user.id and like(i.title, "Showrunner needs you%")
      )
    )
  end

  # The next Wednesday 10:00 UTC (at least a day away), the day before the
  # default Thursday 19:00 UTC slot.
  defp wednesday do
    today = Date.utc_today()
    ahead = Integer.mod(3 - Date.day_of_week(today), 7)
    ahead = if ahead == 0, do: 7, else: ahead
    DateTime.new!(Date.add(today, ahead), ~T[10:00:00], "Etc/UTC")
  end

  defp thursday_at(wed, hour), do: DateTime.add(wed, (24 + hour - 10) * 3600, :second)

  defp grant_calendar!(%{agent: agent, user: user}) do
    {:ok, _} =
      AgentAccess.grant(Platform.Access.Scope.for_user(user), agent.id, %{
        read: true,
        read_private: true,
        create: true,
        preapprove: true
      })
  end

  defp meetings(project),
    do: Repo.all(from(m in Meeting, where: m.project_id == ^project.id))

  # ── the guard itself ──

  describe "SocialBundle" do
    test "present when the runtime's effective tools carry the social bundle", ctx do
      with_social!(ctx)
      assert SocialBundle.status(Repo.get!(Agent, ctx.agent.id)) == :present
    end

    test "absent when the profile lacks it, or there is no runtime", ctx do
      assert SocialBundle.status(ctx.agent) == {:absent, :no_runtime}
      without_social!(ctx)
      assert SocialBundle.status(Repo.get!(Agent, ctx.agent.id)) == {:absent, :not_effective}
    end

    test "absent when the profile lists social but the owner cap removes it", ctx do
      # An owner with no org membership holds nothing, so the cap empties the
      # profile's `social` tools even though the profile names the bundle.
      capped_owner = World.create_user!()
      runtime = runtime!(ctx.agent, capped_owner, ["context_read", "social"])
      assert "social" in RuntimeProfiles.tool_profile(runtime)
      assert SocialBundle.status(Repo.get!(Agent, ctx.agent.id)) == {:absent, :not_effective}
    end
  end

  # ── recording prep ──

  describe "recording prep" do
    test "a clash proposes the next free slot, creates the room and posts the checklist, with no inbox row",
         ctx do
      %{rows: rows, user: user, space: space, project: project} = ctx
      with_social!(ctx)
      grant_calendar!(ctx)
      canvas = board!(ctx, :run_sheet)
      wed = wednesday()

      # The default slot (Thursday 19:00 UTC) is taken on the host's calendar.
      {:ok, _} =
        Platform.Calendar.create_event(Platform.Access.Scope.for_user(user), %{
          title: "Dentist",
          starts_at: thursday_at(wed, 19),
          ends_at: thursday_at(wed, 20),
          time_zone: "Etc/UTC"
        })

      assert {:handled, summary} = Prep.run(rows[Prep], %{}, now: wed)
      assert summary.proposed
      assert summary.checklist_posted

      assert {:ok, episode, document} = Board.read(canvas)
      assert episode.stage == :logistics
      # 19:00 and 19:30 overlap the hour-long clash; 20:00 is the next free step.
      assert DateTime.compare(episode.records_at, thursday_at(wed, 20)) == :eq
      assert episode.room_status == "room ready"
      assert episode.needs_you == []

      [consent] = Repo.all(from(c in Consent, where: c.owner_id == ^user.id))
      hold = Repo.get!(Platform.Calendar.Event, consent.hold_id)
      assert DateTime.compare(hold.starts_at, thursday_at(wed, 20)) == :eq

      assert [meeting] = meetings(project)
      assert Board.meta(document, Prep.meta_key())["meeting_id"] == meeting.id

      assert [checklist] =
               space.id
               |> Chat.list_messages()
               |> Enum.filter(&(&1.content =~ "Pre-show checklist"))

      assert checklist.content =~ "Mic"
      assert checklist.content =~ "Room: /meetings/"
      assert checklist.content =~ "Links"

      assert escalations(user) == []

      # The same day again: nothing new.
      assert {:handled, again} = Prep.run(rows[Prep], %{}, now: wed)
      refute again.proposed
      refute again.checklist_posted
      assert [_] = meetings(project)
      assert escalations(user) == []
    end

    test "no free slot raises exactly one inbox row and one Needs-you item, and no second room",
         ctx do
      %{rows: rows, user: user, project: project} = ctx
      with_social!(ctx)
      grant_calendar!(ctx)
      canvas = board!(ctx, :run_sheet)
      wed = wednesday()

      assert {:handled, _} = Prep.run(rows[Prep], %{}, now: wed)
      assert [_meeting] = meetings(project)
      assert escalations(user) == []

      full = fn _owners, from, to ->
        {:ok, [{DateTime.add(from, -86_400, :second), DateTime.add(to, 86_400, :second)}]}
      end

      for _ <- 1..2 do
        assert {:handled, %{parked: "recording-time"}} =
                 Prep.run(rows[Prep], %{}, now: wed, busy: full)
      end

      assert [row] = escalations(user)
      assert row.title =~ "No free recording slot"

      assert {:ok, episode, _} = Board.read(canvas)
      assert [%{id: "recording-time"}] = episode.needs_you
      assert [_meeting] = meetings(project)
    end

    test "recording day seats the agent in the room with the run sheet and moves to Record",
         ctx do
      %{rows: rows, agent: agent, project: project} = ctx
      with_social!(ctx)
      grant_calendar!(ctx)
      canvas = board!(ctx, :run_sheet)
      wed = wednesday()

      assert {:handled, _} = Prep.run(rows[Prep], %{}, now: wed)

      assert {:handled, %{attached: true, stage: :record}} =
               Prep.run(rows[Prep], %{}, now: thursday_at(wed, 9))

      [meeting] = meetings(project)
      assert Chat.get_agent_participant(meeting.chat_space_id, agent.id)

      assert [seed] = Chat.list_messages(meeting.chat_space_id)
      assert seed.content =~ "Segment seg-2"
      assert seed.content =~ "meeting_say"

      assert {:ok, %Episode{stage: :record}, _} = Board.read(canvas)
    end
  end

  # ── post show ──

  describe "post show" do
    test "with the social bundle: the prompt names the social tools, forbids publishing, and the output's ids are recorded",
         ctx do
      %{rows: rows, user: user, space: space} = ctx
      with_social!(ctx)
      canvas = board!(ctx, :record)

      assert {:ok, context} = PostShow.gather_context(rows[PostShow], %{canvas_id: canvas.id})
      context = Map.put(context, :__responsibility__, rows[PostShow])
      assert {:ok, %{user: prompt}} = Provider.build_prompt(context)
      assert prompt =~ "social_clip_propose"
      assert prompt =~ "social_draft_create"
      assert prompt =~ "Never publish, schedule or submit anything"
      assert prompt =~ "Do not call `social_clip_submit`"

      output = %{
        "show_notes" => "We tested restores. Most people never have.",
        "clip_ids" => ["clip-1", "clip-2"],
        "draft_ids" => ["draft-1", "draft-2", "draft-3"]
      }

      assert :ok = PostShow.handle_output(rows[PostShow], output, %{canvas_id: canvas.id})

      assert {:ok, episode, document} = Board.read(canvas)
      assert episode.stage == :post
      assert [%{id: "approve-posts", question: "Approve posts"}] = episode.needs_you
      assert episode.stages.post == :needs_you

      post = Board.meta(document, PostShow.meta_key())
      assert post["clip_ids"] == ["clip-1", "clip-2"]
      assert post["draft_ids"] == ["draft-1", "draft-2", "draft-3"]

      notes = Enum.find(document["root"] |> nodes(), &(&1["id"] == "episode-show-notes"))
      assert notes["props"]["content"] =~ "Most people never have."

      assert [_] = escalations(user)

      journal =
        Platform.Org.Context.get_context_file(
          Platform.Showrunner.Memory.journal_path(space.id, DateTime.utc_now())
        )

      assert journal.content =~ "[show] Episode 7: show notes:"

      # Recorded once: a second output is refused, nothing doubles.
      assert {:error, :already_posted} =
               PostShow.handle_output(rows[PostShow], output, %{canvas_id: canvas.id})

      assert [_] = escalations(user)
    end

    test "a broadcast for another meeting is skipped without a dispatch", ctx do
      with_social!(ctx)
      canvas = board!(ctx, :record)
      put_logistics!(ctx, canvas, %{"meeting_space_id" => Ecto.UUID.generate()})

      meta = %{payload: %{space_id: Ecto.UUID.generate(), room_id: "meeting-x"}}

      assert {:handled, %{skipped: :not_the_show_meeting}} =
               PostShow.gather_context(ctx.rows[PostShow], meta)
    end

    test "missing audio is retried once, then becomes a Needs-you item", ctx do
      %{rows: rows, user: user, opts: opts} = ctx
      with_social!(ctx)
      canvas = board!(ctx, :record)
      failed = %{"error" => "missing_audio", "detail" => "no track"}

      assert :ok = PostShow.handle_output(rows[PostShow], failed, %{canvas_id: canvas.id}, opts)
      assert_received {:fired, "showrunner.post_show", %{retry_attempt: 1, canvas_id: id}}
      assert id == canvas.id
      assert escalations(user) == []

      meta = %{canvas_id: canvas.id, retry_attempt: 1}
      assert :ok = PostShow.handle_output(rows[PostShow], failed, meta, opts)
      refute_received {:fired, "showrunner.post_show", _}

      assert {:ok, episode, _} = Board.read(canvas)
      assert [%{id: id}] = episode.needs_you
      assert id == PostShow.failed_item_id()
      assert [_] = escalations(user)
    end
  end

  # ── the bundle guard on both social-dependent keys ──

  describe "without the social bundle" do
    for {name, handler, stage} <- [
          {"post_show", PostShow, :record},
          {"retro", Retro, :post}
        ] do
      test "#{name} parks on one Needs-you item: no dispatch, no raise", ctx do
        %{rows: rows, user: user} = ctx
        without_social!(ctx)
        handler = unquote(handler)
        canvas = board!(ctx, unquote(stage))

        for _ <- 1..2 do
          assert {:handled, %{parked: "social-missing"}} =
                   Provider.gather_context(rows[handler], %{canvas_id: canvas.id})
        end

        assert {:ok, episode, _} = Board.read(canvas)
        assert [%{id: "social-missing", question: question}] = episode.needs_you
        assert question =~ "can't reach Social"
        assert [_] = escalations(user)
      end
    end

    test "post_show parks when the owner cap removes a profiled social bundle", ctx do
      runtime!(ctx.agent, World.create_user!(), ["context_read", "social"])
      canvas = board!(ctx, :record)

      assert {:handled, %{parked: "social-missing"}} =
               PostShow.gather_context(ctx.rows[PostShow], %{canvas_id: canvas.id})

      assert {:ok, %Episode{needs_you: [%{id: "social-missing"}]}, _} = Board.read(canvas)
    end

    test "a without-modules build (no extension at all) parks too", ctx do
      with_social!(ctx)
      Application.put_env(:platform, :extensions, [])
      canvas = board!(ctx, :post)

      assert {:handled, %{parked: "social-missing"}} =
               Retro.gather_context(ctx.rows[Retro], %{canvas_id: canvas.id})
    end
  end

  # ── retro ──

  describe "retro" do
    test "records kept and cut segments and emits kept_share", ctx do
      %{rows: rows, space: space} = ctx
      with_social!(ctx)
      canvas = board!(ctx, :post)

      # An experiment on the run-sheet surface that assigned this episode.
      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "kept-share-#{System.unique_integer([:positive])}",
          name: "Kept share",
          surface_key: "showrunner.run_sheet",
          surface_target: "showrunner.run_sheet"
        })

      {:ok, _} =
        Experiments.add_variant(experiment, %{
          slug: "treatment",
          payload: %{"prompt_slug" => "showrunner.run_sheet.v1", "directive" => "Shorter."},
          weight: 1
        })

      {:ok, %Experiment{status: "running"} = running} =
        Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

      Repo.update_all(
        from(v in Variant,
          where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
        ),
        set: [weight: 0]
      )

      _ = RunSheet.payload(canvas.id)

      assert {:ok, context} = Retro.gather_context(rows[Retro], %{canvas_id: canvas.id})
      context = Map.put(context, :__responsibility__, rows[Retro])
      assert {:ok, %{user: prompt}} = Provider.build_prompt(context)
      assert prompt =~ "social_results_get"
      assert prompt =~ "seg-3: Segment seg-3"

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "showrunner-kept-share-#{inspect(ref)}",
        Retro.telemetry_event(),
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:kept_share, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("showrunner-kept-share-#{inspect(ref)}") end)

      output = %{
        "kept_segment_ids" => ["seg-1", "seg-2"],
        "cut_segment_ids" => ["seg-3"],
        "clip_results" => [%{"clip_id" => "clip-1", "segment_id" => "seg-1", "views" => 1200}]
      }

      assert :ok = Retro.handle_output(rows[Retro], output, %{canvas_id: canvas.id})

      assert_received {:kept_share, %{kept_share: share}, %{canvas_id: id, kept: 2, total: 3}}
      assert id == canvas.id
      assert_in_delta share, 2 / 3, 1.0e-9

      assert {:ok, episode, document} = Board.read(canvas)
      assert episode.retro.kept_segment_ids == ["seg-1", "seg-2"]
      assert episode.retro.cut_segment_ids == ["seg-3"]
      assert_in_delta Episode.kept_share(episode), 2 / 3, 1.0e-9

      retro = Enum.find(nodes(document["root"]), &(&1["id"] == "episode-retro"))
      assert retro["props"]["content"] =~ "Kept 2 of 3 segments"

      assert [signal] = Signals.list(running)
      assert signal.label == "kept_share"
      assert signal.source_type == Retro.signal_source_type()
      assert_in_delta signal.confidence, 2 / 3, 1.0e-6

      journal =
        Platform.Org.Context.get_context_file(
          Platform.Showrunner.Memory.journal_path(space.id, DateTime.utc_now())
        )

      assert journal.content =~ "[show] Episode 7: retro: Kept 2 of 3 segments"
    end

    test "a retro naming a segment that is not on the run sheet is refused", ctx do
      with_social!(ctx)
      canvas = board!(ctx, :post)

      assert {:error, :retro_off_sheet} =
               Retro.handle_output(
                 ctx.rows[Retro],
                 %{"kept_segment_ids" => ["seg-9"], "cut_segment_ids" => []},
                 %{canvas_id: canvas.id}
               )
    end
  end

  defp nodes(%{"children" => children} = node) when is_list(children),
    do: [node | Enum.flat_map(children, &nodes/1)]

  defp nodes(node), do: [node]
end

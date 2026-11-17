defmodule Platform.Responsibilities.ShowrunnerHandlersTest do
  @moduledoc """
  The three `showrunner.*` handlers (task 01a1eaf6 stage 3), driven through
  their provider callbacks against a real space, canvas, inbox and journal.

  A fire function that messages this process is passed as `opts[:fire]`, so
  a step that starts the next one (a written brief, a redraft) is observed
  instead of dispatched. It is an argument, not app config (stage 4).
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Inbox.Item
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ShowrunnerResearchBrief, as: Brief
  alias Platform.Responsibilities.Handlers.ShowrunnerRunSheet, as: RunSheet
  alias Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch, as: Pitch
  alias Platform.Responsibilities.Providers.Showrunner, as: Provider
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Config
  alias Platform.Showrunner.Memory

  @topics [
    %{"title" => "Where automation savings go", "angle" => "a", "why_now" => "w"},
    %{"title" => "The 3% rule for backups", "angle" => "a", "why_now" => "w"},
    %{"title" => "Why printers still jam", "angle" => "a", "why_now" => "w"}
  ]

  setup do
    test_pid = self()

    fire = fn key, meta ->
      send(test_pid, {:fired, key, meta})
      {:ok, :observed}
    end

    :ok = Seeds.seed_defaults(only_keys: ["showrunner"])

    agent = agent!()
    {:ok, _} = Roles.assign_role("showrunner", agent.id)
    user = user!()
    space = space!()
    join!(space, "agent", agent.id)
    join!(space, "user", user.id)

    rows =
      for handler <- [Pitch, Brief, RunSheet], into: %{} do
        [spec] = handler.register()
        {:ok, row} = Responsibilities.upsert_by_key(spec)

        {:ok, config} =
          Config.to_trigger(row.trigger_config, %{
            space_id: space.id,
            escalate_user_id: user.id
          })

        {:ok, row} = Responsibilities.update_responsibility(row, %{trigger_config: config})
        {handler, row}
      end

    %{agent: agent, user: user, space: space, rows: rows, opts: [fire: fire]}
  end

  # ── fixtures ──

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

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "show-#{n}@example.com", name: "Host #{n}", oidc_sub: "show-#{n}"})
    |> Repo.insert!()
  end

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

  defp inbox_rows(user), do: Repo.all(from(i in Item, where: i.user_id == ^user.id))

  defp board!(space) do
    canvas = Board.current(space.id)
    on_exit(fn -> CanvasServer.stop(canvas.id) end)
    canvas
  end

  defp pitch!(%{rows: rows, space: space}) do
    assert :ok = Pitch.handle_output(rows[Pitch], %{"topics" => @topics}, %{})
    board!(space)
  end

  # Pitch -> pick -> brief: a board at Run sheet with no run sheet.
  defp at_run_sheet!(%{rows: rows, opts: opts} = ctx) do
    canvas = pitch!(ctx)
    assert {:ok, canvas} = Brief.pick_topic(canvas, "The 3% rule for backups", opts)
    assert_received {:fired, "showrunner.research_brief", %{canvas_id: id}} when id == canvas.id

    brief = %{
      "brief" => "Most people never test a restore.",
      "sources" => [%{"title" => "Survey", "url" => "https://example.com/survey"}],
      "numbers" => [%{"text" => "3% test restores", "source_url" => "https://example.com/s"}],
      "counterpoints" => ["Cloud sync is not backup, but it helps."]
    }

    assert :ok = Brief.handle_output(rows[Brief], brief, %{canvas_id: canvas.id}, opts)
    assert_received {:fired, "showrunner.run_sheet", %{canvas_id: _}}
    canvas
  end

  defp segment(id, from, to, cards) do
    %{
      "id" => id,
      "starts_at_s" => from,
      "ends_at_s" => to,
      "name" => "Segment #{id}",
      "talking_points" => %{"host" => "Open dry.", "co-host" => "Bring the number."},
      "callback_episode" => nil,
      "stat_cards" => cards
    }
  end

  # ── weekly pitch ──

  describe "weekly pitch" do
    test "a pitch whose topic count is not 3 is refused, with no side effect", ctx do
      %{rows: rows, space: space, user: user} = ctx

      for topics <- [Enum.take(@topics, 2), @topics ++ [%{"title" => "Fourth"}], []] do
        assert {:error, {:topic_count, n}} =
                 Pitch.handle_output(rows[Pitch], %{"topics" => topics}, %{})

        assert n == length(topics)
      end

      assert Board.list(space.id) == []
      assert Chat.list_messages(space.id) == []
      assert inbox_rows(user) == []
    end

    test "the pitch creates the episode canvas with Pitch at needs_you and a pick item", ctx do
      %{rows: rows, space: space, user: user} = ctx

      # Also accepts the model's JSON as text.
      assert :ok = Pitch.handle_output(rows[Pitch], Jason.encode!(%{"topics" => @topics}), %{})
      canvas = board!(space)

      assert {:ok, episode, _document} = Board.read(canvas)
      assert episode.number == 1
      assert episode.stage == :pitch
      assert episode.stages.pitch == :needs_you

      titles = Enum.map(@topics, & &1["title"])

      assert episode.needs_you == [
               %{id: Pitch.pick_id(), question: "Pick this topic", options: titles}
             ]

      # The topics message, the canvas message and the pick escalation.
      contents = space.id |> Chat.list_messages() |> Enum.map(& &1.content)
      assert Enum.any?(contents, &(&1 =~ "three topics" and &1 =~ "Why printers still jam"))
      assert Enum.any?(contents, &(&1 =~ "Needs you: Pick this topic"))

      # One inbox row: the human decision, to the configured person.
      assert [%Item{kind: "chat_mention", source_type: "chat_message"}] = inbox_rows(user)

      assert [%{number: 1, lines: [line]}] = Memory.recent_episodes(space.id)
      assert line =~ "[show] Episode 1: pitched"

      # A second fire in the same week does nothing.
      assert :ok = Pitch.handle_output(rows[Pitch], %{"topics" => @topics}, %{})
      assert length(Board.list(space.id)) == 1
      assert length(inbox_rows(user)) == 1
    end

    test "gather_context refuses with no space configured", %{rows: rows} do
      row = %{rows[Pitch] | trigger_config: %{"expression" => "0 14 * * 1"}}
      assert {:error, :no_space_configured} = Pitch.gather_context(row, %{})
    end

    test "the prompt tells the agent to fetch Social itself and carry on without it", ctx do
      assert {:ok, context} = Pitch.gather_context(ctx.rows[Pitch], %{})
      assert context.dispatch_space_id == ctx.space.id

      assert {:ok, %{user: user}} =
               Provider.build_prompt(Map.put(context, :__responsibility__, ctx.rows[Pitch]))

      assert user =~ "social_results_get"
      assert user =~ "social_clip_list"
      assert user =~ "carry on without them"
      assert user =~ "host, co-host"
    end
  end

  # ── run sheet ──

  describe "run sheet" do
    test "an unsourced stat is redrafted once, then escalated as a Needs-you item", ctx do
      %{rows: rows, user: user} = ctx
      canvas = at_run_sheet!(ctx)
      inbox_before = length(inbox_rows(user))

      draft = %{
        "segments" => [
          segment("s1", 0, 600, [%{"text" => "9 in 10 never restore", "source_url" => ""}])
        ],
        "through_line" => "Backups are seatbelts.",
        "cold_open" => %{"a" => "A", "b" => "B"}
      }

      # First invalid draft: one redraft is requested, nothing is escalated.
      assert :ok =
               RunSheet.handle_output(rows[RunSheet], draft, %{canvas_id: canvas.id}, ctx.opts)

      assert_received {:fired, "showrunner.run_sheet",
                       %{redraft_attempt: 1, redraft_error: error, canvas_id: id}}

      assert id == canvas.id
      assert error =~ "s"
      assert {:ok, episode, _} = Board.read(canvas)
      assert episode.run_sheet == []
      assert episode.needs_you == []
      assert length(inbox_rows(user)) == inbox_before

      # The redraft's prompt carries the reason.
      assert {:ok, context} =
               RunSheet.gather_context(rows[RunSheet], %{
                 canvas_id: canvas.id,
                 redraft_attempt: 1,
                 redraft_error: error
               })

      assert context.redraft_note =~ error

      # Still invalid on the redraft: a Needs-you item and one inbox row; no third draft.
      assert :ok =
               RunSheet.handle_output(
                 rows[RunSheet],
                 draft,
                 %{canvas_id: canvas.id, redraft_attempt: 1},
                 ctx.opts
               )

      refute_received {:fired, "showrunner.run_sheet", _}
      assert {:ok, episode, _} = Board.read(canvas)
      assert episode.run_sheet == []
      assert [%{id: invalid_id}] = episode.needs_you
      assert invalid_id == RunSheet.invalid_id()
      assert episode.stages.run_sheet == :needs_you
      assert length(inbox_rows(user)) == inbox_before + 1
    end

    test "a valid draft is written and the cold-open A/B choice goes to Needs you", ctx do
      %{rows: rows, user: user, space: space} = ctx
      canvas = at_run_sheet!(ctx)
      inbox_before = length(inbox_rows(user))

      draft = %{
        "segments" => [
          segment("s1", 0, 300, []),
          segment("s2", 300, 2400, [
            %{"text" => "3% test restores", "source_url" => "https://example.com/s"}
          ])
        ],
        "through_line" => "Backups are seatbelts.",
        "cold_open" => %{"a" => "Open on a dead laptop.", "b" => "Open on the 3%."}
      }

      assert :ok =
               RunSheet.handle_output(rows[RunSheet], draft, %{canvas_id: canvas.id}, ctx.opts)

      assert {:ok, episode, document} = Board.read(canvas)
      assert Enum.map(episode.run_sheet, & &1.id) == ["s1", "s2"]
      assert [%{id: "cold-open", options: ["Cold open A", "Cold open B"]}] = episode.needs_you
      assert document["meta"]["showrunner_draft"]["through_line"] == "Backups are seatbelts."
      assert length(inbox_rows(user)) == inbox_before + 1

      assert [%{lines: lines}] = Memory.recent_episodes(space.id)
      assert Enum.any?(lines, &(&1 =~ "run sheet: 2 segments"))
    end

    test "the experiment arm's prompt_slug is the template the run sheet is drafted from" do
      canvas_id = Ecto.UUID.generate()
      context = %{canvas_id: canvas_id, topic: "Backups", host_roles: "host, co-host"}

      # Control: the seeded v1 body.
      assert {:ok, %{user: control}} = RunSheet.build_prompt(context)
      assert control =~ "You are drafting the run sheet"

      {:ok, _} =
        PromptTemplates.create_template(%{
          slug: "showrunner.run_sheet.arm-test",
          name: "Arm",
          content: "ARM BODY for {{topic}}",
          variables: ["topic"]
        })

      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "run-sheet-#{System.unique_integer([:positive])}",
          name: "Run sheet arm",
          surface_key: "showrunner.run_sheet",
          surface_target: "showrunner.run_sheet"
        })

      {:ok, _} =
        Experiments.add_variant(experiment, %{
          slug: "treatment",
          payload: %{"prompt_slug" => "showrunner.run_sheet.arm-test", "directive" => "Shorter."},
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

      assert RunSheet.payload(canvas_id)["prompt_slug"] == "showrunner.run_sheet.arm-test"
      assert {:ok, %{user: user}} = RunSheet.build_prompt(context)
      assert user =~ "ARM BODY for Backups"
      assert user =~ "Experiment directive (showrunner.run_sheet)\n\nShorter."
      refute user =~ "You are drafting the run sheet"
    end
  end

  # ── unreadable board ──

  describe "a hand-edited board" do
    test "produces one Needs-you item and an inbox row, and never raises", ctx do
      %{rows: rows, user: user, space: space, agent: agent} = ctx
      canvas = pitch!(ctx)
      {:ok, _episode, document} = Board.read(canvas)

      # A human deletes the production rail.
      edited =
        update_in(document, ["root", "children"], fn children ->
          Enum.reject(children, &(&1["type"] == "production_rail"))
        end)

      assert {:ok, _} =
               Chat.patch_canvas({:agent, agent.id}, canvas, [{:replace_document, edited}])

      assert {:error, _} = Board.read(canvas)
      inbox_before = length(inbox_rows(user))

      assert {:error, {:board_unreadable, _}} =
               Brief.gather_context(rows[Brief], %{canvas_id: canvas.id})

      # Handlers asked again on the same board do not raise or pile up items.
      assert :ok =
               RunSheet.handle_output(
                 rows[RunSheet],
                 %{"segments" => []},
                 %{canvas_id: canvas.id},
                 ctx.opts
               )

      assert :ok =
               Brief.handle_output(
                 rows[Brief],
                 %{"brief" => "x", "sources" => [%{"url" => "https://e.x"}]},
                 %{canvas_id: canvas.id},
                 ctx.opts
               )

      {:ok, %{document: live}} = CanvasServer.describe(canvas.id)
      [needs_you] = Enum.filter(live["root"]["children"], &(&1["type"] == "needs_you"))
      raised = Enum.filter(needs_you["props"]["items"], &(&1["id"] == "board-unreadable"))
      assert [%{"question" => question}] = raised
      assert question == Board.unreadable_question()

      assert length(inbox_rows(user)) == inbox_before + 1

      assert space.id
             |> Chat.list_messages()
             |> Enum.count(&(&1.content =~ Board.unreadable_question())) == 1
    end
  end
end

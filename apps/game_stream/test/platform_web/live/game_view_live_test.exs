defmodule PlatformWeb.GameViewLiveTest do
  @moduledoc """
  The Game view (task 01a1557a-efdd stage 2): `/m/games?canvas=<id>&from=...`
  through core's generic extension page, nested as `"ext-page-games"`.

  NOT async: cases toggle `:game_stream, :enabled` (global app env), which
  decides whether Play claims the `games` page at all.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.GameStream
  alias Platform.GameStream.SessionRecord
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias PlatformWeb.GameViewLive

  @sha "a1b2c3d0123456789abcdef0123456789abcdef0"
  @default_from "/files?tab=browse&type=game"
  @browser_url "/files?tab=browse&type=game&sort=name&view=list"

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      sup = Platform.GameStream.Supervisor.sessions()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end

      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    org = Tenancy.get_org_by_slug!("globex")
    space = channel!(%{org_id: org.id, name: "Review builds"})
    user = create_user!(%{name: "Alex"})
    plain_member!(user, org)
    add_user!(space.id, user.id)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Voltron #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/example/voltron"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Dash tuning"})
    task = task |> Ecto.Changeset.change(status: "in_review") |> Repo.update!()

    %{org: org, space: space, user: user, task: task}
  end

  defp game_node(props) do
    %{
      "id" => "game-stream",
      "type" => "game_stream",
      "props" =>
        Map.merge(
          %{
            "session_id" => "gv-none",
            "review_sha" => @sha,
            "branch" => "task/x",
            "title" => "Node"
          },
          props
        )
    }
  end

  defp doc_canvas!(space, children, title \\ "E2E Runner") do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "stack", "props" => %{}, "children" => children},
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  defp game!(ctx, props \\ %{}),
    do: doc_canvas!(ctx.space, [game_node(Map.merge(%{"task_id" => ctx.task.id}, props))])

  defp game_path(canvas_id, from) do
    case from do
      nil -> "/m/games?canvas=" <> canvas_id
      from -> "/m/games?canvas=" <> canvas_id <> "&from=" <> URI.encode_www_form(from)
    end
  end

  defp open(ctx, canvas_id, from \\ nil) do
    {:ok, view, _html} = live(login(ctx.conn, ctx.user.id), game_path(canvas_id, from))
    child = find_live_child(view, "ext-page-games")
    assert child, "the Game view did not nest under ext-page-games"
    {view, child}
  end

  defp doc(child), do: child |> render() |> LazyHTML.from_fragment()

  defp attr(child, selector, name) do
    child |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp text(child, selector),
    do: child |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  # Each matched node's text, one string per node.
  defp texts(child, selector),
    do:
      child
      |> doc()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> squish()))

  defp squish(s), do: s |> String.split() |> Enum.join(" ")

  describe "the page" do
    test "registers /m/games only while GAME_STREAM_ENABLED is set" do
      assert %{live_view: GameViewLive, module: :chat, permission: "canvas.read"} =
               Platform.Extensions.live_page_for("games")

      Application.put_env(:game_stream, :enabled, false)
      assert Platform.Extensions.live_page_for("games") == nil
    end

    test "with GameStream disabled /m/games is a 404", ctx do
      canvas = game!(ctx)
      Application.put_env(:game_stream, :enabled, false)

      assert_error_sent(404, fn ->
        get(login(ctx.conn, ctx.user.id), game_path(canvas.id, nil))
      end)
    end

    test "full window over the glass bar, three tabs with Settings selected, Back to from", ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id, @browser_url)

      assert has_element?(
               child,
               ~s(#game-view[data-fullscreen-viewer][role=dialog][aria-modal=true][aria-label=Game])
             )

      assert has_element?(child, "#game-view.fixed.inset-0.z-50.bg-stage.text-on-viewer")

      assert attr(child, "[role=tablist] [role=tab]", "phx-value-tab") ==
               ~w(settings insights review)

      assert text(child, "[role=tab]") == "Settings Insights Review"
      assert attr(child, "[role=tab][aria-selected=true]", "phx-value-tab") == ["settings"]
      assert has_element?(child, "[data-role=game-tab-body-settings]:not([hidden])")
      assert has_element?(child, "[data-role=game-tab-body-insights][hidden]")
      assert has_element?(child, "[data-role=game-tab-body-review][hidden]")

      assert attr(child, "[data-role=game-back]", "href") == [@browser_url]
      assert attr(child, "[data-role=game-back-desktop]", "href") == [@browser_url]
      assert attr(child, "[data-role=game-back]", "aria-label") == ["Back"]
    end

    test "the top bar, sub line, status line, caption and the desktop header", ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id, @browser_url)

      assert text(child, "[data-role=game-title]") == "E2E Runner"
      assert text(child, "[data-role=game-build]") == "build a1b2c3d"

      assert text(child, "[data-role=game-sub]") ==
               "playable · review build of the task branch · Review builds"

      assert text(child, "[data-role=game-status]") == "stream ready"
      assert text(child, "[data-role=game-caption]") == "⟳ landscape ok"
      assert text(child, "[data-role=game-caption-desktop]") == "⟳ 16:9 · resizes with the pane"
      assert attr(child, "[data-role=game-share]", "aria-label") == ["Share build link"]

      assert text(child, "[data-role=game-back-desktop]") == "Review builds"
      assert text(child, "[data-role=game-build-desktop]") == "build a1b2c3d"

      assert text(child, "[data-role=game-sub-desktop]") ==
               "playable · review build of the task branch"

      assert text(child, "[data-role=game-task]") == "Task: Dash tuning"
      assert attr(child, "[data-role=game-task]", "href") == ["/tasks/" <> ctx.task.id]
      assert text(child, "[data-role=game-share-desktop]") == "Copy build link"

      # The node renders once, in stage chrome.
      assert attr(child, "[phx-hook=GameStream]", "data-gs-chrome") == ["stage"]
    end

    test "a task that is not in review is a draft; no task means no Task button", ctx do
      ctx.task |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()
      {_view, child} = open(ctx, game!(ctx).id)
      assert text(child, "[data-role=game-sub]") =~ ~r/^draft · /
      assert text(child, "[data-role=game-sub-desktop]") =~ ~r/^draft · /

      {_view, child} = open(ctx, game!(ctx, %{"task_id" => "not-a-uuid"}).id)
      assert text(child, "[data-role=game-sub]") =~ ~r/^draft · /
      refute has_element?(child, "[data-role=game-task]")
    end

    test "title falls back to the node's title, then the kind's", ctx do
      untitled = doc_canvas!(ctx.space, [game_node(%{"task_id" => ctx.task.id})], nil)
      {_view, child} = open(ctx, untitled.id)
      assert text(child, "[data-role=game-title]") == "Node"

      bare =
        doc_canvas!(
          ctx.space,
          [%{"id" => "g", "type" => "game_stream", "props" => %{"session_id" => "s"}}],
          nil
        )

      {_view, child} = open(ctx, bare.id)
      assert text(child, "[data-role=game-title]") == "Playable review build"
      refute has_element?(child, "[data-role=game-build]")
    end
  end

  describe "dialog semantics (stage 3)" do
    test "the root carries GameViewDialog, which drops role=dialog at lg (vitest holds the hook)",
         ctx do
      {_view, child} = open(ctx, game!(ctx).id)
      assert attr(child, "#game-view", "phx-hook") == ["GameViewDialog"]

      {_view, child} = open(ctx, Ecto.UUID.generate())
      assert attr(child, "#game-view", "phx-hook") == ["GameViewDialog"]
    end
  end

  describe "Settings (stage 3)" do
    test "Review build names the sha7 and the task status; 50 ms is pressed by default", ctx do
      {_view, child} = open(ctx, game!(ctx).id)

      assert text(child, "[data-role=game-set-build] > span:first-child") ==
               "Review build task branch tip · sha a1b2c3d · in_review"

      assert text(child, "[data-role=game-build-seg]") == "a1b2c3d"
      assert attr(child, "[data-role=game-build-seg]", "aria-pressed") == ["true"]

      assert text(child, "[data-role=game-set-warn] > span:first-child") ==
               "Latency warning input-to-photon · warns above"

      assert text(child, "[data-role=game-warn-seg]") == "30 ms 50 ms 80 ms"

      assert attr(child, "[data-role=game-warn-seg]", "aria-pressed") ==
               ~w(false true false)

      refute has_element?(child, "[data-role=game-warn-seg][disabled]")
      refute has_element?(child, "[data-role=game-set-warn-note]")

      assert text(child, "[data-role=game-set-restart]") ==
               "Restart with these settings Restart"

      # Not in the build: no rows the play host cannot back.
      html = render(child)

      for gone <- ["Your slot", "Seed", "Difficulty", "Speed", "Encoder preset"],
          do: refute(html =~ gone, gone)
    end

    test "pressing 80 ms as a writer writes latency_warn_ms 80 to the node and presses it", ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id)
      [wrapper] = attr(child, "[phx-hook=GameStream]", "id")

      child |> element("#game-warn-80") |> render_click()

      assert attr(child, "[data-role=game-warn-seg]", "aria-pressed") ==
               ~w(false false true)

      {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      [node] = doc["root"]["children"]
      assert node["props"]["latency_warn_ms"] == 80

      # The wrapper's own attribute carries it (the hook re-reads it in
      # updated()); the node is not remounted.
      assert attr(child, "[phx-hook=GameStream]", "data-latency-warn-ms") == ["80"]
      assert attr(child, "[phx-hook=GameStream]", "id") == [wrapper]

      # A value that is not a choice writes nothing.
      render_click(child, "game_latency_warn", %{"ms" => "999"})
      {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      assert hd(doc["root"]["children"])["props"]["latency_warn_ms"] == 80
    end

    test "a reader who is not a space member sees the segments disabled and writes nothing",
         ctx do
      canvas = game!(ctx)
      reader = create_user!(%{name: "Reader"})
      plain_member!(reader, ctx.org)

      assert {:ok, _, _} = Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:user, reader.id})

      assert {:error, :forbidden} =
               Chat.CanvasAccess.fetch_for_writer(canvas.id, {:user, reader.id})

      {_view, child} = open(%{ctx | user: reader}, canvas.id)

      assert attr(child, "[data-role=game-warn-seg]", "disabled") == ["", "", ""]

      assert text(child, "[data-role=game-set-warn-note]") ==
               "Only members of this canvas's space can change this."

      render_click(child, "game_latency_warn", %{"ms" => "80"})
      assert attr(child, "[data-role=game-warn-seg]", "aria-pressed") == ~w(false true false)

      {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      refute Map.has_key?(hd(doc["root"]["children"])["props"], "latency_warn_ms")
      assert has_element?(child, "[data-role=game-restart][disabled]")
    end

    test "Restart is disabled while nothing has ended", ctx do
      {_view, child} = open(ctx, game!(ctx).id)
      assert has_element?(child, "[data-role=game-restart][disabled]")
      refute attr(child, "[data-role=game-restart]", "phx-click") |> Enum.any?()
    end
  end

  describe "Insights (stage 3)" do
    defp run!(task, attrs) do
      now = DateTime.utc_now()

      %SessionRecord{}
      |> SessionRecord.changeset(
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            task_id: task.id,
            review_sha: @sha,
            branch: "task/x",
            host_runtime_id: "host",
            ended_state: "ended",
            started_at: DateTime.add(now, -120, :second),
            ended_at: now
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    test "no samples: the no-sample tiles, the sparkline empty copy, the 0:00 row, no runs",
         ctx do
      {_view, child} = open(ctx, game!(ctx).id)
      child |> element("#game-tab-insights") |> render_click()

      assert texts(child, "[data-role=game-tile-fps] > *") == ["—", "fps now"]
      assert texts(child, "[data-role=game-tile-latency] > *") == ["—", "input→photon"]
      assert texts(child, "[data-role=game-tile-runs] > *") == ["0", "runs today"]

      assert text(child, "[data-role=game-insights] [data-role=game-section-label]") ==
               "FPS · last 2 min Latency · last 2 min Session timeline Recent runs"

      assert text(child, "[data-role=game-spark-fps-empty]") == "Stats appear while you play."
      assert text(child, "[data-role=game-spark-latency-empty]") == "Stats appear while you play."
      refute has_element?(child, "svg[data-role=game-spark-fps]")

      assert texts(child, "[data-role=game-ev] b") == ["0:00"]
      assert texts(child, "[data-role=game-ev]") == ["0:00play host: unavailable"]
      assert attr(child, "#game-timeline", "phx-update") == ["stream"]

      assert text(child, "[data-role=game-runs-empty]") == "No finished runs yet."
      refute has_element?(child, "[data-role=game-run]")
    end

    test "two SessionRecord rows list newest first; runs today counts the last 24h only", ctx do
      now = DateTime.utc_now()

      run!(ctx.task, %{
        ended_reason: "Build failed",
        ended_state: "failed",
        started_at: DateTime.add(now, -600, :second),
        ended_at: DateTime.add(now, -548, :second),
        fps_avg: nil
      })

      run!(ctx.task, %{
        ended_reason: "Stopped",
        started_at: DateTime.add(now, -180, :second),
        ended_at: DateTime.add(now, -72, :second),
        fps_avg: 58.0
      })

      old_start = DateTime.add(now, -3 * 86_400, :second)

      run!(ctx.task, %{
        ended_reason: nil,
        started_at: old_start,
        ended_at: DateTime.add(old_start, 65, :second),
        fps_avg: 30.4
      })

      # Another task's run is not listed.
      {:ok, other} = Tasks.create_task(%{project_id: ctx.task.project_id, title: "Other"})
      run!(other, %{ended_reason: "Elsewhere"})

      {_view, child} = open(ctx, game!(ctx).id)
      child |> element("#game-tab-insights") |> render_click()

      assert attr(child, "#game-runs", "phx-update") == ["stream"]

      assert texts(child, "[data-role=game-run-main]") ==
               ["Stopped · 1:48", "Build failed · 0:52", "ended · 1:05"]

      [r1, r2, r3] =
        child
        |> doc()
        |> LazyHTML.query("[data-role=game-run-small]")
        |> Enum.map(&squish(LazyHTML.text(&1)))

      hhmm = Calendar.strftime(DateTime.add(now, -72, :second), "%H:%M")
      assert r1 == hhmm <> " · 58fps avg"

      assert r2 == Calendar.strftime(DateTime.add(now, -548, :second), "%H:%M") or
               r2 == "yesterday"

      assert r3 ==
               Calendar.strftime(DateTime.add(old_start, 65, :second), "%Y-%m-%d") <>
                 " · 30fps avg"

      assert texts(child, "[data-role=game-tile-runs] > *") == ["2", "runs today"]
      refute has_element?(child, "[data-role=game-runs-empty]")
    end

    test "recent_runs/2 lists at most 10 by default, newest first", ctx do
      now = DateTime.utc_now()

      for i <- 1..11 do
        run!(ctx.task, %{
          ended_reason: "R#{i}",
          started_at: DateTime.add(now, -i * 60 - 30, :second),
          ended_at: DateTime.add(now, -i * 60, :second)
        })
      end

      runs = GameStream.recent_runs(ctx.task.id)
      assert length(runs) == 10
      assert hd(runs).ended_reason == "R1"
      assert List.last(runs).ended_reason == "R10"
    end

    test "recent_runs/2 and runs_since/2 refuse a task id that is not a UUID" do
      assert GameStream.recent_runs("nope") == []
      assert GameStream.runs_since("nope", DateTime.utc_now()) == 0
    end

    test "spark_points/1 follows the masters' scale and needs two values" do
      assert GameViewLive.spark_points([]) == nil
      assert GameViewLive.spark_points([60.0, nil]) == nil
      assert GameViewLive.spark_points([50.0, 60.0]) == "0.0,52.0 320.0,6.0"
      assert GameViewLive.spark_points([5.0, 5.0, 5.0]) == "0.0,52.0 160.0,52.0 320.0,52.0"
    end
  end

  describe "tabs" do
    test "switching selects the tab and never remounts the node; an unknown tab is ignored",
         ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id)
      [wrapper] = attr(child, "[phx-hook=GameStream]", "id")

      child |> element("#game-tab-insights") |> render_click()
      assert attr(child, "[role=tab][aria-selected=true]", "phx-value-tab") == ["insights"]
      assert has_element?(child, "[data-role=game-tab-body-insights]:not([hidden])")
      assert has_element?(child, "[data-role=game-tab-body-settings][hidden]")

      child |> element("#game-tab-review") |> render_click()
      assert attr(child, "[role=tab][aria-selected=true]", "phx-value-tab") == ["review"]

      render_click(child, "game_tab", %{"tab" => "bogus"})
      assert attr(child, "[role=tab][aria-selected=true]", "phx-value-tab") == ["review"]

      assert attr(child, "[phx-hook=GameStream]", "id") == [wrapper]
      assert attr(child, "[phx-hook=GameStream]", "phx-update") == ["ignore"]
    end
  end

  describe "Back" do
    test "from=//example.com, from=https://example.com, a backslash and no from go to the Games browser",
         ctx do
      canvas = game!(ctx)

      for from <- [
            "//example.com",
            "https://example.com",
            "/\\example.com",
            "/x?u=https://e.com",
            nil
          ] do
        {_view, child} = open(ctx, canvas.id, from)
        assert attr(child, "[data-role=game-back]", "href") == [@default_from], inspect(from)
      end
    end

    test "safe_from/1 keeps a local path of at most 512 bytes" do
      assert GameViewLive.safe_from("/files?tab=browse") == "/files?tab=browse"
      long = "/" <> String.duplicate("a", 511)
      assert GameViewLive.safe_from(long) == long
      assert GameViewLive.safe_from(long <> "a") == @default_from
      assert GameViewLive.safe_from("files") == @default_from
      assert GameViewLive.safe_from(nil) == @default_from
      assert GameViewLive.safe_from(%{"a" => 1}) == @default_from
    end
  end

  describe "unavailable" do
    defp assert_unavailable(child) do
      assert has_element?(child, "[data-role=game-unavailable]", "This game isn't available.")
      assert attr(child, "[data-role=game-back]", "href") == [@default_from]
      refute has_element?(child, "[phx-hook=GameStream]")
      refute has_element?(child, "[role=tablist]")
    end

    test "a canvas the viewer cannot read", ctx do
      other_org = Tenancy.get_org_by_slug!("initech")
      private = channel!(%{org_id: other_org.id, name: "Elsewhere"})
      canvas = doc_canvas!(private, [game_node(%{"task_id" => ctx.task.id})])

      assert {:error, :forbidden} =
               Chat.CanvasAccess.fetch_for_viewer(canvas.id, {:user, ctx.user.id})

      {_view, child} = open(ctx, canvas.id)
      assert_unavailable(child)
    end

    test "an unknown id and a malformed id", ctx do
      {_view, child} = open(ctx, Ecto.UUID.generate())
      assert_unavailable(child)
      {_view, child} = open(ctx, "nope")
      assert_unavailable(child)
    end

    test "a canvas with no game_stream node", ctx do
      plain =
        doc_canvas!(ctx.space, [
          %{"id" => "md", "type" => "markdown", "props" => %{"content" => "Notes"}}
        ])

      {_view, child} = open(ctx, plain.id)
      assert_unavailable(child)
    end
  end

  describe "Share" do
    test "copies the canvas's /m/games URL without from, and toasts", ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id, @browser_url)
      url = PlatformWeb.Endpoint.url() <> "/m/games?canvas=" <> canvas.id

      assert attr(child, "[data-role=game-share]", "data-share-url") == [url]
      assert attr(child, "[data-role=game-share-desktop]", "data-share-url") == [url]
      assert attr(child, "[data-role=game-share]", "phx-hook") == ["GameViewShare"]

      render_hook(child, "game_link_copied", %{})
      assert has_element?(child, "#flash-info", "Build link copied")
    end
  end

  describe "the desktop fill toggle" do
    test "toggles game-stage--fill on #game-stage and aria-pressed, client side", ctx do
      {_view, child} = open(ctx, game!(ctx).id)
      [js] = attr(child, "[data-role=game-fill-toggle]", "phx-click")
      assert attr(child, "[data-role=game-fill-toggle]", "aria-pressed") == ["false"]
      assert attr(child, "[data-role=game-fill-toggle]", "aria-label") == ["Fill the pane"]
      assert js =~ ~s("toggle_class")
      assert js =~ "game-stage--fill"
      assert js =~ "#game-stage"
      assert js =~ ~s("toggle_attr")
      assert js =~ "aria-pressed"
      assert has_element?(child, "#game-stage")
    end
  end

  describe "catch-alls" do
    test "a shell broadcast and an unknown event leave the view alive", ctx do
      {_view, child} = open(ctx, game!(ctx).id)
      ref = Process.monitor(child.pid)

      send(child.pid, {:new_message, %{}})
      send(child.pid, :something_else)
      render_hook(child, "no_such_event", %{"x" => 1})

      assert has_element?(child, "#game-view")
      refute_received {:DOWN, ^ref, :process, _, _}
    end
  end

  defmodule StubRunner do
    @moduledoc false
    def branch_head_sha(_args), do: {:ok, "a1b2c3d0123456789abcdef0123456789abcdef0"}
  end

  describe "observers" do
    setup do
      previous = Application.get_env(:platform, :branch_provisioner)
      Application.put_env(:platform, :branch_provisioner, runner: StubRunner)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:platform, :branch_provisioner),
          else: Application.put_env(:platform, :branch_provisioner, previous)
      end)
    end

    defp host!(user) do
      runtime_id = "play-host-#{System.unique_integer([:positive])}"

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: runtime_id,
          tool_profile: [],
          metadata: %{"client_info" => %{"features" => ["game_stream_host"]}}
        })

      {:ok, runtime, _token} = Federation.activate_runtime(runtime)
      RuntimePresence.track(runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime_id) end)
      runtime
    end

    test "a granted session's status drives the status line; an ungranted one does not", ctx do
      host!(ctx.user)
      {:ok, s} = GameStream.start_session(ctx.task.id, linger_ms: 50)
      canvas = game!(ctx, %{"session_id" => s.session_id})
      {_view, child} = open(ctx, canvas.id)

      # Not yet granted: nothing is recorded.
      send(child.pid, {:game_stream, s.session_id, {:status, %{state: "live"}}})
      assert text(child, "[data-role=game-status]") == "stream ready"

      render_hook(child, "game_stream_attach", %{
        "session_id" => s.session_id,
        "canvas_id" => canvas.id,
        "node_id" => "game-stream"
      })

      send(child.pid, {:game_stream, s.session_id, {:status, %{state: "live"}}})
      assert text(child, "[data-role=game-status]") == "streaming"

      # Play's hook still handled it (our observer continued, theirs halted).
      assert_push_event(child, "game_stream", %{type: "status", session_id: sid})
      assert sid == s.session_id

      send(child.pid, {:game_stream, "someone-else", {:status, %{state: "ended"}}})
      assert text(child, "[data-role=game-status]") == "streaming"
    end

    defp granted!(ctx) do
      host!(ctx.user)
      {:ok, s} = GameStream.start_session(ctx.task.id, linger_ms: 50)
      canvas = game!(ctx, %{"session_id" => s.session_id})
      {_view, child} = open(ctx, canvas.id)

      render_hook(child, "game_stream_attach", %{
        "session_id" => s.session_id,
        "canvas_id" => canvas.id,
        "node_id" => "game-stream"
      })

      {child, s.session_id}
    end

    defp stats!(child, session_id, stats),
      do: render_hook(child, "game_stream_stats", %{"session_id" => session_id, "stats" => stats})

    test "two stats events for a granted session: the tiles show the last, polylines have 2 points",
         ctx do
      {child, sid} = granted!(ctx)
      child |> element("#game-tab-insights") |> render_click()

      stats!(child, sid, %{"fps_avg" => 59.6, "rtt_p50_ms" => 38.2, "rtt_p95_ms" => 55.0})
      stats!(child, sid, %{"fps_avg" => 57.4, "rtt_p50_ms" => 41.4, "rtt_p95_ms" => 61.0})

      assert texts(child, "[data-role=game-tile-fps] > *") == ["57", "fps now"]

      assert texts(child, "[data-role=game-tile-latency] > *") == [
               "41ms",
               "input→photon · p95 61"
             ]

      [fps] = attr(child, "svg[data-role=game-spark-fps] polyline", "points")
      [lat] = attr(child, "svg[data-role=game-spark-latency] polyline", "points")
      assert length(String.split(fps)) == 2
      assert length(String.split(lat)) == 2
      assert attr(child, "svg[data-role=game-spark-fps] polyline", "class") == ["stroke-success"]

      assert attr(child, "svg[data-role=game-spark-latency] polyline", "class") == [
               "stroke-warning"
             ]

      refute has_element?(child, "[data-role=game-spark-fps-empty]")
    end

    test "only the last 24 samples are kept", ctx do
      {child, sid} = granted!(ctx)
      child |> element("#game-tab-insights") |> render_click()

      for i <- 1..30, do: stats!(child, sid, %{"fps_avg" => i / 1, "rtt_p50_ms" => 40.0})

      [fps] = attr(child, "svg[data-role=game-spark-fps] polyline", "points")
      assert length(String.split(fps)) == 24
      assert texts(child, "[data-role=game-tile-fps] > *") == ["30", "fps now"]
    end

    test "a stats event for a session NOT in the grants records nothing", ctx do
      {child, _sid} = granted!(ctx)
      child |> element("#game-tab-insights") |> render_click()

      stats!(child, "someone-else", %{
        "fps_avg" => 60.0,
        "rtt_p50_ms" => 40.0,
        "rtt_p95_ms" => 50.0
      })

      stats!(child, "someone-else", %{
        "fps_avg" => 60.0,
        "rtt_p50_ms" => 40.0,
        "rtt_p95_ms" => 50.0
      })

      assert texts(child, "[data-role=game-tile-fps] > *") == ["—", "fps now"]
      assert has_element?(child, "[data-role=game-spark-fps-empty]")
    end

    test "a {:status} message adds a timeline row; an ungranted one does not", ctx do
      {child, sid} = granted!(ctx)
      child |> element("#game-tab-insights") |> render_click()
      [first] = attr(child, "[data-role=game-ev]", "id")

      send(child.pid, {:game_stream, "someone-else", {:status, %{state: "failed"}}})
      send(child.pid, {:game_stream, sid, {:status, %{state: "live"}}})

      rows =
        child
        |> doc()
        |> LazyHTML.query("[data-role=game-ev]")
        |> Enum.map(&squish(LazyHTML.text(&1)))

      assert length(rows) == 2
      assert List.last(rows) =~ ~r/^\d+:\d\dplay host: live$/
      assert attr(child, "[data-role=game-ev]", "id") |> hd() == first
    end

    test "Restart turns on for a writer once the session has ended, aimed at the node's own button",
         ctx do
      {child, sid} = granted!(ctx)
      assert has_element?(child, "[data-role=game-restart][disabled]")

      send(child.pid, {:game_stream, sid, {:status, %{state: "ended"}}})
      refute has_element?(child, "[data-role=game-restart][disabled]")

      [js] = attr(child, "[data-role=game-restart]", "phx-click")
      [[_dispatch, %{"to" => to, "event" => "click"}]] = Jason.decode!(js)

      assert to ==
               ~s(#game-stream-game-stream-game-view-#{sid} [data-gs-panel="ended"] [data-gs-restart])

      # The selector reaches exactly one real button.
      assert child |> doc() |> LazyHTML.query(to) |> Enum.count() == 1

      send(child.pid, {:game_stream, sid, {:status, %{state: "failed"}}})
      [js] = attr(child, "[data-role=game-restart]", "phx-click")
      assert js =~ ~s([data-gs-panel=\\"failed\\"])

      send(child.pid, {:game_stream, sid, {:status, %{state: "live"}}})
      assert has_element?(child, "[data-role=game-restart][disabled]")
    end
  end

  describe "Review (stage 4)" do
    defp review!(ctx) do
      canvas = game!(ctx)
      {view, child} = open(ctx, canvas.id)
      child |> element("#game-tab-review") |> render_click()
      {canvas, view, child}
    end

    defp submit_note(child, text),
      do: child |> form("#game-note-form", note: %{text: text}) |> render_submit()

    defp exec_notes(task_id) do
      case Platform.Orchestration.ExecutionSpace.find_by_task_id(task_id) do
        nil ->
          []

        space ->
          Platform.Orchestration.ExecutionSpace.list_logs_by_metadata(space.id, %{
            "kind" => "game_review"
          })
      end
    end

    test "the compose row, the label and the empty copy naming the task", ctx do
      {_canvas, _view, child} = review!(ctx)

      assert text(child, "[data-role=game-vote]") == "👍 👎"
      assert attr(child, "[data-role=game-vote]", "aria-pressed") == ~w(false false)

      assert attr(child, "[data-role=game-note-input]", "placeholder") ==
               ["Note for the build (goes to the task)"]

      assert attr(child, "[data-role=game-note-input]", "aria-label") == ["Review note"]
      assert text(child, "[data-role=game-note-send]") == "→ task"

      assert text(child, "[data-role=game-review] [data-role=game-section-label]") ==
               "Review notes on build a1b2c3d"

      assert text(child, "[data-role=game-notes-empty]") ==
               ~s(No notes yet. Thumbs + a line is enough; it lands on the task "Dash tuning".)
    end

    test "vote toggling sets aria-pressed; one at a time; tapping the pressed one clears it",
         ctx do
      {_canvas, _view, child} = review!(ctx)

      child |> element("#game-vote-up") |> render_click()
      assert attr(child, "[data-role=game-vote]", "aria-pressed") == ~w(true false)

      child |> element("#game-vote-down") |> render_click()
      assert attr(child, "[data-role=game-vote]", "aria-pressed") == ~w(false true)

      child |> element("#game-vote-down") |> render_click()
      assert attr(child, "[data-role=game-vote]", "aria-pressed") == ~w(false false)
    end

    test "submit posts, inserts the row at the top, resets the form and toasts", ctx do
      {_canvas, _view, child} = review!(ctx)

      child |> element("#game-vote-down") |> render_click()
      child |> form("#game-note-form", note: %{text: "jump"}) |> render_change()
      submit_note(child, "jump feels floaty")

      assert texts(child, "[data-role=game-note-main]") == ["👎 jump feels floaty"]
      [small] = texts(child, "[data-role=game-note-small]")
      assert small =~ ~r/^\d\d:\d\d · → task$/
      refute has_element?(child, "[data-role=game-notes-empty]")
      assert attr(child, "[data-role=game-vote]", "aria-pressed") == ~w(false false)
      assert attr(child, "[data-role=game-note-input]", "value") == [""]
      assert has_element?(child, "#flash-info", "Sent to task · Dash tuning")

      child |> element("#game-vote-up") |> render_click()
      submit_note(child, "")

      assert texts(child, "[data-role=game-note-main]") ==
               ["👍 looks good", "👎 jump feels floaty"]

      assert [%{metadata: %{"vote" => "up"}}, %{metadata: %{"vote" => "down"}}] =
               exec_notes(ctx.task.id)
    end

    test "an empty submit with no vote does nothing and toasts nothing", ctx do
      {_canvas, _view, child} = review!(ctx)

      submit_note(child, "   ")

      assert has_element?(child, "[data-role=game-notes-empty]")
      refute has_element?(child, "[data-role=game-note]")
      refute has_element?(child, "#flash-info", "Sent to task")
      assert exec_notes(ctx.task.id) == []
    end

    test "notes persist across a remount, newest first", ctx do
      {canvas, _view, child} = review!(ctx)
      submit_note(child, "first")
      submit_note(child, "second")

      {_view, child} = open(ctx, canvas.id)
      child |> element("#game-tab-review") |> render_click()

      assert texts(child, "[data-role=game-note-main]") == ["📝 second", "📝 first"]
      refute has_element?(child, "[data-role=game-notes-empty]")
    end

    test "switching to Review does not remount the node", ctx do
      canvas = game!(ctx)
      {_view, child} = open(ctx, canvas.id)
      [wrapper] = attr(child, "[phx-hook=GameStream]", "id")
      child |> element("#game-tab-review") |> render_click()
      submit_note(child, "keep it")
      assert attr(child, "[phx-hook=GameStream]", "id") == [wrapper]
    end
  end
end

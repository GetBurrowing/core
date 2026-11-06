defmodule Platform.Chat.Canvas.KindsGameStreamBuildingTest do
  @moduledoc """
  The Building card for long builds (task 01a17b51 stage 3; design canvas
  01a170ca addendum 2b). An Unreal build runs 10-30 minutes, so the card
  names the step, shows the elapsed time in mono, says how long the last
  build took, and only says "taking longer than usual" after twice that. No
  progress bar, no warning colour. A build that fails shows "Build didn't
  finish", the step and Open task, and no way to retry.
  """

  use Platform.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Platform.Chat.Canvas.Kinds.GameStream, as: GameStreamKind

  @sha "0123456789abcdef0123456789abcdef01234567"
  @session "11111111-1111-7111-8111-111111111111"
  @task "22222222-2222-7222-8222-222222222222"
  @min 60_000

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    :ok
  end

  defp render_card(state, extra, last_build_ms) do
    node = %{
      "id" => "gs",
      "type" => "game_stream",
      "props" => %{
        "session_id" => @session,
        "task_id" => @task,
        "review_sha" => @sha,
        "branch" => "task/x"
      }
    }

    render_component(&GameStreamKind.render/1,
      node: node,
      dom_id_scope: "canvas-x-expanded",
      canvas_id: "canvas-x",
      status:
        {:ok, Map.merge(%{state: state, detail: nil, elapsed_ms: 0, task_id: @task}, extra)},
      last_build_ms: last_build_ms
    )
  end

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp text(html, selector),
    do: html |> q(selector) |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp count(html, selector), do: html |> q(selector) |> Enum.count()

  describe "the step" do
    test "a Compiling, Cooking, Staging, Packaging or Archiving detail is named next to the sha" do
      for step <- ~w(Compiling Cooking Staging Packaging Archiving) do
        html = render_card("building", %{detail: "#{step} (45s)"}, nil)
        assert text(html, "[data-gs-building-title]") == "Building 0123456 · #{step}"
        assert count(html, "[data-gs-step], [data-gs-on-host]") == 0
      end
    end

    test "Editor scripts is a step too" do
      html = render_card("building", %{detail: "Editor scripts (3s)"}, nil)
      assert text(html, "[data-gs-building-title]") == "Building 0123456 · Editor scripts"
    end

    test "a Godot build (detail 'Preparing ...') keeps today's text, plus elapsed" do
      html =
        render_card(
          "building",
          %{detail: "Preparing task/x at 0123456789ab", elapsed_ms: 754_000},
          nil
        )

      assert text(html, "[data-gs-building-title]") == "Building 0123456 on the play host…"
      assert text(html, "[data-gs-elapsed]") == "12:34"
      assert count(html, "[data-gs-last-build]") == 0
    end

    test "an Unreal 'Preparing' detail is not a step either" do
      html = render_card("building", %{detail: "Preparing (2s)"}, nil)
      assert text(html, "[data-gs-building-title]") == "Building 0123456 on the play host…"
    end

    test "elapsed time is mono, and there is no progress bar and no warning colour" do
      html = render_card("building", %{detail: "Cooking (5s)", elapsed_ms: 760_000}, 18 * @min)
      assert text(html, "[data-gs-panel=building] .font-mono") =~ "Building · 12:40"

      assert count(
               html,
               "[data-gs-panel=building] progress, [data-gs-panel=building] [role=progressbar]"
             ) == 0

      refute html |> q("[data-gs-panel=building]") |> LazyHTML.to_html() =~ "warning"
    end
  end

  describe "the last build" do
    test "is named in minutes when one exists" do
      html = render_card("building", %{detail: "Cooking (5s)"}, 18 * @min)
      assert text(html, "[data-gs-last-build]") == "Last build took 18 min"
    end

    test "is absent when none does" do
      html = render_card("building", %{detail: "Cooking (5s)"}, nil)
      assert count(html, "[data-gs-last-build]") == 0
    end

    test "a very short build still reads 1 min" do
      html = render_card("building", %{}, 10_000)
      assert text(html, "[data-gs-last-build]") == "Last build took 1 min"
    end
  end

  describe "taking longer than usual" do
    test "is hidden until the build passes twice the last one" do
      html = render_card("building", %{elapsed_ms: 36 * @min}, 18 * @min)
      assert count(html, "[data-gs-longer][hidden]") == 1
      assert count(html, "[data-gs-longer]:not([hidden])") == 0
    end

    test "shows after twice the last build" do
      html = render_card("building", %{elapsed_ms: 36 * @min + 1}, 18 * @min)
      assert count(html, "[data-gs-longer]:not([hidden])") == 1
      assert text(html, "[data-gs-longer]") == "This is taking longer than usual"
    end

    test "never appears without a last build" do
      html = render_card("building", %{elapsed_ms: 90 * @min}, nil)
      assert count(html, "[data-gs-longer]") == 0
      refute html =~ "longer than usual"
    end

    test "is not a fixed number of seconds" do
      html = render_card("building", %{elapsed_ms: 11_000}, 18 * @min)
      assert count(html, "[data-gs-longer]:not([hidden])") == 0
    end

    test "longer_than_usual?/2 is false without a numeric last build" do
      refute GameStreamKind.longer_than_usual?(99 * @min, nil)
      refute GameStreamKind.longer_than_usual?(99 * @min, 0)
      refute GameStreamKind.longer_than_usual?(nil, 5 * @min)
      assert GameStreamKind.longer_than_usual?(11 * @min, 5 * @min)
    end
  end

  describe "a build that did not finish" do
    test "says so, names the step and offers Open task, with no Retry" do
      detail = "build: Build failed during Cooking: LogCook: Error: bad asset"
      html = render_card("failed", %{detail: detail, ended_reason: detail}, nil)
      assert text(html, "[data-gs-panel=failed] [data-gs-reason]") == "Build didn't finish"
      assert text(html, "[data-gs-fail-step]") == "Failed during Cooking"
      assert count(html, "[data-gs-fail-step]:not([hidden])") == 1
      assert count(html, "[data-gs-open-task]:not([hidden])") == 1
      assert text(html, "[data-gs-open-task]") == "Open task"
      [href] = html |> q("[data-gs-open-task]") |> LazyHTML.attribute("href")
      assert href == "/tasks/" <> @task
      assert count(html, "[data-gs-panel=failed] [data-gs-restart][hidden]") == 1
      assert count(html, "[data-gs-panel=failed] [data-gs-restart]:not([hidden])") == 0
      refute html |> q("[data-gs-panel=failed]") |> LazyHTML.to_html() =~ "Retry"
    end

    test "a timeout names its step the same way" do
      detail = "build: Build timed out during Compiling"
      html = render_card("failed", %{detail: detail, ended_reason: detail}, nil)
      assert text(html, "[data-gs-fail-step-name]") == "Compiling"
    end

    test "any other failure keeps its text and Start again" do
      html =
        render_card(
          "failed",
          %{detail: "The game exited (code 3)", ended_reason: "The game exited (code 3)"},
          nil
        )

      assert text(html, "[data-gs-panel=failed] [data-gs-reason]") == "The game exited (code 3)"
      assert count(html, "[data-gs-open-task]:not([hidden])") == 0
      assert count(html, "[data-gs-fail-step]:not([hidden])") == 0
      assert count(html, "[data-gs-panel=failed] [data-gs-restart]:not([hidden])") == 1
    end
  end

  describe "build_step/1 and build_failure_step/1" do
    test "recognise the host's words and nothing else" do
      assert GameStreamKind.build_step("Cooking (12s)") == "Cooking"
      assert GameStreamKind.build_step("Cooking") == "Cooking"
      assert GameStreamKind.build_step("Editor scripts (1s)") == "Editor scripts"
      assert GameStreamKind.build_step("Cookbook") == nil
      assert GameStreamKind.build_step("Importing assets (5s)") == nil
      assert GameStreamKind.build_step(nil) == nil

      assert GameStreamKind.build_failure_step("Build failed during Archiving: x") == "Archiving"

      assert GameStreamKind.build_failure_step("build: Build failed during Editor scripts: x") ==
               "Editor scripts"

      assert GameStreamKind.build_failure_step("The game exited (code 3)") == nil
      assert GameStreamKind.build_failure_step(nil) == nil
    end
  end
end

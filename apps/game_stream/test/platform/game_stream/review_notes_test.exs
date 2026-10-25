defmodule Platform.GameStream.ReviewNotesTest do
  @moduledoc """
  Review notes (task 01a1557a-efdd stage 4): a note is ONE log-only message
  in the build's task's execution space, read back by review_sha.

  NOT async: toggles `:game_stream, :enabled` (global app env), which
  registers the game_stream canvas kind the fixtures are written in.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.GameStream.ReviewNotes
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  @sha "c3d4e5f0123456789abcdef0123456789abcdef0"
  @other_sha "d4e5f6a0123456789abcdef0123456789abcdef0"

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    org = Tenancy.get_org_by_slug!("globex")
    space = channel!(%{org_id: org.id, name: "Review builds"})
    user = create_user!(%{name: "Sam"})
    plain_member!(user, org)
    add_user!(space.id, user.id)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Notes #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/example/notes"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Jump tuning"})
    canvas = game_canvas!(space, %{"task_id" => task.id, "review_sha" => @sha})

    %{org: org, space: space, user: user, task: task, canvas: canvas}
  end

  defp game_canvas!(space, props) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "E2E Notes",
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "props" => %{},
            "children" => [
              %{
                "id" => "game-stream",
                "type" => "game_stream",
                "props" => Map.merge(%{"session_id" => "rn-none", "branch" => "task/x"}, props)
              }
            ]
          },
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  defp space_messages(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil -> []
      space -> Repo.all(from(m in Message, where: m.space_id == ^space.id))
    end
  end

  describe "post/3" do
    test "writes one log-only message in the task's execution space, creating it", ctx do
      assert ExecutionSpace.find_by_task_id(ctx.task.id) == nil

      assert {:ok, note} =
               ReviewNotes.post({:user, ctx.user.id}, ctx.canvas.id, %{
                 vote: "down",
                 text: "  jump feels floaty  "
               })

      assert %{vote: "down", text: "jump feels floaty"} = note

      assert [message] = space_messages(ctx.task.id)
      assert message.id == note.id
      assert message.log_only == true
      assert message.content == "👎 jump feels floaty · build c3d4e5f"

      assert %{
               "kind" => "game_review",
               "vote" => "down",
               "review_sha" => @sha,
               "canvas_id" => canvas_id,
               "author_user_id" => author_user_id,
               "log_only" => true
             } = message.metadata

      assert {canvas_id, author_user_id} == {ctx.canvas.id, ctx.user.id}
    end

    test "neither a vote nor text is :empty and writes nothing", ctx do
      for attrs <- [%{vote: nil, text: ""}, %{vote: nil, text: "   "}, %{}, %{vote: "sideways"}] do
        assert {:error, :empty} = ReviewNotes.post({:user, ctx.user.id}, ctx.canvas.id, attrs)
      end

      assert space_messages(ctx.task.id) == []
    end

    test "a vote with no text defaults to looks good / needs work; text alone is a 📝", ctx do
      viewer = {:user, ctx.user.id}
      assert {:ok, %{text: "looks good"}} = ReviewNotes.post(viewer, ctx.canvas.id, %{vote: "up"})

      assert {:ok, %{text: "needs work"}} =
               ReviewNotes.post(viewer, ctx.canvas.id, %{vote: "down", text: ""})

      assert {:ok, %{vote: nil}} = ReviewNotes.post(viewer, ctx.canvas.id, %{text: "hmm"})

      contents = ctx.task.id |> space_messages() |> Enum.map(& &1.content) |> Enum.sort()

      assert contents ==
               Enum.sort([
                 "👍 looks good · build c3d4e5f",
                 "👎 needs work · build c3d4e5f",
                 "📝 hmm · build c3d4e5f"
               ])
    end

    test "text is capped at 500 characters", ctx do
      long = String.duplicate("a", 600)

      assert {:ok, %{text: text}} =
               ReviewNotes.post({:user, ctx.user.id}, ctx.canvas.id, %{text: long})

      assert String.length(text) == 500
    end

    test "a viewer with no grant on the canvas is refused and nothing is written", ctx do
      outsider = create_user!(%{name: "Outsider"})
      other_org = Tenancy.get_org_by_slug!("initech")
      plain_member!(outsider, other_org)

      assert {:error, _} =
               ReviewNotes.post({:user, outsider.id}, ctx.canvas.id, %{vote: "up"})

      assert {:error, _} = ReviewNotes.post(nil, ctx.canvas.id, %{vote: "up"})
      assert space_messages(ctx.task.id) == []
    end

    test "a canvas whose node has no task or no sha is refused", ctx do
      no_sha = game_canvas!(ctx.space, %{"task_id" => ctx.task.id})
      no_task = game_canvas!(ctx.space, %{"review_sha" => @sha})
      ghost = game_canvas!(ctx.space, %{"task_id" => Ecto.UUID.generate(), "review_sha" => @sha})

      for canvas <- [no_sha, no_task, ghost] do
        assert {:error, :no_build} =
                 ReviewNotes.post({:user, ctx.user.id}, canvas.id, %{vote: "up"})
      end

      assert space_messages(ctx.task.id) == []
    end
  end

  describe "list/2" do
    test "filters by review_sha and lists newest first", ctx do
      viewer = {:user, ctx.user.id}
      other = game_canvas!(ctx.space, %{"task_id" => ctx.task.id, "review_sha" => @other_sha})

      {:ok, first} = ReviewNotes.post(viewer, ctx.canvas.id, %{vote: "down", text: "one"})
      {:ok, _} = ReviewNotes.post(viewer, other.id, %{text: "other build"})
      {:ok, second} = ReviewNotes.post(viewer, ctx.canvas.id, %{vote: "up"})

      {:ok, space} = ExecutionSpace.find_or_create(ctx.task.id)

      {:ok, _} =
        ExecutionSpace.post_log(space.id, "a plain log", metadata: %{"review_sha" => @sha})

      assert [
               %{id: id2, vote: "up", text: "looks good"},
               %{id: id1, vote: "down", text: "one"}
             ] = ReviewNotes.list(ctx.task.id, @sha)

      assert {id2, id1} == {second.id, first.id}
      assert [%{text: "other build", vote: nil}] = ReviewNotes.list(ctx.task.id, @other_sha)
    end

    test "no execution space, or arguments of the wrong shape, list nothing", ctx do
      assert ReviewNotes.list(ctx.task.id, @sha) == []
      assert ReviewNotes.list("nope", @sha) == []
      assert ReviewNotes.list(ctx.task.id, nil) == []
    end
  end
end

defmodule Platform.GameStream.ReviewNotes do
  @moduledoc """
  Review notes on a playable build (task 01a1557a-efdd, Burrow redesign 21,
  stage 4): the Game view's Review tab, thumbs plus a line that lands on the
  build's task.

  Platform.Tasks has no comment API, so the task's record of notes is its
  EXECUTION SPACE: `post/3` writes one message there with
  `Platform.Orchestration.ExecutionSpace.post_log/3` and `list/2` reads them
  back with `ExecutionSpace.list_logs_by_metadata/3`. No Repo call here.

  ## Log-only on purpose

  A note is recorded on the task WITHOUT waking its agent: `post_log/3`
  persists and broadcasts but triggers no attention routing. A reviewer
  leaving "jump feels floaty" on a build is not a dispatch.

  ## The message

      content:  "{👍|👎|📝} {text} · build {sha7}"
      metadata: %{"kind" => "game_review", "vote" => "up" | "down" | nil,
                  "review_sha" => sha, "canvas_id" => id,
                  "author_user_id" => user id, "text" => text}

  merged over post_log's fixed `source`/`log_only` keys. `"text"` is the
  note as the list renders it, so the list never parses `content` back.
  """

  alias Platform.Chat.CanvasAccess
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Tasks

  @max_text 500
  @list_limit 50
  @kind "game_review"

  @type note :: %{
          id: binary(),
          vote: String.t() | nil,
          text: String.t(),
          inserted_at: DateTime.t()
        }

  @doc """
  Post a note from `viewer` (`{:user, user_id}`) on the canvas's game build.

  Re-checks `CanvasAccess.fetch_for_viewer/3` (audit off), then takes the
  first `game_stream` node's `task_id` and `review_sha`, refusing a canvas
  without both (or whose task does not exist). `text` is trimmed and capped
  at #{@max_text} characters. Neither a vote nor text is `{:error, :empty}`
  and writes nothing; an empty text with `"up"` is "looks good", with
  `"down"` "needs work".

  Returns `{:ok, note}` (the shape `list/2` returns) or `{:error, reason}`.
  """
  @spec post(term(), term(), map()) :: {:ok, note()} | {:error, term()}
  def post({:user, user_id} = viewer, canvas_id, attrs) when is_map(attrs) do
    vote = vote(attrs[:vote] || attrs["vote"])
    text = text(attrs[:text] || attrs["text"])

    with {:ok, text} <- note_text(vote, text),
         {:ok, canvas, _level} <- CanvasAccess.fetch_for_viewer(canvas_id, viewer, audit: false),
         {:ok, task_id, sha} <- build_of(canvas.document),
         {:ok, space} <- ExecutionSpace.find_or_create(task_id),
         {:ok, message} <-
           ExecutionSpace.post_log(space.id, content(vote, text, sha),
             metadata: %{
               "kind" => @kind,
               "vote" => vote,
               "review_sha" => sha,
               "canvas_id" => canvas.id,
               "author_user_id" => user_id,
               "text" => text
             }
           ) do
      {:ok, %{id: message.id, vote: vote, text: text, inserted_at: message.inserted_at}}
    end
  end

  def post(_viewer, _canvas_id, _attrs), do: {:error, :not_found}

  @doc """
  The notes on `review_sha` in the task's execution space, newest first, at
  most #{@list_limit}. `[]` when the task has no execution space yet, or for
  arguments that are not a task UUID and a sha.
  """
  @spec list(term(), term()) :: [note()]
  def list(task_id, review_sha) when is_binary(review_sha) and review_sha != "" do
    with true <- Platform.UUID.valid?(task_id),
         %{id: space_id} <- ExecutionSpace.find_by_task_id(task_id) do
      space_id
      |> ExecutionSpace.list_logs_by_metadata(
        %{"kind" => @kind, "review_sha" => review_sha},
        limit: @list_limit
      )
      |> Enum.map(fn m ->
        %{
          id: m.id,
          vote: vote(m.metadata["vote"]),
          text: m.metadata["text"] || m.content,
          inserted_at: m.inserted_at
        }
      end)
    else
      _ -> []
    end
  end

  def list(_task_id, _review_sha), do: []

  @doc "The glyph a note is listed with: 👍, 👎, or 📝 for a text-only note."
  @spec glyph(String.t() | nil) :: String.t()
  def glyph("up"), do: "👍"
  def glyph("down"), do: "👎"
  def glyph(_vote), do: "📝"

  defp vote(v) when v in ["up", "down"], do: v
  defp vote(_v), do: nil

  defp text(t) when is_binary(t), do: t |> String.trim() |> String.slice(0, @max_text)
  defp text(_t), do: ""

  defp note_text(nil, ""), do: {:error, :empty}
  defp note_text("up", ""), do: {:ok, "looks good"}
  defp note_text("down", ""), do: {:ok, "needs work"}
  defp note_text(_vote, text), do: {:ok, text}

  defp content(vote, text, sha),
    do: glyph(vote) <> " " <> text <> " · build " <> String.slice(sha, 0, 7)

  # The first game_stream node's task and build. Untyped document data, so
  # both are shape-checked and the task must exist before a space is made.
  defp build_of(%{"root" => root}) do
    with %{"props" => %{"task_id" => task_id, "review_sha" => sha}} <- find_game(root),
         true <- is_binary(sha) and sha != "",
         true <- Platform.UUID.valid?(task_id),
         %{deleted_at: nil} <- Tasks.get_task_record(task_id) do
      {:ok, task_id, sha}
    else
      _ -> {:error, :no_build}
    end
  end

  defp build_of(_document), do: {:error, :no_build}

  defp find_game(%{"type" => "game_stream"} = node), do: node

  defp find_game(%{"children" => children}) when is_list(children),
    do: Enum.find_value(children, &find_game/1)

  defp find_game(_node), do: nil
end

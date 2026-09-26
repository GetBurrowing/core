defmodule Platform.GameStream.Tools do
  @moduledoc """
  The behaviour behind the `play` MCP bundle (task 01a0db5f stage 2).
  `Platform.Federation.ToolSurface` routes every `play_session_*` name here
  with one prefix clause; the definitions are in
  `Platform.Federation.PlayTools`.

  ## The flag is checked first

  With `GAME_STREAM_ENABLED` unset every call returns
  `PlayTools.disabled_error/0` before any argument is read, any row is
  looked up or any process is asked anything.

  ## Reachability

  The bundle is not a default grant; the transports refuse a runtime without
  `play` in its `allowed_bundles` before `execute/3` runs, exactly as for
  `experiments`.

  ## The canvas

  `play_session_start` creates a canvas in the task's execution space whose
  root is a `stack` holding one `game_stream` node, and attaches it to the
  task through `Platform.Tasks.CanvasAttachments.attach_canvas/4` — the
  function `task_attach_canvas` calls, with the caller as the authorization
  subject. The canvas is created WITHOUT a companion chat message
  (`Chat.create_canvas/1`), so starting a session posts nothing an
  attention router could route to an agent. A canvas that cannot be created
  or attached does not stop the session: the result carries
  `canvas_id: nil` and a `canvas_error`, and the session keeps running.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas.Links
  alias Platform.Chat.CanvasDocument
  alias Platform.Federation.PlayTools
  alias Platform.GameStream
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Tasks.CanvasAttachments

  @doc false
  @spec execute(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def execute(tool, args, context) do
    if GameStream.enabled?() do
      run(
        tool,
        if(is_map(args), do: args, else: %{}),
        if(is_map(context), do: context, else: %{})
      )
    else
      {:error, PlayTools.disabled_error()}
    end
  end

  defp run("play_session_start", args, context) do
    with {:ok, task_id} <- required_string(args, "task_id") do
      opts = [
        started_by: actor(context),
        idle_timeout_s: Map.get(args, "idle_timeout_s"),
        force_relay: Map.get(args, "force_relay") in [true, "true"]
      ]

      case GameStream.start_session(task_id, opts) do
        {:ok, status} ->
          {:ok,
           status
           |> Map.take([:session_id, :review_sha, :branch, :state])
           |> Map.merge(canvas_for(status, context))}

        {:error, reason} ->
          {:error, start_error(reason, task_id)}
      end
    end
  end

  defp run("play_session_stop", args, _context) do
    with {:ok, session_id} <- required_string(args, "session_id") do
      case GameStream.stop_session(session_id, "Stopped by an agent") do
        {:ok, status} -> {:ok, Map.take(status, [:session_id, :state, :ended_reason])}
        {:error, reason} -> {:error, session_error(reason, session_id)}
      end
    end
  end

  defp run("play_session_status", args, _context) do
    with {:ok, session_id} <- required_string(args, "session_id") do
      case GameStream.status(session_id) do
        {:ok, status} ->
          {:ok,
           Map.take(status, [
             :session_id,
             :task_id,
             :state,
             :detail,
             :elapsed_ms,
             :review_sha,
             :branch,
             :ended_reason
           ])}

        {:error, reason} ->
          {:error, session_error(reason, session_id)}
      end
    end
  end

  defp run(tool, _args, _context) do
    {:error,
     %{
       error: "Unknown tool: #{tool}",
       code: :unknown_tool,
       recoverable: false,
       suggestion: "The play bundle defines: #{Enum.join(PlayTools.names(), ", ")}"
     }}
  end

  # ── The canvas ──────────────────────────────────────────────────────────

  defp canvas_for(status, context) do
    document = %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "game-stream",
            "type" => "game_stream",
            "props" => %{
              "session_id" => status.session_id,
              "task_id" => status.task_id,
              "review_sha" => status.review_sha,
              "branch" => status.branch,
              "title" => "Review build",
              "latency_warn_ms" => 50
            }
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }

    with {:ok, document} <- validate(document),
         {:ok, space} <- ExecutionSpace.find_or_create(status.task_id),
         {:ok, participant} <- ExecutionSpace.ensure_system_participant(space.id),
         {:ok, canvas} <-
           Chat.create_canvas(%{
             space_id: space.id,
             created_by: participant.id,
             title: "Play #{String.slice(status.review_sha, 0, 12)}",
             document: document
           }),
         {:ok, _attachment} <-
           CanvasAttachments.attach_canvas(
             attach_actor(context),
             status.task_id,
             canvas.id,
             note: "Playable review build #{status.review_sha}",
             attached_by: attached_by(context)
           ) do
      %{canvas_id: canvas.id, view_url: Links.view_url(canvas.id)}
    else
      error ->
        Logger.warning(
          "[GameStream] session #{status.session_id}: canvas not created/attached: #{inspect(error)}"
        )

        %{canvas_id: nil, view_url: nil, canvas_error: canvas_error(error)}
    end
  end

  defp validate(document) do
    case CanvasDocument.validate(document) do
      {:ok, doc} -> {:ok, doc}
      {:error, reasons} -> {:error, {:invalid_document, reasons}}
    end
  end

  defp canvas_error({:error, {:invalid_document, reasons}}),
    do: "document invalid: " <> Enum.join(reasons, "; ")

  defp canvas_error({:error, atom}) when is_atom(atom), do: Atom.to_string(atom)
  defp canvas_error({:error, %Ecto.Changeset{} = cs}), do: inspect(cs.errors)
  defp canvas_error(other), do: inspect(other)

  # ── Context ─────────────────────────────────────────────────────────────

  defp actor(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) -> {:agent, Map.get(context, :agent_id)}
      is_binary(Map.get(context, :user_id)) -> {:user, Map.get(context, :user_id)}
      true -> nil
    end
  end

  # The same two readings `ToolSurface.task_attach_canvas` makes of one
  # context: the authorization subject and the attribution.
  defp attach_actor(context), do: actor(context)

  defp attached_by(context) do
    case actor(context) do
      {kind, id} -> %{kind: Atom.to_string(kind), id: id}
      nil -> %{}
    end
  end

  # ── Errors ──────────────────────────────────────────────────────────────

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         %{
           error: "#{key} is required (string)",
           code: :invalid_arguments,
           recoverable: true,
           suggestion: "Pass #{key} as a UUID string."
         }}
    end
  end

  defp start_error(:no_review_branch, task_id) do
    %{
      error:
        "Task #{task_id} has no review branch: nothing was started, and main is never played in its place.",
      code: :no_review_branch,
      recoverable: true,
      suggestion: "Push the task's branch (task/<full task uuid>) and try again."
    }
  end

  defp start_error(:not_in_review, task_id) do
    %{
      error: "Task #{task_id} is not in_review; only a review build can be played.",
      code: :not_in_review,
      recoverable: false,
      suggestion: "Wait until the task reaches in_review."
    }
  end

  defp start_error(:no_play_host, _task_id) do
    %{
      error: "Stream unavailable. No play host is connected.",
      code: :no_play_host,
      recoverable: true,
      suggestion: "Start the suite-play-host service on the play machine, then try again."
    }
  end

  defp start_error(:host_busy, _task_id) do
    %{
      error: "The play host is already running a session.",
      code: :host_busy,
      recoverable: true,
      suggestion: "Stop the running session with play_session_stop, or wait for it to end."
    }
  end

  defp start_error(:task_not_found, task_id) do
    %{
      error: "Task not found: #{task_id}",
      code: :task_not_found,
      recoverable: false,
      suggestion: "Use task_list to find the task."
    }
  end

  defp start_error(:no_repo, task_id) do
    %{
      error: "Task #{task_id}'s project has no resolvable repo_url.",
      code: :no_repo,
      recoverable: false,
      suggestion: "Set the project's repo_url to its GitHub repository."
    }
  end

  defp start_error(other, task_id) do
    %{
      error: "Could not start a play session for task #{task_id}: #{inspect(other)}",
      code: :start_failed,
      recoverable: true,
      suggestion: "Check play_session_status or the core log, then try again."
    }
  end

  defp session_error(:not_found, session_id) do
    %{
      error: "Play session not found: #{session_id}",
      code: :not_found,
      recoverable: false,
      suggestion: "Sessions are in memory and an ended one is readable for about a minute."
    }
  end

  defp session_error(other, session_id) do
    %{
      error: "Play session #{session_id}: #{inspect(other)}",
      code: :session_error,
      recoverable: false,
      suggestion: "Check play_session_status."
    }
  end
end

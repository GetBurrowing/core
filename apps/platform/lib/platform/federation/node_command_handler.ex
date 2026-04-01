defmodule Platform.Federation.NodeCommandHandler do
  @moduledoc """
  Routes OpenClaw node.invoke.request commands to Suite subsystems.

  Phase 2: canvas commands are wired to real `Platform.Chat` canvas operations.
  Phase 3 stubs: `canvas.eval` and `canvas.snapshot` (require client round-trip).
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.PubSub
  alias Platform.Federation.NodeContext
  alias Platform.Agents.Agent
  import Ecto.Query, only: [from: 2]

  # ── canvas.present ──────────────────────────────────────────────────

  def handle("canvas.present", params, ctx) do
    with {:ok, url} <- validate_canvas_url(params["url"]),
         {:ok, space_id} <- resolve_space(params, ctx),
         {:ok, agent} <- resolve_agent(ctx.agent_id),
         {:ok, participant} <- Chat.ensure_agent_participant(space_id, agent) do
      canvas_attrs = %{
        "title" => params["title"] || "Canvas",
        "canvas_type" => params["canvas_type"] || "custom",
        "state" => %{"url" => url}
      }

      case Chat.create_canvas_with_message(space_id, participant.id, canvas_attrs) do
        {:ok, canvas, _message} ->
          PubSub.broadcast(space_id, {:canvas_created, canvas})
          {:ok, %{canvas_id: canvas.id, space_id: space_id}}

        {:error, reason} ->
          {:error, "CANVAS_CREATE_FAILED", "Failed to create canvas: #{inspect(reason)}"}
      end
    end
  end

  # ── canvas.navigate ─────────────────────────────────────────────────

  def handle("canvas.navigate", params, _ctx) do
    with {:ok, url} <- validate_canvas_url(params["url"]),
         {:ok, canvas} <- fetch_canvas(params["canvas_id"]) do
      case Chat.update_canvas_state(canvas, %{"url" => url}) do
        {:ok, updated} ->
          PubSub.broadcast(canvas.space_id, {:canvas_updated, updated})
          PubSub.broadcast_canvas(canvas.id, {:canvas_updated, updated})
          {:ok, %{canvas_id: updated.id}}

        {:error, reason} ->
          {:error, "CANVAS_UPDATE_FAILED", "Failed to navigate canvas: #{inspect(reason)}"}
      end
    end
  end

  # ── canvas.hide ─────────────────────────────────────────────────────

  def handle("canvas.hide", params, _ctx) do
    with {:ok, canvas} <- fetch_canvas(params["canvas_id"]) do
      new_metadata = Map.put(canvas.metadata || %{}, "hidden", true)

      case Chat.update_canvas(canvas, %{metadata: new_metadata}) do
        {:ok, updated} ->
          PubSub.broadcast(canvas.space_id, {:canvas_hidden, updated})
          PubSub.broadcast_canvas(canvas.id, {:canvas_hidden, updated})
          {:ok, %{canvas_id: updated.id}}

        {:error, reason} ->
          {:error, "CANVAS_HIDE_FAILED", "Failed to hide canvas: #{inspect(reason)}"}
      end
    end
  end

  # ── canvas.a2ui_push ────────────────────────────────────────────────

  def handle("canvas.a2ui_push", params, ctx) do
    canvas_id = params["canvas_id"]

    with {:ok, canvas} <- get_or_create_canvas(canvas_id, params, ctx) do
      case Chat.update_canvas_state(canvas, %{"a2ui_content" => params["jsonl"]}) do
        {:ok, updated} ->
          PubSub.broadcast(canvas.space_id, {:canvas_updated, updated})
          PubSub.broadcast_canvas(canvas.id, {:canvas_updated, updated})
          {:ok, %{canvas_id: updated.id}}

        {:error, reason} ->
          {:error, "A2UI_PUSH_FAILED", "Failed to push A2UI content: #{inspect(reason)}"}
      end
    end
  end

  # ── canvas.a2ui_reset ───────────────────────────────────────────────

  def handle("canvas.a2ui_reset", params, _ctx) do
    with {:ok, canvas} <- fetch_canvas(params["canvas_id"]) do
      case Chat.update_canvas_state(canvas, %{"a2ui_content" => nil}) do
        {:ok, updated} ->
          PubSub.broadcast(canvas.space_id, {:canvas_updated, updated})
          PubSub.broadcast_canvas(canvas.id, {:canvas_updated, updated})
          {:ok, %{canvas_id: updated.id}}

        {:error, reason} ->
          {:error, "A2UI_RESET_FAILED", "Failed to reset A2UI: #{inspect(reason)}"}
      end
    end
  end

  # ── Gateway dot-notation aliases ─────────────────────────────────────
  def handle("canvas.a2ui.pushJSONL", params, ctx), do: handle("canvas.a2ui_push", params, ctx)
  def handle("canvas.a2ui.reset", params, ctx), do: handle("canvas.a2ui_reset", params, ctx)

  # ── canvas.eval (Phase 3 stub) ─────────────────────────────────────

  def handle("canvas.eval", _params, _ctx) do
    {:ok, %{result: nil, note: "canvas.eval requires Phase 3 client-side implementation"}}
  end

  # ── canvas.snapshot (Phase 3 stub) ──────────────────────────────────

  def handle("canvas.snapshot", _params, _ctx) do
    {:ok, %{snapshot: nil, note: "canvas.snapshot requires Phase 3 client-side implementation"}}
  end

  # ── Unknown command ─────────────────────────────────────────────────

  def handle(command, _params, _ctx) do
    Logger.warning("[NodeCommandHandler] unknown command: #{command}")
    {:error, "UNKNOWN_COMMAND", "Unknown command: #{command}"}
  end

  # ── Space resolution ────────────────────────────────────────────────

  @doc false
  def resolve_space(params, ctx) do
    cond do
      # 1. Explicit space_id in params
      is_binary(params["space_id"]) ->
        {:ok, params["space_id"]}

      # 2. Current engagement context from NodeContext
      is_binary(ctx[:agent_id]) && NodeContext.get_space(ctx.agent_id) != nil ->
        {:ok, NodeContext.get_space(ctx.agent_id)}

      # 3. Default: first space the agent participates in
      is_binary(ctx[:agent_id]) ->
        case first_agent_space(ctx.agent_id) do
          nil -> {:error, "NO_SPACE", "No space available for agent #{ctx.agent_id}"}
          space_id -> {:ok, space_id}
        end

      true ->
        {:error, "NO_AGENT", "No agent_id in context"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp fetch_canvas(nil), do: {:error, "MISSING_CANVAS_ID", "canvas_id is required"}

  defp fetch_canvas(canvas_id) do
    case Chat.get_canvas(canvas_id) do
      nil -> {:error, "CANVAS_NOT_FOUND", "Canvas #{canvas_id} not found"}
      canvas -> {:ok, canvas}
    end
  end

  defp validate_canvas_url(url) when not is_binary(url) do
    {:error, "INVALID_CANVAS_URL", "Canvas URL must be an http(s) URL"}
  end

  defp validate_canvas_url(url) do
    trimmed = String.trim(url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, trimmed}

      _ ->
        {:error, "INVALID_CANVAS_URL", "Canvas URL must be an http(s) URL"}
    end
  end

  defp get_or_create_canvas(canvas_id, _params, _ctx) when is_binary(canvas_id) do
    case Chat.get_canvas(canvas_id) do
      nil -> {:error, "CANVAS_NOT_FOUND", "Canvas #{canvas_id} not found"}
      canvas -> {:ok, canvas}
    end
  end

  defp get_or_create_canvas(nil, params, ctx) do
    # No canvas_id provided — create a new canvas in the current space
    with {:ok, space_id} <- resolve_space(params, ctx),
         {:ok, agent} <- resolve_agent(ctx.agent_id),
         {:ok, participant} <- Chat.ensure_agent_participant(space_id, agent) do
      case Chat.create_canvas_with_message(space_id, participant.id, %{
             "title" => params["title"] || "A2UI Canvas",
             "canvas_type" => "custom",
             "state" => %{}
           }) do
        {:ok, canvas, _message} ->
          PubSub.broadcast(space_id, {:canvas_created, canvas})
          {:ok, canvas}

        {:error, reason} ->
          {:error, "CANVAS_CREATE_FAILED", "Failed to create canvas: #{inspect(reason)}"}
      end
    end
  end

  # Resolve agent_id string → {:ok, %Agent{}} or {:error, ...}
  # Auto-creates a built_in agent record if the slug doesn't exist yet.
  defp resolve_agent(nil), do: {:error, "NO_AGENT", "No agent_id in context"}

  defp resolve_agent(agent_id) do
    case find_agent(agent_id) do
      nil -> upsert_openclaw_agent(agent_id)
      agent -> {:ok, agent}
    end
  end

  # Create a minimal agent record for an OpenClaw agent slug that hasn't been imported yet.
  defp upsert_openclaw_agent(slug) do
    attrs = %{
      slug: slug,
      name: slug,
      status: "active",
      runtime_type: "built_in"
    }

    case Platform.Repo.insert(Agent.changeset(%Agent{}, attrs)) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, %Ecto.Changeset{errors: [_ | _]}} ->
        # Race: inserted concurrently — re-fetch
        case find_agent(slug) do
          nil -> {:error, "AGENT_CREATE_FAILED", "Agent #{slug} could not be created or found"}
          agent -> {:ok, agent}
        end

      {:error, reason} ->
        {:error, "AGENT_CREATE_FAILED", "Failed to create agent: #{inspect(reason)}"}
    end
  end

  # Look up agent by UUID primary key or slug (e.g. "main").
  defp find_agent(agent_id) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, _} ->
        Platform.Repo.get(Agent, agent_id)

      :error ->
        Platform.Repo.one(from(a in Agent, where: a.slug == ^agent_id, limit: 1))
    end
  end

  defp first_agent_space(agent_id) do
    case find_agent(agent_id) do
      nil ->
        nil

      agent ->
        case Platform.Federation.agent_spaces(agent) do
          [%{space_id: space_id} | _] -> space_id
          _ -> nil
        end
    end
  end
end

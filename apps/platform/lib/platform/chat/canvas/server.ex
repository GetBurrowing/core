defmodule Platform.Chat.Canvas.Server do
  @moduledoc """
  Per-canvas GenServer (ADR 0036).

  Each active canvas runs its own process registered by canvas id in
  `Platform.Chat.Registry` under `Platform.Chat.CanvasSupervisor`. The server
  is the single writer for its canvas: all patches flow through it, are
  validated against the kind registry, and applied with rebase-or-reject
  concurrency.

  ## Rebase-or-reject

  Every `apply_patches/3` call carries a `base_revision` — the revision the
  caller last saw. The server decides:

    * **apply** when `base_revision == current_revision` (trivial head write)
    * **rebase** when the patch's target nodes still exist and the changes
      since `base_revision` do not structurally conflict
    * **reject** with a structured `{:conflict, payload}` otherwise

  The rejection payload lets an agent self-correct on its next turn:

      %{
        reason: :target_deleted | :schema_violation | :too_stale | :illegal_child,
        offending_op_index: non_neg_integer(),
        offending_node_id: binary() | nil,
        current_revision: pos_integer(),
        expected_kind: binary() | nil,
        tree: map() | nil  # only when too stale to rebase
      }

  Postgres is an async write-through sink. The in-memory document is the
  authoritative current state during an active session; persistence happens
  via `Task.Supervisor` without blocking the patch path.

  ## Lifecycle

  Started on demand via `start_server/1`. Loads the current document from the
  DB on init, terminates via standard supervisor shutdown — restart loses the
  in-memory revision counter but the persisted document remains valid.
  """

  use GenServer

  require Logger

  alias Platform.Chat
  alias Platform.Chat.{Canvas, CanvasDocument, CanvasPatch}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  @type conflict_reason ::
          :target_deleted
          | :schema_violation
          | :too_stale
          | :illegal_child
          | :unknown_operation

  @type conflict_payload :: %{
          required(:reason) => conflict_reason(),
          required(:offending_op_index) => non_neg_integer(),
          required(:offending_node_id) => binary() | nil,
          required(:current_revision) => pos_integer(),
          optional(:expected_kind) => binary() | nil,
          optional(:tree) => map() | nil,
          optional(:message) => binary()
        }

  defmodule State do
    @moduledoc false
    @enforce_keys [:canvas_id, :space_id, :document, :revision]
    defstruct canvas_id: nil, space_id: nil, document: nil, revision: 1
  end

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Start the per-canvas server under the supervisor, idempotent."
  @spec start_server(binary()) :: {:ok, pid()} | {:error, term()}
  def start_server(canvas_id) when is_binary(canvas_id) do
    case whereis(canvas_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        DynamicSupervisor.start_child(
          Platform.Chat.CanvasSupervisor,
          {__MODULE__, canvas_id: canvas_id}
        )
    end
  end

  @doc "Return the pid for canvas id, or nil if not running."
  @spec whereis(binary()) :: pid() | nil
  def whereis(canvas_id) do
    case Registry.lookup(Platform.Chat.Registry, {:canvas, canvas_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Apply patches with rebase-or-reject concurrency.

  Returns `{:ok, new_revision}` on success, or `{:conflict, payload}` on
  rejection. Any other error (canvas not found, schema violation on a fresh
  write) is returned as `{:error, term}`.
  """
  @spec apply_patches(binary(), [CanvasPatch.operation()], non_neg_integer()) ::
          {:ok, pos_integer()}
          | {:conflict, conflict_payload()}
          | {:error, term()}
  def apply_patches(canvas_id, operations, base_revision)
      when is_binary(canvas_id) and is_list(operations) and is_integer(base_revision) do
    with {:ok, _pid} <- start_server(canvas_id) do
      GenServer.call(via(canvas_id), {:apply_patches, operations, base_revision})
    end
  end

  @doc "Return a snapshot of the current document + revision."
  @spec describe(binary()) ::
          {:ok, %{document: map(), revision: pos_integer()}} | {:error, term()}
  def describe(canvas_id) when is_binary(canvas_id) do
    with {:ok, _pid} <- start_server(canvas_id) do
      GenServer.call(via(canvas_id), :describe)
    end
  end

  @doc """
  Broadcast a kind-emitted event (form submit, checklist toggle, action click)
  on the canvas PubSub topic. Events are signals — they do NOT mutate the
  document by themselves. Subscribers (agents, LiveView hooks, task system)
  decide how to respond.
  """
  @spec emit_event(binary(), map()) :: :ok
  def emit_event(canvas_id, event) when is_binary(canvas_id) and is_map(event) do
    ChatPubSub.broadcast_canvas(canvas_id, {:canvas_event, canvas_id, event})
  end

  @doc "Stop the server for a canvas (e.g. in tests). No-op if not running."
  @spec stop(binary()) :: :ok
  def stop(canvas_id) do
    case whereis(canvas_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Platform.Chat.CanvasSupervisor, pid)
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  def start_link(opts) do
    canvas_id = Keyword.fetch!(opts, :canvas_id)
    GenServer.start_link(__MODULE__, opts, name: via(canvas_id))
  end

  @impl true
  def init(opts) do
    canvas_id = Keyword.fetch!(opts, :canvas_id)

    case Chat.get_canvas(canvas_id) do
      nil ->
        {:stop, :canvas_not_found}

      %Canvas{} = canvas ->
        document =
          case canvas.document do
            %{"version" => _, "root" => _} = doc -> doc
            _ -> CanvasDocument.new()
          end

        revision = CanvasDocument.revision(document)
        revision = if revision < 1, do: 1, else: revision

        {:ok,
         %State{
           canvas_id: canvas_id,
           space_id: canvas.space_id,
           document: document,
           revision: revision
         }}
    end
  end

  @impl true
  def handle_call({:apply_patches, operations, base_revision}, _from, %State{} = state) do
    case apply_with_rebase(state, operations, base_revision) do
      {:ok, new_document, new_revision} ->
        persist_async(state.canvas_id, new_document)

        ChatPubSub.broadcast_canvas(
          state.canvas_id,
          {:canvas_patched, state.canvas_id, new_revision, operations}
        )

        :telemetry.execute(
          [:platform, :chat, :canvas_patched],
          %{system_time: System.system_time()},
          %{
            canvas_id: state.canvas_id,
            space_id: state.space_id,
            revision: new_revision,
            op_count: length(operations)
          }
        )

        {:reply, {:ok, new_revision},
         %State{state | document: new_document, revision: new_revision}}

      {:conflict, payload} ->
        {:reply, {:conflict, payload}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:describe, _from, %State{} = state) do
    {:reply, {:ok, %{document: state.document, revision: state.revision}}, state}
  end

  # ── Rebase-or-reject core ───────────────────────────────────────────────

  defp apply_with_rebase(%State{revision: current} = state, operations, base_revision) do
    cond do
      base_revision == current ->
        apply_at_head(state.document, operations, current)

      base_revision > current ->
        # Client claims a future revision — impossible; treat as stale.
        {:conflict,
         %{
           reason: :too_stale,
           offending_op_index: 0,
           offending_node_id: nil,
           current_revision: current,
           tree: state.document,
           message: "base_revision #{base_revision} ahead of current #{current}"
         }}

      true ->
        try_rebase(state.document, operations, current)
    end
  end

  defp apply_at_head(document, operations, current_revision) do
    case CanvasPatch.apply_many(document, operations) do
      {:ok, new_document} ->
        {:ok, new_document, current_revision + 1}

      {:error, reason} ->
        {:conflict, classify_rejection(operations, document, reason, current_revision)}
    end
  end

  defp try_rebase(document, operations, current_revision) do
    # Rebase heuristic: replay operations against current document. If the
    # target node is still present for each op and the resulting tree
    # validates, accept; otherwise reject with the rebase reason.
    if rebase_safe?(operations, document) do
      apply_at_head(document, operations, current_revision)
    else
      {:conflict,
       %{
         reason: :target_deleted,
         offending_op_index: offending_index(operations, document),
         offending_node_id: offending_node_id(operations, document),
         current_revision: current_revision,
         tree: document,
         message: "patch target no longer exists at current revision"
       }}
    end
  end

  defp rebase_safe?(operations, document) do
    Enum.all?(operations, fn op ->
      case op_target(op) do
        nil -> true
        id -> CanvasDocument.get_node(document, id) != nil
      end
    end)
  end

  defp op_target({:set_props, id, _}), do: id
  defp op_target({:replace_children, id, _}), do: id
  defp op_target({:append_child, id, _}), do: id
  defp op_target({:delete_node, id}), do: id
  defp op_target({:replace_document, _}), do: nil
  defp op_target(_), do: nil

  defp offending_index(operations, document) do
    operations
    |> Enum.with_index()
    |> Enum.find_value(0, fn {op, idx} ->
      case op_target(op) do
        nil -> nil
        id -> if CanvasDocument.get_node(document, id) == nil, do: idx, else: nil
      end
    end)
  end

  defp offending_node_id(operations, document) do
    Enum.find_value(operations, fn op ->
      case op_target(op) do
        nil -> nil
        id -> if CanvasDocument.get_node(document, id) == nil, do: id, else: nil
      end
    end)
  end

  defp classify_rejection(operations, document, reason, current_revision)
       when is_binary(reason) do
    cond do
      String.contains?(reason, "not found") ->
        %{
          reason: :target_deleted,
          offending_op_index: offending_index(operations, document),
          offending_node_id: offending_node_id(operations, document),
          current_revision: current_revision,
          message: reason
        }

      String.contains?(reason, "not allowed") ->
        %{
          reason: :illegal_child,
          offending_op_index: 0,
          offending_node_id: nil,
          current_revision: current_revision,
          message: reason
        }

      String.contains?(reason, "unsupported") ->
        %{
          reason: :unknown_operation,
          offending_op_index: 0,
          offending_node_id: nil,
          current_revision: current_revision,
          message: reason
        }

      true ->
        %{
          reason: :schema_violation,
          offending_op_index: 0,
          offending_node_id: nil,
          current_revision: current_revision,
          message: reason
        }
    end
  end

  # ── Persistence ─────────────────────────────────────────────────────────

  defp persist_async(canvas_id, document) do
    if Application.get_env(:platform, :canvas_persist_sync, false) do
      do_persist(canvas_id, document)
    else
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        do_persist(canvas_id, document)
      end)
    end

    :ok
  end

  defp do_persist(canvas_id, document) do
    case Repo.get(Canvas, canvas_id) do
      nil ->
        :ok

      canvas ->
        canvas
        |> Canvas.changeset(%{"document" => document})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Canvas.Server] persist failed canvas=#{canvas_id} reason=#{inspect(reason)}"
            )
        end
    end
  end

  defp via(canvas_id), do: {:via, Registry, {Platform.Chat.Registry, {:canvas, canvas_id}}}
end

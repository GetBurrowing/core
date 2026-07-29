defmodule Platform.Tasks.CanvasAttachments do
  @moduledoc """
  Context module for task → canvas attachments (task_attach_canvas, stage 2).

  Pairs with the `Platform.Tasks.CanvasAttachment` schema (stage 1). Kept as a
  dedicated submodule rather than bolted onto `Platform.Tasks` because that
  parent module is already 2000+ lines and the attachment boundary is crisp:
  the MCP tool surface (stage 3), the dispatch bundler (stage 4), and the
  LiveView (stage 5) all consume this surface and nothing else from `Tasks`
  to do their work.

  ## Soft-reference invariant

  `canvas_id` is a soft reference — there is **no** FK from
  `task_canvas_attachments.canvas_id` to `chat_canvases.id`. Soft-deleting a
  canvas leaves the attachment row stale (not broken), which matches how
  downstream consumers degrade: a missing canvas surfaces as `canvas: nil`
  in `list_task_canvases/1` so the caller can choose to detach it rather
  than failing loud.

  The flip side is that `attach_canvas/4` validates canvas existence
  (and `is_nil(deleted_at)`) **before** insert, so creating a dangling
  attachment from an MCP tool call surfaces loud at attach time, not
  silently later in a downstream consumer.

  ## Idempotent re-attach

  `attach_canvas/4` is idempotent on `(task_id, canvas_id)`. A second call
  with the same pair updates `note` + `attached_by_*` + bumps `updated_at`
  on the existing row, returning the same `id`. This matches how the MCP
  tool will be invoked when an agent attaches the same evidence canvas
  multiple times across a multi-stage task — re-attach is a no-op rather
  than a duplicate row or a unique-constraint surface.
  """

  import Ecto.Query

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasAccess
  alias Platform.Repo
  alias Platform.Tasks.{CanvasAttachment, Task}

  @type attached_by :: %{kind: String.t(), id: binary()}
  @type attach_opts :: [{:note, String.t() | nil} | {:attached_by, attached_by()}]

  @type list_entry :: %{
          attachment: %CanvasAttachment{},
          canvas:
            %{id: binary(), title: String.t() | nil, kind: String.t() | nil, deleted_at: any()}
            | nil
        }

  @type task_entry :: %{
          attachment: %CanvasAttachment{},
          task:
            %{
              id: binary(),
              title: String.t() | nil,
              status: String.t() | nil,
              project_id: binary() | nil
            }
            | nil
        }

  # ── attach ────────────────────────────────────────────────────────────────

  @doc """
  Attach a canvas to a task, on behalf of `actor`.

  Validates that both the task and the canvas exist (and that the canvas is
  not soft-deleted), and that `actor` may READ the canvas, before insert.
  Idempotent on `(task_id, canvas_id)` via upsert — a second call updates
  `note` + attribution + bumps `updated_at` and returns the same row id.

  ## Why the attacher is authorized against the canvas

  `Platform.Chat.CanvasAccess`'s `:task_reader` grant says: you may read a
  canvas if it is attached to a task whose project org you belong to. An
  unauthorized attach is therefore a self-service grant — staple a stranger's
  canvas id onto a task in your own org and the whole org can read it.

  So attaching requires already holding a read grant on the canvas. You cannot
  confer a read you do not have. `actor` is a
  `t:Platform.Chat.CanvasAccess.actor/0`; the read is resolved with
  `audit: false`, since an authorization probe is not a read of the document.

  **`:attached_by` is attribution, not authorization.** It records who to show
  in the UI and is caller-supplied; it is never the subject of this check.
  `attached_by` and `actor` legitimately differ — see
  `Platform.Responsibilities.Handlers.DesignTaskDirection`, which attaches as
  `:system` while attributing the canvas to the responsible designer.

  There is deliberately no defaulting arity: a caller that forgets the actor
  should fail to compile, not silently bypass the gate.

  ## Options

    * `:note` — optional human note (string).
    * `:attached_by` — `%{kind: "agent" | "user", id: <uuid>}`. Required.

  ## Returns

    * `{:ok, %CanvasAttachment{}}` on success (insert or upsert).
    * `{:error, :task_not_found}` if the task id doesn't resolve.
    * `{:error, :canvas_not_found}` if the canvas id doesn't resolve, or the
      canvas is soft-deleted.
    * `{:error, :canvas_forbidden}` if `actor` may not read the canvas.
    * `{:error, %Ecto.Changeset{}}` if the inputs fail changeset validation
      (missing `attached_by`, bad `kind`, etc.).
  """
  @spec attach_canvas(CanvasAccess.actor(), binary(), binary(), attach_opts()) ::
          {:ok, %CanvasAttachment{}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :task_not_found}
          | {:error, :canvas_not_found}
          | {:error, :canvas_forbidden}
  def attach_canvas(actor, task_id, canvas_id, opts \\ [])
      when is_binary(task_id) and is_binary(canvas_id) and is_list(opts) do
    with :ok <- ensure_task_exists(task_id),
         :ok <- ensure_canvas_attachable(canvas_id),
         :ok <- ensure_canvas_readable(canvas_id, actor) do
      attached_by = Keyword.get(opts, :attached_by, %{})
      kind = attached_by[:kind] || attached_by["kind"]
      id = attached_by[:id] || attached_by["id"]

      attrs = %{
        task_id: task_id,
        canvas_id: canvas_id,
        note: Keyword.get(opts, :note),
        attached_by_kind: kind,
        attached_by_id: id
      }

      changeset = CanvasAttachment.changeset(%CanvasAttachment{}, attrs)

      Repo.insert(changeset,
        on_conflict: {:replace, [:note, :attached_by_kind, :attached_by_id, :updated_at]},
        conflict_target: [:task_id, :canvas_id],
        returning: true
      )
      |> tap_settle_design_step()
    end
  end

  # ADR-0046 member 7 stage 4. A canvas landing on a task is the completion
  # signal for the pre-plan design step: the canvas IS the deliverable, so the
  # deliverable arriving is the honest signal — and unlike a dedicated "I'm
  # done" MCP tool it also works when a human attaches the canvas by hand, and
  # cannot be forgotten in a way that is indistinguishable from stalling.
  #
  # `Platform.Design.PreplanStep.settle/2` is a no-op unless the task's cursor
  # is `"designing"` or its design step is recorded `"failed"`, so this is inert
  # for every other attachment in the system.
  #
  # Side-effect only, twice over: the `{:ok, _}` tuple is returned verbatim, and
  # the whole call is wrapped so a settler that raises cannot turn a successful
  # attach into an error or a crash. Asserted in `canvas_attachments_test.exs`
  # with a deliberately raising stub injected through the seam below.
  defp tap_settle_design_step({:ok, %CanvasAttachment{} = attachment} = result) do
    {mod, fun} =
      Application.get_env(
        :platform,
        :design_preplan_settler,
        {Platform.Design.PreplanStep, :settle}
      )

    _ =
      try do
        apply(mod, fun, [attachment.task_id, attachment])
      rescue
        e ->
          require Logger

          Logger.warning(
            "[task_attach_canvas] design settle hook raised for task=" <>
              "#{attachment.task_id}: #{Exception.message(e)}"
          )

          :error
      catch
        :exit, reason ->
          require Logger

          Logger.warning(
            "[task_attach_canvas] design settle hook exited for task=" <>
              "#{attachment.task_id}: #{inspect(reason)}"
          )

          :error
      end

    result
  end

  defp tap_settle_design_step(other), do: other

  # ── detach ────────────────────────────────────────────────────────────────

  @doc """
  Detach a canvas from a task.

  Returns `:ok` if exactly one row was deleted; `{:error, :not_found}` if
  no matching pair existed. Safe to call on a pair whose canvas was
  soft-deleted upstream — the attachment row is keyed independently.
  """
  @spec detach_canvas(binary(), binary()) :: :ok | {:error, :not_found}
  def detach_canvas(task_id, canvas_id)
      when is_binary(task_id) and is_binary(canvas_id) do
    query =
      from(a in CanvasAttachment,
        where: a.task_id == ^task_id and a.canvas_id == ^canvas_id
      )

    case Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {n, _} when n >= 1 -> :ok
    end
  end

  # ── list ──────────────────────────────────────────────────────────────────

  @doc """
  List attachments for a task with their canvas envelope.

  Returns rows in `inserted_at` ASC order. Each entry is
  `%{attachment: %CanvasAttachment{}, canvas: ... | nil}`. The `canvas`
  envelope is a thin map (`id`, `title`, `kind`, `deleted_at`) so callers
  don't drag the full document graph around when they're just rendering a
  list.

  When the underlying canvas is missing or soft-deleted, `canvas` is `nil`
  rather than dropped — so the caller sees the stale attachment exists and
  can choose to detach it.

  Implementation is a single batched query: load the attachments, then ONE
  `Repo.all` over the unique canvas ids. Not N+1.
  """
  @spec list_task_canvases(binary()) :: [list_entry()]
  def list_task_canvases(task_id) when is_binary(task_id) do
    attachments =
      from(a in CanvasAttachment,
        where: a.task_id == ^task_id,
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()

    canvas_ids =
      attachments
      |> Enum.map(& &1.canvas_id)
      |> Enum.uniq()

    canvases_by_id =
      case canvas_ids do
        [] ->
          %{}

        ids ->
          from(c in Canvas, where: c.id in ^ids)
          |> Repo.all()
          |> Map.new(fn c -> {c.id, c} end)
      end

    Enum.map(attachments, fn attachment ->
      %{
        attachment: attachment,
        canvas: canvas_envelope(Map.get(canvases_by_id, attachment.canvas_id))
      }
    end)
  end

  @doc """
  Reverse of `list_task_canvases/1`: list the tasks a canvas is attached to.

  Returns rows in `inserted_at` ASC order. Each entry is
  `%{attachment: %CanvasAttachment{}, task: ... | nil}`, where the `task`
  envelope is a thin map (`id`, `title`, `status`, `project_id`) for symmetry
  with the forward lookup — callers authorize or render off the envelope
  without dragging the full 60-field task row around.

  `task_id` carries a real FK (`on_delete: :delete_all`), so an attachment
  whose task vanished cannot exist. `deleted_at` is a different matter: tasks
  soft-delete, and a soft-deleted task surfaces as `task: nil` — the same
  "stale attachment, not broken attachment" degradation `list_task_canvases/1`
  applies to a soft-deleted canvas. `Platform.Chat.CanvasAccess` depends on
  that: a `:task_reader` grant must not survive the deletion of the only task
  that conferred it.

  Single LEFT JOIN — not N+1, and not the two-query batch its sibling needs
  (that one joins across a soft reference with no FK, so it cannot join).
  """
  @spec list_canvas_tasks(binary()) :: [task_entry()]
  def list_canvas_tasks(canvas_id) when is_binary(canvas_id) do
    if Platform.UUID.valid?(canvas_id) do
      from(a in CanvasAttachment,
        left_join: t in Task,
        on: t.id == a.task_id,
        where: a.canvas_id == ^canvas_id,
        order_by: [asc: a.inserted_at],
        select: {a, t}
      )
      |> Repo.all()
      |> Enum.map(fn {attachment, task} ->
        %{attachment: attachment, task: task_envelope(task)}
      end)
    else
      []
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # `task_id` / `canvas_id` are raw `canvas_attach` MCP tool arguments.
  # Malformed folds into the existing not-found error. Platform.UUID.valid?/1,
  # not a bare Ecto.UUID.cast/1 — a bare cast accepts any 16-byte binary.
  defp ensure_task_exists(task_id) do
    if not Platform.UUID.valid?(task_id) do
      {:error, :task_not_found}
    else
      case Repo.get(Task, task_id) do
        nil -> {:error, :task_not_found}
        %Task{} -> :ok
      end
    end
  end

  defp ensure_canvas_attachable(canvas_id) do
    if not Platform.UUID.valid?(canvas_id) do
      {:error, :canvas_not_found}
    else
      case Repo.get(Canvas, canvas_id) do
        nil -> {:error, :canvas_not_found}
        %Canvas{deleted_at: nil} -> :ok
        %Canvas{} -> {:error, :canvas_not_found}
      end
    end
  end

  # The attach-time authorization gate (task 019e2c4b stage 2).
  #
  # Runs AFTER `ensure_canvas_attachable/1` so a caller attaching a canvas that
  # simply does not exist hears "not found" rather than "forbidden" — the
  # denial must not become an existence oracle richer than the read door
  # already is.
  #
  # `:system` is the explicit opt-out for platform-initiated attaches, which
  # have no principal to authorize. `CanvasAccess` resolves it; there is no
  # bypass here that `CanvasAccess` does not also know about.
  defp ensure_canvas_readable(canvas_id, actor) do
    case CanvasAccess.fetch_for_viewer(canvas_id, actor, audit: false) do
      {:ok, _canvas, _level} -> :ok
      {:error, :not_found} -> {:error, :canvas_not_found}
      {:error, :forbidden} -> {:error, :canvas_forbidden}
    end
  end

  # Surface a soft-deleted or absent canvas as `nil` so list_task_canvases/1
  # callers can detach the stale row rather than failing loud. Live canvases
  # collapse to a minimal envelope so we don't drag the whole document graph
  # into list responses.
  defp canvas_envelope(nil), do: nil
  defp canvas_envelope(%Canvas{deleted_at: %DateTime{}}), do: nil

  defp canvas_envelope(%Canvas{} = canvas) do
    %{
      id: canvas.id,
      title: canvas.title,
      kind: extract_kind(canvas.document),
      deleted_at: canvas.deleted_at
    }
  end

  # Symmetric with `canvas_envelope/1`: a missing (FK-impossible) or
  # soft-deleted task collapses to `nil` so the caller sees a stale
  # attachment rather than a phantom grant. See `list_canvas_tasks/1`.
  defp task_envelope(nil), do: nil
  defp task_envelope(%Task{deleted_at: %DateTime{}}), do: nil

  defp task_envelope(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      status: task.status,
      project_id: task.project_id
    }
  end

  # Mirror `Platform.Chat.CanvasDocument.root_kind/1` but keep the dependency
  # local + tolerant: any non-binary root type collapses to `nil`. The kind
  # field is informational (UI hint), not load-bearing for any consumer in
  # stages 3/4/5.
  defp extract_kind(%{"root" => %{"type" => t}}) when is_binary(t), do: t
  defp extract_kind(_), do: nil
end

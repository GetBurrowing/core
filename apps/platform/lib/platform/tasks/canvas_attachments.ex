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

  The flip side is that `attach_canvas/3` validates canvas existence
  (and `is_nil(deleted_at)`) **before** insert, so creating a dangling
  attachment from an MCP tool call surfaces loud at attach time, not
  silently later in a downstream consumer.

  ## Idempotent re-attach

  `attach_canvas/3` is idempotent on `(task_id, canvas_id)`. A second call
  with the same pair updates `note` + `attached_by_*` + bumps `updated_at`
  on the existing row, returning the same `id`. This matches how the MCP
  tool will be invoked when an agent attaches the same evidence canvas
  multiple times across a multi-stage task — re-attach is a no-op rather
  than a duplicate row or a unique-constraint surface.
  """

  import Ecto.Query

  alias Platform.Chat.Canvas
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

  # ── attach ────────────────────────────────────────────────────────────────

  @doc """
  Attach a canvas to a task.

  Validates that both the task and the canvas exist (and that the canvas is
  not soft-deleted) before insert. Idempotent on `(task_id, canvas_id)` via
  upsert — a second call updates `note` + attribution + bumps `updated_at`
  and returns the same row id.

  ## Options

    * `:note` — optional human note (string).
    * `:attached_by` — `%{kind: "agent" | "user", id: <uuid>}`. Required.

  ## Returns

    * `{:ok, %CanvasAttachment{}}` on success (insert or upsert).
    * `{:error, :task_not_found}` if the task id doesn't resolve.
    * `{:error, :canvas_not_found}` if the canvas id doesn't resolve, or the
      canvas is soft-deleted.
    * `{:error, %Ecto.Changeset{}}` if the inputs fail changeset validation
      (missing `attached_by`, bad `kind`, etc.).
  """
  @spec attach_canvas(binary(), binary(), attach_opts()) ::
          {:ok, %CanvasAttachment{}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :task_not_found}
          | {:error, :canvas_not_found}
  def attach_canvas(task_id, canvas_id, opts \\ [])
      when is_binary(task_id) and is_binary(canvas_id) and is_list(opts) do
    with :ok <- ensure_task_exists(task_id),
         :ok <- ensure_canvas_attachable(canvas_id) do
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
    end
  end

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

  # ── internals ─────────────────────────────────────────────────────────────

  defp ensure_task_exists(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {:error, :task_not_found}
      %Task{} -> :ok
    end
  end

  defp ensure_canvas_attachable(canvas_id) do
    case Repo.get(Canvas, canvas_id) do
      nil -> {:error, :canvas_not_found}
      %Canvas{deleted_at: nil} -> :ok
      %Canvas{} -> {:error, :canvas_not_found}
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

  # Mirror `Platform.Chat.CanvasDocument.root_kind/1` but keep the dependency
  # local + tolerant: any non-binary root type collapses to `nil`. The kind
  # field is informational (UI hint), not load-bearing for any consumer in
  # stages 3/4/5.
  defp extract_kind(%{"root" => %{"type" => t}}) when is_binary(t), do: t
  defp extract_kind(_), do: nil
end

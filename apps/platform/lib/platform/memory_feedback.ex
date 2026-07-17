defmodule Platform.MemoryFeedback do
  @moduledoc """
  Capture surface for the memory-feedback training corpus.

  Layer 1 of the plan: append-only ledger recording every mutation
  against org memory (edits, deletes, and — future — retention signals
  when the historian promotes a journal entry into long-term memory).

  ## Stage boundaries

  Stage 1 (this module):
    * schema (`Platform.MemoryFeedback.Entry`) + migration
    * `record_edit/1`, `record_delete/1`, `record_retention/1`

  Stage 2 wires the capture hooks into `Platform.Org.Context`
  write paths. Stage 3 fleshes out the query API (`list_recent/1`,
  `deleted_at_path/2`, `signature_matches?/2`). Stage 4 exposes it
  through MCP. Stage 5 injects the deleted-paths notice into the
  historian dreaming instruction.

  Why a separate context module rather than living inside
  `Platform.Org.Context`: matches the per-domain layout used elsewhere
  in the codebase (`Platform.Chat`, `Platform.Tasks`, `Platform.Meetings`).
  `Platform.Org.Context` stays a schema-facade for context files;
  MemoryFeedback owns capture + query.
  """

  import Ecto.Query, only: [where: 3, order_by: 3, limit: 2]

  alias Platform.MemoryFeedback.Entry
  alias Platform.Repo

  @default_namespace "org_context"
  @default_list_limit 20
  @max_list_limit 100

  @doc """
  Record an edit against a memory path.

  `attrs` must include `:original_content`, `:edited_content`, `:path`,
  and `:namespace`. Optional: `:original_author_id`, `:editor_id`,
  `:workspace_id`, `:reason_text`.

  `feedback_kind` is forced to `"edit"` — callers must not override it.
  """
  @spec record_edit(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record_edit(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:feedback_kind, "edit")
    |> insert()
  end

  @doc """
  Record a delete against a memory path.

  `edited_content` is forced to `nil` — a delete has no successor
  content. `feedback_kind` is forced to `"delete"`.
  """
  @spec record_delete(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record_delete(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:feedback_kind, "delete")
    |> Map.put(:edited_content, nil)
    |> insert()
  end

  @doc """
  Reserved for layer-2 (unpromoted-journal retention signal).

  Currently a stub — the historian promotion pipeline that will feed
  this hasn't landed yet. Returns `{:error, :not_implemented}` so
  accidental callers fail loudly rather than silently no-oping.
  """
  @spec record_retention(map()) :: {:error, :not_implemented}
  def record_retention(_attrs), do: {:error, :not_implemented}

  # ── Read API ─────────────────────────────────────────────────────────

  @doc """
  Recent feedback rows, newest first.

  ## Options
    * `:namespace` (default `"org_context"`) — strict-eq scope.
    * `:workspace_id` — `nil` returns rows across all workspaces;
      a UUID applies a strict-eq filter (no `is_nil` fallback — nil
      here means "don't filter", not "match null-workspace rows").
    * `:path_prefix` — `nil` means no filter; a binary applies an
      `ilike "prefix%"` filter with `_`/`%`/`\\` escaped so the prefix
      is literal.
    * `:feedback_kind` — `"edit"` | `"delete"` | `"retention"` or `nil`
      for all kinds.
    * `:limit` (default 20, silently clamped to a max of 100).

  Ordering is `inserted_at DESC`. This is the layer-1 read shape;
  layer-3 may add a `signature_sha256` index for large corpora — do
  not preempt that here.
  """
  @spec list_recent(keyword()) :: [Entry.t()]
  def list_recent(opts \\ []) when is_list(opts) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)
    path_prefix = Keyword.get(opts, :path_prefix)
    feedback_kind = Keyword.get(opts, :feedback_kind)
    lim = min(Keyword.get(opts, :limit, @default_list_limit), @max_list_limit)

    Entry
    |> where([e], e.namespace == ^namespace)
    |> maybe_filter_workspace(workspace_id)
    |> maybe_filter_path_prefix(path_prefix)
    |> maybe_filter_feedback_kind(feedback_kind)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^lim)
    |> Repo.all()
  end

  @doc """
  Most-recent delete row for `path`, or `nil` when the path has never
  been deleted.

  Edits at the same path are ignored — only `feedback_kind: "delete"`
  rows participate. Layer-3's write-time rejection gate will lean on
  this to surface "this path was previously deleted for reason X" as
  a warning surface in MCP/editor UIs.

  ## Options
    * `:namespace` (default `"org_context"`)
    * `:workspace_id` (default `nil` → no filter)
  """
  @spec deleted_at_path(String.t(), keyword()) :: Entry.t() | nil
  def deleted_at_path(path, opts \\ []) when is_binary(path) and is_list(opts) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)

    Entry
    |> where([e], e.namespace == ^namespace)
    |> where([e], e.path == ^path)
    |> where([e], e.feedback_kind == "delete")
    |> maybe_filter_workspace(workspace_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  True iff `content` (byte-exact SHA-256 match) matches the
  `original_content` of any prior `feedback_kind: "delete"` row in
  scope. Edits are ignored — a rejected-then-restored edit does not
  count as a signature match.

  This is intentionally naive: layer-1 loads candidate delete rows
  into the BEAM and hashes each `original_content` in-Elixir. Layer-3's
  optimisation is a persisted `signature_sha256` binary column with a
  unique-per-scope index; **do not add that column here.** For the
  historian's dreaming loop and current MCP volumes the linear scan is
  well below the noise floor.

  ## Options
    * `:namespace` (default `"org_context"`)
    * `:workspace_id` (default `nil` → no filter)
  """
  @spec signature_matches?(binary(), keyword()) :: boolean()
  def signature_matches?(content, opts \\ []) when is_binary(content) and is_list(opts) do
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    workspace_id = Keyword.get(opts, :workspace_id)
    target_sha = :crypto.hash(:sha256, content)

    Entry
    |> where([e], e.namespace == ^namespace)
    |> where([e], e.feedback_kind == "delete")
    |> maybe_filter_workspace(workspace_id)
    |> Repo.all()
    |> Enum.any?(fn %Entry{original_content: original} ->
      is_binary(original) and :crypto.hash(:sha256, original) == target_sha
    end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Ecto.Changeset.cast accepts either atom-keyed or string-keyed maps
  # but chokes on a mixed map. Since our public API forces `feedback_kind`
  # via `Map.put(attrs, :feedback_kind, "edit")`, we stringify everything
  # first so cast sees a single-shape map. Unknown keys are silently
  # dropped by cast's field allowlist — no `String.to_existing_atom`
  # gymnastics needed.
  defp insert(attrs) do
    %Entry{}
    |> Entry.changeset(stringify_keys(attrs))
    |> Repo.insert()
  end

  defp stringify_keys(%{} = attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp maybe_filter_workspace(queryable, nil), do: queryable

  defp maybe_filter_workspace(queryable, workspace_id) do
    where(queryable, [e], e.workspace_id == ^workspace_id)
  end

  defp maybe_filter_path_prefix(queryable, nil), do: queryable

  defp maybe_filter_path_prefix(queryable, prefix) when is_binary(prefix) do
    pattern = escape_ilike(prefix) <> "%"
    where(queryable, [e], ilike(e.path, ^pattern))
  end

  defp maybe_filter_feedback_kind(queryable, nil), do: queryable

  defp maybe_filter_feedback_kind(queryable, kind) when is_binary(kind) do
    where(queryable, [e], e.feedback_kind == ^kind)
  end

  # Escape `%`, `_`, and `\` so a caller-supplied prefix is treated as
  # a literal by Postgres `ilike`. Matches the shape used in Chat's
  # mention search (`escape_ilike/1`).
  defp escape_ilike(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end

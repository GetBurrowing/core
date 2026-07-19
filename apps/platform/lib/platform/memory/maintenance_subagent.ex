defmodule Platform.Memory.MaintenanceSubagent do
  @moduledoc """
  Maintenance-op fan-out for the Historian dreaming loop (ADR-0041 M8
  stage 7).

  Each op — link repair, format normalize, retired cleanup — receives a
  bucket of `Platform.Memory.Integrity.scan/1` entries and dispatches
  ONE fresh BEAM subagent per item so the caller's context never
  accumulates per-link diffs. That per-op discipline is load-bearing
  (acceptance criterion 10): dreaming runs at 03:00 local and the
  parent Historian transcript stays digestible only if each entry-level
  rewrite is a separately-audited unit rather than a rolling patch
  buffer.

  The subagent boundary is a `Task.async_stream/3` process bounded at
  `max_concurrency: 4` with a per-item wall clock of 60 s and
  `on_timeout: :kill_task` — bounds the blast radius of a single bad
  entry (a malformed page, a Repo hiccup) and guarantees the batch
  completes in bounded wall time regardless of item count. One failed
  op does NOT cancel the batch: failures are collected into the
  returned list as `{:error, reason, item}` while surviving items keep
  running.

  Every attempted op — success or failure — records an audit event on
  the `Platform.Audit` stream so a post-hoc auditor can reconstruct the
  full sequence of changes from a dreaming run without replaying the
  Historian's transcript. Successful ops carry the before/after content
  hashes so a spot-check reviewer can verify what actually changed
  without loading the full page bodies.

  ## Public entry points

    * `spawn_link_repair/2` — items from the `:broken` bucket
    * `spawn_format_normalize/2` — items from the `:format_dirty` bucket
    * `spawn_retired_cleanup/2` — items from the `:retired_target` bucket

  Each returns `[{:ok, %Platform.Audit.Event{}} | {:error, reason,
  item}]` with the same length + order as the input list.

  ## Options

    * `:runner` — per-item side-effect function. Signature
      `(op, item, opts) -> {:ok, %{before_hash, after_hash, notes}} |
      {:error, term()}`. Default implementation rewrites the source
      page via `Platform.Org.Wiki.upsert_page/3`; tests inject a fake
      runner to (a) record the exact scoped payload each subagent
      receives (regression guard for acceptance criterion 10) and (b)
      simulate failures without a real DB path.
    * `:actor_slug` — default `"historian.dreaming"`. Written into the
      audit metadata (`"actor_slug"`) and passed to the runner so a
      federated dreaming variant can attribute correctly.
    * `:actor_id` — optional UUID of the calling agent row. Written to
      the audit event's `actor_id` column. Nil is legal; the audit row
      still records `actor_type: "agent"` and the slug in metadata.
    * `:workspace_id` — optional UUID scoping the page write. Passed
      through to the runner and recorded on the audit event.
    * `:max_concurrency` — override the default parallel-op cap (4).
    * `:timeout` — override the per-item timeout in milliseconds
      (60_000). Applies to each async task in isolation.

  ## Regression guard — subagent payload scoping (acceptance criterion 10)

  The runner receives EXACTLY ONE item plus the sanitized opts —
  never the full items list, never the surrounding batch context. The
  test module asserts on the payload the runner actually saw so a
  refactor that broadcasts the whole batch into each task (a natural
  accident with closures) trips a red test rather than silently
  bloating the audit trail and the LLM subagent context (once the
  runner grows into an LLM invocation in a follow-up stage).
  """

  require Logger

  alias Platform.Audit
  alias Platform.Org.Wiki

  @default_actor_slug "historian.dreaming"
  @default_concurrency 4
  @default_timeout_ms 60_000

  @type op :: :link_repair | :format_normalize | :retired_cleanup

  @type item :: %{
          required(:source_id) => String.t(),
          required(:source_path) => String.t(),
          required(:target_path) => String.t(),
          optional(:resolved_target_path) => String.t() | nil,
          optional(atom()) => any()
        }

  @type runner_result ::
          {:ok,
           %{
             required(:before_hash) => String.t(),
             required(:after_hash) => String.t(),
             optional(:notes) => String.t() | nil
           }}
          | {:error, term()}

  @type runner :: (op(), item(), keyword() -> runner_result())

  @type opts :: [
          runner: runner(),
          actor_slug: String.t(),
          actor_id: binary() | nil,
          workspace_id: binary() | nil,
          max_concurrency: pos_integer(),
          timeout: pos_integer()
        ]

  @type result :: {:ok, Audit.Event.t()} | {:error, term(), item()}

  @doc """
  Fan out one subagent per `:broken`-bucket item.

  When the paired Integrity entry carries `resolved_target_path: nil`
  (the standard shape for `:broken`), the default runner strips the
  wikilink brackets so the referrer no longer points at a dangling
  target. See the module doc for how to inject a smarter runner.
  """
  @spec spawn_link_repair([item()], opts()) :: [result()]
  def spawn_link_repair(items, opts \\ []) when is_list(items) and is_list(opts) do
    run_batch(:link_repair, items, opts)
  end

  @doc """
  Fan out one subagent per `:format_dirty`-bucket item.

  Rewrites bare `[[slug]]` references to the absolute
  `[[org/page/foo/bar.md]]` form given by
  `Integrity.scan/1`'s `resolved_target_path`.
  """
  @spec spawn_format_normalize([item()], opts()) :: [result()]
  def spawn_format_normalize(items, opts \\ []) when is_list(items) and is_list(opts) do
    run_batch(:format_normalize, items, opts)
  end

  @doc """
  Fan out one subagent per `:retired_target`-bucket item.

  Strips the wikilink brackets from the referrer so the intentionally-
  removed target is no longer surfaced as a live link. Redirect
  semantics (rewrite to the successor page when `MemoryFeedback` grows
  a move-tracking column) is deliberately out of scope for stage 7;
  the runner falls through to a strip when `resolved_target_path` is
  nil, which is always true for the retired bucket today.
  """
  @spec spawn_retired_cleanup([item()], opts()) :: [result()]
  def spawn_retired_cleanup(items, opts \\ []) when is_list(items) and is_list(opts) do
    run_batch(:retired_cleanup, items, opts)
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Empty bucket is the common case (Integrity.scan produces empty
  # buckets on a clean corpus). Short-circuiting avoids spinning up a
  # Task.async_stream supervisor + associated allocations for nothing.
  defp run_batch(_op, [], _opts), do: []

  defp run_batch(op, items, opts) when is_list(items) do
    runner = Keyword.get(opts, :runner, &default_runner/3)
    concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    items
    |> Enum.with_index()
    |> Task.async_stream(
      fn {item, _idx} -> run_one(op, item, runner, opts) end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      # `ordered: true` so the returned list aligns with input index —
      # simplifies the {:error, reason, item} rebuild without carrying
      # the index through the async payload.
      ordered: true
    )
    |> Enum.zip(items)
    |> Enum.map(fn
      {{:ok, {:ok, event}}, _item} ->
        {:ok, event}

      {{:ok, {:error, reason}}, item} ->
        {:error, reason, item}

      {{:exit, :timeout}, item} ->
        Logger.warning("[memory.maintenance] op=#{op} timed out for source_id=#{item.source_id}")

        {:error, :timeout, item}

      {{:exit, reason}, item} ->
        Logger.warning(
          "[memory.maintenance] op=#{op} task exited " <>
            "source_id=#{item.source_id} reason=#{inspect(reason)}"
        )

        {:error, {:exited, reason}, item}
    end)
  end

  # Per-item execution. The runner receives EXACTLY the scoped payload
  # `(op, item, scoped_opts)` — never the surrounding batch, never any
  # cross-item state. `scoped_opts` is a copy of the caller opts filtered
  # to the whitelist the runner is contracted to consume, so a refactor
  # that adds a batch-shaped opt (e.g. `:all_items`) doesn't accidentally
  # leak it into the per-item call site.
  @scoped_opt_keys ~w(workspace_id actor_slug actor_id)a

  defp run_one(op, item, runner, opts) do
    scoped_opts =
      opts
      |> Keyword.take(@scoped_opt_keys)
      |> Keyword.put_new(:actor_slug, Keyword.get(opts, :actor_slug, @default_actor_slug))

    case safe_runner_invoke(runner, op, item, scoped_opts) do
      {:ok, summary} when is_map(summary) ->
        record_audit(op, item, summary, opts)

      {:error, reason} ->
        record_audit_failure(op, item, reason, opts)
        {:error, reason}

      other ->
        Logger.warning(
          "[memory.maintenance] runner returned unexpected shape op=#{op} " <>
            "source_id=#{item.source_id} result=#{inspect(other)}"
        )

        record_audit_failure(op, item, {:runner_bad_shape, other}, opts)
        {:error, {:runner_bad_shape, other}}
    end
  end

  defp safe_runner_invoke(runner, op, item, opts) when is_function(runner, 3) do
    runner.(op, item, opts)
  rescue
    error ->
      {:error, {:runner_raised, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:runner_exited, reason}}

    kind, reason ->
      {:error, {:runner_threw, kind, reason}}
  end

  defp safe_runner_invoke(runner, _op, _item, _opts) do
    {:error, {:runner_not_callable, inspect(runner)}}
  end

  # ── Audit ─────────────────────────────────────────────────────────────

  defp record_audit(op, item, summary, opts) do
    attrs =
      build_audit_attrs(op, item, opts, "ok", %{
        "before_hash" => Map.get(summary, :before_hash),
        "after_hash" => Map.get(summary, :after_hash),
        "notes" => Map.get(summary, :notes)
      })

    case Audit.record(attrs) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        Logger.warning(
          "[memory.maintenance] audit record failed op=#{op} source_id=#{item.source_id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, {:audit_failed, reason}}
    end
  end

  defp record_audit_failure(op, item, reason, opts) do
    attrs =
      build_audit_attrs(op, item, opts, "error", %{
        "reason" => inspect(reason)
      })

    case Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, err} ->
        Logger.warning(
          "[memory.maintenance] audit record failed on error-path op=#{op} " <>
            "source_id=#{item.source_id} reason=#{inspect(err)}"
        )

        :ok
    end
  end

  defp build_audit_attrs(op, item, opts, outcome, extra_metadata) do
    actor_slug = Keyword.get(opts, :actor_slug, @default_actor_slug)
    actor_id = Keyword.get(opts, :actor_id)
    workspace_id = Keyword.get(opts, :workspace_id)

    metadata =
      %{
        "actor_slug" => actor_slug,
        "workspace_id" => workspace_id,
        "source_id" => item.source_id,
        "source_path" => item.source_path,
        "target_path" => item.target_path,
        "resolved_target_path" => Map.get(item, :resolved_target_path),
        "outcome" => outcome
      }
      |> Map.merge(extra_metadata)

    %{
      event_type: "platform.memory.maintenance." <> to_string(op),
      actor_type: "agent",
      actor_id: actor_id,
      action: to_string(op),
      resource_type: "wiki_page",
      resource_id: item.source_id,
      metadata: metadata
    }
  end

  # ── Default runner ────────────────────────────────────────────────────

  # Concrete rewrite path. Loads the source page via `Wiki.get_page/2`
  # to keep the read + write on the same public API surface as the rest
  # of `Platform.Org.Wiki`, then delegates the actual bracket rewrite
  # to `rewrite_content/3` and persists via `Wiki.upsert_page/3` so the
  # `org_wiki_links` re-materialization runs — the whole point of the
  # repair is to move a link from `target_id IS NULL` to resolved.
  #
  # Returns `{:ok, %{before_hash, after_hash, notes}}` on a successful
  # write. When the rewrite is a no-op (target string didn't appear
  # in the page body — the write ledger races with a manual edit), we
  # still return `{:ok, ...}` with `notes: "no-op"` and equal hashes so
  # the audit trail records that the subagent looked and found nothing
  # to change.
  defp default_runner(op, item, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, page} <- fetch_source_page(item, workspace_id) do
      before_content = page.content || ""
      before_hash = hash(before_content)

      case rewrite_content(op, before_content, item) do
        {:ok, ^before_content, _notes} ->
          # No-op rewrite — target string wasn't present. Record but
          # skip the write so we don't bump the page version for a
          # zero-change edit.
          {:ok, %{before_hash: before_hash, after_hash: before_hash, notes: "no-op"}}

        {:ok, new_content, notes} ->
          after_hash = hash(new_content)

          case Wiki.upsert_page(item.source_path, %{content: new_content},
                 workspace_id: workspace_id
               ) do
            {:ok, _updated_page} ->
              {:ok, %{before_hash: before_hash, after_hash: after_hash, notes: notes}}

            {:error, reason} ->
              {:error, {:upsert_failed, reason}}
          end
      end
    end
  end

  defp fetch_source_page(%{source_path: path}, workspace_id) do
    case Wiki.get_page(path, workspace_id: workspace_id) do
      nil -> {:error, {:source_page_missing, path}}
      page -> {:ok, page}
    end
  end

  # Rewrite strategies per op. Kept deterministic (no LLM) so the audit
  # trail is reproducible from Integrity.scan output alone.
  defp rewrite_content(:format_normalize, content, %{
         target_path: target,
         resolved_target_path: resolved
       })
       when is_binary(resolved) and resolved != "" do
    {rewritten, notes} = replace_wikilink(content, target, resolved)
    {:ok, rewritten, notes}
  end

  defp rewrite_content(op, content, %{
         target_path: target,
         resolved_target_path: resolved
       })
       when op in [:link_repair, :retired_cleanup] and is_binary(resolved) and resolved != "" do
    # A :broken entry with a runner-supplied redirect target (future
    # extension) rewrites to the resolved path — same shape as
    # :format_normalize.
    {rewritten, notes} = replace_wikilink(content, target, resolved)
    {:ok, rewritten, notes}
  end

  defp rewrite_content(op, content, %{target_path: target})
       when op in [:link_repair, :retired_cleanup] do
    # No redirect: strip the wikilink brackets, leave the visible text.
    {rewritten, notes} = strip_wikilink(content, target)
    {:ok, rewritten, notes}
  end

  # Replace occurrences of `[[<old>]]` (and `[[<old>|display]]`) with
  # `[[<new>]]` / `[[<new>|display]]`. Returns the rewritten string and
  # a note describing the count of replacements.
  defp replace_wikilink(content, old, new) do
    escaped = Regex.escape(old)
    # Two patterns: with and without a display alias.
    with_alias = Regex.compile!("\\[\\[" <> escaped <> "\\|([^\\]]*)\\]\\]")
    plain = Regex.compile!("\\[\\[" <> escaped <> "\\]\\]")

    {step1, n1} = replace_and_count(content, with_alias, "[[" <> new <> "|\\1]]")
    {step2, n2} = replace_and_count(step1, plain, "[[" <> new <> "]]")

    {step2, "replaced #{n1 + n2} occurrence(s) of [[#{old}]] with [[#{new}]]"}
  end

  # Strip `[[<target>]]` / `[[<target>|display]]` down to the visible
  # text — for the alias form keep the display, for the plain form keep
  # the target basename.
  defp strip_wikilink(content, target) do
    escaped = Regex.escape(target)
    with_alias = Regex.compile!("\\[\\[" <> escaped <> "\\|([^\\]]*)\\]\\]")
    plain = Regex.compile!("\\[\\[" <> escaped <> "\\]\\]")

    {step1, n1} = replace_and_count(content, with_alias, "\\1")
    {step2, n2} = replace_and_count(step1, plain, target)

    {step2, "stripped #{n1 + n2} occurrence(s) of [[#{target}]]"}
  end

  defp replace_and_count(content, regex, replacement) do
    count = length(Regex.scan(regex, content))
    {Regex.replace(regex, content, replacement), count}
  end

  defp hash(content) when is_binary(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end
end

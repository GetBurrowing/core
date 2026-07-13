defmodule Platform.Audit.HistorianAudit do
  @moduledoc """
  Read helpers for historian dispatch audit events (task 019f5bc4).

  All events under `platform.historian.*` are workspace- or org-scoped via
  `resource_type` + `resource_id`. This module returns them ordered by
  insertion time (newest last, matching `Platform.Audit.list/1` convention,
  which orders by ascending `id`).
  """

  alias Platform.Audit

  @historian_event_prefix "platform.historian."

  @doc """
  Recent historian events for a workspace_id OR org_id.

  ## Options

    * `:limit` — max rows (default 50).
    * `:event_type` — restrict to a single subtype (e.g. `"pass_completed"`);
      omit for all `platform.historian.*` events.
    * `:scope_type` — `"workspace"` (default) or `"org"`. Passed as-is to
      the `resource_type` filter.

  Returns `[%Platform.Audit.Event{}]` newest last (matches `Audit.list/1`
  ordering — `order_by: [asc: e.id]`).

  ## Example

      iex> Platform.Audit.HistorianAudit.recent_for_scope(workspace_id)
      [%Platform.Audit.Event{event_type: "platform.historian.pass_started", ...},
       %Platform.Audit.Event{event_type: "platform.historian.window_dispatched", ...},
       ...]
  """
  @spec recent_for_scope(binary(), keyword()) :: [Platform.Audit.Event.t()]
  def recent_for_scope(scope_id, opts \\ []) when is_binary(scope_id) do
    limit = Keyword.get(opts, :limit, 50)
    scope_type = Keyword.get(opts, :scope_type, "workspace")

    event_type =
      case Keyword.get(opts, :event_type) do
        nil -> @historian_event_prefix <> "*"
        sub when is_binary(sub) -> @historian_event_prefix <> sub
      end

    Audit.list(
      resource_type: scope_type,
      resource_id: scope_id,
      event_type: event_type,
      limit: limit
    )
  end
end

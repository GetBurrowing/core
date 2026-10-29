defmodule PlatformWeb.ExecutionStatus do
  @moduledoc "Shared measured-execution fragments for task lists, details and chat."
  use PlatformWeb, :html
  alias Platform.Orchestration.ExecutionStatus, as: Projection

  attr :status, :map, default: nil
  attr :class, :string, default: ""

  def line(assigns) do
    assigns = assign(assigns, :status, assigns.status || Projection.unknown())

    ~H"""
    <span
      data-role="execution-status"
      data-state={@status.state}
      class={[
        "execution-status inline-flex items-center gap-1.5 text-sm font-medium shrink-0 whitespace-nowrap",
        @class
      ]}
    >
      <span
        aria-hidden="true"
        class={[
          "execution-dot size-2 shrink-0 rounded-full",
          "execution-dot-#{@status.state}",
          @status.pulse? && "execution-pulse"
        ]}
      >
      </span>
      <span class={@status.state == :human && "execution-human-chip rounded px-1.5 py-0.5"}>
        {@status.label}
      </span>
      <span
        class="execution-utility text-xs text-subtle"
        title={iso(@status.activity_at || @status.blocked_at)}
      >
        · {time_copy(@status)}
      </span>
    </span>
    """
  end

  attr :status, :map, required: true
  attr :target, :any, default: nil
  attr :pending, :boolean, default: false
  attr :error, :string, default: nil
  attr :can_write, :boolean, default: false

  def header(assigns) do
    ~H"""
    <section
      data-role="execution-header"
      data-state={@status.state}
      class={[
        "execution-header rounded border border-base-300 bg-base-100 p-3 space-y-2",
        @status.state != :running && "execution-rule",
        "execution-rule-#{@status.state}"
      ]}
    >
      <div class="flex flex-wrap items-center gap-2">
        <strong :if={@status.state == :human} class="text-sm">NEEDS A PERSON</strong>
        <.line status={@status} />
      </div>
      <p :if={@status.blocked_at} class="execution-utility text-xs text-subtle">
        Blocked since
        <time datetime={iso(@status.blocked_at)}>
          {Calendar.strftime(@status.blocked_at, "%H:%MZ")}
        </time>
        ({@status.elapsed})
      </p>
      <p :if={@status.reason} class="text-sm font-medium">Reason: {@status.reason}</p>
      <p :if={@status.stage} class="execution-utility text-xs text-subtle">{@status.stage}</p>
      <p :for={dep <- @status.dependencies} class="text-sm">
        Dependency {short_id(dep.id)} is now {String.upcase(dep.status)}
      </p>
      <button
        :if={@status.can_recheck? && @can_write}
        type="button"
        class="btn btn-primary btn-sm"
        phx-click="execution_recheck"
        phx-target={@target}
        phx-value-lease={@status.lease_id}
        phx-value-revision={@status.hold_revision}
        disabled={@pending}
        data-role="execution-recheck"
      >
        {if @pending, do: "Re-check requested", else: "Re-check blocker"}
      </button>
      <p :if={@error} role="status" class="text-sm" data-role="execution-recheck-error">{@error}</p>
    </section>
    """
  end

  defp time_copy(%{state: :unknown, elapsed: "unknown"}), do: "last activity unknown"
  defp time_copy(%{state: :unknown, elapsed: elapsed}), do: "last activity #{elapsed} ago"

  defp time_copy(%{state: state, elapsed: elapsed}) when state in [:human, :waiting],
    do: "blocked #{elapsed}"

  defp time_copy(%{elapsed: elapsed}), do: "#{elapsed} ago"
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil
  defp short_id(id) when is_binary(id), do: String.slice(id, 9, 4)
  defp short_id(_), do: "unknown"
end

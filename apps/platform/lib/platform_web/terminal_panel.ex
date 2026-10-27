defmodule PlatformWeb.TerminalPanel do
  @moduledoc """
  The "Open terminal" entry in an agent's detail panel, and the owner's own
  record of past terminal sessions (task 01a17b17 stage 3).

  The entry is gated on `Platform.Federation.RemoteAccess`, not on a bare
  owner check: it renders only for a kind the terminal may ever be offered for,
  and for a viewer of that kind. For everyone else it is ABSENT, not disabled.
  Core still refuses the join on the server (stage 2); this only decides what is
  drawn.
  """
  use Phoenix.Component

  import Ecto.Query

  alias Platform.Audit.Event
  alias Platform.Federation
  alias Platform.Federation.RemoteAccess
  alias Platform.Repo

  @activity_limit 5

  @doc "True when `user_id` may be shown the terminal for `runtime`."
  def offer?(nil, _user_id), do: false

  def offer?(runtime, user_id) do
    runtime |> RemoteAccess.kind_for(user_id) |> RemoteAccess.allowed_kind?()
  end

  @doc "The path of the terminal for a runtime."
  def path(runtime_id), do: "/terminal/" <> runtime_id

  attr(:agent, :map, required: true)
  attr(:user_id, :string, default: nil)

  def entry(assigns) do
    runtime = assigns.agent.runtime_id && Federation.get_runtime(assigns.agent.runtime_id)
    offer? = offer?(runtime, assigns.user_id)

    assigns =
      assigns
      |> assign(:offer?, offer?)
      |> assign(:runtime, runtime)
      |> assign(:entries, if(offer?, do: activity(runtime.runtime_id, assigns.user_id), else: []))

    ~H"""
    <div :if={@offer?} id="terminal-entry" class="mt-4 rounded-2xl border border-edge p-4 text-sm">
      <.link
        navigate={path(@runtime.runtime_id)}
        id="open-terminal"
        class="inline-flex items-center gap-2 rounded-lg px-3 py-2 text-base-content lg:hover:bg-base-200"
      >
        <span class="hero-command-line h-5 w-5" /> Open terminal
      </.link>
      <ul :if={@entries != []} id="terminal-activity" class="mt-3 space-y-1 text-muted">
        <li :for={e <- @entries} id={"terminal-activity-#{e.id}"}>
          You opened the terminal, {e.mode_text}, <.clock id={"opened-#{e.id}"} at={e.opened_at} /> to
          <.clock id={"closed-#{e.id}"} at={e.closed_at} />
        </li>
      </ul>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:at, :any, required: true)

  defp clock(assigns) do
    ~H"""
    <time id={@id} phx-hook="LocalTime" datetime={DateTime.to_iso8601(@at)}>
      {Calendar.strftime(@at, "%H:%M")}
    </time>
    """
  end

  @doc "The viewer's own closed sessions for a runtime, newest first."
  def activity(runtime_id, user_id) when is_binary(runtime_id) and is_binary(user_id) do
    Repo.all(
      from(e in Event,
        where:
          e.event_type == "terminal.session.closed" and e.resource_id == ^runtime_id and
            e.actor_id == ^user_id,
        order_by: [desc: e.id],
        limit: ^@activity_limit
      )
    )
    |> Enum.flat_map(&entry_for/1)
  end

  def activity(_runtime_id, _user_id), do: []

  defp entry_for(%Event{id: id, metadata: meta}) do
    with {:ok, opened, _} <- DateTime.from_iso8601(meta["opened_at"] || ""),
         {:ok, closed, _} <- DateTime.from_iso8601(meta["closed_at"] || "") do
      [%{id: id, mode_text: mode_text(meta["mode"]), opened_at: opened, closed_at: closed}]
    else
      _ -> []
    end
  end

  defp mode_text("rw"), do: "can type"
  defp mode_text(_), do: "view only"
end

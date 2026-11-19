defmodule PlatformWeb.Components.Mail.AccessAgentRow do
  @moduledoc """
  One agent's row in the Email Access panel (task 01a1f5cc stage 4).

  An agent may hold two grants on a mailbox: an ordinary `access` grant and
  the `flag_important` grant chosen in Email > Accounts. The panel shows ONE
  row per agent (`EmailLive.load_access/2` folds the grant rows by agent):
  the "Flags important email" sub-line marks the flag agent, and Revoke
  revokes the access grant only. An agent holding ONLY the flag grant has
  nothing for Revoke to remove, so it gets a "Turn off in Email > Accounts"
  link instead: the flag grant is changed through the ledger there.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  attr(:agent, :map, required: true, doc: "%{id, name, avatar_url, granted_at, access?, flag?}")
  attr(:manage?, :boolean, required: true)
  attr(:accounts_path, :string, required: true)

  def access_agent_row(assigns) do
    ~H"""
    <li
      class="flex min-h-11 items-center gap-3 py-2"
      data-role="access-agent-row"
      data-agent-id={@agent.id}
    >
      <.agent_avatar name={@agent.name} avatar_url={@agent.avatar_url} size="sm" />
      <div class="flex min-w-0 flex-1 flex-col">
        <span class="truncate text-sm text-base-content">{@agent.name}</span>
        <span
          :if={@agent.flag?}
          class="truncate text-xs text-subtle"
          data-role="access-agent-flag"
        >
          Flags important email
        </span>
      </div>
      <span
        :if={granted_text(@agent.granted_at)}
        class="shrink-0 font-mono text-xs text-subtle"
        data-role="access-agent-granted"
      >
        {granted_text(@agent.granted_at)}
      </span>
      <button
        :if={@manage? and @agent.access?}
        type="button"
        phx-click="confirm_revoke"
        phx-value-agent_id={@agent.id}
        class="btn btn-ghost btn-xs min-h-11 shrink-0 lg:min-h-6"
        data-role="access-revoke"
      >
        Revoke
      </button>
      <.link
        :if={@manage? and not @agent.access?}
        patch={@accounts_path}
        class="link min-h-11 shrink-0 content-center text-xs text-base-content lg:min-h-6"
        data-role="access-agent-turn-off"
      >
        Turn off in Email &gt; Accounts
      </.link>
    </li>
    """
  end

  defp granted_text(%DateTime{} = at), do: "granted " <> Calendar.strftime(at, "%m-%d %H:%M")
  defp granted_text(%NaiveDateTime{} = at), do: "granted " <> Calendar.strftime(at, "%m-%d %H:%M")
  defp granted_text(_), do: nil
end

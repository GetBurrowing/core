defmodule PlatformWeb.Components.ReplyFailureRow do
  @moduledoc """
  The chat row for a reply-failure notice (task 01a10322 stage 4): a
  `content_type: "system"` message with `metadata["kind"] == "reply_failure"`,
  posted by `Platform.Chat.ReplyFailure.notify/2` when an agent could not
  answer a message addressed to it.

  A system row, not a chat bubble (design canvas
  01a10325-8f2d-7001-b858-b92639451ceb): the agent's avatar at reduced
  opacity, the error icon, the notice's two lines, box radius, and `error` at
  low opacity as the ground tint.

  Everyone in the space sees both lines. What follows them depends on the
  viewer:

    * someone `Platform.Agents.NativeAgents.can_manage?/2` admits gets one
      action matching the cause (Log in / Start <Name> / Restart <Name> /
      Open <Name>), a link to the agent on Agent Resources, where the control
      itself is re-checked server-side;
    * everyone else reads "Someone who manages <Name> can fix this in Agent
      Resources."

  A declined-chat notice (`cause: "chat_declined"`, task 01a1b20f) is one
  line, "<Name> doesn't take chat messages.", with no action and no
  hand-off: nothing is broken, so there is nothing to fix. It keeps none of
  the failure styling (design canvas 01a1b6d9, task 01a1b25f stage 1) — a
  bare system line at a normal line's height: the `info` icon in `text-info`
  and the copy in `text-neutral`, no tint box, no error icon, no dimmed
  avatar. Declining chat is a choice, not a failure.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Chat.ReplyFailure
  alias Platform.Repo

  attr :msg, :map, required: true
  # The viewing user's id; decides whether the action or the hand-off line
  # renders. A nil viewer (anonymous / embedded without a user) manages
  # nothing.
  attr :viewer_user_id, :string, default: nil

  def row(assigns) do
    metadata = assigns.msg.metadata || %{}
    agent = load_agent(metadata["agent_id"])
    name = (agent && agent.name) || "This agent"
    cause = metadata["cause"]
    declined? = cause == "chat_declined"

    [line1, line2] =
      if declined?,
        do: [ReplyFailure.chat_declined_line(name), nil],
        else: lines(assigns.msg.content, name, cause)

    assigns =
      assigns
      |> assign(:agent, agent)
      |> assign(:name, name)
      |> assign(:cause, cause)
      |> assign(:line1, line1)
      |> assign(:line2, line2)
      |> assign(:declined?, declined?)
      |> assign(:can_manage?, NativeAgents.can_manage?(assigns.viewer_user_id, agent))
      |> assign(:native?, NativeAgents.managed?(agent))

    if declined? do
      # Design canvas 01a1b6d9 (task 01a1b25f stage 1): one line — info icon
      # in text-info, copy in text-neutral — no tint box, no error icon, no
      # dimmed avatar, no action and no hand-off.
      ~H"""
      <div
        data-role="reply-failure"
        data-cause={@cause}
        role="status"
        class="my-1 flex items-start gap-3"
      >
        <span
          class="hero-information-circle mt-0.5 size-5 shrink-0 text-info"
          aria-hidden="true"
        />
        <div class="min-w-0 flex-1 text-sm leading-5 text-neutral">
          <p>{@line1}</p>
        </div>
      </div>
      """
    else
      ~H"""
      <div
        data-role="reply-failure"
        data-cause={@cause}
        role="status"
        class="my-1 flex items-start gap-3 rounded-box bg-error/10 px-3 py-3"
      >
        <div class="shrink-0 opacity-50">
          <.agent_avatar
            name={@name}
            avatar_url={@agent && @agent.avatar_url}
            size="md"
          />
        </div>
        <span
          class="hero-exclamation-circle mt-0.5 size-5 shrink-0 text-error"
          aria-hidden="true"
        />
        <div class="min-w-0 flex-1 text-sm leading-5 text-base-content">
          <p class="font-semibold">{@line1}</p>
          <p :if={@line2}>{@line2}</p>
          <.link
            :if={!@declined? && @can_manage? && @agent}
            navigate={~p"/control/#{@agent.slug}"}
            data-role="reply-failure-action"
            class={[
              "btn btn-sm mt-2",
              @cause in ["needs_login", "stopped"] && "btn-primary",
              @cause not in ["needs_login", "stopped"] && "btn-outline"
            ]}
          >
            {action_label(@cause, @name, @native?)}
          </.link>
          <p
            :if={!@declined? && !@can_manage?}
            data-role="reply-failure-handoff"
            class="mt-1 text-xs leading-4 text-subtle"
          >
            Someone who manages {@name} can fix this in Agents.
          </p>
        </div>
      </div>
      """
    end
  end

  @doc "The action a manager sees, by cause. Copy verbatim from the canvas."
  @spec action_label(String.t() | nil, String.t()) :: String.t()
  def action_label("needs_login", _name), do: "Log in"
  def action_label("stopped", name), do: "Start #{name}"
  def action_label("crashed", name), do: "Restart #{name}"
  def action_label(_unknown, name), do: "Open #{name}"

  @doc """
  The action for a native agent (`native? == true`): as `action_label/2`,
  except that an unknown cause offers Restart <Name>. A native agent that
  went silent with no cause anyone could name (stage 7 round 2, the no-reply
  watchdog) is fixed by a restart, which the install can do; "Open" named no
  fix. Deviation from the canvas's "Open Ada", recorded in the stage report.
  A federated agent keeps "Open <Name>": Burrow cannot restart it.
  """
  @spec action_label(String.t() | nil, String.t(), boolean()) :: String.t()
  def action_label(cause, name, true) when cause in ["needs_login", "stopped", "crashed"],
    do: action_label(cause, name)

  def action_label(_unknown, name, true), do: "Restart #{name}"
  def action_label(cause, name, _native?), do: action_label(cause, name)

  # The posted text is the record of what was true when it was posted; fall
  # back to the canvas copy when the body is not the two-line shape.
  defp lines(content, name, cause) when is_binary(content) do
    case String.split(content, "\n", parts: 2) do
      [one, two] -> [one, two]
      _ -> canvas_lines(name, cause)
    end
  end

  defp lines(_content, name, cause), do: canvas_lines(name, cause)

  defp canvas_lines(name, cause) do
    cause_atom = Enum.find(ReplyFailure.causes(), :unknown, &(Atom.to_string(&1) == cause))
    [ReplyFailure.headline(name), ReplyFailure.cause_line(cause_atom, name)]
  end

  # `agent_id` is read from message metadata, which any message can carry, so
  # it is checked before it reaches Agent's strict UUIDv7 PK.
  defp load_agent(id) when is_binary(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Agent, id)
  end

  defp load_agent(_), do: nil
end

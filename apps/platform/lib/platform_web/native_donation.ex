defmodule PlatformWeb.NativeDonation do
  @moduledoc """
  The web half of Burrow's personal-context donations (task 01a111bb).

  When the app's web view does something a person did by hand (sent a
  message, created a task, approved or rejected a plan, started a meeting),
  the LiveView pushes `"native_donate"`. `assets/js/native_donations.js`
  forwards it to the native `SuiteNative.donate` plugin, which donates a
  recipients-only intent to iOS so Siri learns who the person talks to. In a
  plain browser the JS is a no-op.

  ## Ids only, never content

  A payload carries the kind plus that kind's allow-listed id keys, and
  nothing else, whatever the caller passes:

  | kind              | keys                                              |
  |-------------------|---------------------------------------------------|
  | `message_sent`    | `space_id`, `recipient_ids` (`[%{type, id}]`, max 10) |
  | `task_created`    | `task_id`, `project_id`                           |
  | `approval_acted`  | `task_id`, `action`                               |
  | `meeting_started` | `meeting_id`                                      |

  There is no text, title, body or name key on any kind. Apple's personal
  context predicts future RECIPIENTS, not content, so content is never
  donated.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat.Participant
  alias Platform.Repo

  @event "native_donate"
  @max_recipients 10

  @keys %{
    "message_sent" => [:space_id, :recipient_ids],
    "task_created" => [:task_id, :project_id],
    "approval_acted" => [:task_id, :action],
    "meeting_started" => [:meeting_id]
  }

  @doc "The kinds a donation can carry."
  def kinds, do: Map.keys(@keys)

  @doc "The id keys allowed for `kind`."
  def allowed_keys(kind), do: Map.fetch!(@keys, kind)

  @doc """
  Push a donation for `kind` with `ids`. Keys outside the kind's allow-list
  are dropped, so no caller can add content to a payload.
  """
  @spec push(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push(socket, kind, ids) when is_map_key(@keys, kind) and is_map(ids) do
    Phoenix.LiveView.push_event(socket, @event, payload(kind, ids))
  end

  @doc "The payload `push/3` sends. Public so its shape can be asserted."
  @spec payload(String.t(), map()) :: map()
  def payload(kind, ids) when is_map_key(@keys, kind) and is_map(ids) do
    ids
    |> Map.take(Map.fetch!(@keys, kind))
    |> Map.put(:kind, kind)
  end

  @doc """
  The `message_sent` donation for a message the participant
  `author_participant_id` just posted in `space`: the OTHER participants of a
  DM or group as `%{type, id}` (at most #{@max_recipients}), none for a
  channel or any other kind.
  """
  @spec message_sent(Phoenix.LiveView.Socket.t(), map() | nil, binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def message_sent(socket, %{id: space_id, kind: kind}, author_participant_id)
      when is_binary(space_id) do
    push(socket, "message_sent", %{
      space_id: space_id,
      recipient_ids: recipients(space_id, kind, author_participant_id)
    })
  end

  def message_sent(socket, _space, _author_participant_id), do: socket

  defp recipients(space_id, kind, author_participant_id) when kind in ["dm", "group"] do
    from(p in Participant,
      where:
        p.space_id == ^space_id and p.participant_type in ["user", "agent"] and
          p.id != ^(author_participant_id || Ecto.UUID.generate()),
      order_by: [asc: p.joined_at, asc: p.id],
      limit: @max_recipients,
      select: %{type: p.participant_type, id: p.participant_id}
    )
    |> Repo.all()
  end

  defp recipients(_space_id, _kind, _author_participant_id), do: []
end

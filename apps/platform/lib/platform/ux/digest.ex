defmodule Platform.Ux.Digest do
  @moduledoc """
  The weekly UX digest (task 01a1af00 stage 4): the `fyi` findings the
  friction watch held, plus a one-line count of the decisions it sent to
  inboxes, posted as ONE chat message in the designer agent's configured
  digest space. Never an Inbox row: decisions go to the Inbox
  (`Platform.Ux.Decisions`), FYIs come here.

  ## When

  The same weekly cron fire as the watch: `Handlers.UxFrictionWatch` runs
  `Platform.Ux.FrictionWatch.run/2` and then `post/2` when the trigger is the
  cron (`kind: :cron`). An on-demand fire runs only the watch, so firing it by
  hand twice never posts two digests.

  ## Where

  The space id in the agent's `metadata["ux_digest_space_id"]`
  (`digest_space_key/0`). It must be a space the agent participates in and
  must NOT be an external or mixed space (`Platform.Chat.external_space_ids/0`):
  the FYIs are read from internal chat and are not posted where an external
  user would read them. Unset, or failing either check, nothing is posted
  and the FYIs stay `open` for the next fire.

  ## What it says

  Each FYI as its question and evidence line ("Seen N× this week across M
  channels"). No quotes, no message links and no space names: the digest
  space's members may not be able to read the source channels. Then one
  line with the number of decisions filed in the window. A posted FYI is
  marked `posted` so the next digest does not repeat it. With no FYI and no
  decision there is nothing to say and nothing is posted.

  The message is the agent's own post with `skip_mention_scan: true`, so an
  `@` inside a question never pings anyone.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding

  @digest_space_key "ux_digest_space_id"
  @window_seconds 7 * 86_400
  @max_fyis 20

  @type result ::
          {:ok, %{message_id: String.t(), fyis: [String.t()], decisions: non_neg_integer()}}
          | {:skipped, :nothing_to_post | :no_digest_space | :space_not_allowed | :no_agent}
          | {:error, term()}

  @doc "The agent metadata key naming the digest space."
  @spec digest_space_key() :: String.t()
  def digest_space_key, do: @digest_space_key

  @doc """
  The digest space for `agent`, when it is configured, the agent is in it and
  it is not external or mixed. `{:ok, space_id}` or `{:skipped, reason}`.
  """
  @spec digest_space(map() | nil) :: {:ok, String.t()} | {:skipped, atom()}
  def digest_space(%{id: agent_id} = agent) when is_binary(agent_id) do
    space_id = (Map.get(agent, :metadata) || %{})[@digest_space_key]

    cond do
      not Platform.UUID.valid?(space_id) ->
        {:skipped, :no_digest_space}

      is_nil(Chat.get_agent_participant(space_id, agent_id)) ->
        {:skipped, :space_not_allowed}

      space_id in Chat.external_space_ids() ->
        {:skipped, :space_not_allowed}

      true ->
        {:ok, space_id}
    end
  end

  def digest_space(_agent), do: {:skipped, :no_agent}

  @doc """
  Post the digest for `agent`. Options: `:now` (window end, default now),
  `:org_id` (only findings of that org, plus org-less ones). Never raises.
  """
  @spec post(map() | nil, keyword()) :: result()
  def post(agent, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    window_start = DateTime.add(now, -@window_seconds, :second)
    org_id = Keyword.get(opts, :org_id)

    with {:ok, space_id} <- digest_space(agent),
         fyis = open_fyis(org_id),
         decisions = decision_count(org_id, window_start, now),
         :ok <- something_to_say(fyis, decisions),
         %{} = participant <- Chat.get_agent_participant(space_id, agent.id) do
      content = render(fyis, decisions)

      case Chat.post_message(%{
             space_id: space_id,
             participant_id: participant.id,
             content_type: "text",
             content: content,
             metadata: %{
               "source" => "ux_digest",
               "skip_mention_scan" => true,
               "finding_ids" => Enum.map(fyis, & &1.id),
               "decision_count" => decisions
             }
           }) do
        {:ok, message} ->
          mark_posted(fyis)
          {:ok, %{message_id: message.id, fyis: Enum.map(fyis, & &1.id), decisions: decisions}}

        {:error, reason} ->
          Logger.warning("[ux.digest] post refused: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:skipped, _} = skipped -> skipped
      nil -> {:skipped, :space_not_allowed}
    end
  rescue
    error ->
      Logger.warning("[ux.digest] raised: #{Exception.message(error)}")
      {:error, :crashed}
  end

  @doc "The digest text for `fyis` and a decision count."
  @spec render([Finding.t()], non_neg_integer()) :: String.t()
  def render(fyis, decisions) do
    fyi_block =
      case fyis do
        [] ->
          []

        fyis ->
          [
            "**FYI**"
            | Enum.map(fyis, &"- #{&1.question} (#{Decisions.evidence_line(&1.evidence)})")
          ]
      end

    lines =
      ["**UX weekly digest**", ""] ++
        fyi_block ++
        if(fyi_block == [], do: [], else: [""]) ++
        [decision_line(decisions)]

    Enum.join(lines, "\n")
  end

  defp decision_line(0), do: "No decisions sent to inboxes this week."
  defp decision_line(1), do: "1 decision sent to an inbox this week."
  defp decision_line(n), do: "#{n} decisions sent to inboxes this week."

  defp something_to_say([], 0), do: {:skipped, :nothing_to_post}
  defp something_to_say(_fyis, _decisions), do: :ok

  defp open_fyis(org_id) do
    from(f in Finding,
      where: f.kind == "fyi" and f.status == "open",
      order_by: [asc: f.inserted_at],
      limit: @max_fyis
    )
    |> org_scope(org_id)
    |> Repo.all()
  end

  defp decision_count(org_id, window_start, now) do
    from(f in Finding,
      where: f.kind == "decision" and f.inserted_at >= ^window_start and f.inserted_at <= ^now,
      select: count(f.id)
    )
    |> org_scope(org_id)
    |> Repo.one()
  end

  # `org_id` comes from the fire's trigger meta; a malformed one scopes
  # nothing rather than raising a cast error inside the query.
  defp org_scope(query, org_id) do
    if Platform.UUID.valid?(org_id),
      do: where(query, [f], f.org_id == ^org_id or is_nil(f.org_id)),
      else: query
  end

  defp mark_posted([]), do: :ok

  defp mark_posted(fyis) do
    ids = Enum.map(fyis, & &1.id)
    now = DateTime.utc_now()

    from(f in Finding, where: f.id in ^ids and f.status == "open")
    |> Repo.update_all(set: [status: "posted", updated_at: now])

    :ok
  end
end

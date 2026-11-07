defmodule Platform.Feedback.ShippedNotices do
  @moduledoc """
  The reporting install's half of "Shipped" (task 01a1b678 stage 4).

  On each `Platform.Sharing.UsageBatcher` cycle, `run/0` takes this install's
  OWN published `feedback_submissions` rows that have not had a notice yet,
  asks whether each has shipped, and posts one in-app notice to whoever filed
  it. Only fingerprints this install filed are ever asked about: the rows
  are the ones `Platform.Feedback.Submission` reserved here, and only a row
  whose filer is a person or agent of this install is read (on the broker
  host the shared ledger also holds other installs' rows, whose actor is a
  per-IP id that matches no agent, so they are never picked).

  ## Where shipped comes from

    * an install on the Broker adapter asks
      `GithubPublisher.Broker.shipped?/1` (`GET <base>/issues/<fingerprint>`);
    * the broker host itself reads `Platform.Feedback.Inbox.shipped?/1`;
    * anything else has no answer and posts nothing.

  ## Where the notice goes

    * an agent filer: the space it filed from (`notice_space_id`) when it is
      still a participant there, else Help & feedback when it is in it;
    * a person filer: their direct conversation with Burrow
      (`Platform.Agents.Burrow`), found or opened.

  The notice is a `system` message with `metadata.kind` `"feedback_shipped"`,
  rendered in `--color-info` by `PlatformWeb.ChatMessage`. A row with nowhere
  to post stays pending and is tried again next cycle. Off while the owner's
  feedback switch is off. Never raises.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Feedback.BrokerServer
  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.Feedback.Inbox
  alias Platform.Feedback.SubmissionRecord
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Sharing.HelpChannel

  @kind "feedback_shipped"
  @batch 50

  @doc "The notice message's `metadata.kind`."
  def kind, do: @kind

  @doc """
  Check this install's pending rows once. Returns
  `%{checked: n, notified: n}`, or `:off`.
  """
  @spec run() :: %{checked: non_neg_integer(), notified: non_neg_integer()} | :off
  def run do
    if feedback_on?() do
      rows = pending()

      notified =
        Enum.count(rows, fn row ->
          with {:ok, true} <- shipped?(row.fingerprint),
               true <- claim(row) do
            case notify(row) do
              {:ok, _message} ->
                true

              _ ->
                release(row)
                false
            end
          else
            _ -> false
          end
        end)

      %{checked: length(rows), notified: notified}
    else
      :off
    end
  rescue
    error ->
      Logger.warning("[Feedback.ShippedNotices] run failed: #{inspect(error.__struct__)}")
      %{checked: 0, notified: 0}
  end

  @doc "The notice text for an issue."
  @spec text(String.t() | nil, pos_integer() | nil) :: String.t()
  def text(repository, number) when is_binary(repository) and is_integer(number),
    do: "Shipped: feedback you sent to Burrow is done. Issue #{repository}##{number} is closed."

  def text(_repository, _number), do: "Shipped: feedback you sent to Burrow is done."

  # ── private ────────────────────────────────────────────────────────────

  defp pending do
    from(s in SubmissionRecord,
      left_join: u in User,
      on: u.id == s.actor_user_id,
      left_join: a in Agent,
      on: a.id == s.actor_agent_id,
      where:
        s.status == "published" and is_nil(s.shipped_notified_at) and
          (not is_nil(u.id) or not is_nil(a.id)),
      order_by: [asc: s.published_at],
      limit: @batch
    )
    |> Repo.all()
  end

  defp shipped?(fingerprint) do
    cond do
      GithubPublisher.adapter() == Broker -> Broker.shipped?(fingerprint)
      BrokerServer.enabled?() -> {:ok, Inbox.shipped?(fingerprint)}
      true -> {:ok, false}
    end
  end

  defp notify(%SubmissionRecord{} = row) do
    case notice_space(row) do
      nil -> :skip
      space_id -> post(space_id, row)
    end
  end

  defp notice_space(%SubmissionRecord{actor_agent_id: agent_id} = row) when is_binary(agent_id) do
    Enum.find([row.notice_space_id, help_space_id()], fn space_id ->
      is_binary(space_id) and not is_nil(Chat.get_agent_participant(space_id, agent_id))
    end)
  end

  defp notice_space(%SubmissionRecord{actor_user_id: user_id}) when is_binary(user_id) do
    with %Agent{id: burrow_id} <- Platform.Agents.Burrow.get(),
         {:ok, %{id: space_id}} <- Chat.find_or_create_agent_dm(burrow_id, user_id) do
      space_id
    else
      _ -> nil
    end
  end

  defp notice_space(_row), do: nil

  defp help_space_id do
    case HelpChannel.space() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp post(space_id, row) do
    with {:ok, system} <- ExecutionSpace.ensure_system_participant(space_id) do
      Chat.post_message(%{
        space_id: space_id,
        participant_id: system.id,
        content_type: "system",
        content: text(row.external_repository, row.external_issue_number),
        metadata: %{
          "kind" => @kind,
          "repository" => row.external_repository,
          "issue_number" => row.external_issue_number
        }
      })
    end
  end

  # Claim the row before posting, so two nodes running a cycle at once post
  # one notice. A post that fails releases the claim for the next cycle.
  defp claim(row) do
    {count, _} =
      Repo.update_all(
        from(s in SubmissionRecord, where: s.id == ^row.id and is_nil(s.shipped_notified_at)),
        set: [shipped_notified_at: DateTime.utc_now()]
      )

    count == 1
  end

  defp release(row) do
    Repo.update_all(from(s in SubmissionRecord, where: s.id == ^row.id),
      set: [shipped_notified_at: nil]
    )
  end

  defp feedback_on? do
    Platform.Sharing.enabled?(:feedback)
  rescue
    _ -> false
  end
end

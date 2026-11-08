defmodule Platform.Feedback.Inbox do
  @moduledoc """
  The broker host's feedback inbox (task 01a1b678 stage 4): which requests
  the most installs share, and which have shipped.

  It is a core page on the broker-host install (`PlatformWeb.FeedbackInboxLive`)
  rather than GitHub labels plus a view, because the broker host already holds
  the shared `feedback_submissions` ledger, counting distinct installs needs a
  per-install key that public labels would publish, and it needs no new
  service or credential. ADR 0060 records the decision.

  ## Writes

    * `record/3`, from `Platform.Feedback.BrokerServer.create/2` after a
      created or duplicate answer: one `Inbox.Request` per fingerprint and one
      `Inbox.InstallReport` per (fingerprint, sharing install id). A second
      identical pair is a no-op, so the count is of distinct installs.
    * `mark_shipped/3`, from the GitHub `issues` webhook when an issue in the
      feedback repository closes as completed (or reopens, which clears it).

  ## Reads

    * `shipped?/1` answers `GET /issues/:fingerprint`'s `shipped` key, so a
      reporting install learns about the fingerprints it filed.
    * `list/0` is the inbox, sorted by distinct-install count.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Feedback.Inbox.{InstallReport, Request}
  alias Platform.Feedback.SubmissionRecord
  alias Platform.Repo
  alias Platform.Tasks.RepoRef

  @fingerprint_format ~r/\A[0-9a-f]{64}\z/
  @title_max 200

  @type row :: %{
          fingerprint: String.t(),
          title: String.t() | nil,
          installs: non_neg_integer(),
          shipped: boolean(),
          repository: String.t() | nil,
          issue_number: pos_integer() | nil
        }

  @doc """
  Record that the install with `sharing_install_id` sent `fingerprint`,
  whose issue is `identity`. `title` is the sanitized title. A missing or
  malformed install id records the request but no install. Never raises.
  """
  @spec record(String.t(), term(), %{
          optional(:title) => String.t() | nil,
          repository: String.t(),
          issue_number: pos_integer()
        }) :: :ok
  def record(fingerprint, sharing_install_id, identity) when is_binary(fingerprint) do
    if Regex.match?(@fingerprint_format, fingerprint) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Request,
        [
          %{
            id: Platform.Types.UUIDv7.generate(),
            fingerprint: fingerprint,
            title: title(Map.get(identity, :title)),
            external_repository: identity.repository,
            external_issue_number: identity.issue_number,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:fingerprint]
      )

      case Platform.UUID.cast(sharing_install_id) do
        {:ok, install_id} ->
          Repo.insert_all(
            InstallReport,
            [
              %{
                id: Platform.Types.UUIDv7.generate(),
                fingerprint: fingerprint,
                sharing_install_id: install_id,
                inserted_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:fingerprint, :sharing_install_id]
          )

        :error ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def record(_fingerprint, _install_id, _identity), do: :ok

  @doc """
  Mark every request whose issue is `repository`#`issue_number` shipped
  (`true`) or open again (`false`). Returns the number of requests changed.
  Requests the inbox has not seen yet are created from the ledger, so an
  issue filed before this stage still ships.
  """
  @spec mark_shipped(String.t(), pos_integer(), boolean()) :: non_neg_integer()
  def mark_shipped(repository, issue_number, shipped?)
      when is_binary(repository) and is_integer(issue_number) do
    fingerprints = ledger_fingerprints(repository, issue_number)
    now = DateTime.utc_now()

    Enum.each(fingerprints, fn fingerprint ->
      record(fingerprint, nil, %{repository: repository, issue_number: issue_number})
    end)

    {count, _} =
      Repo.update_all(
        from(r in Request, where: r.fingerprint in ^fingerprints),
        set: [shipped_at: if(shipped?, do: now), updated_at: now]
      )

    count
  end

  @doc """
  The webhook seam: an `issues` delivery (already signature-verified by the
  caller) that closes an issue in the feedback repository as `completed`
  marks its requests shipped; a `reopened` one clears it. Anything else, or a
  node that is not the broker host, is `:ignored`. Returns `{:ok, changed}`.
  """
  @spec handle_issue_event(map()) :: {:ok, non_neg_integer()} | :ignored
  def handle_issue_event(%{"action" => action, "issue" => %{} = issue} = params)
      when action in ["closed", "reopened"] do
    with true <- Platform.Feedback.BrokerServer.enabled?(),
         false <- Map.has_key?(issue, "pull_request"),
         number when is_integer(number) and number > 0 <- issue["number"],
         {:ok, repository} <- RepoRef.normalize(get_in(params, ["repository", "full_name"])),
         true <- RepoRef.same?(repository, Platform.Feedback.GithubPublisher.repository()),
         {:ok, shipped?} <- transition(action, issue["state_reason"]) do
      {:ok, mark_shipped(repository, number, shipped?)}
    else
      _ -> :ignored
    end
  end

  def handle_issue_event(_params), do: :ignored

  defp transition("closed", "completed"), do: {:ok, true}
  defp transition("reopened", _reason), do: {:ok, false}
  defp transition(_action, _reason), do: :ignored

  @doc "Whether the request `fingerprint` has shipped."
  @spec shipped?(term()) :: boolean()
  def shipped?(fingerprint) when is_binary(fingerprint) do
    Repo.exists?(
      from(r in Request, where: r.fingerprint == ^fingerprint and not is_nil(r.shipped_at))
    )
  end

  def shipped?(_fingerprint), do: false

  @doc "The inbox rows, most distinct installs first, then the newest."
  @spec list() :: [row()]
  def list do
    from(r in Request,
      left_join: i in InstallReport,
      on: i.fingerprint == r.fingerprint,
      group_by: r.id,
      order_by: [desc: count(i.id), desc: r.inserted_at],
      select: %{
        fingerprint: r.fingerprint,
        title: r.title,
        installs: count(i.id),
        shipped: not is_nil(r.shipped_at),
        repository: r.external_repository,
        issue_number: r.external_issue_number
      }
    )
    |> Repo.all()
  end

  # The fingerprints the shared ledger published as this issue. Repository
  # identity is compared case-insensitively, like everywhere else.
  defp ledger_fingerprints(repository, issue_number) do
    from(s in SubmissionRecord,
      where: s.external_issue_number == ^issue_number and s.status == "published",
      select: {s.fingerprint, s.external_repository}
    )
    |> Repo.all()
    |> Enum.filter(fn {_fp, repo} -> is_binary(repo) and RepoRef.same?(repo, repository) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp title(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @title_max) do
      "" -> nil
      clean -> clean
    end
  end

  defp title(_value), do: nil
end

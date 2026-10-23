defmodule Platform.Memory.Insights.Outside do
  @moduledoc """
  Insights that propose a message to someone OUTSIDE the org, and the email
  DRAFT each one becomes. Task `01a15ee1-48c8-7000-a8f1-33a5586cb458`,
  stage 3.

  ## Who is outside

  `outside?/1` is true when the insight's `action["addressee"]` is an email
  address AND either `Platform.Memory.Insights.Routing.addressee/1` resolves
  it to no user, or to a user with no non-external membership in the
  insight's org (`Platform.Memory.Insights.Tier.org_id/1`,
  `Platform.Tenancy.internal_member?/2`). It decides on
  MEMBERSHIP directly and never reads the tier: how an internal member named
  by email is tiered has changed over time, and that must not decide whether
  a message leaves the org.

  ## Drafts, never mail

  `draft/3` saves the message as ONE email draft through the same call the
  `mail_draft_create` tool makes, `Platform.Mail.Drafts.create/3` with the
  `{:agent, id}` actor of the `memory.dreaming` holder, addressed to the
  email, subject the first line of the body (at most 120 characters), body
  the insight body. The draft's id is stored on the insight as
  `action["mail_draft_id"]` (`Platform.Memory.Insight.routing_changeset/2`),
  under a row lock, so a re-run never drafts twice.

  Nothing is drafted when the Email module is off
  (`Platform.Mail.Config.enabled?/0`) or the org has no non-archived mail
  account (`Platform.Mail.list_accounts/1`); the insight still renders as an
  outside message, with no draft. When an account exists, the draft is put
  on the org's first one, so it opens ready to review.

  NOTHING HERE SENDS. `Platform.Mail.Dispatch` is the only way a draft
  becomes mail, it refuses an agent actor, and no code path of the insights
  pipeline calls it.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Tier
  alias Platform.Repo

  @subject_max 120
  @address ~r/^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/

  @doc "The email address an insight names as its addressee, or nil."
  @spec email(map()) :: String.t() | nil
  def email(%{action: %{"addressee" => raw}}) when is_binary(raw) do
    value = String.trim(raw)
    if Regex.match?(@address, value), do: value, else: nil
  end

  def email(_insight), do: nil

  @doc "True when the insight proposes a message to someone outside its org."
  @spec outside?(map()) :: boolean()
  def outside?(insight) when is_map(insight) do
    case email(insight) do
      nil ->
        false

      address ->
        case Routing.addressee(address) do
          {user_id, _reason} when is_binary(user_id) ->
            not Platform.Tenancy.internal_member?(%{id: user_id}, Tier.org_id(insight))

          _ ->
            true
        end
    end
  end

  def outside?(_insight), do: false

  @doc "The subject a draft gets: the body's first line, at most 120 characters."
  @spec subject(String.t() | nil) :: String.t()
  def subject(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, @subject_max)
  end

  def subject(_body), do: ""

  @doc """
  Draft the outside message of `insight` as `agent` (the `memory.dreaming`
  holder), once. Returns `{:ok, draft_id}` (the new or the already stored
  draft), `:skip` when the insight is not outside or the Email module is off
  or the org has no account, or `{:error, reason}`. See the moduledoc.
  """
  @spec draft(Insight.t(), %{id: binary()}, keyword()) ::
          {:ok, binary()} | :skip | {:error, term()}
  def draft(%Insight{} = insight, %{id: agent_id}, _opts \\ []) when is_binary(agent_id) do
    org_id = Tier.org_id(insight)

    cond do
      not outside?(insight) -> :skip
      not Platform.Mail.Config.enabled?() -> :skip
      not is_binary(org_id) -> :skip
      true -> draft_locked(insight.id, org_id, agent_id)
    end
  end

  defp draft_locked(insight_id, org_id, agent_id) do
    Repo.transaction(fn ->
      locked =
        Repo.one(from(i in Insight, where: i.id == ^insight_id, lock: "FOR UPDATE"))

      case locked do
        nil ->
          Repo.rollback(:not_found)

        %Insight{action: %{"mail_draft_id" => id}} when is_binary(id) ->
          id

        %Insight{} = insight ->
          case Platform.Mail.list_accounts(org_id) do
            [] -> :skip
            [account | _] -> create(insight, org_id, agent_id, account.id)
          end
      end
    end)
    |> case do
      {:ok, :skip} -> :skip
      {:ok, id} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp create(insight, org_id, agent_id, account_id) do
    attrs = %{
      "account_id" => account_id,
      "to_addresses" => [email(insight)],
      "subject" => subject(insight.body),
      "body" => insight.body
    }

    with {:ok, draft} <- Platform.Mail.Drafts.create({:agent, agent_id}, org_id, attrs),
         {:ok, _} <-
           insight
           |> Insight.routing_changeset(%{
             action: Map.put(insight.action || %{}, "mail_draft_id", draft.id)
           })
           |> Repo.update() do
      draft.id
    else
      {:error, reason} ->
        Logger.warning(
          "[insight_outside] insight #{insight.id} not drafted: " <> inspect(reason, limit: 5)
        )

        Repo.rollback(reason)
    end
  end
end

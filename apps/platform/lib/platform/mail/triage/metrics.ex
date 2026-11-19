defmodule Platform.Mail.Triage.Metrics do
  @moduledoc """
  The acted-on metric of mail triage (task 01a1f426 stage 3): of the emails
  the briefing called out (`top` and `action` items), how many did the
  reader act on.

  An item is ACTED when:

    * the reader sends an accepted delivery from that mailbox to the
      sender's address after the item was created
      (`on_delivery_accepted/1`, called by `Platform.Mail.Dispatch` once a
      send is `accepted`; `acted_how` `"reply"`);
    * the reader marks it Done in the briefing
      (`Platform.Mail.Triage.mark_done/2`; `acted_how` `"manual"`);
    * a triage draft is sent (stage 5; `acted_how` `"draft_sent"`).

  `summary/2` (one org) and `for_user/2` (one reader) count, from `since`:
  `called_out`, `acted`, `acted_rate` (acted / called_out, `0.0` when
  nothing was called out), `dismissed`, `missed_reports` (the reader's
  "This needed me" verdicts), and the draft counts stage 5 fills:
  `drafts_created`, `drafts_sent`, `few_edit_sent` (sent with an
  `edit_ratio` of at most #{0.2}).

  Every outcome is also the telemetry event
  `[:platform, :mail, :triage, :item]` with measurements `%{count: 1}` and
  metadata `%{tier, outcome, org_id}` (`emit/2`): codes and an id, never a
  subject, a why line, an address or a body. Reads select counts only; the
  only mail field read is the sender's address, compared in memory with a
  delivery's recipients and never logged.
  """

  import Ecto.Query

  require Logger

  alias Platform.Mail.{Delivery, InboundMessage}
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Context, Feedback, Item}
  alias Platform.Repo

  @called_out ~w(top action)
  @few_edit_max 0.2

  @type counts :: %{
          called_out: non_neg_integer(),
          acted: non_neg_integer(),
          acted_rate: float(),
          dismissed: non_neg_integer(),
          missed_reports: non_neg_integer(),
          drafts_created: non_neg_integer(),
          drafts_sent: non_neg_integer(),
          few_edit_sent: non_neg_integer()
        }

  @doc "The org's counts for items created at or after `since`."
  @spec summary(binary(), DateTime.t()) :: counts()
  def summary(org_id, %DateTime{} = since) when is_binary(org_id) do
    if Platform.UUID.valid?(org_id) do
      counts(
        from(i in Item, where: i.org_id == ^org_id),
        from(f in Feedback, where: f.org_id == ^org_id),
        since
      )
    else
      empty()
    end
  end

  @doc "One reader's counts for items created at or after `since`."
  @spec for_user(map(), DateTime.t()) :: counts()
  def for_user(%{id: user_id}, %DateTime{} = since) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id) do
      counts(
        from(i in Item, where: i.user_id == ^user_id),
        from(f in Feedback, where: f.user_id == ^user_id),
        since
      )
    else
      empty()
    end
  end

  def for_user(_user, _since), do: empty()

  defp counts(items, feedback, since) do
    row =
      from(i in items,
        where: i.inserted_at >= ^since and i.tier in ^@called_out,
        select: %{
          called_out: count(i.id),
          acted: filter(count(i.id), i.status == "acted"),
          dismissed: filter(count(i.id), i.status == "dismissed"),
          drafts_created: filter(count(i.id), not is_nil(i.draft_id)),
          drafts_sent: filter(count(i.id), i.acted_how == "draft_sent"),
          few_edit_sent:
            filter(count(i.id), i.acted_how == "draft_sent" and i.edit_ratio <= ^@few_edit_max)
        }
      )
      |> Repo.one()

    missed =
      from(f in feedback,
        where: f.verdict == "missed" and f.inserted_at >= ^since,
        select: count(f.id)
      )
      |> Repo.one()

    row
    |> Map.put(:missed_reports, missed)
    |> Map.put(:acted_rate, rate(row.acted, row.called_out))
  end

  defp rate(_acted, 0), do: 0.0
  defp rate(acted, called_out), do: acted / called_out

  defp empty do
    %{
      called_out: 0,
      acted: 0,
      acted_rate: 0.0,
      dismissed: 0,
      missed_reports: 0,
      drafts_created: 0,
      drafts_sent: 0,
      few_edit_sent: 0
    }
  end

  @doc """
  The `Platform.Mail.Dispatch` hook: `delivery` was accepted. Every OPEN
  called-out item of the sending person, in the delivery's mailbox, created
  at or before the acceptance, whose sender's address is one of the
  delivery's recipients, becomes `acted` with `acted_how` `"reply"`.

  Only a person's send counts (`actor_type` `"user"`). Never raises: a
  failure here is logged by id and never touches the send. Returns the
  number of items marked.
  """
  @spec on_delivery_accepted(Delivery.t() | any()) :: non_neg_integer()
  def on_delivery_accepted(
        %Delivery{status: "accepted", actor_type: "user", actor_id: user_id} = delivery
      )
      when is_binary(user_id) do
    at = delivery.accepted_at || DateTime.utc_now()
    recipients = delivery.recipients |> List.wrap() |> Enum.map(&Context.address/1)

    matched =
      from(i in Item,
        join: m in InboundMessage,
        on: m.id == i.inbound_message_id,
        where: i.user_id == ^user_id and i.account_id == ^delivery.account_id,
        where: i.status == "open" and i.tier in ^@called_out,
        where: i.inserted_at <= ^at,
        select: {i, m.from_address}
      )
      |> Repo.all(Triage.quiet_opts())
      |> Enum.filter(fn {_item, from} -> Context.address(from) in recipients end)
      |> Enum.map(fn {item, _from} -> item end)

    Enum.each(matched, fn item ->
      {:ok, updated} =
        item
        |> Item.update_changeset(%{status: "acted", acted_at: at, acted_how: "reply"})
        |> Repo.update(Triage.quiet_opts())

      emit(updated, "acted_reply")
    end)

    if matched != [] do
      Logger.info(
        "[Mail.Triage] acted_by_reply delivery=#{delivery.id} user=#{user_id} items=#{length(matched)}"
      )
    end

    length(matched)
  rescue
    e ->
      Logger.warning(
        "[Mail.Triage] acted hook failed delivery=#{delivery.id} error=#{inspect(e.__struct__)}"
      )

      0
  end

  def on_delivery_accepted(_delivery), do: 0

  @doc """
  The `[:platform, :mail, :triage, :item]` telemetry event for one item's
  outcome (`"notified"`, `"acted_reply"`, `"acted_manual"`, `"dismissed"`,
  `"draft_sent"`): metadata `%{tier, outcome, org_id}` only.
  """
  @spec emit(Item.t(), String.t()) :: :ok
  def emit(%Item{tier: tier, org_id: org_id}, outcome) when is_binary(outcome) do
    :telemetry.execute(
      [:platform, :mail, :triage, :item],
      %{count: 1},
      %{tier: tier, outcome: outcome, org_id: org_id}
    )
  end
end

defmodule Platform.Meetings.CancellationMail do
  @moduledoc """
  Emails a cancelled meeting's guests that it is off (task 01a19e7f stage 2).

  A guest has no account, so no push, inbox row or chat identity reaches
  them. The one guest we can write to is a guest invite that carries an
  email, which booking links produce (`Platform.Calendar.BookingLinks`). This
  module sends those guests one cancellation email each, through the SAME
  audited outbox and the SAME org sender config as the booking confirmation
  (`Platform.Calendar.BookingConfirmation`):

    * the sender is the org's meeting sender from
      `Platform.Mail.OrgSender.resolve/2`. No default is inferred;
    * the draft is created with `Platform.Mail.Drafts.create_system/2` and
      queued with `Platform.Mail.Dispatch.enqueue/2`, with responsibility
      `meetings.cancellation_notice`. SMTP runs later in `Platform.Mail.Outbox`;
    * with no sender configured for the org, or `Platform.Mail.Config.enabled?/0`
      false, nothing is sent and one line is logged for the meeting.

  Called only from `Platform.Meetings.MeetingNotifier`, inside the
  `mark_cancellation_notified/1` claim, so a meeting's guests are mailed at
  most once. A failure for one guest is logged and the rest still get theirs.
  """

  alias Platform.{Mail, Repo}
  alias Platform.Meetings
  alias Platform.Meetings.Meeting

  require Logger

  @responsibility "meetings.cancellation_notice"

  @doc """
  Queue one cancellation email per live guest invite of `meeting` that has an
  email address. Returns the number of drafts queued. Never raises for an
  expected condition.
  """
  @spec deliver(Meeting.t()) :: non_neg_integer()
  def deliver(%Meeting{} = meeting) do
    case guest_emails(meeting) do
      [] ->
        0

      emails ->
        case sender(meeting) do
          {:ok, org_id, sender} ->
            Enum.count(emails, &(enqueue(meeting, org_id, sender, &1) == :ok))

          {:skip, reason} ->
            Logger.info(
              "[CancellationMail] not emailing #{length(emails)} guest(s) of " <>
                "meeting=#{meeting.id}: #{reason}"
            )

            0
        end
    end
  end

  @doc "The responsibility recorded on every cancellation draft and delivery."
  @spec responsibility() :: String.t()
  def responsibility, do: @responsibility

  defp guest_emails(%Meeting{id: id}) do
    id
    |> Meetings.list_invites()
    |> Enum.filter(&(is_nil(&1.user_id) and is_binary(&1.email) and String.trim(&1.email) != ""))
    |> Enum.map(&String.trim(&1.email))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp sender(%Meeting{project_id: project_id}) do
    with %{org_id: org_id} when is_binary(org_id) <-
           project_id && Repo.get(Platform.Tasks.Project, project_id),
         {:ok, sender} <- Mail.OrgSender.resolve(org_id, :meetings) do
      {:ok, org_id, sender}
    else
      {:skip, :mail_disabled} -> {:skip, "mail is disabled"}
      {:skip, :ambiguous_sender} -> {:skip, "more than one account has a meetings sender"}
      _ -> {:skip, "no meeting mail sender is configured for the org"}
    end
  end

  defp enqueue(%Meeting{} = meeting, org_id, sender, email) do
    with {:ok, draft} <-
           Mail.Drafts.create_system(org_id, %{
             account_id: sender.account_id,
             sender_key: sender.sender_key,
             to_addresses: [email],
             subject: "Cancelled: #{meeting.name}",
             body: body(meeting),
             on_behalf_of_user_id: on_behalf_of(meeting, org_id),
             responsibility: @responsibility
           }),
         {:ok, _delivery} <- Mail.Dispatch.enqueue(draft.id, :system) do
      :ok
    else
      error ->
        Logger.warning(
          "[CancellationMail] could not queue a cancellation email for " <>
            "meeting=#{meeting.id}: #{inspect(error_reason(error))}"
        )

        :error
    end
  end

  # The organizer, when they are still an internal member of the org:
  # `Mail.Drafts` refuses an `on_behalf_of_user_id` that is not one, and a
  # notice must not fail for want of attribution.
  defp on_behalf_of(%Meeting{created_by_user_id: user_id}, org_id) when is_binary(user_id) do
    if Platform.Tenancy.internal_member?(%{id: user_id}, org_id), do: user_id
  end

  defp on_behalf_of(%Meeting{}, _org_id), do: nil

  # The draft and delivery can carry the body; log only the reason.
  defp error_reason({:error, {:refused, refusal, _delivery}}), do: {:refused, refusal}
  defp error_reason({:error, %Ecto.Changeset{errors: errors}}), do: {:invalid, errors}
  defp error_reason({:error, reason}), do: reason
  defp error_reason(other), do: other

  defp body(%Meeting{scheduled_start_at: %DateTime{} = starts_at} = meeting) do
    "#{meeting.name} has been cancelled. It was scheduled for " <>
      Calendar.strftime(starts_at, "%a %b %-d, %Y at %H:%M UTC") <> "."
  end

  defp body(%Meeting{} = meeting), do: "#{meeting.name} has been cancelled."
end

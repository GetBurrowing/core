defmodule Platform.Calendar.BookingConfirmation do
  @moduledoc """
  Queues meeting guest confirmations through the existing audited mail outbox.

  `:calendar_booking_mail_senders` maps project org ids to an explicit
  `%{account_id: uuid, sender_key: key}`. No default account is inferred.
  Missing configuration, disabled mail and policy refusals remain visible
  on the booking receipt. SMTP runs after commit through Mail.Outbox.
  """
  alias Platform.{Mail, Repo}

  def enqueue(meeting, owner_id, guest, slot, guest_url) do
    project = Repo.get(Platform.Tasks.Project, meeting.project_id)

    config =
      case Application.get_env(:platform, :calendar_booking_mail_senders, %{}) do
        value when is_map(value) -> value
        _ -> %{}
      end

    with %{org_id: org_id} when is_binary(org_id) <- project,
         %{account_id: account, sender_key: sender} <- Map.get(config, org_id),
         true <- Mail.Config.enabled?(),
         {:ok, draft} <-
           Mail.Drafts.create_system(org_id, %{
             account_id: account,
             sender_key: sender,
             to_addresses: [guest["email"]],
             subject: "Booking confirmed: #{meeting.name}",
             body:
               "Your booking is confirmed for #{DateTime.to_iso8601(slot.starts_at)}.\n\nJoin your meeting: #{guest_url}",
             on_behalf_of_user_id: owner_id,
             responsibility: "calendar.booking_confirmation"
           }),
         {:ok, delivery} <- Mail.Dispatch.enqueue(draft.id, :system) do
      {delivery.id, nil}
    else
      {:error, {:refused, _, delivery}} ->
        {delivery.id, "Confirmation email refused by the configured sender policy"}

      _ ->
        {nil, "Confirmation email unavailable; owner must share the guest invite"}
    end
  end
end

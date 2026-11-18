defmodule Platform.Calendar.BookingConfirmation do
  @moduledoc """
  Queues meeting guest confirmations through the existing audited mail outbox.

  The sender is the org's meeting sender, resolved by
  `Platform.Mail.OrgSender.resolve/2`: an explicit app-env entry, else the
  one send-enabled account carrying the `"meetings"` sender key. No default
  account is inferred. Missing configuration, disabled mail and policy
  refusals remain visible on the booking receipt. SMTP runs after commit
  through Mail.Outbox.
  """
  alias Platform.{Mail, Repo}

  @doc """
  Queue the guest's `Booking confirmed:` email. `host_names` is the link's
  host set, owner first; a shared link (two or more) adds
  `With A and B.` to the body (task 01a1eff0-6880 stage 2). Only the guest
  is addressed: no co-host is mailed.
  """
  def enqueue(meeting, owner_id, guest, slot, guest_url, host_names \\ []) do
    project = Repo.get(Platform.Tasks.Project, meeting.project_id)

    with %{org_id: org_id} when is_binary(org_id) <- project,
         {:ok, %{account_id: account, sender_key: sender}} <-
           Mail.OrgSender.resolve(org_id, :meetings),
         {:ok, draft} <-
           Mail.Drafts.create_system(org_id, %{
             account_id: account,
             sender_key: sender,
             to_addresses: [guest["email"]],
             subject: "Booking confirmed: #{meeting.name}",
             body:
               "Your booking is confirmed for #{DateTime.to_iso8601(slot.starts_at)}." <>
                 with_hosts(host_names) <> "\n\nJoin your meeting: #{guest_url}",
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

  @doc ~S"""
  The shared-link line: `" With A and B."` for two hosts, `" With A, B and
  C."` for three or more, `""` for a single host.

      iex> Platform.Calendar.BookingConfirmation.with_hosts(["Ryan Milvenan", "Jordan Coombs"])
      " With Ryan Milvenan and Jordan Coombs."
      iex> Platform.Calendar.BookingConfirmation.with_hosts(["A", "B", "C"])
      " With A, B and C."
      iex> Platform.Calendar.BookingConfirmation.with_hosts(["Ryan Milvenan"])
      ""
  """
  def with_hosts(names) when is_list(names) and length(names) > 1 do
    {init, [last]} = Enum.split(names, -1)
    " With " <> Enum.join(init, ", ") <> " and " <> last <> "."
  end

  def with_hosts(_), do: ""
end

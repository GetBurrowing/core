defmodule Platform.Meetings.InviteMailer do
  @moduledoc """
  Sends the meeting emails (task 01a1a933 stage 3): the invitation when
  someone is invited, the cancellation when the meeting is called off, and
  the update when its time changes. Each is a `Platform.Meetings.InviteMail`
  message with a calendar part, queued through the audited outbox
  (`Platform.Mail.Drafts.create_system/2` + `Platform.Mail.Dispatch.enqueue/3`)
  and handed to SMTP by `Platform.Mail.Outbox` after commit.

  ## Sender

  The org's meeting sender, `Platform.Mail.OrgSender.resolve(org_id,
  :meetings)`: never a platform address, never an org's first account.
  With none configured (or mail disabled) nothing is sent and, for an
  invitation, the reason is recorded on the invite.

  ## Who gets one

    * a member or external user: their account email, unless they turned
      meeting emails off (`Platform.Accounts.email_notifications?/1`);
    * a guest: `invite.email` whenever it is present. Guests always receive
      it; a name-only guest has no address and gets nothing, which is not
      an error;
    * never the inviter themselves.

  Reply-To is the inviter's address when known, and the draft is sent on
  the inviter's behalf when they are an internal member of the org. The
  inviter is the `inviter_user_id` the caller passes, else the meeting's
  `created_by_user_id`.

  Cancellations and updates go to the same audience: every live invite that
  got an invitation email (`mail_delivery_id` set) plus every guest with an
  address, the people who may hold the event on a calendar.

  ## The receipt (invitations only)

  Mirrors `Platform.Calendar.BookingConfirmation`: a queued invitation sets
  `meeting_invites.mail_delivery_id`; a refusal sets `mail_delivery_id` and
  `mail_error`; a skip (no sender, mail disabled) sets `mail_error`. A later
  SMTP failure is read off the delivery row
  (`Platform.Meetings.invite_mail_failed?/1`). Opting out, a name-only
  guest and the inviter themselves record nothing: no email was owed.

  Nothing here raises into an invite: `Platform.Meetings.InviteDelivery`
  calls `send_invitation/3` inside a rescue, after its `delivered_at` claim.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Mail
  alias Platform.Mail.OrgSender
  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteMail
  alias Platform.Meetings.Meeting
  alias Platform.Repo

  require Logger

  @responsibilities %{
    invitation: "meetings.invite_email",
    cancelled: "meetings.cancellation_notice",
    updated: "meetings.update_notice"
  }

  @type result ::
          {:ok, Mail.Delivery.t()}
          | {:skip, atom()}
          | {:error, term()}
          | :not_owed

  @doc "The responsibility recorded on each kind's drafts and deliveries."
  @spec responsibility(InviteMail.kind()) :: String.t()
  def responsibility(kind), do: Map.fetch!(@responsibilities, kind)

  @doc """
  Email `invite`'s invitee that they are invited to `meeting`, and record
  the outcome on the invite.

  Options: `notify_email: false` sends nothing and records nothing (the
  booking path, which sends its own confirmation); `inviter_user_id`;
  `inviter_time_zone` (the zone the inviter's page was rendered in).
  """
  @spec send_invitation(Invite.t(), Meeting.t(), keyword()) :: result()
  def send_invitation(%Invite{} = invite, %Meeting{} = meeting, opts \\ []) do
    if Keyword.get(opts, :notify_email, true) == false do
      :not_owed
    else
      inviter = inviter(meeting, Keyword.get(opts, :inviter_user_id))

      case recipient(invite, inviter) do
        nil ->
          :not_owed

        recipient ->
          result =
            with {:ok, setup} <- setup(meeting, inviter, opts) do
              send_one(:invitation, meeting, recipient, setup)
            end

          record(invite, result)
          nudge([result])
          result
      end
    end
  end

  @doc """
  Email everyone who may hold `meeting` on a calendar that it is cancelled
  (`METHOD:CANCEL`, same UID). Returns how many were queued.
  """
  @spec send_cancellations(Meeting.t()) :: non_neg_integer()
  def send_cancellations(%Meeting{} = meeting), do: send_to_audience(:cancelled, meeting)

  @doc """
  Email everyone who may hold `meeting` on a calendar its new time or name
  (`METHOD:REQUEST`, same UID, the bumped SEQUENCE). Returns how many were
  queued.

  Options (task 01a1b281 stage 2):

    * `only: invite_ids` narrows the audience to those invites. The edit
      path snapshots the audience BEFORE it adds invitees and passes the
      snapshot here, so an invitee added by the same edit gets their
      invitation and never an update as well. Recipients are still resolved
      now, so someone who opted out in between is not mailed.
    * `changed: fields` names what moved (`:time`, `:name`) for the
      email's "changed" line. Without it the line reads "Time changed".
  """
  @spec send_updates(Meeting.t(), keyword()) :: non_neg_integer()
  def send_updates(%Meeting{} = meeting, opts \\ []) do
    send_to_audience(:updated, meeting, opts)
  end

  @doc """
  Email ONE removed invitee that `meeting` is off for them (`METHOD:CANCEL`,
  same UID, SEQUENCE + 1), while the meeting itself goes ahead (task
  01a1b281 stage 2). Sent only when `invite` is in the calendar audience
  (`calendar_holder?/1`): someone who never got an invitation email holds
  no calendar copy to remove. Never to the inviter.
  """
  @spec send_cancellation(Invite.t(), Meeting.t()) :: result()
  def send_cancellation(%Invite{} = invite, %Meeting{} = meeting) do
    inviter = inviter(meeting, nil)

    with true <- calendar_holder?(invite) || :not_owed,
         %{} = recipient <- recipient(invite, inviter) || :not_owed,
         {:ok, setup} <- setup(meeting, inviter, []) do
      result = send_one(:cancelled, meeting, recipient, setup)
      log_failure(:cancelled, meeting, result)
      nudge([result])
      result
    end
  end

  # ── Audience ─────────────────────────────────────────────────────────────

  @doc """
  The ONE rule for who gets a cancellation or an update email about
  `meeting`, as `[{invite, recipient}]` (task 01a1b281 stage 2 exposed it so
  `Platform.Meetings.preview_meeting_edit/2` reads the same answer the mail
  is sent to): every live invite that is a `calendar_holder?/1`, resolved
  through `recipient/2` (account email unless opted out; guest address;
  never the inviter), one per address.

  `only: invite_ids` narrows to those invites.
  """
  @spec audience(Meeting.t(), keyword()) :: [{Invite.t(), InviteMail.recipient()}]
  def audience(%Meeting{} = meeting, opts \\ []) do
    inviter = inviter(meeting, nil)

    meeting.id
    |> Meetings.list_invites()
    |> narrow_to(Keyword.get(opts, :only))
    |> Enum.filter(&calendar_holder?/1)
    |> Enum.map(&{&1, recipient(&1, inviter)})
    |> Enum.reject(fn {_invite, recipient} -> is_nil(recipient) end)
    |> Enum.uniq_by(fn {_invite, recipient} -> String.downcase(recipient.email) end)
  end

  @doc """
  May `invite`'s invitee hold the meeting on a calendar? True when an
  invitation email was queued for it (`mail_delivery_id`) or it is a guest
  with an address.
  """
  @spec calendar_holder?(Invite.t()) :: boolean()
  def calendar_holder?(%Invite{} = invite),
    do: not is_nil(invite.mail_delivery_id) or guest_with_address?(invite)

  @doc """
  Who an email about `meeting` for `invite` would go to, or nil: the same
  `recipient/2` every send uses, with the meeting's creator as the inviter.
  `invite` need not be persisted, so a preview can ask about an invitee it
  has not added yet.
  """
  @spec recipient_for(Invite.t(), Meeting.t()) :: InviteMail.recipient() | nil
  def recipient_for(%Invite{} = invite, %Meeting{} = meeting),
    do: recipient(invite, inviter(meeting, nil))

  defp narrow_to(invites, nil), do: invites

  defp narrow_to(invites, ids) when is_list(ids) do
    keep = MapSet.new(ids)
    Enum.filter(invites, &MapSet.member?(keep, &1.id))
  end

  defp send_to_audience(kind, %Meeting{} = meeting, opts \\ []) do
    inviter = inviter(meeting, nil)
    recipients = meeting |> audience(opts) |> Enum.map(&elem(&1, 1))

    case recipients do
      [] ->
        0

      _ ->
        case setup(meeting, inviter, []) do
          {:ok, setup} ->
            setup = put_changed_line(setup, Keyword.get(opts, :changed))
            results = Enum.map(recipients, &send_one(kind, meeting, &1, setup))
            Enum.each(results, &log_failure(kind, meeting, &1))
            nudge(results)
            Enum.count(results, &match?({:ok, _}, &1))

          skip ->
            Logger.info(
              "[InviteMailer] not emailing #{length(recipients)} recipient(s) of " <>
                "meeting=#{meeting.id} (#{kind}): #{inspect(skip)}"
            )

            0
        end
    end
  end

  defp put_changed_line(setup, changed) when is_list(changed) do
    line =
      case {:time in changed, :name in changed} do
        {true, true} -> "Time and title changed"
        {false, true} -> "Title changed"
        _ -> nil
      end

    if line, do: put_in(setup, [:ctx, :changed_line], line), else: setup
  end

  defp put_changed_line(setup, _changed), do: setup

  defp guest_with_address?(%Invite{user_id: nil, email: email}), do: present?(email)
  defp guest_with_address?(%Invite{}), do: false

  # ── Recipient ────────────────────────────────────────────────────────────

  defp recipient(%Invite{user_id: user_id}, inviter) when is_binary(user_id) do
    with %User{email: email} = user when is_binary(email) and email != "" <-
           Accounts.get_user(user_id),
         false <- same_person?(user, inviter),
         true <- Accounts.email_notifications?(user) do
      %{name: user.name, email: email, preferences: user.preferences || %{}}
    else
      _ -> nil
    end
  end

  defp recipient(%Invite{email: email} = invite, inviter) do
    address = email && String.trim(email)

    cond do
      not present?(address) -> nil
      inviter && same_address?(inviter.email, address) -> nil
      true -> %{name: invite.display_name, email: address, short_code: invite.short_code}
    end
  end

  defp same_person?(%User{id: id}, %User{id: id}), do: true
  defp same_person?(_user, _inviter), do: false

  defp same_address?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.trim(a)) == String.downcase(b)

  defp same_address?(_a, _b), do: false

  defp inviter(%Meeting{} = meeting, inviter_user_id) do
    case inviter_user_id || meeting.created_by_user_id do
      id when is_binary(id) -> Accounts.get_user(id)
      _ -> nil
    end
  end

  # ── Sending ──────────────────────────────────────────────────────────────

  # Everything that does not depend on the recipient: org, sender, the
  # sending identity, the inviter's part, hosts and branding.
  defp setup(%Meeting{} = meeting, inviter, opts) do
    with org_id when is_binary(org_id) <- Meetings.meeting_org_id(meeting) || {:skip, :no_org},
         {:ok, %{account_id: account_id, sender_key: sender_key}} <-
           OrgSender.resolve(org_id, :meetings),
         {:ok, {_account, sender}} <- Mail.resolve_sender(org_id, account_id, sender_key) do
      org_name = org_name(org_id)
      app_url = app_url()

      {:ok,
       %{
         org_id: org_id,
         account_id: account_id,
         sender_key: sender_key,
         inviter: inviter,
         reply_to: reply_to(inviter),
         on_behalf_of: on_behalf_of(inviter, org_id),
         ctx: %{
           organizer: {present_or(sender.display_name, org_name), sender.address},
           inviter: inviter_ctx(inviter, opts),
           org_name: org_name,
           app_url: app_url,
           guest_url: guest_url(),
           brand: brand(app_url),
           calendar_url: app_url <> Meetings.calendar_link_path(meeting),
           attendees: attendee_names(meeting)
         }
       }}
    end
  end

  defp send_one(kind, %Meeting{} = meeting, recipient, setup) do
    built = InviteMail.build(kind, meeting, recipient, setup.ctx)

    with {:ok, draft} <-
           Mail.Drafts.create_system(setup.org_id, %{
             account_id: setup.account_id,
             sender_key: setup.sender_key,
             to_addresses: [recipient.email],
             subject: built.subject,
             body: built.body,
             html_body: built.html_body,
             reply_to: setup.reply_to,
             calendar_method: built.calendar_method,
             calendar_ics: built.calendar_ics,
             on_behalf_of_user_id: setup.on_behalf_of,
             responsibility: responsibility(kind)
           }) do
      Mail.Dispatch.enqueue(draft.id, :system)
    end
  end

  # ── Receipt ──────────────────────────────────────────────────────────────

  defp record(%Invite{} = invite, result) do
    {delivery_id, error} =
      case result do
        {:ok, %{id: id}} ->
          {id, nil}

        {:error, {:refused, _refusal, %{id: id}}} ->
          {id, "Invite email refused by the sender policy"}

        {:skip, :mail_disabled} ->
          {nil, "Invite email not sent: email is turned off"}

        {:skip, :no_sender} ->
          {nil, "Invite email not sent: no meetings sender is configured"}

        {:skip, :ambiguous_sender} ->
          {nil, "Invite email not sent: more than one meetings sender"}

        {:skip, _} ->
          {nil, "Invite email not sent"}

        {:error, _} ->
          {nil, "Invite email could not be queued"}
      end

    from(i in Invite, where: i.id == ^invite.id)
    |> Repo.update_all(set: [mail_delivery_id: delivery_id, mail_error: error])

    :ok
  end

  # The Outbox claims queued rows after commit. Inside a caller's
  # transaction the row is not visible yet, so the nudge would find
  # nothing; the Outbox's own tick picks it up instead.
  defp nudge(results) do
    if Enum.any?(results, &match?({:ok, _}, &1)) and not Repo.in_transaction?() do
      Mail.Outbox.nudge()
    end

    :ok
  end

  defp log_failure(_kind, _meeting, {:ok, _}), do: :ok

  defp log_failure(kind, %Meeting{} = meeting, result) do
    Logger.warning(
      "[InviteMailer] #{kind} email not queued for meeting=#{meeting.id}: " <>
        inspect(reason(result))
    )
  end

  # The draft and delivery carry the body; log only the reason.
  defp reason({:error, {:refused, refusal, _delivery}}), do: {:refused, refusal}
  defp reason({:error, %Ecto.Changeset{errors: errors}}), do: {:invalid, errors}
  defp reason(other), do: other

  # ── Context ──────────────────────────────────────────────────────────────

  defp inviter_ctx(nil, _opts), do: nil

  defp inviter_ctx(%User{} = inviter, opts) do
    zone =
      Keyword.get(opts, :inviter_time_zone) ||
        Map.get(inviter.preferences || %{}, "time_zone")

    %{name: inviter.name, time_zone: zone}
  end

  defp reply_to(%User{email: email}) when is_binary(email) do
    if Mail.Drafts.valid_address?(email), do: email
  end

  defp reply_to(_inviter), do: nil

  # `Mail.Drafts` refuses an `on_behalf_of_user_id` that is not an internal
  # member, and an email must not fail for want of attribution.
  defp on_behalf_of(%User{id: id}, org_id) do
    if Platform.Tenancy.internal_member?(%{id: id}, org_id), do: id
  end

  defp on_behalf_of(_inviter, _org_id), do: nil

  defp org_name(org_id) do
    case Platform.Tenancy.get_org(org_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp app_url, do: PlatformWeb.Endpoint.url()

  # Who else is invited, by the name the invite UI shows: an account's name,
  # else the guest's display name. The meeting has no stored reason or
  # agenda, so no `reason` is passed.
  defp attendee_names(%Meeting{id: id}) do
    id
    |> Meetings.list_invites(preload: [:user])
    |> Enum.map(fn
      %Invite{user: %User{name: name}} when is_binary(name) -> name
      %Invite{display_name: name} -> name
    end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp guest_url do
    if GuestInvite.guest_host_configured?(), do: "https://" <> GuestInvite.guest_host()
  end

  # The install's name, icon and palettes. A missing branding row paints the
  # shipped palette rather than failing the email.
  defp brand(app_url) do
    InviteMail.brand(Platform.Branding.get(), app_url)
  rescue
    _ -> nil
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present_or(value, fallback), do: if(present?(value), do: value, else: fallback)
end

defmodule Platform.Meetings.InviteDeliveryTest do
  @moduledoc """
  Tests for `Platform.Meetings.InviteDelivery` — the module that decides
  which surface an invitee can actually be reached on, and records which
  one ran (task `019fb955-6577-7fb0-8c97-c70d233bba23`).

  ## Why both collaborators go through recorders

  `Platform.Notifications.fan_out_to_user/2` short-circuits ENTIRELY when
  `Application.get_env(:platform, :env) == :test` — it returns `:ok`
  without spawning the delivery Task, so the Ecto sandbox is not raced.
  That means a test which tried to observe a *real* push would observe
  nothing, and would go on passing against an implementation that deleted
  the push call. The stub is not a convenience here; it is the only thing
  that makes the push assertion mean anything.

  `Platform.Inbox` is recorded for the symmetric reason plus one more: the
  emit and the push are two independent surfaces covering each other, and
  the regression this suite exists to catch is one of them silently going
  away. Every internal-carrier test therefore asserts BOTH halves in the
  SAME test — asserting one is exactly how this regresses.

  ## The flag is off by default in this suite

  `config/test.exs` sets `:meetings_enabled` to `false`, so
  `Config.enabled?/0` is false for the whole suite unless a test says
  otherwise. Delivery tests opt in per-`describe`; the flag-off test does
  not, which is why it reads the ambient state rather than setting one.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  defmodule InboxRecorder do
    @moduledoc """
    Test double for `Platform.Inbox`. Records each `emit/1` as
    `{:inbox_emit, attrs}` so tests can assert the args AND count them.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def emit(attrs) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:inbox_emit, attrs})
      end

      {:ok, attrs}
    end
  end

  defmodule RaisingInbox do
    @moduledoc """
    An `emit/1` that blows up, to prove the push still runs. The two
    surfaces exist to cover each other; one failing must not suppress the
    other.
    """
    def emit(_attrs), do: raise("inbox is down")
  end

  defmodule NotifStub do
    @moduledoc """
    Stand-in for `Platform.Notifications`. Records both entry points so a
    test can tell them apart:

      * `{:push_user, user_id, payload, opts}` — `fan_out_to_user/2`, the
        only path that can reach an invitee who is not in the meeting's
        chat space.
      * `{:push_humans, ids, payload, opts}` — `fan_out_to_humans/3`,
        which takes chat-participant ROW ids. Recorded so a test can prove
        delivery does NOT use it.
    """
    def install(pid \\ self()) do
      :persistent_term.put({__MODULE__, :owner}, pid)
    end

    def fan_out_to_user(user_id, payload, opts \\ []) do
      notify({:push_user, user_id, payload, opts})
    end

    def fan_out_to_humans(ids, payload, opts \\ []) do
      notify({:push_humans, ids, payload, opts})
    end

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, msg)
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :inbox_module, InboxRecorder)
    Application.put_env(:platform, :notifications_module, NotifStub)
    InboxRecorder.install(self())
    NotifStub.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :inbox_module)
      Application.delete_env(:platform, :notifications_module)
    end)

    :ok
  end

  # Opt the flag ON. `config/test.exs` pins it false for the suite, and
  # `Config.enabled?/0` short-circuits the OS env read when the key is set,
  # so this is hermetic regardless of the host's `MEETINGS_ENABLED`.
  defp enable_meetings! do
    prior = Application.fetch_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:platform, :meetings_enabled, value)
        :error -> Application.delete_env(:platform, :meetings_enabled)
      end
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp create_user(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(%{name: name, email: "delivery-#{n}@example.com", oidc_sub: "sub-#{n}"})
      |> Repo.insert()

    user
  end

  defp create_meeting(name) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project"})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  # A meeting whose host participant carries a display name, so the inbox
  # body's "From <host>" has something real to read.
  defp meeting_hosted_by(name, host_name) do
    meeting = create_meeting(name)
    host = create_user(host_name)

    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: host.id,
        joined_at: DateTime.utc_now(),
        display_name: host_name
      })

    meeting =
      meeting
      |> Ecto.Changeset.change(host_participant_id: participant.id)
      |> Repo.update!()

    {meeting, host}
  end

  defp invite_row(meeting, user) do
    {:ok, invite} =
      %Invite{}
      |> Invite.changeset(%{meeting_id: meeting.id, user_id: user.id})
      |> Repo.insert()

    invite
  end

  defp guest_row(meeting, display_name) do
    {:ok, invite} =
      %Invite{}
      |> Invite.changeset(%{meeting_id: meeting.id, display_name: display_name})
      |> Repo.insert()

    invite
  end

  # Drain and COUNT, rather than assert-one-and-hope. A duplicate send is
  # the exact regression the `delivered_at` CAS exists to prevent, and it is
  # invisible to an `assert_receive` that stops at the first match.
  defp count_messages(tag, acc \\ 0) do
    receive do
      msg when elem(msg, 0) == tag -> count_messages(tag, acc + 1)
    after
      200 -> acc
    end
  end

  defp reload(%Invite{id: id}), do: Repo.get!(Invite, id)

  # ── The flag ───────────────────────────────────────────────────────────────

  describe "with meetings disabled" do
    test "deliver/2 answers {:ok, :disabled} and touches absolutely nothing" do
      # No `enable_meetings!/0` — `config/test.exs` already pins the flag
      # false, so this reads the fail-closed default rather than staging a
      # special state.
      refute Platform.Meetings.Config.enabled?()

      {meeting, _host} = meeting_hosted_by("Dark", "Host")
      invite = invite_row(meeting, create_user("Invitee"))

      assert InviteDelivery.deliver(invite, meeting) == {:ok, :disabled}

      # Both halves of the flag-off requirement: no side effects, and
      # nothing raised (the assertion above would not have been reached).
      assert count_messages(:inbox_emit) == 0
      assert count_messages(:push_user) == 0

      # And no row write either — the claim is NOT taken when the flag is
      # off, so flipping the flag on later still delivers.
      persisted = reload(invite)
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)
    end
  end

  # ── The internal carrier ───────────────────────────────────────────────────

  describe "an internal invitee" do
    setup do
      enable_meetings!()
      :ok
    end

    test "gets BOTH a meeting_invited inbox row AND a user-keyed push" do
      {meeting, _host} = meeting_hosted_by("Kickoff", "Ada")
      user = create_user("Invitee")
      invite = invite_row(meeting, user)

      assert InviteDelivery.deliver(invite, meeting) == {:ok, :internal_inbox_push}

      user_id = user.id

      # Half one: the durable inbox row.
      assert_receive {:inbox_emit, attrs}, 1_000
      assert attrs.user_id == user_id
      assert attrs.kind == "meeting_invited"
      assert attrs.source_type == "meeting"
      assert attrs.source_id == meeting.id
      assert attrs.title == "Meeting invite: Kickoff"
      assert attrs.body == "From Ada"

      # Half two: the push. `Inbox.emit/1` inserts and broadcasts; it does
      # NOT push (the documented gap from task `019f9251`), so asserting
      # only the emit above would pass against an implementation that
      # notifies nobody's device.
      assert_receive {:push_user, ^user_id, payload, _opts}, 1_000
      assert payload.title == "Meeting invite: Kickoff"
      assert payload.body == "From Ada"

      # Both carry the SAME url, and it is slug-keyed: the router declares
      # `live("/meetings/:slug", MeetingLive, :show)`. An id here renders a
      # 404 for a notification that otherwise looks fine.
      assert attrs.url == "/meetings/#{meeting.slug}"
      assert payload.url == "/meetings/#{meeting.slug}"
      refute attrs.url =~ meeting.id

      # `fan_out_to_humans/3` takes chat-participant ROW ids and cannot
      # address an invitee outside the meeting's chat space.
      assert count_messages(:push_humans) == 0
    end

    test "falls back to 'Someone' when the meeting has no named host" do
      meeting = create_meeting("Anonymous")
      invite = invite_row(meeting, create_user("Invitee"))

      assert InviteDelivery.deliver(invite, meeting) == {:ok, :internal_inbox_push}

      assert_receive {:inbox_emit, %{body: "From Someone"}}, 1_000
    end

    test "stamps delivered_at and the carrier that actually ran" do
      {meeting, _host} = meeting_hosted_by("Receipt", "Ada")
      invite = invite_row(meeting, create_user("Invitee"))

      assert is_nil(invite.delivered_at)
      assert {:ok, :internal_inbox_push} = InviteDelivery.deliver(invite, meeting)

      persisted = reload(invite)
      assert %DateTime{} = persisted.delivered_at
      assert persisted.delivery_carrier == "internal_inbox_push"
    end

    test "delivering the SAME invite twice sends exactly once" do
      # THE DUPLICATE-PUSH GUARD. `Meetings.invite_user/3` is idempotent on
      # the `{meeting_id, user_id}` unique index and returns the EXISTING
      # row on a re-invite, so a host who double-submits hands delivery the
      # same struct twice.
      {meeting, _host} = meeting_hosted_by("Double", "Ada")
      invite = invite_row(meeting, create_user("Invitee"))

      assert {:ok, :internal_inbox_push} = InviteDelivery.deliver(invite, meeting)
      assert {:ok, :already_delivered} = InviteDelivery.deliver(invite, meeting)

      # The COUNT is the assertion. The return value above is satisfied by
      # an implementation that returns the right atom and sends anyway.
      assert count_messages(:inbox_emit) == 1
      assert count_messages(:push_user) == 1
    end

    test "a re-delivery of a STALE struct is still refused by the database" do
      # The struct-level `delivered_at: nil` head is an optimisation; the
      # guarantee is the nil-guarded WHERE clause. Handing delivery the
      # pre-delivery struct a second time exercises the SQL, not the head.
      {meeting, _host} = meeting_hosted_by("Stale", "Ada")
      invite = invite_row(meeting, create_user("Invitee"))

      assert {:ok, :internal_inbox_push} = InviteDelivery.deliver(invite, meeting)
      assert %Invite{delivered_at: nil} = invite

      assert {:ok, :already_delivered} = InviteDelivery.deliver(invite, meeting)
      assert count_messages(:inbox_emit) == 1
      assert count_messages(:push_user) == 1
    end

    test "a failing inbox emit does not suppress the push" do
      Application.put_env(:platform, :inbox_module, RaisingInbox)

      {meeting, _host} = meeting_hosted_by("Half Down", "Ada")
      user = create_user("Invitee")
      invite = invite_row(meeting, user)

      assert {:ok, :internal_inbox_push} = InviteDelivery.deliver(invite, meeting)

      user_id = user.id
      assert_receive {:push_user, ^user_id, _payload, _opts}, 1_000
    end
  end

  # ── Guests ─────────────────────────────────────────────────────────────────

  describe "a guest invitee" do
    setup do
      enable_meetings!()
      :ok
    end

    test "answers :guest_link with no inbox row and no push" do
      {meeting, _host} = meeting_hosted_by("Guest Meeting", "Ada")
      invite = guest_row(meeting, "Grace")

      assert Invite.kind(invite) == :guest
      assert InviteDelivery.deliver(invite, meeting) == {:ok, :guest_link}

      # A guest has no account, so an inbox row and a push are both
      # addressed at a user id that does not exist. Their channel is the
      # per-invite URL `invite_guest/2` already returned.
      assert count_messages(:inbox_emit) == 0
      assert count_messages(:push_user) == 0

      persisted = reload(invite)
      assert %DateTime{} = persisted.delivered_at
      assert persisted.delivery_carrier == "guest_link"
    end
  end

  # ── External users ─────────────────────────────────────────────────────────

  describe "an external invitee" do
    setup do
      enable_meetings!()
      :ok
    end

    test "refuses rather than falling through to the internal carrier" do
      # An inbox row an external user cannot open, plus a push that
      # deep-links them into a 403, is a notification that looks BROKEN
      # rather than absent. Stage 4 owns this branch; until then it must
      # refuse, and the refusal has to be tested or the fall-through is
      # free to reappear.
      {meeting, _host} = meeting_hosted_by("Cross Org", "Ada")
      user = create_user("External")

      {:ok, _membership} =
        Tenancy.mark_membership_external(%{
          user_id: user.id,
          org_id: tenant_org_id("soylent")
        })

      assert Platform.Tenancy.external_user?(%{id: user.id})

      invite = invite_row(meeting, user)

      assert InviteDelivery.deliver(invite, meeting) == {:error, :not_implemented}

      assert count_messages(:inbox_emit) == 0
      assert count_messages(:push_user) == 0

      # The claim is released: nothing carried this invite, so it must not
      # read as delivered, and stage 4 has to be able to deliver it later.
      persisted = reload(invite)
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)
    end
  end

  # ── Wiring: the send sits in the same call stack as the insert ────────────

  describe "Meetings.invite_user/3 wiring" do
    setup do
      enable_meetings!()
      :ok
    end

    test "delivers in-line and leaves the return shape unchanged" do
      {meeting, _host} = meeting_hosted_by("Wired", "Ada")
      user = create_user("Invitee")

      assert {:ok, %Invite{} = invite} = Meetings.invite_user(meeting, user.id)

      user_id = user.id
      assert_receive {:inbox_emit, %{user_id: ^user_id, kind: "meeting_invited"}}, 1_000
      assert_receive {:push_user, ^user_id, _payload, _opts}, 1_000

      assert reload(invite).delivery_carrier == "internal_inbox_push"
    end

    test "a re-invite returns the existing row and does NOT send again" do
      {meeting, _host} = meeting_hosted_by("Rewired", "Ada")
      user = create_user("Invitee")

      assert {:ok, %Invite{id: id}} = Meetings.invite_user(meeting, user.id)
      assert {:ok, %Invite{id: ^id}} = Meetings.invite_user(meeting, user.id)

      assert count_messages(:inbox_emit) == 1
      assert count_messages(:push_user) == 1
    end

    test "a malformed user_id still answers {:error, changeset} and sends nothing" do
      {meeting, _host} = meeting_hosted_by("Bad Id", "Ada")

      assert {:error, changeset} = Meetings.invite_user(meeting, "higginshigginsxx")
      assert changeset.errors[:user_id]

      assert count_messages(:inbox_emit) == 0
      assert count_messages(:push_user) == 0
    end
  end

  describe "Meetings.invite_guest/2 wiring" do
    setup do
      enable_meetings!()
      :ok
    end

    test "delivers in-line and leaves the return shape unchanged" do
      {meeting, _host} = meeting_hosted_by("Guest Wired", "Ada")

      assert {:ok, %{invite: %Invite{} = invite, token: token, url: url}} =
               Meetings.invite_guest(meeting, %{display_name: "Grace"})

      assert is_binary(token)
      assert is_binary(url)

      assert reload(invite).delivery_carrier == "guest_link"

      assert count_messages(:inbox_emit) == 0
      assert count_messages(:push_user) == 0
    end
  end
end

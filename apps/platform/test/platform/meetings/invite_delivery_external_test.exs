defmodule Platform.Meetings.InviteDeliveryExternalTest do
  @moduledoc """
  The external-user carrier of `Platform.Meetings.InviteDelivery` — task
  `019fb955-6577-7fb0-8c97-c70d233bba23` stage 4.

  ## Why the two `refute_receive`s are the point of this file

  An external user's `/inbox` is 403 (`ExternalUserScope.gate_external/2`
  allowlists exactly `[]`, `["chat"]` and `["chat", slug]`), so an inbox
  row for them is *written and unreachable*. Push is OS-level and would
  still fire, deep-linking them into that 403 — a notification that looks
  BROKEN rather than absent, which is worse than silence.

  So "a message was posted" is NOT the assertion this file exists to make.
  An implementation that posted the message AND wrote the unreachable
  inbox row AND fired the 403-bound push would satisfy it completely.
  Every delivery test here asserts the message AND both negatives.

  ## Why this is a `ConnCase`

  One invariant can only be stated against the request path: the URL the
  carrier produces must be `/chat/<space.id>` and never
  `/chat/<space.slug>`. `ExternalUserScope.resolve_space/2` resolves a
  slug through `Chat.get_space_by_slug(slug, org_id: <the EXTERNAL user's
  own org>)`, while `create_guest_chat_space/2` stamps the org of the
  MEETING's project — for an external invitee those differ by definition,
  so the slug lookup misses and only the bare-UUID fallback admits them.
  Asserting the UUID path succeeds proves nothing on its own; the slug
  path has to be driven and seen to 403, or the trap is untested.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.InviteDelivery
  alias Platform.Meetings.SenderSeed
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.ExternalUserFixtures, as: World
  alias PlatformWeb.Plugs.ExternalUserScope

  import Phoenix.LiveViewTest

  defmodule InboxRecorder do
    @moduledoc "Records `Platform.Inbox.emit/1` calls as `{:inbox_emit, attrs}`."
    def install(pid \\ self()), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def emit(attrs) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:inbox_emit, attrs})
      end

      {:ok, attrs}
    end
  end

  defmodule NotifStub do
    @moduledoc "Records `Platform.Notifications` fan-outs so a refute can see them."
    def install(pid \\ self()), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, opts \\ []),
      do: notify({:push_user, user_id, payload, opts})

    def fan_out_to_humans(ids, payload, opts \\ []),
      do: notify({:push_humans, ids, payload, opts})

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

    prior = Application.fetch_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, true)

    on_exit(fn ->
      Application.delete_env(:platform, :inbox_module)
      Application.delete_env(:platform, :notifications_module)

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

    %User{}
    |> User.changeset(%{name: name, email: "ext-#{n}@example.com", oidc_sub: "ext-sub-#{n}"})
    |> Repo.insert!()
  end

  # The established shape for "this account is external": an `org_memberships`
  # row with `external: true`, which is exactly what `Tenancy.external_user?/1`
  # reads. Written through `Tenancy.mark_membership_external/1` rather than by
  # hand so the fixture cannot drift from the predicate.
  defp external_user(name, org_slug \\ "sxi") do
    user = create_user(name)
    org = Tenancy.get_org_by_slug!(org_slug)

    {:ok, _membership} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})

    assert Tenancy.external_user?(%{id: user.id})

    {user, org}
  end

  # The meeting's project takes the DEFAULT org (fabrikam), which is deliberately
  # NOT the external invitee's tenant org — that difference is what makes the
  # slug-vs-UUID trap real rather than staged.
  defp meeting_hosted_by(name, host_name) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project"})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
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

  defp invite_row(meeting, user, attrs \\ %{}) do
    %Invite{}
    |> Invite.changeset(Map.merge(%{meeting_id: meeting.id, user_id: user.id}, attrs))
    |> Repo.insert!()
  end

  defp reload(%Invite{id: id}), do: Repo.get!(Invite, id)

  defp messages_in(space_id), do: Chat.list_messages(space_id, order: :asc, limit: 100)

  # Build a conn with the assigns `RequireAuth` would have set and run the
  # plug, exactly as `external_user_scope_test.exs` does. `format: "html"` so
  # the deny path can render :"403".
  defp gate(path, user, org) do
    Phoenix.ConnTest.build_conn(:get, path)
    |> Plug.Conn.put_private(:phoenix_format, "html")
    |> Plug.Conn.assign(:current_user, Accounts.get_user(user.id))
    |> Plug.Conn.assign(:current_user_org_membership, %{org: org, role: :member})
    |> ExternalUserScope.call(ExternalUserScope.init([]))
  end

  # ── The carrier ────────────────────────────────────────────────────────────

  describe "an external invitee" do
    test "gets a chat message and NEITHER an inbox row NOR a push" do
      {meeting, _host} = meeting_hosted_by("Cross Org", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)

      space_id = reload(invite).delivery_space_id
      assert is_binary(space_id)

      # The message exists, in the delivery space.
      assert [message] = messages_in(space_id)
      assert message.content =~ "Cross Org"
      assert message.content =~ "Ada"

      # Authored BY the seeded agent — checked by identity, not existence.
      # The participant row is what `chat_messages.participant_id` points at,
      # so posting as the AGENT id instead would either dangle or attribute
      # the invite to whoever happens to own that row.
      %{} = agent = SenderSeed.get()
      author = Chat.get_participant(message.participant_id)
      assert author.participant_type == "agent"
      assert author.participant_id == agent.id
      assert author.space_id == space_id

      # The invitee is a participant — without this row the message is
      # written and unreachable, which is the whole failure mode.
      assert Chat.participant?(space_id, user.id)

      # BOTH negatives. Asserting only the message above passes against an
      # implementation that ALSO wrote the unreachable inbox row and fired
      # the 403-bound push.
      refute_receive {:inbox_emit, _}, 200
      refute_receive {:push_user, _, _, _}, 200
      refute_receive {:push_humans, _, _, _}, 200
    end

    test "stamps the receipt: delivered_at, the carrier and the space" do
      {meeting, _host} = meeting_hosted_by("Receipted", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      assert is_nil(invite.delivered_at)
      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)

      persisted = reload(invite)
      assert %DateTime{} = persisted.delivered_at
      assert persisted.delivery_carrier == "external_chat"
      assert is_binary(persisted.delivery_space_id)
    end

    test "delivering twice reuses the space and posts exactly ONE message" do
      {meeting, _host} = meeting_hosted_by("Double", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)
      first_space_id = reload(invite).delivery_space_id

      # A stale struct, exactly what a host's double-submit hands delivery.
      assert {:ok, :already_delivered} = InviteDelivery.deliver(invite, meeting)

      # Re-run the carrier itself against the RELOADED row too, so the reuse
      # branch of `delivery_space_for_invite/2` is exercised and not merely
      # short-circuited by the CAS.
      reloaded = reload(invite)
      assert {:ok, space} = Meetings.delivery_space_for_invite(reloaded, meeting)
      assert space.id == first_space_id

      assert reload(invite).delivery_space_id == first_space_id

      # The COUNT is the assertion. A second mint, or a second post, both
      # show up here and nowhere in the return values above.
      assert length(messages_in(first_space_id)) == 1

      # And exactly one participant row per side — the `Repo.get_by/2` guard
      # ahead of `Chat.add_participant/2` is what keeps the second pass from
      # raising on `chat_participants_unique`.
      participants = Chat.list_participants(first_space_id)
      assert length(Enum.filter(participants, &(&1.participant_type == "user"))) == 1
      assert length(Enum.filter(participants, &(&1.participant_type == "agent"))) == 1
    end

    test "releases the claim when the delivery space cannot carry a message" do
      # THE GENUINE FAILURE PATH, and the reason stage 3's release survives
      # into stage 4. The eventual 24h guest-space reaper archives exactly
      # this `kind: "guest_meeting"` row, and `Chat.add_participant/2` /
      # `Chat.post_message/2` both refuse an archived space. Nothing carried
      # the invite, so it must not read as delivered — the release is what
      # lets a later call try again once an operator has fixed the cause.
      {meeting, _host} = meeting_hosted_by("Shuttered", "Ada")
      {user, _org} = external_user("External")

      {:ok, space} = Meetings.create_guest_chat_space(meeting, user.id)
      {:ok, _archived} = Chat.archive_space(space)

      invite = invite_row(meeting, user, %{delivery_space_id: space.id})

      assert {:error, :space_archived} = InviteDelivery.deliver(invite, meeting)

      persisted = reload(invite)
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)

      assert messages_in(space.id) == []
      refute_receive {:inbox_emit, _}, 200
      refute_receive {:push_user, _, _, _}, 200
    end

    test "releases the claim when a stale struct names a space that is gone" do
      # `meeting_invites.delivery_space_id` carries an FK with
      # `on_delete: :nilify_all` (migration 20260801180904), so a PERSISTED
      # row can never point at a deleted space — deleting the space NULLs
      # the column and the next delivery mints a fresh one. The
      # `:delivery_space_missing` branch is therefore reachable only from a
      # struct whose field did not come out of that column, which is what
      # this test hands it. Recorded rather than deleted because the branch
      # is the difference between an error the caller can retry and an
      # `Ecto.NoResultsError` out of a delivery path documented never to
      # raise for an expected condition.
      {meeting, _host} = meeting_hosted_by("Vanished", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      stale = %{invite | delivery_space_id: Ecto.UUID.generate()}

      assert {:error, :delivery_space_missing} = InviteDelivery.deliver(stale, meeting)

      persisted = reload(invite)
      assert is_nil(persisted.delivered_at)
      assert is_nil(persisted.delivery_carrier)

      refute_receive {:inbox_emit, _}, 200
      refute_receive {:push_user, _, _, _}, 200
    end
  end

  # ── The slug-vs-UUID trap ──────────────────────────────────────────────────

  describe "the URL the carrier produces" do
    test "names the space by UUID, and the SLUG path is a 403 for its own addressee" do
      {meeting, _host} = meeting_hosted_by("Linked", "Ada")
      {user, org} = external_user("External")
      invite = invite_row(meeting, user)

      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)

      space = Chat.get_space(reload(invite).delivery_space_id)
      assert [message] = messages_in(space.id)

      assert message.content =~ "/chat/#{space.id}"
      refute message.content =~ "/chat/#{space.slug}"

      # The trap, driven rather than asserted. The space carries the
      # MEETING's project org; the plug resolves a slug against the EXTERNAL
      # user's own org. Those differ, so the slug lookup misses and the
      # uniform 403 fires — for the one person the link was addressed to.
      denied = gate("/chat/#{space.slug}", user, org)
      assert denied.halted
      assert denied.status == 403

      # Only the bare-UUID fallback admits them.
      admitted = gate("/chat/#{space.id}", user, org)
      refute admitted.halted
    end
  end

  # ── The link has to RENDER, not merely be admitted ─────────────────────────

  describe "the invite URL, driven through the router" do
    # `gate/3` above calls `ExternalUserScope.call/2` DIRECTLY. The plug is not
    # the router and it is certainly not the LiveView: `refute admitted.halted`
    # says "the gate let this request past", never "the page came back". Those
    # are different claims, and the gap between them is where a real 500 lived.
    #
    # `ChatLive.handle_params/3` calls `space_page_title/3`, which routes every
    # non-"channel" kind through `Chat.display_name_for_space/3`. That function
    # matches on `kind`, and this space's kind is "guest_meeting" — a kind it
    # had no clause for. So the single URL the invite message hands the
    # external invitee raised `FunctionClauseError` and answered HTTP 500,
    # while every plug-level assertion above stayed green. Only a request that
    # MOUNTS the page can see that, so these tests drive `/chat/<uuid>` end to
    # end.
    test "the UUID url the invitee is handed actually renders", %{conn: conn} do
      {meeting, _host} = meeting_hosted_by("Rendered", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)
      space = Chat.get_space(reload(invite).delivery_space_id)

      # The url is read out of the message the invitee actually received, so
      # this test cannot drift onto a path the carrier stopped producing.
      assert [message] = messages_in(space.id)
      assert message.content =~ "/chat/#{space.id}"

      response =
        conn
        |> World.login(user.id)
        |> get("/chat/#{space.id}")

      # 200, not 403 and not 500. The status is the whole point: the plug
      # tests above pass identically whether this is 200 or 500.
      assert response.status == 200
      body = html_response(response, 200)

      # And it must render THIS space under its own name — via the code path
      # that crashed. Note the assertion is against the <title>, NOT the body
      # at large: a bare `body =~ space.name` passes on the compose
      # textarea's `placeholder="Message #<name>"`, which renders
      # `@active_space.name` raw and never calls `display_name_for_space/3`.
      # Measured — a mutation returning a hardcoded wrong name from the new
      # clause left `body =~ space.name` green, because that placeholder still
      # carried the real name. The title is fed by `space_page_title/3` and so
      # binds to the function under test.
      assert title(body) =~ space.name
    end

    test "and mounts connected, over the socket", %{conn: conn} do
      {meeting, _host} = meeting_hosted_by("Mounted", "Ada")
      {user, _org} = external_user("External")
      invite = invite_row(meeting, user)

      assert {:ok, :external_chat} = InviteDelivery.deliver(invite, meeting)
      space = Chat.get_space(reload(invite).delivery_space_id)

      # `live/2` runs the dead render AND the connected mount, so this also
      # covers `handle_params/3`'s `connected?(socket)` branch — the one a
      # plain `get/2` never reaches.
      {:ok, view, _html} =
        conn
        |> World.login(user.id)
        |> live("/chat/#{space.id}")

      # `page_title/1` reads exactly what `space_page_title/3` assigned, so
      # this cannot be satisfied by an incidental render of the name
      # elsewhere on the page (see the sibling test for why that matters).
      assert page_title(view) =~ space.name
    end
  end

  # The <title> of a dead render. `Phoenix.LiveViewTest.page_title/1` only
  # works on a connected view, so the `get/2` case extracts it by hand.
  defp title(body) do
    case Regex.run(~r|<title[^>]*>(.*?)</title>|s, body) do
      [_, inner] -> inner
      nil -> flunk("no <title> in the rendered body")
    end
  end

  # ── Wiring ─────────────────────────────────────────────────────────────────

  describe "Meetings.invite_user/3 wiring" do
    test "an external invitee is delivered to in-line, over chat" do
      {meeting, _host} = meeting_hosted_by("Wired External", "Ada")
      {user, _org} = external_user("External")

      assert {:ok, %Invite{} = invite} = Meetings.invite_user(meeting, user.id)

      persisted = reload(invite)
      assert persisted.delivery_carrier == "external_chat"
      assert [_message] = messages_in(persisted.delivery_space_id)

      refute_receive {:inbox_emit, _}, 200
      refute_receive {:push_user, _, _, _}, 200
    end
  end
end

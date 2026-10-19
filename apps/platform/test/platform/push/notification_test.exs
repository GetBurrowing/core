defmodule Platform.Push.NotificationTest do
  @moduledoc """
  Task 01a10882 stage 2: ONE notification model, read by both transports.

  The property under test is agreement: for every kind, the web push payload
  and the APNs payload are serialisations of the SAME struct, so title, body,
  url, kind and every id match. And an external recipient's redaction runs
  once, before the split, so both transports carry the identical redacted copy.
  """
  # async: false — the external fixture reads org_memberships and emits
  # telemetry on the shared `[:platform, :push, :external_safe_preview]` event.
  use Platform.DataCase, async: false

  alias Platform.Chat.AttentionRouter
  alias Platform.Chat.Message
  alias Platform.Chat.Space
  alias Platform.Inbox.Item
  alias Platform.Push
  alias Platform.Push.Notification
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.TenancyFixtures

  defp insert_user(name \\ "User") do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: name,
      email: "notif-#{n}@example.com",
      oidc_sub: "sub-notif-#{n}"
    })
  end

  defp external_user do
    user = insert_user("Xavier External")

    {:ok, _} =
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.acme_org_id()})

    user
  end

  defp space do
    %Space{
      id: Ecto.UUID.generate(),
      name: "Internal Acme Globex",
      slug: "internal-acme-globex"
    }
  end

  defp message(content) do
    %Message{id: Ecto.UUID.generate(), content: content}
  end

  defp inbox_item(kind, attrs \\ %{}) do
    struct(
      %Item{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        kind: kind,
        source_type: "task",
        source_id: Ecto.UUID.generate(),
        title: "Label: Ship the iOS app",
        body: "row body",
        url: "/tasks/abc"
      },
      attrs
    )
  end

  # One notification per kind the system produces.
  defp every_kind do
    [
      Notification.from_map(%{title: "Legacy", body: "legacy body", url: "/meetings/x"}),
      AttentionRouter.push_notification("Sam", message("hi @[Robin]"), :mention, space(), []),
      AttentionRouter.push_notification("Sam", message("ambient"), :all, space(), []),
      Notification.from_inbox_item(inbox_item("task_plan_review")),
      Notification.from_inbox_item(
        inbox_item("review_request_pending", %{source_type: "task_review"})
      ),
      Notification.from_inbox_item(inbox_item("task_sponsor_assigned")),
      Notification.from_inbox_item(inbox_item("meeting_invited", %{source_type: "meeting"}))
    ]
  end

  defp assert_transports_agree(%Notification{} = n) do
    web = Notification.to_web_payload(n)
    apns = Notification.to_apns_payload(n)

    assert web.title == apns["aps"]["alert"]["title"], "title differs for #{n.kind}"
    assert web.body == apns["aps"]["alert"]["body"], "body differs for #{n.kind}"
    assert web[:url] == apns["url"], "url differs for #{n.kind}"
    assert web.kind == apns["kind"], "kind differs for #{n.kind}"

    for key <- ~w(space_id message_id task_id inbox_item_id install_host)a do
      assert web[key] == apns[Atom.to_string(key)], "#{key} differs for #{n.kind}"
    end

    assert web[:category] == apns["aps"]["category"], "category differs for #{n.kind}"
    # The APNs thread id is the same thread, prefixed with the install host
    # (task 01a1261e); web push keeps the bare thread id.
    expected_thread = web[:thread_id] && "#{n.install_host}:#{web[:thread_id]}"
    assert expected_thread == apns["aps"]["thread-id"], "thread differs for #{n.kind}"

    {web, apns}
  end

  describe "both transports read one model" do
    test "every kind: web and APNs carry identical title, body, url, kind and ids" do
      kinds = every_kind()

      assert Enum.map(kinds, & &1.kind) ==
               ~w(generic chat_mention chat_message task_plan_review review_request_pending task_sponsor_assigned meeting_invited)

      Enum.each(kinds, &assert_transports_agree/1)
    end

    test "an external user gets the identical redacted copy on both transports" do
      user = external_user()

      Enum.each(every_kind(), fn n ->
        redacted = Push.preview_for_user(user.id, n)
        {web, apns} = assert_transports_agree(redacted)

        assert web.title == "New message"
        assert apns["aps"]["alert"]["title"] == "New message"
        assert apns["aps"]["alert"]["body"] == "You have a new message"
        assert web.url == "/chat"

        # Nothing that identifies the source survives on either transport.
        for key <- ~w(space_id message_id task_id inbox_item_id category thread_id)a do
          refute Map.has_key?(web, key), "web payload kept #{key} for #{n.kind}"
        end

        for key <- ~w(space_id message_id task_id inbox_item_id) do
          refute Map.has_key?(apns, key), "APNs payload kept #{key} for #{n.kind}"
        end

        refute Map.has_key?(apns["aps"], "category")
        refute Map.has_key?(apns["aps"], "thread-id")
      end)
    end

    test "an internal user gets the notification unchanged" do
      user = insert_user()
      [_, mention | _] = every_kind()
      assert Push.preview_for_user(user.id, mention) == mention
    end

    test "the web payload keeps the keys sw.js reads" do
      web =
        Notification.to_web_payload(Notification.from_map(%{title: "T", body: "B", url: "/u"}))

      assert %{title: "T", body: "B", url: "/u", kind: "generic"} = web
      assert web.install_host == "www.example.com"
    end
  end

  describe "a nil body" do
    test "is omitted from both payloads, never sent as null" do
      n = Notification.from_map(%{title: "You're now sponsoring: T", body: nil, url: "/tasks/t"})

      apns = Notification.to_apns_payload(n)
      assert apns["aps"]["alert"] == %{"title" => "You're now sponsoring: T"}
      refute Map.has_key?(apns["aps"]["alert"], "body")
      refute Jason.encode!(apns) =~ "null"

      web = Notification.to_web_payload(n)
      refute Map.has_key?(web, :body)
      assert web.title == "You're now sponsoring: T"
      refute Jason.encode!(web) =~ "null"
    end
  end

  # Task 01a14ba1: the struct carries the legacy SUITE_* id; the wire id is
  # chosen per device scheme, and only "burrow" devices get BURROW_*.
  describe "wire category per device scheme" do
    @pairs [
      {"chat_mention", "SUITE_MENTION", "BURROW_MENTION"},
      {"task_plan_review", "SUITE_OPEN", "BURROW_OPEN"},
      {"review_request_pending", "SUITE_OPEN", "BURROW_OPEN"},
      {"meeting_ring_waiting", "SUITE_RING_WAITING", "BURROW_RING_WAITING"}
    ]

    test "wire_category/2 maps each legacy id for :burrow and leaves :legacy alone" do
      for {_kind, legacy, burrow} <- @pairs do
        assert Notification.wire_category(legacy, :legacy) == legacy
        assert Notification.wire_category(legacy, :burrow) == burrow
      end
    end

    test "nil stays nil under both schemes" do
      assert Notification.wire_category(nil, :legacy) == nil
      assert Notification.wire_category(nil, :burrow) == nil

      n = Notification.from_map(%{title: "a", body: "b", url: "/"})
      refute Map.has_key?(Notification.to_apns_payload(n, :burrow)["aps"], "category")
      refute Map.has_key?(Notification.to_fcm_payload(n, :burrow)["data"], "category")
    end

    test "the struct keeps the legacy id; the /1 arities are the legacy scheme" do
      for {kind, legacy, burrow} <- @pairs do
        n = Notification.new(%{kind: kind, title: "t", body: "b", url: "/"})

        assert n.category == legacy
        assert Notification.to_apns_payload(n) == Notification.to_apns_payload(n, :legacy)
        assert Notification.to_fcm_payload(n) == Notification.to_fcm_payload(n, :legacy)
        assert Notification.to_apns_payload(n)["aps"]["category"] == legacy
        assert Notification.to_fcm_payload(n)["data"]["category"] == legacy
        assert Notification.to_apns_payload(n, :burrow)["aps"]["category"] == burrow
        assert Notification.to_fcm_payload(n, :burrow)["data"]["category"] == burrow
        assert Notification.to_web_payload(n).category == legacy
      end
    end

    test "scheme_for_device/1 is :burrow only for a \"burrow\" row" do
      assert Notification.scheme_for_device(%{push_category_scheme: "burrow"}) == :burrow
      assert Notification.scheme_for_device(%{push_category_scheme: nil}) == :legacy
      assert Notification.scheme_for_device(%{push_category_scheme: "other"}) == :legacy
      assert Notification.scheme_for_device(%Platform.Mobile.ApnsDevice{}) == :legacy
      assert Notification.scheme_for_device(%Platform.Mobile.FcmDevice{}) == :legacy
    end
  end

  describe "categories and grouping" do
    test "a mention gets SUITE_MENTION and is grouped by its space" do
      s = space()
      n = AttentionRouter.push_notification("Sam", message("x"), :mention, s, [])

      assert n.category == "SUITE_MENTION"
      assert n.thread_id == s.id
      assert n.url == "/chat/internal-acme-globex?message=#{n.message_id}"
      assert n.space_id == s.id
    end

    # A DM has no slug (prod: kind=dm, slug NULL). A slug-only url collapsed
    # to "/chat", and Open landed on the first channel, not the DM.
    test "a mention in a slug-less DM links to that DM and its message, never bare /chat" do
      dm = %Space{id: Ecto.UUID.generate(), name: nil, kind: "dm", slug: nil}
      msg = message("ping")
      n = AttentionRouter.push_notification("Sam", msg, :mention, dm, [])

      assert n.url == "/chat/#{dm.id}?message=#{msg.id}"
      assert Notification.to_apns_payload(n)["url"] == n.url
    end

    test "an org-scoped space links by id, matching the web app's space_path_segment" do
      s = %Space{space() | org_id: Ecto.UUID.generate()}
      msg = message("x")
      n = AttentionRouter.push_notification("Sam", msg, :mention, s, [])

      assert n.url == "/chat/#{Platform.Chat.space_path_segment(s)}?message=#{msg.id}"
      assert n.url == "/chat/#{s.id}?message=#{msg.id}"
    end

    test "plan and review requests share one Approvals group with SUITE_OPEN" do
      for kind <- ~w(task_plan_review review_request_pending) do
        n = Notification.from_inbox_item(inbox_item(kind))
        assert n.category == "SUITE_OPEN"
        assert n.thread_id == "approvals"

        assert Notification.to_apns_payload(n)["aps"]["thread-id"] ==
                 "#{n.install_host}:approvals"
      end
    end

    test "every other kind has no category (tap opens)" do
      assert Notification.from_map(%{title: "a", body: "b", url: "/"}).category == nil

      assert AttentionRouter.push_notification("J", message("x"), :all, space(), []).category ==
               nil

      assert Notification.from_inbox_item(inbox_item("meeting_invited")).category == nil
    end

    test "the inbox item id is the collapse id" do
      item = inbox_item("task_plan_review")
      n = Notification.from_inbox_item(item)
      assert n.collapse_id == item.id
      assert n.inbox_item_id == item.id
    end
  end

  describe "copy (canvas 01a10887 rev 23)" do
    test "mention title is {Author} in {Space}" do
      n = AttentionRouter.push_notification("Sam", message("x"), :mention, space(), [])
      assert n.title == "Sam in Internal Acme Globex"
    end

    test "plan and review titles are fixed and the body is the task title" do
      {:ok, project} = Tasks.create_project(%{name: "Proj #{System.unique_integer([:positive])}"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Suite iOS app v1"})

      plan =
        Notification.from_inbox_item(
          inbox_item("task_plan_review", %{source_id: task.id, title: "Plan ready for review: x"})
        )

      review =
        Notification.from_inbox_item(
          inbox_item("review_request_pending", %{source_type: "task_review", source_id: task.id})
        )

      assert {plan.title, plan.body} == {"Plan ready to approve", "Suite iOS app v1"}
      assert {review.title, review.body} == {"Review requested", "Suite iOS app v1"}
      assert plan.task_id == task.id
    end

    test "a missing task falls back to the title after the inbox label" do
      n = Notification.from_inbox_item(inbox_item("task_plan_review"))
      assert n.body == "Ship the iOS app"
    end

    test "body strips formatting and turns @[Name] into @Name" do
      assert Notification.body_text(
               "**Heads up** @[Robin Smith], see [the doc](https://x.test/a)"
             ) ==
               "Heads up @Robin Smith, see the doc"

      assert Notification.body_text("# Title\n\n> quoted `code` and _emph_") ==
               "Title quoted code and emph"

      assert Notification.body_text("snake_case_name stays") == "snake_case_name stays"
    end

    test "an attachment-only message reads Sent a photo / Sent a PDF: {filename}" do
      assert Notification.body_text("", [%{content_type: "image/jpeg", filename: "a.jpg"}]) ==
               "Sent a photo"

      assert Notification.body_text(nil, [
               %{content_type: "application/pdf", filename: "Q3 board deck.pdf"}
             ]) == "Sent a PDF: Q3 board deck.pdf"

      assert Notification.body_text("  ", []) == ""
    end

    test "a long body is cut at a word boundary and ends with an ellipsis" do
      text = String.duplicate("word ", 60)
      body = Notification.body_text(text)

      assert String.ends_with?(body, "word…")
      assert String.length(body) <= 201
      refute body =~ "wor…"
    end
  end

  describe "FCM payload (task 01a10d8e stage 1)" do
    test "a chat notification carries the author and the space separately" do
      n = AttentionRouter.push_notification("Sam", message("hi"), :mention, space(), [])

      assert n.author_name == "Sam"
      assert n.space_name == "Internal Acme Globex"
      assert n.title == "Sam in Internal Acme Globex", "the title is unchanged"
    end

    test "to_fcm_payload is data-only, high priority, with string values only" do
      for n <- every_kind() do
        message = Notification.to_fcm_payload(n)

        refute Map.has_key?(message, "notification"), "#{n.kind} must be data-only"
        refute Map.has_key?(message, "token"), "the transport adds the token, not the model"
        assert message["android"]["priority"] == "high"

        data = message["data"]
        assert is_map(data)

        assert Enum.all?(data, fn {k, v} -> is_binary(k) and is_binary(v) end),
               "FCM rejects non-string data values (#{n.kind})"

        refute Enum.any?(data, fn {_k, v} -> v == "" end), "nils are dropped, never blanked"

        assert data["kind"] == n.kind
        assert data["title"] == n.title
        assert data["url"] == n.url
        assert data["install_host"] == n.install_host
      end
    end

    test "every field the app reads is in data, and agrees with the web payload" do
      [_, mention | _] = every_kind()
      data = Notification.to_fcm_payload(mention)["data"]
      web = Notification.to_web_payload(mention)

      for key <- ~w(title body url kind category thread_id space_id message_id install_host)a do
        assert data[Atom.to_string(key)] == web[key], "#{key} differs"
      end

      assert data["author_name"] == "Sam"
      assert data["space_name"] == "Internal Acme Globex"
      refute Map.has_key?(data, "task_id")
    end

    test "collapse_id becomes android.collapse_key, cut to 64 characters" do
      long =
        Notification.new(%{kind: "generic", title: "t", collapse_id: String.duplicate("x", 90)})

      assert Notification.to_fcm_payload(long)["android"]["collapse_key"] ==
               String.duplicate("x", 64)

      item = inbox_item("task_plan_review")
      n = Notification.from_inbox_item(item)
      assert Notification.to_fcm_payload(n)["android"]["collapse_key"] == item.id

      none = Notification.from_map(%{title: "a", body: "b", url: "/"})
      refute Map.has_key?(Notification.to_fcm_payload(none)["android"], "collapse_key")
    end

    test "redaction clears author_name and space_name on every transport" do
      user = external_user()
      [_, mention | _] = every_kind()
      assert mention.author_name == "Sam"

      redacted = Push.preview_for_user(user.id, mention)

      assert redacted.author_name == nil
      assert redacted.space_name == nil

      data = Notification.to_fcm_payload(redacted)["data"]
      refute Map.has_key?(data, "author_name")
      refute Map.has_key?(data, "space_name")
      refute Map.has_key?(data, "space_id")
      refute Jason.encode!(data) =~ "Sam"
      refute Jason.encode!(data) =~ "Internal Acme Globex"
      assert data["title"] == "New message"
    end
  end

  # Task 01a10d8e stage 6 (behavioural gate, finding 1): a DM mention reached
  # Android with url "/chat" and no space_name, so Open landed in a channel and
  # MessagingStyle had no conversation title.
  describe "a DM mention on the FCM path" do
    test "carries /chat/<dm id>?message=<id> and the recipient's name for the DM" do
      alice = insert_user("Alice Recipient")
      bob = insert_user("Bob Sender")
      {:ok, dm} = Platform.Chat.find_or_create_dm(bob.id, "user", alice.id)
      assert is_nil(dm.name) and is_nil(dm.slug), "the prod DM shape"

      alice_row =
        Enum.find(Platform.Chat.list_participants(dm.id), &(&1.participant_id == alice.id))

      bob_row = Enum.find(Platform.Chat.list_participants(dm.id), &(&1.participant_id == bob.id))

      # Each side names the DM after the OTHER person, as the web sidebar does.
      assert AttentionRouter.push_conversation_name(dm, alice_row) == "Bob Sender"
      assert AttentionRouter.push_conversation_name(dm, bob_row) == "Alice Recipient"

      msg = message("@[Alice Recipient] ping")

      n =
        AttentionRouter.push_notification(
          "Bob Sender",
          msg,
          :mention,
          dm,
          [],
          AttentionRouter.push_conversation_name(dm, alice_row)
        )

      data = Notification.to_fcm_payload(n)["data"]
      assert data["url"] == "/chat/#{dm.id}?message=#{msg.id}"
      assert data["space_name"] == "Bob Sender"
      assert data["author_name"] == "Bob Sender"
      assert data["space_id"] == dm.id
      assert data["message_id"] == msg.id
      # The title is what APNs and web push show. A DM has no name, so it
      # names the install (task 01a120c5 stage 3; was a compiled "Suite").
      assert n.title == "Bob Sender in Burrow"
    end

    test "a named space keeps its own name; an unresolved recipient falls back to it" do
      s = space()
      assert AttentionRouter.push_conversation_name(s, Ecto.UUID.generate()) == s.name

      dm = %Space{id: Ecto.UUID.generate(), kind: "dm", name: nil, slug: nil}
      assert AttentionRouter.push_conversation_name(dm, Ecto.UUID.generate()) == nil
    end
  end

  # Task 01a111bb stage 2: the sender's identity, for the iOS Notification
  # Service Extension's communication notification.
  defp agent_sender do
    %Platform.Chat.Participant{
      id: Ecto.UUID.generate(),
      participant_type: "agent",
      participant_id: Ecto.UUID.generate(),
      display_name: "Burrow Helper"
    }
  end

  describe "author fields and mutable-content (task 01a111bb)" do
    test "a chat notification from a participant carries author_id and author_type everywhere" do
      sender = agent_sender()
      n = AttentionRouter.push_notification(sender, message("done"), :all, space(), [])

      assert n.author_id == sender.participant_id
      assert n.author_type == "agent"
      assert n.author_name == "Burrow Helper"

      apns = Notification.to_apns_payload(n)
      assert apns["author_id"] == sender.participant_id
      assert apns["author_type"] == "agent"
      assert apns["author_name"] == "Burrow Helper"
      assert apns["space_name"] == n.space_name
      assert is_binary(apns["space_name"])

      data = Notification.to_fcm_payload(n)["data"]
      assert data["author_id"] == sender.participant_id
      assert data["author_type"] == "agent"
    end

    test "a bare sender name carries no author identity" do
      n = AttentionRouter.push_notification("Sam", message("hi"), :all, space(), [])
      assert n.author_id == nil
      refute Map.has_key?(Notification.to_apns_payload(n), "author_id")
    end

    test "mutable-content is set for chat_message and chat_mention only" do
      for n <- every_kind() do
        aps = Notification.to_apns_payload(n)["aps"]

        if n.kind in ~w(chat_message chat_mention) do
          assert aps["mutable-content"] == 1, "missing for #{n.kind}"
        else
          refute Map.has_key?(aps, "mutable-content"), "set for #{n.kind}"
        end
      end

      kinds = Enum.map(every_kind(), & &1.kind)
      assert "chat_message" in kinds and "chat_mention" in kinds
    end

    test "redact/2 drops the author fields on every transport" do
      sender = agent_sender()
      n = AttentionRouter.push_notification(sender, message("secret"), :mention, space(), [])
      assert n.author_id

      redacted = Notification.redact(n, %{title: "New message", body: "", url: "/"})

      assert redacted.author_id == nil
      assert redacted.author_type == nil
      refute Map.has_key?(Notification.to_apns_payload(redacted), "author_id")
      refute Map.has_key?(Notification.to_apns_payload(redacted), "author_type")
      refute Map.has_key?(Notification.to_apns_payload(redacted), "author_name")
      refute Map.has_key?(Notification.to_apns_payload(redacted), "space_name")
      refute Map.has_key?(Notification.to_apns_payload(redacted), "space_id")
      refute Map.has_key?(Notification.to_fcm_payload(redacted)["data"], "author_id")

      # The same through the real external-recipient path.
      external = Push.preview_for_user(external_user().id, n)
      assert external.author_id == nil
      assert external.author_type == nil
    end
  end

  # Task 01a116c4 stage 1: the space kind, so Android can tell a dm (a
  # one-to-one conversation) from a group. FCM only.
  describe "space_kind (task 01a116c4)" do
    test "to_fcm_payload carries space_kind; web and APNs payloads do not" do
      dm = %Space{id: Ecto.UUID.generate(), kind: "dm", name: nil, slug: nil}
      n = AttentionRouter.push_notification("Sam", message("hi"), :all, dm, [])
      assert n.space_kind == "dm"

      assert Notification.to_fcm_payload(n)["data"]["space_kind"] == "dm"
      refute Map.has_key?(Notification.to_web_payload(n), :space_kind)
      refute Map.has_key?(Notification.to_web_payload(n), "space_kind")
      refute Map.has_key?(Notification.to_apns_payload(n), "space_kind")
      refute Map.has_key?(Notification.to_apns_payload(n)["aps"], "space_kind")
    end

    test "redact/2 clears space_kind" do
      n = AttentionRouter.push_notification("Sam", message("x"), :mention, space(), [])
      assert n.space_kind == "channel"

      redacted = Notification.redact(n, %{title: "New message", body: "", url: "/"})
      assert redacted.space_kind == nil
      refute Map.has_key?(Notification.to_fcm_payload(redacted)["data"], "space_kind")
    end

    test "the FCM data names the author participant (pins the 01a111bb dependency)" do
      sender = agent_sender()
      n = AttentionRouter.push_notification(sender, message("hi"), :mention, space(), [])
      assert Notification.to_fcm_payload(n)["data"]["author_id"] == sender.participant_id
    end
  end

  # ── Task 01a12773 stage 2: the sender's picture and letter-disc tone ──

  defp insert_agent!(avatar_url) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Agents.Agent{
      slug: "avatar-push-#{n}",
      name: "Avatar Push #{n}",
      status: "active",
      avatar_url: avatar_url
    })
  end

  defp agent_participant(agent) do
    %Platform.Chat.Participant{
      id: Ecto.UUID.generate(),
      participant_type: "agent",
      participant_id: agent.id,
      display_name: agent.name
    }
  end

  defp user_participant(user, attrs \\ %{}) do
    struct(
      %Platform.Chat.Participant{
        id: Ecto.UUID.generate(),
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name
      },
      attrs
    )
  end

  defp user_with_avatar!(avatar_url) do
    "Pictured Person"
    |> insert_user()
    |> Ecto.Changeset.change(avatar_url: avatar_url)
    |> Repo.update!()
  end

  defp avatar_agent_url(agent) do
    "https://#{Notification.install_host()}/api/app/agents/#{agent.id}/avatar?v=c0ffee12"
  end

  defp avatar_user_url(user, source) do
    v = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "https://#{Notification.install_host()}/api/app/users/#{user.id}/avatar?v=#{v}"
  end

  defp push_from(sender, reason \\ :all),
    do: AttentionRouter.push_notification(sender, message("x"), reason, space(), [])

  describe "sender avatar (task 01a12773)" do
    test "an agent with an avatar gets the absolute bearer route with the stored ?v= verbatim" do
      agent = insert_agent!("/agents/placeholder/avatar?v=c0ffee12")
      n = push_from(agent_participant(agent))

      assert is_binary(Notification.install_host())
      assert n.author_avatar_url == avatar_agent_url(agent)
      assert n.author_avatar_tone == "agent"
    end

    test "an agent without an avatar has no url, and still the agent tone" do
      for stored <- [nil, "", "   "] do
        n = push_from(agent_participant(insert_agent!(stored)))

        assert n.author_avatar_url == nil, inspect(stored)
        assert n.author_avatar_tone == "agent"
        refute Map.has_key?(Notification.to_fcm_payload(n)["data"], "author_avatar_url")
        refute Map.has_key?(Notification.to_apns_payload(n), "author_avatar_url")
      end
    end

    test "fcm data and the apns body carry both keys; the web payload carries neither" do
      agent = insert_agent!("/agents/placeholder/avatar?v=c0ffee12")
      n = push_from(agent_participant(agent), :mention)

      data = Notification.to_fcm_payload(n)["data"]
      assert data["author_avatar_url"] == avatar_agent_url(agent)
      assert data["author_avatar_tone"] == "agent"

      apns = Notification.to_apns_payload(n)
      assert apns["author_avatar_url"] == avatar_agent_url(agent)
      assert apns["author_avatar_tone"] == "agent"
      refute Map.has_key?(apns["aps"], "author_avatar_url")

      web = Notification.to_web_payload(n)
      web_keys = web |> Map.keys() |> Enum.map(&to_string/1)
      refute "author_avatar_url" in web_keys
      refute "author_avatar_tone" in web_keys
      refute inspect(web) =~ "/api/app/agents/"
    end

    test "a user's absolute https picture becomes the app route, versioned by its url" do
      url = "https://lh3.googleusercontent.example/a/AAcHTt-face=s96-c"
      user = user_with_avatar!(url)
      n = push_from(user_participant(user))

      # The apps drop a body over 256 KB, so the push names the install's
      # route that serves the picture sized for them, never the IdP url.
      expected = avatar_user_url(user, url)
      assert n.author_avatar_url == expected
      assert Notification.to_fcm_payload(n)["data"]["author_avatar_url"] == expected
      assert Notification.to_apns_payload(n)["author_avatar_url"] == expected
      refute inspect(Notification.to_fcm_payload(n)) =~ "googleusercontent"
    end

    test "a changed user picture changes the route's ?v= token" do
      user = user_with_avatar!("https://idp.example/one.png")
      first = push_from(user_participant(user)).author_avatar_url

      user =
        user |> Ecto.Changeset.change(avatar_url: "https://idp.example/two.png") |> Repo.update!()

      second = push_from(user_participant(user)).author_avatar_url

      assert first == avatar_user_url(user, "https://idp.example/one.png")
      assert second == avatar_user_url(user, "https://idp.example/two.png")
      assert first != second
    end

    test "a participant avatar_url equal to the user's also uses the route" do
      user = user_with_avatar!("https://idp.example/user.png")
      participant = user_participant(user, %{avatar_url: "https://idp.example/user.png"})

      assert push_from(participant).author_avatar_url ==
               avatar_user_url(user, "https://idp.example/user.png")
    end

    test "the participant's own avatar_url wins over the user's, as in the chat" do
      user = user_with_avatar!("https://idp.example/user.png")
      participant = user_participant(user, %{avatar_url: "https://idp.example/participant.png"})

      assert push_from(participant).author_avatar_url == "https://idp.example/participant.png"
    end

    test "a user picture that is not absolute https is dropped" do
      for bad <- [
            "http://idp.example/face.png",
            "/uploads/face.png",
            "face.png",
            "https://",
            "javascript:alert(1)",
            "not a url at all",
            ""
          ] do
        n = push_from(user_participant(user_with_avatar!(bad)))

        assert n.author_avatar_url == nil, "kept #{inspect(bad)}"
        assert is_binary(n.author_avatar_tone)
      end
    end

    test "a user's tone is the palette index the chat colours that user with" do
      user = insert_user("Tone Pair")
      participant = user_participant(user)
      n = push_from(participant)

      # The seed the chat renders this author with, and the class it draws.
      chat_seed =
        PlatformWeb.ChatLive.PresenceHooks.participant_identity(participant, user).avatar_seed

      assert chat_seed == user.oidc_sub
      chat_class = PlatformWeb.AvatarComponents.fallback_palette_class(chat_seed)

      assert n.author_avatar_tone in Enum.map(0..7, &Integer.to_string/1)
      assert chat_class == "avatar-fallback-" <> n.author_avatar_tone
    end

    test "the tone moves with the seed (the pair test is not vacuous)" do
      tones =
        for _ <- 1..24 do
          push_from(user_participant(insert_user("Spread"))).author_avatar_tone
        end

      assert tones |> Enum.uniq() |> length() > 1
    end

    test "a bare sender name carries neither field" do
      n = push_from("Sam")
      assert n.author_avatar_url == nil
      assert n.author_avatar_tone == nil
    end

    test "redact/2 output carries neither field on any transport" do
      n = push_from(agent_participant(insert_agent!("/agents/x/avatar?v=c0ffee12")), :mention)
      assert n.author_avatar_url

      for redacted <- [
            Notification.redact(n, %{title: "New message", body: "", url: "/"}),
            Push.preview_for_user(external_user().id, n)
          ] do
        assert redacted.author_avatar_url == nil
        assert redacted.author_avatar_tone == nil

        for payload <- [
              Notification.to_fcm_payload(redacted)["data"],
              Notification.to_apns_payload(redacted),
              Notification.to_web_payload(redacted)
            ] do
          refute inspect(payload) =~ "author_avatar"
          refute inspect(payload) =~ "/api/app/agents/"
        end
      end
    end

    test "non-chat kinds carry neither field" do
      for n <- every_kind(), n.kind not in ~w(chat_message chat_mention) do
        assert n.author_avatar_url == nil
        assert n.author_avatar_tone == nil

        for key <- ~w(author_avatar_url author_avatar_tone) do
          refute Map.has_key?(Notification.to_fcm_payload(n)["data"], key)
          refute Map.has_key?(Notification.to_apns_payload(n), key)
        end
      end
    end
  end

  defp with_unread(n, count, as_of \\ ~U[2026-10-10 15:00:00.123456Z]),
    do: %Notification{n | unread_count: count, unread_as_of: as_of}

  describe "per-install unread and thread ids (task 01a1261e)" do
    test "APNs carries unread_count as an integer and unread_as_of as ISO-8601" do
      [_, mention | _] = every_kind()
      apns = Notification.to_apns_payload(with_unread(mention, 7))

      assert apns["unread_count"] == 7
      assert apns["unread_as_of"] == "2026-10-10T15:00:00.123456Z"

      refute Map.has_key?(apns["aps"], "badge"),
             "the app sums the badge, the server never sets it"
    end

    test "FCM data carries both as strings, and a zero count survives as \"0\"" do
      [_, mention | _] = every_kind()

      data = Notification.to_fcm_payload(with_unread(mention, 0))["data"]
      assert data["unread_count"] == "0"
      assert data["unread_as_of"] == "2026-10-10T15:00:00.123456Z"
    end

    test "with no count stamped, neither key appears on any transport" do
      for n <- every_kind() do
        apns = Notification.to_apns_payload(n)
        data = Notification.to_fcm_payload(n)["data"]

        refute Map.has_key?(apns, "unread_count")
        refute Map.has_key?(apns, "unread_as_of")
        refute Map.has_key?(data, "unread_count")
        refute Map.has_key?(data, "unread_as_of")
      end
    end

    test "web push never carries the count" do
      [_, mention | _] = every_kind()
      web = Notification.to_web_payload(with_unread(mention, 4))

      refute Map.has_key?(web, :unread_count)
      refute Map.has_key?(web, :unread_as_of)
    end

    test "the APNs thread id is prefixed with install_host; web and FCM keep the bare id" do
      s = space()
      n = AttentionRouter.push_notification("Sam", message("x"), :mention, s, [])
      n = %Notification{n | install_host: "suite-b.localhost"}

      assert Notification.to_apns_payload(n)["aps"]["thread-id"] == "suite-b.localhost:" <> s.id
      assert Notification.to_web_payload(n).thread_id == s.id
      assert Notification.to_fcm_payload(n)["data"]["thread_id"] == s.id

      approvals = %Notification{
        Notification.from_inbox_item(inbox_item("task_plan_review"))
        | install_host: "suite-b.localhost"
      }

      assert Notification.to_apns_payload(approvals)["aps"]["thread-id"] ==
               "suite-b.localhost:approvals"
    end

    test "two installs' threads for the same space id never collide on APNs" do
      s = space()
      n = AttentionRouter.push_notification("Sam", message("x"), :mention, s, [])

      a = Notification.to_apns_payload(%Notification{n | install_host: "suite-a.localhost"})
      b = Notification.to_apns_payload(%Notification{n | install_host: "suite-b.localhost"})

      refute a["aps"]["thread-id"] == b["aps"]["thread-id"]
    end

    test "no install host leaves the bare thread id; no thread leaves no thread-id" do
      n = Notification.new(%{kind: "chat_mention", title: "t", space_id: "s1", install_host: nil})
      n = %Notification{n | install_host: nil}
      assert Notification.to_apns_payload(n)["aps"]["thread-id"] == "s1"

      generic = Notification.from_map(%{title: "a", body: "b", url: "/"})
      refute Map.has_key?(Notification.to_apns_payload(generic)["aps"], "thread-id")
    end
  end
end

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
      Tenancy.mark_membership_external(%{user_id: user.id, org_id: TenancyFixtures.fabrikam_org_id()})

    user
  end

  defp space do
    %Space{
      id: Ecto.UUID.generate(),
      name: "Internal Fabrikam SXI",
      slug: "internal-fabrikam-sxi"
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
      AttentionRouter.push_notification("Harper", message("hi @[Marlowe]"), :mention, space(), []),
      AttentionRouter.push_notification("Harper", message("ambient"), :all, space(), []),
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
    assert web[:thread_id] == apns["aps"]["thread-id"], "thread differs for #{n.kind}"

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

  describe "categories and grouping" do
    test "a mention gets SUITE_MENTION and is grouped by its space" do
      s = space()
      n = AttentionRouter.push_notification("Harper", message("x"), :mention, s, [])

      assert n.category == "SUITE_MENTION"
      assert n.thread_id == s.id
      assert n.url == "/chat/internal-fabrikam-sxi?message=#{n.message_id}"
      assert n.space_id == s.id
    end

    # A DM has no slug (prod: kind=dm, slug NULL). A slug-only url collapsed
    # to "/chat", and Open landed on the first channel, not the DM.
    test "a mention in a slug-less DM links to that DM and its message, never bare /chat" do
      dm = %Space{id: Ecto.UUID.generate(), name: nil, kind: "dm", slug: nil}
      msg = message("ping")
      n = AttentionRouter.push_notification("Harper", msg, :mention, dm, [])

      assert n.url == "/chat/#{dm.id}?message=#{msg.id}"
      assert Notification.to_apns_payload(n)["url"] == n.url
    end

    test "an org-scoped space links by id, matching the web app's space_path_segment" do
      s = %Space{space() | org_id: Ecto.UUID.generate()}
      msg = message("x")
      n = AttentionRouter.push_notification("Harper", msg, :mention, s, [])

      assert n.url == "/chat/#{Platform.Chat.space_path_segment(s)}?message=#{msg.id}"
      assert n.url == "/chat/#{s.id}?message=#{msg.id}"
    end

    test "plan and review requests share one Approvals group with SUITE_OPEN" do
      for kind <- ~w(task_plan_review review_request_pending) do
        n = Notification.from_inbox_item(inbox_item(kind))
        assert n.category == "SUITE_OPEN"
        assert n.thread_id == "approvals"
        assert Notification.to_apns_payload(n)["aps"]["thread-id"] == "approvals"
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
      n = AttentionRouter.push_notification("Harper", message("x"), :mention, space(), [])
      assert n.title == "Harper in Internal Fabrikam SXI"
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
               "**Heads up** @[Marlowe Smith], see [the doc](https://x.test/a)"
             ) ==
               "Heads up @Marlowe Smith, see the doc"

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
end

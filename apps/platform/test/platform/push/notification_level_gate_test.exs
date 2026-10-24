defmodule Platform.Push.NotificationLevelGateTest do
  @moduledoc """
  Task 01a1557a-e538 stage 1: the notification-level gate in `Platform.Push`.

  `permitted?/2` is pure; both send functions apply it to a USER recipient
  right after the archived-user branch and before any subscription read,
  and emit `[:platform, :push, :notification_level]` on both branches.
  """

  # async: false: the telemetry handlers below are global.
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox.Item
  alias Platform.Push
  alias Platform.Push.Notification
  alias Platform.Repo

  # ── Every kind the codebase emits ─────────────────────────────────────────

  # Producers that build a `%Notification{}` with a literal kind
  # (`Notification.new(%{kind: "..."})`), found by scanning lib/.
  defp scanned_new_kinds do
    Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__))
    |> Enum.flat_map(fn path ->
      ~r/Notification\.new\(%\{\s*kind:\s*"([a-z_]+)"/
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> List.flatten()
    end)
    |> Enum.uniq()
  end

  # The full set: the chat builder's two kinds, the legacy-map kind, every
  # Inbox item kind (`Notification.from_inbox_item/1` carries `item.kind`),
  # and the literal `Notification.new/1` kinds.
  defp all_kinds do
    chat_mention =
      Notification.chat(%{reason: :mention, author: "A", app_name: "Burrow", content: "x"}).kind

    chat_message =
      Notification.chat(%{reason: :all, author: "A", app_name: "Burrow", content: "x"}).kind

    generic = Notification.from_map(%{title: "t", body: "b"}).kind

    Enum.uniq([chat_mention, chat_message, generic] ++ Item.kinds() ++ scanned_new_kinds())
  end

  describe "permitted?/2 over every emitted kind" do
    test "the kind list is non-empty and holds the known producers" do
      scanned = scanned_new_kinds()
      assert scanned != [], "the Notification.new scan found no producers: the regex is stale"
      assert "meeting_ring_waiting" in scanned

      kinds = all_kinds()
      assert "chat_mention" in kinds
      assert "chat_message" in kinds
      assert "generic" in kinds
      assert "task_plan_review" in kinds
      assert "insight_briefing" in kinds
      assert length(kinds) >= 10
    end

    test "direct permits only chat_mention; all and mentions permit every kind" do
      for kind <- all_kinds() do
        n = %Notification{kind: kind}

        assert Push.permitted?("direct", n) == (kind == "chat_mention"),
               "direct on #{kind}"

        assert Push.permitted?("all", n), "all on #{kind}"
        assert Push.permitted?("mentions", n), "mentions on #{kind}"
      end
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp insert_user(level) do
    n = System.unique_integer([:positive])
    prefs = if level, do: %{"notification_level" => level}, else: %{}

    Repo.insert!(%User{
      name: "Gate #{n}",
      email: "gate-#{n}@example.com",
      oidc_sub: "gate-#{n}",
      preferences: prefs
    })
  end

  defp user_participant(user) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Gate",
        slug: "gate-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp attach(event, tag) do
    handler_id = "level-gate-#{tag}-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, measurements, metadata, _cfg ->
          send(parent, {tag, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Statements against push_subscriptions issued by THIS process while `fun`
  # runs: how the test sees whether the gate came before any device read.
  defp subscription_reads(fun) do
    parent = self()
    handler_id = "level-gate-subs-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _e, _m, meta, _c ->
          if self() == parent and is_binary(meta[:query]) and meta[:query] =~ "push_subscriptions" do
            send(parent, {:subs_read, handler_id})
          end
        end,
        nil
      )

    try do
      capture_log(fun)
    after
      :telemetry.detach(handler_id)
    end

    count_msgs(handler_id, 0)
  end

  defp count_msgs(handler_id, n) do
    receive do
      {:subs_read, ^handler_id} -> count_msgs(handler_id, n + 1)
    after
      0 -> n
    end
  end

  defp message, do: Notification.new(%{kind: "chat_message", title: "t", body: "b"})
  defp mention, do: Notification.new(%{kind: "chat_mention", title: "t", body: "b"})

  # ── send_to_user/2 ────────────────────────────────────────────────────────

  describe "send_to_user/2 under level direct" do
    setup do
      attach([:platform, :push, :notification_level], :level)
      :ok
    end

    test "a chat_message is suppressed before any subscription read" do
      user = insert_user("direct")

      reads = subscription_reads(fn -> assert Push.send_to_user(user.id, message()) == :ok end)

      assert_received {:level, %{count: 1}, meta}

      assert meta == %{
               user_id: user.id,
               kind: "chat_message",
               level: "direct",
               decision: :suppressed
             }

      assert reads == 0
    end

    test "a chat_mention is sent and reaches the subscription read" do
      user = insert_user("direct")

      reads = subscription_reads(fn -> assert Push.send_to_user(user.id, mention()) == :ok end)

      assert_received {:level, %{count: 1},
                       %{decision: :sent, kind: "chat_mention", level: "direct"}}

      # Positive control for the zero above: the sent branch does read devices.
      assert reads >= 1
    end

    test "a legacy map (kind generic) is suppressed; the default level sends it" do
      direct = insert_user("direct")
      default = insert_user(nil)

      capture_log(fn ->
        Push.send_to_user(direct.id, %{title: "t", body: "b", url: "/x"})
        Push.send_to_user(default.id, %{title: "t", body: "b", url: "/x"})
      end)

      direct_id = direct.id
      default_id = default.id
      assert_received {:level, _, %{user_id: ^direct_id, kind: "generic", decision: :suppressed}}
      assert_received {:level, _, %{user_id: ^default_id, level: "mentions", decision: :sent}}
    end

    test "the debug line names the decision and never the title or body" do
      user = insert_user("direct")
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          Push.send_to_user(
            user.id,
            Notification.new(%{kind: "chat_message", title: "SECRET-TITLE", body: "SECRET-BODY"})
          )
        end)

      assert log =~
               "[Push] notification_level user_id=#{user.id} kind=chat_message level=direct decision=suppressed"

      refute log =~ "SECRET-TITLE"
      refute log =~ "SECRET-BODY"
    end
  end

  # ── send_notification/2 ───────────────────────────────────────────────────

  describe "send_notification/2 with a USER participant row" do
    setup do
      attach([:platform, :push, :notification_level], :level)
      :ok
    end

    test "under level direct: chat_message suppressed, chat_mention sent" do
      user = insert_user("direct")
      p = user_participant(user)

      suppressed_reads =
        subscription_reads(fn -> assert Push.send_notification(p.id, message()) == :ok end)

      assert_received {:level, %{count: 1}, meta}

      assert meta == %{
               user_id: user.id,
               kind: "chat_message",
               level: "direct",
               decision: :suppressed
             }

      assert suppressed_reads == 0

      sent_reads =
        subscription_reads(fn -> assert Push.send_notification(p.id, mention()) == :ok end)

      assert_received {:level, %{count: 1},
                       %{decision: :sent, kind: "chat_mention", user_id: uid}}

      assert uid == user.id
      assert sent_reads >= 1
    end

    test "an agent participant is never gated" do
      {:ok, space} =
        Chat.create_space(%{
          name: "Gate",
          slug: "gate-a-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      agent =
        Repo.insert!(%Platform.Agents.Agent{
          slug: "gate-agent-#{System.unique_integer([:positive])}",
          name: "Gate Agent",
          status: "active"
        })

      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      reads = subscription_reads(fn -> assert Push.send_notification(p.id, message()) == :ok end)

      refute_received {:level, _, _}
      assert reads >= 1
    end
  end

  # ── archived users ────────────────────────────────────────────────────────

  describe "an archived user" do
    setup do
      attach([:platform, :push, :notification_level], :level)
      attach([:platform, :push, :suppressed_archived_user], :archived)
      :ok
    end

    test "takes the archived branch first, in both send functions" do
      user = insert_user("direct")
      p = user_participant(user)
      {:ok, _} = Accounts.archive_user(user)

      capture_log(fn ->
        assert Push.send_to_user(user.id, mention()) == :ok
        assert Push.send_notification(p.id, mention()) == :ok
      end)

      uid = user.id
      pid = p.id
      assert_received {:archived, %{count: 1}, %{user_id: ^uid}}
      assert_received {:archived, %{count: 1}, %{participant_id: ^pid}}
      refute_received {:level, _, _}
    end
  end
end

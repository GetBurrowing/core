defmodule PlatformWeb.Components.InboxItemKindLabelTest do
  @moduledoc """
  ONE kind-label table (redesign rung 14 stage 3): `InboxItem.kind_label/2`
  holds the desktop (`:long`) and phone (`:short`) forms side by side, and
  `PlatformWeb.Inbox.InboxList` keeps no map of its own.
  """
  use ExUnit.Case, async: true

  alias Platform.Inbox.Item
  alias PlatformWeb.Components.InboxItem
  alias PlatformWeb.Inbox.InboxList

  # The desktop labels as they rendered before the fold (inbox_item.ex on
  # 567443e8c: five explicit clauses, the humanizing fallback for the rest,
  # "Notification" for a non-string).
  @desktop %{
    "review_request_pending" => "Review requested",
    "task_plan_review" => "Plan needs review",
    "chat_mention" => "Mention",
    "meeting_starting" => "Meeting starting",
    "meeting_invited" => "Meeting invite",
    "task_sponsor_assigned" => "Task sponsor assigned",
    "lifecycle_step_failed" => "Lifecycle step failed",
    # Main's briefing kind (task 01a15ee1), humanized there: "Briefing".
    "briefing" => "Briefing",
    # Main's meeting briefing kind (task 01a1694a), humanized there too.
    "meeting_briefing" => "Meeting briefing"
  }

  describe "desktop labels are unchanged" do
    test "one desktop label per core kind" do
      # Positive control: the pin covers every core kind.
      assert Enum.sort(Map.keys(@desktop)) == Enum.sort(Item.core_kinds())

      for {kind, label} <- @desktop do
        assert InboxItem.kind_label(kind) == label, kind
      end

      assert InboxItem.kind_label(nil) == "Notification"
      assert InboxItem.kind_label("some_future_kind") == "Some future kind"
    end
  end

  describe "one table, two forms" do
    test "every labelled kind and every known kind yields both forms" do
      assert Enum.sort(InboxItem.labelled_kinds()) == Enum.sort(Item.core_kinds())

      kinds = Enum.uniq(InboxItem.labelled_kinds() ++ Item.kinds())

      for kind <- kinds, form <- [:long, :short] do
        label = InboxItem.kind_label(kind, form)
        assert String.trim(label) != "", "#{kind} #{form}"
      end

      assert InboxItem.kind_label("meeting_starting", :short) == "Starting now"
      assert InboxItem.kind_label("lifecycle_step_failed", :short) == "Step failed"
    end

    test "the phone kind word is the table's short form, for every kind" do
      for kind <- Item.kinds() do
        assert InboxList.kind_word(kind) == InboxItem.kind_label(kind, :short), kind
      end
    end

    test "InboxList keeps no kind-keyed map of its own" do
      src = File.read!(Path.expand("../../../lib/platform_web/live/inbox/inbox_list.ex", __DIR__))
      # Anti-vacuity: the file was read and is the phone list.
      assert src =~ "inbox-phone"

      for kind <- Item.core_kinds() do
        refute src =~ ~r/"#{kind}"\s*=>/, "inbox_list.ex maps #{kind} itself"
      end

      refute src =~ "@kind_words"
    end
  end
end

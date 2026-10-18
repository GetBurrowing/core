defmodule Platform.Chat.MentionBackfillTest do
  @moduledoc "Tests the rewrite logic used by `Platform.Chat.MentionBackfill.run/1`."
  use ExUnit.Case, async: true

  alias Platform.Chat.MentionBackfill

  defp roster(entries) do
    Enum.map(entries, fn {display_name, participant_id} ->
      %{display_name: display_name, participant_id: participant_id}
    end)
  end

  describe "rewrite_content/2" do
    test "rewrites single-word legacy mention to bracketed" do
      r = roster([{"Zip", "agent-1"}])
      assert MentionBackfill.rewrite_content("hey @zip", r) == "hey @[Zip]"
    end

    test "rewrites multi-word legacy mention with space in display name" do
      r = roster([{"Alex Rivera", "usr-1"}])

      assert MentionBackfill.rewrite_content("hi @Alex Rivera!", r) ==
               "hi @[Alex Rivera]!"
    end

    test "prefers longest match when shorter name is a prefix" do
      r = roster([{"Alex", "usr-1"}, {"Alex Rivera", "usr-2"}])

      assert MentionBackfill.rewrite_content("@Alex Rivera hi", r) ==
               "@[Alex Rivera] hi"

      assert MentionBackfill.rewrite_content("@Alex hey", r) == "@[Alex] hey"
    end

    test "canonicalizes casing from the roster display name" do
      r = roster([{"Mycroft", "agent-mycroft"}])
      assert MentionBackfill.rewrite_content("@mycroft here", r) == "@[Mycroft] here"
    end

    test "leaves bare @ without a matching roster entry untouched" do
      r = roster([{"Zip", "agent-1"}])

      assert MentionBackfill.rewrite_content("ping @nobody please", r) ==
               "ping @nobody please"
    end

    test "does not trigger on mid-word @ (e.g. email addresses)" do
      r = roster([{"example", "usr-1"}])

      assert MentionBackfill.rewrite_content("email me at foo@example.com", r) ==
               "email me at foo@example.com"
    end

    test "preserves trailing non-word characters like punctuation" do
      r = roster([{"Alex", "usr-1"}])
      assert MentionBackfill.rewrite_content("sup @Alex?", r) == "sup @[Alex]?"
      assert MentionBackfill.rewrite_content("@Alex, hi", r) == "@[Alex], hi"
    end

    test "respects word boundary: @Ryans does not match Alex" do
      r = roster([{"Alex", "usr-1"}])

      assert MentionBackfill.rewrite_content("happy @Ryans party", r) ==
               "happy @Ryans party"
    end

    test "rewrites multiple mentions in one message" do
      r = roster([{"Zip", "agent-1"}, {"Nova", "agent-2"}])

      assert MentionBackfill.rewrite_content("@zip and @nova help", r) ==
               "@[Zip] and @[Nova] help"
    end

    test "matches by participant_id when display_name is absent from content" do
      r = [%{display_name: "Alex", participant_id: "alex-slug"}]
      assert MentionBackfill.rewrite_content("@alex-slug hi", r) == "@[Alex] hi"
    end

    test "handles empty roster gracefully" do
      assert MentionBackfill.rewrite_content("@alice @bob", []) == "@alice @bob"
    end

    test "handles nil / non-string content gracefully" do
      assert MentionBackfill.rewrite_content(nil, roster([{"A", "1"}])) == nil
    end
  end

  describe "module existence" do
    test "release-callable module is defined" do
      assert Code.ensure_loaded?(Platform.Chat.MentionBackfill)
      assert function_exported?(Platform.Chat.MentionBackfill, :run, 0)
      assert function_exported?(Platform.Chat.MentionBackfill, :run, 1)
    end

    test "mix task shim is defined" do
      assert Code.ensure_loaded?(Mix.Tasks.Platform.BackfillMentions)
    end
  end
end

defmodule Platform.Memory.Insights.ParserTest do
  @moduledoc "Task 01a13867 stage 1: the `<synthesis-insight>` grammar and each skip rule."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Memory.Insights.Parser

  defp block(attrs, body), do: "<synthesis-insight #{attrs}>#{body}</synthesis-insight>"

  test "parses every attribute in any order and hashes the trimmed body" do
    content =
      block(
        ~s(source="page:org/page/a.md" confidence="high" action="briefing" evidence="e1" addressee="ops" target="org/page/a.md"),
        "\n  The body.\n"
      )

    assert [parsed] = Parser.parse(content)
    assert parsed.action_type == "briefing"
    assert parsed.confidence == "high"
    assert parsed.evidence == "e1"
    assert parsed.source_ref == "page:org/page/a.md"
    assert parsed.body == "The body."
    assert parsed.block_hash == Parser.hash("The body.")
    assert parsed.action == %{"target" => "org/page/a.md", "addressee" => "ops"}
  end

  test "a page_edit lifts its hunks, in order, into the action map" do
    body = """
    The rate limit doubled.
    <old>limit is 50</old>
    <new>limit is 100</new>
    <old>since May</old><new>since October</new>
    """

    assert [parsed] =
             Parser.parse(
               block(~s(action="page_edit" confidence="high" target="org/page/x.md"), body)
             )

    assert parsed.action["hunks"] == [
             %{"old" => "limit is 50", "new" => "limit is 100"},
             %{"old" => "since May", "new" => "since October"}
           ]

    assert parsed.body =~ "<old>limit is 50</old>"
  end

  test "all four action types parse" do
    for action <- ~w(briefing question task) do
      assert [%{action_type: ^action}] =
               Parser.parse(block(~s(action="#{action}" confidence="low"), "b"))
    end
  end

  describe "skips with a warning" do
    test "an unknown action" do
      log =
        capture_log(fn ->
          assert [] = Parser.parse(block(~s(action="memo" confidence="high"), "b"))
        end)

      assert log =~ "invalid action"
    end

    test "a missing action" do
      log = capture_log(fn -> assert [] = Parser.parse(block(~s(confidence="high"), "b")) end)
      assert log =~ "missing action"
    end

    test "a missing confidence" do
      log = capture_log(fn -> assert [] = Parser.parse(block(~s(action="briefing"), "b")) end)
      assert log =~ "missing confidence"
    end

    test "an unknown confidence" do
      log =
        capture_log(fn ->
          assert [] = Parser.parse(block(~s(action="briefing" confidence="certain"), "b"))
        end)

      assert log =~ "invalid confidence"
    end

    test "an empty body" do
      log =
        capture_log(fn ->
          assert [] = Parser.parse(block(~s(action="briefing" confidence="high"), "  \n "))
        end)

      assert log =~ "empty body"
    end

    test "a page_edit without a hunk" do
      log =
        capture_log(fn ->
          assert [] =
                   Parser.parse(block(~s(action="page_edit" confidence="high"), "Fix the page."))
        end)

      assert log =~ "page_edit without"
    end

    test "a page_edit with only half a hunk" do
      capture_log(fn ->
        assert [] =
                 Parser.parse(
                   block(~s(action="page_edit" confidence="high"), "<old>x</old> only")
                 )
      end)
    end
  end

  test "a malformed block does not stop the next one" do
    content =
      block(~s(action="memo" confidence="high"), "bad") <>
        block(~s(action="task" confidence="high"), "good")

    capture_log(fn -> assert [%{body: "good"}] = Parser.parse(content) end)
  end

  test "nil and prose yield nothing" do
    assert Parser.parse(nil) == []
    assert Parser.parse("just prose") == []
  end
end

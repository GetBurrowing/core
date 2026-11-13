defmodule Platform.Chat.GroupMentionTokenTest do
  use ExUnit.Case, async: true
  alias Platform.Chat.GroupMentionToken, as: Token
  @id "019f1234-1234-7123-8123-123456789abc"
  test "stable identity and written label round trip; duplicates collapse" do
    token = Token.encode(@id, "Design team")
    assert token == "@[group:#{@id}|Design team]"
    assert Token.parse(token <> " " <> token) == [%{id: @id, name: "Design team"}]
    assert Token.strip("hi " <> token <> " @[Alice]") == "hi  @[Alice]"
  end
  test "malformed namespace tokens are stripped but never parsed" do
    text = "@[group:not-a-uuid|Alice] @[group:broken] @[Alice]"
    assert Token.parse(text) == []
    assert Token.strip(text) == "  @[Alice]"
  end
  test "labels may contain pipes but cannot introduce nested mentions or line breaks" do
    assert Token.parse(Token.encode(@id, "People | Design")) == [%{id: @id, name: "People | Design"}]
    for name <- ["", " ", "Team\nOps", "@[Alice]"] do
      assert_raise ArgumentError, fn -> Token.encode(@id, name) end
    end
    assert Token.parse("@[group:#{@id}| ]") == []
  end
end

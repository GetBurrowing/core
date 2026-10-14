defmodule Platform.AgentHost.RedactTest do
  @moduledoc """
  What "Recent output" may show of a native agent's pane (task 01a10322
  stage 6). The agent host applies the same rules first
  (`services/agent-host/src/pane.ts`); core applies them again, so this pass
  must be idempotent over the host's output.
  """
  use ExUnit.Case, async: true

  alias Platform.AgentHost.Redact

  test "a login screen is withheld whole, whatever the host said" do
    for line <- [
          " Select login method:",
          " Paste code here if prompted >",
          "https://claude.com/cai/oauth/authorize?code=true&state=x",
          "  Detected a custom API key in your environment"
        ] do
      assert Redact.pane(%{"lines" => ["ok", line], "hidden" => nil}) == %{
               lines: [],
               hidden: :login
             }
    end

    assert Redact.pane(%{"lines" => ["anything"], "hidden" => "login"}) == %{
             lines: [],
             hidden: :login
           }
  end

  test "ordinary lines pass, scrubbed (positive control)" do
    assert Redact.pane(%{
             "lines" => [
               "hello",
               "key sk-ant-api03-abcDEF_123 here",
               "export ANTHROPIC_API_KEY=whatever",
               "CLAUDE_CODE_OAUTH_TOKEN: tok",
               "Authorization: Bearer abc.def",
               "https://example.com/cb?code=abc&x=1",
               7
             ]
           }) == %{
             lines: [
               "hello",
               "key sk-ant-[redacted] here",
               "export ANTHROPIC_API_KEY=[redacted]",
               "CLAUDE_CODE_OAUTH_TOKEN: [redacted]",
               "Authorization: Bearer [redacted]",
               "https://example.com/cb?code=[redacted]&x=1"
             ],
             hidden: nil
           }
  end

  test "scrubbing is idempotent: the host's output is not scrubbed twice over" do
    once = Redact.line("sk-ant-api03-abc ANTHROPIC_API_KEY=x Bearer y https://e.com/?code=z")
    assert Redact.line(once) == once

    assert once ==
             "sk-ant-[redacted] ANTHROPIC_API_KEY=[redacted] Bearer [redacted] https://e.com/?code=[redacted]"
  end

  test "lines are capped" do
    out = Redact.lines(Enum.map(1..300, &"l#{&1}") ++ [String.duplicate("x", 900)])
    assert length(out) == 200
    assert String.length(List.last(out)) == 500
  end
end

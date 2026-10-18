defmodule Platform.Meetings.SummaryPromptTest do
  @moduledoc """
  The summarizer system prompt is served to the model from code. Task
  01a14b9e stage 3 made its assignee example a neutral placeholder name;
  these asserts pin the literal and check the whole prompt with the
  install-identity scanner.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.SummaryPrompt
  alias Platform.Regression.InstallIdentityScanner, as: Scanner

  test "the assignee example uses a placeholder name" do
    assert SummaryPrompt.system_prompt() =~
             ~s{- Include the assignee if identifiable from speaker names (e.g., "Sam will...")}
  end

  test "the prompt carries no install-identity hit" do
    assert Scanner.hits(SummaryPrompt.system_prompt()) == []
  end
end

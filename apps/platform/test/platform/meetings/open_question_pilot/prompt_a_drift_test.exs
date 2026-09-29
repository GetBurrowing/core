defmodule Platform.Meetings.OpenQuestionPilot.PromptADriftTest do
  @moduledoc """
  Arm A's prompt (`priv/imp_pilot/open_question/prompt_a.txt`) is a COPY of
  the latest force-update heredoc for `meetings.intent_classify.v1`
  (migration 20260911030000). It must stay byte-identical to what that
  migration wrote. The migrated row is read from the test database, which
  every migration has run against. That row is the migration's output, NOT
  the live production row, which the pilot never reads. The recorded
  sha256 in `arm_a.json` must match the file.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Meetings.OpenQuestionPilot.Runner
  alias Platform.Orchestration.PromptTemplates

  test "prompt_a.txt is byte-identical to the migrated meetings.intent_classify.v1 row" do
    %{content: row} = PromptTemplates.get_template_by_slug("meetings.intent_classify.v1")
    file = File.read!(Path.join(Programs.dir(), "prompt_a.txt"))

    assert file == row,
           "prompt_a.txt (#{byte_size(file)} bytes) drifted from the migrated row " <>
             "(#{byte_size(row)} bytes); re-copy it and update arm_a.json's sha256"
  end

  test "arm_a.json records the prompt's sha256 and the loader checks it" do
    config = Runner.arm_a_config()

    assert config["prompt_sha256"] ==
             :crypto.hash(:sha256, config["template"]) |> Base.encode16(case: :lower)

    assert config["prompt_bytes"] == byte_size(config["template"])
  end
end

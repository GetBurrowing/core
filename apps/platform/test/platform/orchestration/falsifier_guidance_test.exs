defmodule Platform.Orchestration.FalsifierGuidanceTest do
  @moduledoc """
  Pins the falsifier-filing guidance on both AGENT-side carriers (task
  01a0a5f5 stage 2).

  Scope note, deliberately narrow: presence and placement of a falsifier are
  INSTRUCTION ONLY on every agent path. The MCP `task_create` / `task_update`
  body is free-form prose with no composer and no anchor, so nothing here can
  assert what a FILED ticket looks like — such a test would either exercise a
  filer that would have complied anyway, or nothing at all. Ordering is
  asserted against the stage-3 composer, where it is structural.

  Precedence note for anyone reading a failure here: these assertions are
  about the hardcoded DEFAULT. A variant beats the seeded row, and the row
  beats the constant — so green here does not mean an agent received this
  text. That is what the stage-4 force-update migration is for.
  """
  use ExUnit.Case, async: true

  alias Platform.Federation.ToolDoc
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.PromptTemplates

  # The header order as it stood BEFORE this task's insert. Downstream stack
  # members (scribe_completion, triage_dispatch) index these as stable
  # anchors, so the contract is order as well as presence.
  @pre_existing_headers [
    "## Execution posture — close the ticket",
    "## Finishing is the job",
    "## Subagent-spawn discipline",
    "## Organization Context",
    "## Writing to Org Memory",
    "## Skill discovery — do this BEFORE you start executing",
    "## Submitting evidence for a manual_approval validation",
    "## Tool-name conventions (dot vs underscore)"
  ]

  @new_header "## Filing a ticket — state its falsifier"

  defp preamble, do: PromptTemplates.default_content_for_slug("federation.preamble")

  describe "federation.preamble default content" do
    test "carries the falsifier header, the worked example, and the placement instruction" do
      content = preamble()

      assert content =~ @new_header
      assert content =~ "**State what would show this ticket is wrong.**"

      assert content =~
               "Name the observation — a grep that comes back empty, a status that differs, a test that passes —"

      assert content =~ "**Put it ABOVE the prescriptive content, not at the end.**"
      assert content =~ "`## Wrong`"
    end

    test "every pre-existing section header is still present AND in its prior relative order" do
      content = preamble()

      offsets =
        Enum.map(@pre_existing_headers, fn header ->
          case :binary.match(content, header) do
            {offset, _len} -> {header, offset}
            :nomatch -> flunk("anchor header missing from the preamble: #{header}")
          end
        end)

      # Assert the ORDER, not merely presence: a reordering that kept every
      # header would pass a presence-only check, and a reordering is exactly
      # what breaks the downstream anchor contract.
      assert offsets == Enum.sort_by(offsets, &elem(&1, 1)),
             "pre-existing headers are out of their prior relative order: " <>
               inspect(Enum.sort_by(offsets, &elem(&1, 1)))
    end

    test "the new section sits between 'Finishing is the job' and 'Subagent-spawn discipline'" do
      content = preamble()

      {finishing, _} = :binary.match(content, "## Finishing is the job")
      {new, _} = :binary.match(content, @new_header)
      {subagent, _} = :binary.match(content, "## Subagent-spawn discipline")

      assert finishing < new
      assert new < subagent
    end
  end

  defp rendered(name) do
    ToolSurface.tool_definitions()
    |> Enum.find(&(Map.get(&1, :name) == name))
    |> case do
      nil -> flunk("no tool descriptor named #{name}")
      tool -> ToolDoc.render_description(tool)
    end
  end

  describe "task tool descriptors, rendered" do
    # Rendered, not the raw `:description` field: `render_description/1` is
    # what `MCPController.to_mcp_tool/1` serves, and it folds `:returns` /
    # `:limitations` / `:when_to_use` in after the raw description. Asserting
    # the map field would leave the served text untested.
    test "task_create's RENDERED description requires a falsifier sentence and says where it goes" do
      text = rendered("task_create")

      assert text =~ "falsifier sentence"
      assert text =~ "OPEN the `description` body"
      assert text =~ "`## Wrong`"
      assert text =~ "stop and re-derive"
    end

    test "task_update's RENDERED description carries the same requirement for body writes" do
      text = rendered("task_update")

      assert text =~ "falsifier sentence"
      assert text =~ "`## Wrong`"
      assert text =~ "stop and re-derive"
    end
  end
end

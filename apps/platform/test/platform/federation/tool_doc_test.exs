defmodule Platform.Federation.ToolDocTest do
  @moduledoc """
  Task 01a08a0c stage 1 — the renderer, and specifically its DEGENERATE case.

  `Platform.Federation.ToolDoc.render_description/1` folds a tool's `returns`,
  `limitations` and `when_to_use` prose into the one string `tools/list`
  actually carries. The interesting failure is not "the prose is missing" —
  the wire test in `tool_doc_wire_test.exs` covers that across every tool. It
  is "a tool WITHOUT one of the fields gains a heading above nothing", which
  turns a fix into noise on every future tool that ships with two fields
  instead of three.

  ## Why every input here is a literal map

  THE NEGATIVE CONTROL DOES NOT EXIST IN THE TREE. All 104 entries of
  `ToolSurface.tool_definitions/0` carry all three fields non-blank (verified
  by anchored counts: 104 `name:`, 104 `returns:`, 104 `limitations:`, 104
  `when_to_use:`). There is no blank-field tool to point the renderer at, so
  the blank cases are CONSTRUCTED. `render_description/1` is public precisely
  so they can be — `to_mcp_tool/1` is private and would force this through a
  transport that has no such tool to serve.

  The assertion in each blank case is BYTE IDENTITY with the input
  description, not "does not contain a heading". Identity also catches a
  trailing `\\n\\n` separator, which "no heading" would miss and which is the
  more likely bug: the separator and the heading are emitted by different
  expressions.
  """
  use ExUnit.Case, async: true

  alias Platform.Federation.ToolDoc
  alias Platform.Federation.ToolSurface

  @description "Read a task's execution leases, newest first."
  @returns "A list of lease rows with `status`, `holder` and `expires_at`."
  @limitations "AN EMPTY LIST IS A LEGITIMATE ANSWER FOR A LIVE, HEALTHY TASK."
  @when_to_use "When a stage looks stalled and you need to know who holds it."

  describe "blank, nil and absent fields emit nothing" do
    test "an empty-string limitations produces a byte-identical description" do
      out = ToolDoc.render_description(%{description: @description, limitations: ""})

      assert out == @description
      refute out =~ "Limitations:"
    end

    test "a nil limitations produces a byte-identical description" do
      out = ToolDoc.render_description(%{description: @description, limitations: nil})

      assert out == @description
      refute out =~ "Limitations:"
    end

    test "a whitespace-only field produces a byte-identical description" do
      out =
        ToolDoc.render_description(%{
          description: @description,
          returns: "   ",
          limitations: "\n\n",
          when_to_use: "\t"
        })

      assert out == @description

      for heading <- ToolDoc.headings() do
        refute out =~ heading, "a whitespace-only field emitted #{heading}"
      end
    end

    test "a map carrying only a description produces a byte-identical description" do
      out = ToolDoc.render_description(%{description: @description})

      assert out == @description

      for heading <- ToolDoc.headings() do
        refute out =~ heading, "an absent field emitted #{heading}"
      end
    end

    # A blank field must not take its NEIGHBOURS down with it. Without this,
    # `render_description/1` could satisfy every test above by returning the
    # description unchanged in all cases — which is exactly the identity
    # passthrough this stage started from, and it is green on the four tests
    # above.
    test "a blank field is skipped while its non-blank siblings still render" do
      out =
        ToolDoc.render_description(%{
          description: @description,
          returns: @returns,
          limitations: "",
          when_to_use: @when_to_use
        })

      assert out =~ "Returns: " <> @returns
      assert out =~ "When to use: " <> @when_to_use
      refute out =~ "Limitations:"
    end
  end

  describe "a full definition" do
    test "keeps the original description first and unmodified, then all three blocks" do
      out =
        ToolDoc.render_description(%{
          description: @description,
          returns: @returns,
          limitations: @limitations,
          when_to_use: @when_to_use
        })

      assert String.starts_with?(out, @description)

      assert out =~ "Returns: " <> @returns
      assert out =~ "Limitations: " <> @limitations
      assert out =~ "When to use: " <> @when_to_use

      # Fixed order, and it is asserted by POSITION rather than by presence —
      # "all three appear" is satisfied by any permutation.
      returns_at = :binary.match(out, "Returns:") |> elem(0)
      limitations_at = :binary.match(out, "Limitations:") |> elem(0)
      when_at = :binary.match(out, "When to use:") |> elem(0)

      assert returns_at < limitations_at
      assert limitations_at < when_at

      refute String.ends_with?(out, "\n")
    end

    test "a real ToolSurface definition round-trips its own four fields" do
      # POSITIVE CONTROL for the literal maps above: the shape the renderer is
      # handed in production is a real definition map, not a hand-written one,
      # and the field names have to match. A typo'd key would leave every test
      # above green — they would just be rendering a map with no `:returns`.
      definition = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "task_get"))
      assert definition, "task_get missing from the tool surface"

      out = ToolDoc.render_description(definition)

      assert String.starts_with?(out, definition.description)
      assert out =~ definition.returns
      assert out =~ definition.limitations
      assert out =~ definition.when_to_use
      assert byte_size(out) > byte_size(definition.description)
    end
  end
end

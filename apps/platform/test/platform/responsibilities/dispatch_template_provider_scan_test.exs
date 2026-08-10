defmodule Platform.Responsibilities.DispatchTemplateProviderScanTest do
  @moduledoc """
  The durable guard from task `019fe844`: a dispatch template may not
  instruct an agent to obtain something whose handler is a stub.

  ## The class of defect, not the instance

  The instance was `design.critique`: the reviewer dispatch template told
  every reviewer to "obtain Saru's design review", and the handler behind
  that responsibility returned `%{missing?: true}` from `gather_context/2`
  and logged a placeholder warning instead of dispatching. Four reviewers
  read that instruction; four produced different outcomes; one filed a gate
  recording that no design review had been obtained, minutes before a
  critique arrived containing a finding the reviewer had missed. An
  instruction that cannot be followed is worse than no instruction, because
  it is satisfied by whoever is in the biggest hurry.

  Fixing that one handler does not stop it recurring. So this scan is keyed
  to the CLASS: for every `design.*` / `architecture.*` responsibility key
  named in any prompt template body, the key's handler must return real
  context — never a map carrying a `missing?` marker.

  ## What passes today, and why that is not reassuring on its own

  `design.spec_writer` and `design.brand_check` are still stubs. They pass
  this scan today ONLY because no template references them: they are
  inert-but-harmless rather than a live false promise, and fixing them was
  deliberately left out of scope. What this scan changes is the cost of
  referencing them — the moment any template body names either key, this
  test fails the build, and the choice becomes "implement the handler" or
  "do not write the instruction" rather than "ship the instruction and hope".

  ## The scan is shown to bite

  A scan that passes because it matched nothing is the exact failure mode
  this whole ticket is about. `"the scan detonates on a stub key"` below
  runs the same predicate against a synthetic template body naming
  `design.spec_writer` and asserts it reports a violation. If that test
  ever goes green-by-vacuity, so has the real one.

  Sibling guard on a different axis: `chat_trigger_names_a_role_test.exs`
  asserts no chat trigger regex names an agent handle (naming); this one
  asserts no dispatch template names a stub-backed key (reachability).
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Providers

  # Dotted keys in the two features that own agent-facing review work.
  @key_pattern ~r/\b((?:design|architecture)\.[a-z_]+)\b/

  describe "prompt templates only name responsibilities with real handlers" do
    test "no template names a responsibility whose gather_context/2 is a stub" do
      keys = keys_named_in_templates()

      # Anti-vacuity: if this scan matches nothing it proves nothing. The
      # reviewer template names `design.critique`, so zero matches means
      # the extraction broke, not that the tree is clean.
      refute keys == [],
             "the scan matched no responsibility keys at all — extraction is broken, " <>
               "not the tree clean"

      assert "design.critique" in keys,
             "expected the reviewer dispatch template to still name design.critique; " <>
               "got #{inspect(keys)}"

      violations = Enum.filter(keys, &stub_context?/1)

      assert violations == [],
             """
             These responsibility keys are named in a prompt template body but their
             handler's gather_context/2 still returns a stub marker:

               #{Enum.join(violations, "\n  ")}

             A dispatch template must not instruct an agent to obtain something no
             handler can produce. Either implement the handler or delete the
             instruction — see the moduledoc.
             """
    end

    test "the scan detonates on a stub key" do
      # The proof that the assertion above can fail. `design.spec_writer`
      # is a real registered responsibility with a real stub handler; it
      # escapes the scan today only because no template names it.
      synthetic = "Before the gate, obtain the design.spec_writer output for this surface."

      keys = extract_keys(synthetic)
      assert keys == ["design.spec_writer"]

      assert Enum.filter(keys, &stub_context?/1) == ["design.spec_writer"],
             "the stub predicate did not fire on a known stub handler — the scan " <>
               "above would pass over a real regression"
    end
  end

  # ── Scan internals ────────────────────────────────────────────────────────

  defp keys_named_in_templates do
    PromptTemplates.default_templates()
    |> Enum.flat_map(&extract_keys(Map.get(&1, :content, "")))
    |> Enum.uniq()
    |> Enum.filter(&(handler_for(&1) != nil))
    |> Enum.sort()
  end

  defp extract_keys(body) when is_binary(body) do
    @key_pattern
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&(handler_for(&1) != nil))
    |> Enum.sort()
  end

  defp extract_keys(_), do: []

  defp handler_for("design." <> _ = key), do: Providers.Design.handler_for(key)
  defp handler_for("architecture." <> _ = key), do: Providers.Architecture.handler_for(key)
  defp handler_for(_), do: nil

  # A handler is a stub when its gathered context carries a `missing?`
  # marker anywhere. An `{:error, _}` return is NOT a stub: refusing to
  # dispatch on unresolvable input is the correct behaviour and is exactly
  # what `design.critique` does now when no canvas resolves.
  defp stub_context?(key) do
    handler = handler_for(key)
    responsibility = responsibility_for(handler, key)

    case safe_gather(handler, responsibility) do
      {:ok, context} when is_map(context) -> marks_missing?(context)
      _ -> false
    end
  end

  defp safe_gather(handler, responsibility) do
    handler.gather_context(responsibility, %{})
  rescue
    _ -> :raised
  catch
    _, _ -> :raised
  end

  # Registered rows are not guaranteed to be seeded in the test database,
  # and the scan must not silently pass because a row was absent — so the
  # struct is built from the handler's own registration spec.
  defp responsibility_for(handler, key) when is_atom(handler) and not is_nil(handler) do
    spec =
      handler.register()
      |> Enum.find(&(&1.key == key))

    struct(Platform.Responsibilities.Responsibility, spec || %{key: key})
  end

  defp marks_missing?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} ->
      key_is_missing_marker?(k) or marks_missing?(v)
    end)
  end

  defp marks_missing?(list) when is_list(list), do: Enum.any?(list, &marks_missing?/1)
  defp marks_missing?(_), do: false

  defp key_is_missing_marker?(:missing?), do: true
  defp key_is_missing_marker?("missing?"), do: true
  defp key_is_missing_marker?(_), do: false
end

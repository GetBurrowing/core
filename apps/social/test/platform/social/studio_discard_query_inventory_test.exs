defmodule Platform.Social.StudioDiscardQueryInventoryTest do
  use ExUnit.Case, async: true

  # Source inventory, not proof of query behavior: each explicit Studio-flow
  # comparison in this module must have a reviewed discard classification.
  test "Studio flow queries stay classified for discarded rows" do
    source = File.read!(Path.expand("../../../lib/platform/social/studio.ex", __DIR__))
    ast = Code.string_to_quoted!(source)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          name = function_name(head)

          {_body, count} =
            Macro.prewalk(body, 0, fn
              {:==, _, [lhs, "studio"]} = comparison, n ->
                if Macro.to_string(lhs) =~ ~r/\.flow$/,
                  do: {comparison, n + 1},
                  else: {comparison, n}

              other, n ->
                {other, n}
            end)

          {node, if(count > 0, do: [{name, count} | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    classifications = %{
      list_posts: {:exclude, 1},
      list_discarded_drafts: {:discarded_only, 1},
      discarded_render_reservations: {:discarded_only, 1},
      restore_destination_taken?: {:include, 1},
      existing_post: {:include, 1},
      render_destination_taken?: {:include, 1},
      no_duplicate_destination: {:include, 1}
    }

    counts =
      Enum.reduce(found, %{}, fn {name, count}, acc ->
        Map.update(acc, name, count, &(&1 + count))
      end)

    assert counts ==
             Map.new(classifications, fn {name, {_decision, count}} -> {name, count} end)
  end

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _}), do: name
end

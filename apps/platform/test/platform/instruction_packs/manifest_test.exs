defmodule Platform.InstructionPacks.ManifestTest do
  use ExUnit.Case, async: true
  import Platform.InstructionPackFixtures
  alias Platform.InstructionPacks.Manifest

  test "strict typed text and stable canonical bytes" do
    m = manifest()
    assert {:ok, ^m} = Manifest.validate(m)
    assert Manifest.canonical(m) == Manifest.canonical(Map.new(Enum.reverse(Map.to_list(m))))
    assert String.length(Manifest.digest(m)) == 64
  end

  test "reject unknown fields, unsupported types, paths, duplicates and excessive bounds" do
    e = hd(manifest()["entries"])

    bad = [
      Map.put(manifest(), "tools", []),
      manifest(%{"schema_version" => 2}),
      manifest(%{"entries" => [e, e]}),
      manifest(%{"entries" => List.duplicate(e, 101)}),
      manifest(%{"changelog" => String.duplicate("x", 4097)}),
      manifest(%{"version" => 2}),
      manifest(%{"published_at" => "not a time"}),
      manifest(%{"entries" => [%{e | "content" => <<255>>}]}),
      manifest(%{"entries" => [%{e | "content" => String.duplicate("x", 65_537)}]})
    ]

    bad =
      bad ++
        for type <-
              ~w(shell javascript python archive attachment executable_skill permissions tool_grants secrets sharing network_destination role_membership responsibility),
            do: manifest(%{"entries" => [%{e | "type" => type}]})

    bad =
      bad ++
        [
          manifest(%{"entries" => [%{e | "target" => "../../secret"}]}),
          manifest(%{"entries" => [Map.put(e, "hook", "run")]}),
          manifest(%{"entries" => []})
        ]

    for m <- bad, do: assert({:error, :invalid_manifest} = Manifest.validate(m))
  end
end

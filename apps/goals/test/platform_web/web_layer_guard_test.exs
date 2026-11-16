defmodule PlatformWeb.GoalsWebLayerGuardTest do
  @moduledoc """
  Source guards (task 01a1dfc1, Goals 4/8 stage 1):

    * the web layer (`apps/goals/lib/platform_web`) reads and writes only
      through `Platform.Goals` and core's public context functions: no Repo
      call, no query, no Goals schema alias;
    * no colour literal anywhere under `apps/goals/lib`: colours come only
      from the semantic token classes core's components use.

  Each scan has a positive control over planted text, so an empty result
  means the pattern could have hit.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)
  @web Path.join(@lib, "platform_web")

  @schemas ~w(Goal Stop Grant Entry Reading Proposal)
  @data_patterns [
    {:repo, ~r/\bRepo\./},
    {:ecto_query, ~r/\bEcto\.Query\b/},
    {:import_ecto, ~r/\bimport\s+Ecto\b/},
    {:goals_schema, ~r/\bPlatform\.Goals\.(#{Enum.join(@schemas, "|")})\b/},
    {:goals_schema_group,
     ~r/\balias\s+Platform\.Goals\.\{[^}]*\b(#{Enum.join(@schemas, "|")})\b[^}]*\}/s}
  ]

  @colour_patterns [
    {:hex, ~r/#[0-9a-fA-F]{3,8}\b/},
    {:rgb, ~r/\brgba?\(/i},
    {:hsl, ~r/\bhsla?\(/i},
    {:oklch, ~r/\boklch\(/i}
  ]

  # Goals 4/8 stage 2: the page reads the number straight from
  # `Platform.Goals.goal_number/2`; no reader layer, stand-in or stub.
  @number_patterns [
    {:number_reader, ~r/number_reader/},
    {:goals_number, ~r/GoalsNumber/},
    {:stub_module, ~r/defmodule\s+[\w.]*(Unfilled|Stub)\b/}
  ]

  defp hits(text, patterns),
    do: for({name, re} <- patterns, Regex.match?(re, text), do: name)

  defp scan(dir, patterns) do
    files = Path.wildcard(Path.join(dir, "**/*.{ex,exs,heex}"))
    found = for file <- files, hit <- hits(File.read!(file), patterns), do: {file, hit}
    {files, found}
  end

  describe "positive controls" do
    test "the data scan hits each pattern" do
      assert hits("Repo.all(q)", @data_patterns) == [:repo]
      assert hits("import Ecto.Query", @data_patterns) == [:ecto_query, :import_ecto]
      assert hits("import Ecto.Changeset", @data_patterns) == [:import_ecto]
      assert hits("x = Ecto.Query.from(g in y)", @data_patterns) == [:ecto_query]

      for schema <- @schemas do
        assert hits("alias Platform.Goals.#{schema}", @data_patterns) == [:goals_schema]

        assert hits("alias Platform.Goals.{Visibility, #{schema}}", @data_patterns) ==
                 [:goals_schema_group]
      end

      assert hits("alias Platform.Goals\nGoals.describe_goals(user)", @data_patterns) == []
    end

    test "the colour scan hits each pattern" do
      for literal <- ~w(#fff #f97316 #f9731680 #ABCDEF) do
        assert hits(~s(class="text-[#{literal}]"), @colour_patterns) == [:hex], literal
      end

      assert hits("color: rgb(0 0 0)", @colour_patterns) == [:rgb]
      assert hits("color: rgba(0,0,0,1)", @colour_patterns) == [:rgb]
      assert hits("color: hsl(10 20% 30%)", @colour_patterns) == [:hsl]
      assert hits("color: oklch(70% 0.1 40)", @colour_patterns) == [:oklch]
      assert hits(~S["Goal · #{owner}" <> text-base-content/70], @colour_patterns) == []
    end
  end

  test "the number scan hits each pattern" do
    assert hits("config :goals, :number_reader, X", @number_patterns) == [:number_reader]
    assert hits("alias PlatformWeb.GoalsNumber", @number_patterns) == [:goals_number]
    assert hits("defmodule Platform.Goals.NumberUnfilled do", @number_patterns) == [:stub_module]
    assert hits("defmodule PlatformWeb.GoalsReaderStub do", @number_patterns) == [:stub_module]

    assert hits("defmodule PlatformWeb.GoalsList do\n Goals.goal_number(u, id)", @number_patterns) ==
             []
  end

  test "apps/goals/lib has no number reader layer, stand-in or stub" do
    {files, found} = scan(@lib, @number_patterns)
    assert Enum.any?(files, &String.ends_with?(&1, "live/goals_list.ex")), "nothing scanned"
    assert found == []
  end

  test "apps/goals/lib/platform_web touches no data layer" do
    {files, found} = scan(@web, @data_patterns)
    assert Enum.any?(files, &String.ends_with?(&1, "live/goals_live.ex")), "nothing scanned"
    assert found == []
  end

  test "apps/goals/lib has no colour literal" do
    {files, found} = scan(@lib, @colour_patterns)
    assert Enum.any?(files, &String.ends_with?(&1, "platform/goals.ex")), "nothing scanned"
    assert Enum.any?(files, &String.ends_with?(&1, "live/goals_live.ex")), "nothing scanned"
    assert found == []
  end
end

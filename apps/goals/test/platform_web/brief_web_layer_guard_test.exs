defmodule PlatformWeb.BriefWebLayerGuardTest do
  use ExUnit.Case, async: true

  @web Path.expand("../../lib/platform_web", __DIR__)
  @schemas ~w(Goal Stop Grant Entry Reading Ask AskAnswer BriefItem WakeUp GoalClock)
  @patterns [
    repo: ~r/\bRepo\./,
    query: ~r/\bEcto\.Query\b/,
    import: ~r/\bimport\s+Ecto\b/,
    schema: ~r/\balias\s+Platform\.Goals\.(#{Enum.join(@schemas, "|")})\b/,
    grouped_schema:
      ~r/\balias\s+Platform\.Goals\.\{[^}]*\b(#{Enum.join(@schemas, "|")})\b[^}]*\}/s,
    hex: ~r/#[0-9a-fA-F]{3,8}\b/,
    rgb: ~r/\brgba?\(/i,
    hsl: ~r/\bhsla?\(/i,
    oklch: ~r/\boklch\(/i
  ]

  defp hits(text), do: for({name, pattern} <- @patterns, Regex.match?(pattern, text), do: name)

  test "brief, practice, check-in and idea views use contexts and semantic colours" do
    files =
      for family <- ~w(brief flash check idea retro),
          file <- Path.wildcard(Path.join(@web, "**/goals_#{family}*.ex")),
          do: file

    assert Enum.any?(files, &String.ends_with?(&1, "goals_brief_component.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "goals_brief_cards.ex"))
    assert for(file <- files, hit <- hits(File.read!(file)), do: {file, hit}) == []
  end

  test "every forbidden pattern has a planted positive control" do
    assert hits("Repo.all(q)") == [:repo]
    assert hits("import Ecto.Query") == [:query, :import]
    assert hits("import Ecto.Changeset") == [:import]

    for schema <- @schemas do
      assert hits("alias Platform.Goals.#{schema}") == [:schema]
      assert hits("alias Platform.Goals.{Clock, #{schema}}") == [:grouped_schema]
    end

    assert hits("#abc") == [:hex]
    assert hits("rgb(1 2 3)") == [:rgb]
    assert hits("hsl(1 2% 3%)") == [:hsl]
    assert hits("oklch(1 2 3)") == [:oklch]
    assert hits("alias Platform.Goals\nGoals.brief_items(user, date)") == []
  end
end

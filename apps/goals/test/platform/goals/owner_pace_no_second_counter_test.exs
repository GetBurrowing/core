defmodule Platform.Goals.OwnerPaceNoSecondCounterTest do
  use ExUnit.Case, async: false
  @lib Path.expand("../../../lib", __DIR__)
  @root Path.expand("../../../../..", __DIR__)

  # Scope the scan to count expressions involving ignored rows, not unrelated
  # Enum.count calls in files which also write ignored answers.
  defp ignored_count?(text),
    do: Regex.match?(~r/answer\s*==\s*"ignored"[\s\S]{0,180}count\(/, text)

  test "only owner_pace counts ignored answers; the scan detects a planted count" do
    assert ignored_count?(~s|a.answer == "ignored", select: count(i.digest_date, :distinct)|)
    files = Path.wildcard(Path.join(@lib, "**/*.ex"))
    found = Enum.filter(files, &(File.read!(&1) |> ignored_count?()))
    assert Enum.map(found, &Path.basename/1) == ["owner_pace.ex"]
    source = File.read!(Path.join(@lib, "platform/goals/owner_pace.ex"))
    assert source =~ "count(i.digest_date, :distinct)"
    assert source =~ "Visibility.visible_goals(owner)"
  end

  test "the task migration adds no pacing counter and refresh has exactly two call sites" do
    migration =
      File.read!(
        Path.join(
          @root,
          "apps/goals/priv/repo/migrations/20261115164425_add_goal_retro_and_pacing.exs"
        )
      )

    integer_columns =
      Regex.scan(~r/add\(:(\w+), :integer/, migration, capture: :all_but_first) |> List.flatten()

    assert integer_columns == ["retro_every"]

    calls =
      for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          hit <- Regex.scan(~r/(?:Platform\.Goals\.)?OwnerPace\.refresh\(/, File.read!(file)),
          do: {file, hit}

    assert length(calls) == 2
  end
end

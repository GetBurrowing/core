defmodule Platform.Meetings.CompanionFixtureParityTest do
  @moduledoc """
  Task 01a13ca2 stage 4: the cross-language companion identity fixture.

  `test/support/fixtures/companion_identities_v1.json` is the table the
  server (`Meetings.person_identity/1`), the page (`personIdentity`) and the
  iOS app (`CallParticipant.isCompanion`) are each tested against. The page
  reads the server file directly; the iOS suite reads a copy bundled into
  its test target. The copy must be byte-identical, or the iOS suite could
  pass against a table the server no longer uses.

  The rig clones the whole repo, so the client path exists under test.
  """
  use ExUnit.Case, async: true

  @platform_root Path.expand("../../..", __DIR__)
  @repo_root Path.expand("../..", @platform_root)

  @server Path.join(@platform_root, "test/support/fixtures/companion_identities_v1.json")
  @ios Path.join(
         @repo_root,
         "clients/ios/ios/App/AppTests/Fixtures/companion_identities_v1.json"
       )

  test "the iOS copy is byte-identical to the server fixture" do
    assert File.exists?(@ios), "missing client fixture: #{Path.relative_to(@ios, @repo_root)}"

    assert File.read!(@ios) == File.read!(@server),
           "#{Path.relative_to(@ios, @repo_root)} differs from the server fixture; copy it byte for byte"
  end

  test "the server fixture has cases" do
    cases = @server |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
    assert length(cases) > 0
  end
end

defmodule Platform.Meetings.CohostProfileTest do
  use ExUnit.Case, async: true
  alias Platform.Meetings.CohostProfile

  test "ordinary invitations do not carry show-specific instructions" do
    for value <- [nil, false, "true", %{}] do
      assert CohostProfile.invitation_options(value) == []
    end
  end

  test "explicit show mode supplies the profile to the existing voice dispatch" do
    opts = CohostProfile.invitation_options(true)
    assert opts[:mode] == "show_cohost"
    assert opts[:cohost_profile]["persona"] =~ "How To Computer"
    assert opts[:cohost_profile]["episode_brief"] =~ "AI economy"
  end
end

defmodule Platform.Meetings.CohostProfile do
  @moduledoc "Show instructions passed through the existing meeting voice dispatch."
  @path Path.expand("../../../priv/cohosts/how_to_computer.json", __DIR__)
  @external_resource @path
  @profile @path |> File.read!() |> Jason.decode!()

  def invitation_options(true), do: [mode: "show_cohost", cohost_profile: @profile]
  def invitation_options(_), do: []
end

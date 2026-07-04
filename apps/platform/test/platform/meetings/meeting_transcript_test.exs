defmodule Platform.Meetings.TranscriptTest do
  @moduledoc """
  Schema-level tests for `Platform.Meetings.Transcript`.

  Task 019f2566 stage 1 additions: the `router_dispatched_at` field is
  cast through the changeset and defaults to nil on freshly-inserted
  transcripts, so the SummarizerSweeper (stage 2) can treat
  `is_nil(router_dispatched_at)` as "the router hasn't fired for this
  transcript yet".
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings.Transcript

  describe "changeset — router_dispatched_at (task 019f2566 stage 1)" do
    test "accepts router_dispatched_at as a %DateTime{} and casts it through" do
      now = DateTime.utc_now()

      changeset =
        Transcript.changeset(%Transcript{}, %{
          room_id: "space-#{Ecto.UUID.generate()}",
          router_dispatched_at: now
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :router_dispatched_at) == now
    end

    test "router_dispatched_at is optional — omitted attrs still produce a valid changeset" do
      changeset =
        Transcript.changeset(%Transcript{}, %{room_id: "space-#{Ecto.UUID.generate()}"})

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :router_dispatched_at)
    end

    test "freshly-inserted transcript has router_dispatched_at defaulting to nil" do
      {:ok, transcript} =
        %Transcript{}
        |> Transcript.changeset(%{room_id: "space-#{Ecto.UUID.generate()}", status: "recording"})
        |> Platform.Repo.insert()

      assert is_nil(transcript.router_dispatched_at),
             "router_dispatched_at should default to nil until the router fires"
    end
  end
end

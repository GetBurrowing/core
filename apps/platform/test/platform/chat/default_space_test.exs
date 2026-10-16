defmodule Platform.Chat.DefaultSpaceTest do
  @moduledoc """
  A fresh install's "#general" (task 01a10322 stage 6): created once when the
  install has no channel, never a second time, and never when a channel
  already exists.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat.{DefaultSpace, Space}
  alias Platform.Repo

  defp channels, do: Repo.all(from(s in Space, where: s.kind == "channel"))

  setup do
    # Start from an install with no channel at all.
    Repo.delete_all(from(s in Space, where: s.kind == "channel"))
    :ok
  end

  test "run twice on an install with no channel: one General" do
    assert {:ok, %Space{name: "General", slug: "general", kind: "channel"} = space} =
             DefaultSpace.ensure()

    assert space.org_id == Platform.Tenancy.get_root_org().id
    assert DefaultSpace.ensure() == :exists
    assert DefaultSpace.run_at_boot() == :ok
    assert [%Space{slug: "general"}] = channels()
  end

  test "an install that already has a channel is left alone" do
    {:ok, _} =
      Platform.Chat.create_space(%{
        name: "Ops",
        slug: "ops-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: Platform.Tenancy.get_root_org().id
      })

    assert DefaultSpace.ensure() == :exists
    assert [%Space{name: "Ops"}] = channels()
  end
end

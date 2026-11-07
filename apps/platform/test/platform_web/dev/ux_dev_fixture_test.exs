defmodule PlatformWeb.UxDevFixtureTest do
  @moduledoc """
  The dev fixture for the UX role (task 01a1af00 stage 4,
  `PlatformWeb.UxDevFixture`): from an empty state, a seeded chat with
  friction produces ONE Inbox item for the recipient through the real
  Router path, the unreadable spaces contribute nothing, and the cron fire
  puts the fyi in the digest space.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias PlatformWeb.UxDevFixture

  setup do
    previous = Application.get_env(:platform, :ux_friction_watch_provider)
    on_exit(fn -> restore(previous) end)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ux-fixture-#{n}@example.com",
        name: "Fixture Viewer",
        oidc_sub: "uxf-#{n}"
      })

    {:ok, rig} = UxDevFixture.seed(user.id)
    %{user: user, rig: rig}
  end

  defp restore(nil), do: Application.delete_env(:platform, :ux_friction_watch_provider)
  defp restore(p), do: Application.put_env(:platform, :ux_friction_watch_provider, p)

  test "an empty state shows nothing until the watch fires", %{user: user} do
    status = UxDevFixture.status(user.id)
    assert status.findings == []
    assert status.inbox_items == []
  end

  test "a seeded friction chat files ONE decision Inbox item, twice-fired", %{
    user: user,
    rig: rig
  } do
    assert {:ok, _} = UxDevFixture.fire(user.id, nil)
    assert {:ok, _} = UxDevFixture.fire(user.id, nil)

    status = UxDevFixture.status(user.id)
    assert [decision] = Enum.filter(status.findings, &(&1.kind == "decision"))
    assert [item] = status.inbox_items
    assert item.user_id == user.id
    assert item.source_id == decision.id
    assert String.ends_with?(decision.question, "?")
    assert decision.evidence["count"] == 6
    assert decision.evidence["spaces"] == 2
    assert length(decision.evidence["quotes"]) <= 2
    assert length(decision.options) <= 3
    assert Enum.count(decision.options, & &1["recommended"]) == 1

    assert %{"before" => "/chat/attachments/" <> _, "after" => "/chat/attachments/" <> _} =
             decision.mockup_refs

    # Linked to a task, so an answer lands in that task's log.
    assert Repo.get!(Platform.Ux.Finding, decision.id).task_id

    # Nothing from the non-member channel or the mixed space, anywhere.
    blob = Jason.encode!(status)

    for id <- rig.unreadable_space_ids ++ rig.unreadable_message_ids,
        do: refute(blob =~ id)

    assert length(status.gathered_signals) == 9
  end

  test "the cron fire posts the fyi to the digest space, not the Inbox", %{user: user, rig: rig} do
    assert {:ok, _} = UxDevFixture.fire(user.id, "cron")

    status = UxDevFixture.status(user.id)
    assert [fyi] = Enum.filter(status.findings, &(&1.kind == "fyi"))
    assert fyi.status == "posted"
    assert [message] = status.digest_messages
    assert message.space_id == rig.digest_space_id
    assert message.content =~ fyi.question
    assert message.content =~ "1 decision sent to an inbox this week."
    assert [item] = status.inbox_items
    refute item.source_id == fyi.id
  end
end

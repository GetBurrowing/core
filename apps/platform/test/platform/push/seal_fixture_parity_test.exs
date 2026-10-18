defmodule Platform.Push.SealFixtureParityTest do
  @moduledoc """
  Task 01a1261e stage 1: the cross-language sealed-push fixture.

  `test/support/fixtures/push_seal_v1.json` is the contract the iOS
  Notification Service Extension and the Android receiver decrypt in their
  own suites (stages 4 and 5). Three things must hold, or a client could
  pass its test against a fixture the server no longer produces:

    1. both client copies are byte-identical to the server's;
    2. the server reproduces the fixture's `sealed` blob exactly from its
       inputs (fixed recipient and ephemeral keys through the test-only
       `Seal.seal/4`), and opens it back to `plaintext`;
    3. `plaintext` is the JSON of `Notification.to_fcm_payload/2`'s `"data"`
       under the `:burrow` category scheme (task 01a14ba1: the fixture
       models a dual-register build, so its category is `BURROW_MENTION`)
       for the sample notification below: one inner shape for both
       platforms, with `unread_count` / `unread_as_of` in it.

  The rig clones the whole repo, so the client paths exist under test.
  """
  use ExUnit.Case, async: true

  alias Platform.Push.Notification
  alias Platform.Push.Seal

  @platform_root Path.expand("../../..", __DIR__)
  @repo_root Path.expand("../..", @platform_root)

  @server Path.join(@platform_root, "test/support/fixtures/push_seal_v1.json")
  @ios Path.join(@repo_root, "clients/ios/ios/App/AppTests/Fixtures/push_seal_v1.json")
  @android Path.join(
             @repo_root,
             "clients/android/android/app/src/test/resources/push_seal_v1.json"
           )

  defp fixture, do: @server |> File.read!() |> Jason.decode!()
  defp key(fixture, name), do: Base.url_decode64!(fixture[name], padding: false)

  test "both client copies are byte-identical to the server fixture" do
    server = File.read!(@server)

    for path <- [@ios, @android] do
      assert File.exists?(path), "missing client fixture: #{Path.relative_to(path, @repo_root)}"

      assert File.read!(path) == server,
             "#{Path.relative_to(path, @repo_root)} differs from the server fixture; copy it byte for byte"
    end
  end

  test "the server reproduces the sealed blob exactly and opens it" do
    f = fixture()
    sk_r = key(f, "recipient_private_key")
    sk_e = key(f, "ephemeral_private_key")

    assert f["version"] == 1
    assert f["info"] == Seal.info()
    assert Seal.public_key(sk_r) == key(f, "recipient_public_key")
    assert Seal.public_key(sk_e) == key(f, "ephemeral_public_key")

    assert {:ok, sealed} =
             Seal.seal(
               f["recipient_public_key"],
               f["plaintext"],
               f["install_host"],
               ephemeral: {key(f, "ephemeral_public_key"), sk_e}
             )

    assert sealed == f["sealed"]
    assert {:ok, plaintext} = Seal.open(sk_r, f["sealed"], f["install_host"])
    assert plaintext == f["plaintext"]
    assert {:error, :open_failed} = Seal.open(sk_r, f["sealed"], "suite-a.localhost")
  end

  test "the plaintext is the FCM data map of the sample notification" do
    n =
      Notification.new(%{
        kind: "chat_mention",
        title: "Dana in launch",
        body: "@Robin can you check the deck before 3?",
        url: "/chat/launch?message=01a1261e-0000-7000-8000-00000000000b",
        space_id: "01a1261e-0000-7000-8000-00000000000a",
        message_id: "01a1261e-0000-7000-8000-00000000000b",
        thread_id: "01a1261e-0000-7000-8000-00000000000a",
        install_host: "suite-b.localhost",
        author_name: "Dana",
        author_id: "01a1261e-0000-7000-8000-00000000000c",
        author_type: "user",
        space_name: "launch",
        space_kind: "channel",
        unread_count: 3,
        unread_as_of: ~U[2026-10-10 15:00:00Z]
      })

    data = Notification.to_fcm_payload(n, :burrow)["data"]

    assert Jason.decode!(fixture()["plaintext"]) == data
    assert data["category"] == "BURROW_MENTION"
    assert data["unread_count"] == "3"
    assert data["unread_as_of"] == "2026-10-10T15:00:00Z"

    # A device that registered no scheme still gets the legacy id.
    assert Notification.to_fcm_payload(n)["data"]["category"] == "SUITE_MENTION"
    assert Notification.to_fcm_payload(n)["data"] == Map.put(data, "category", "SUITE_MENTION")
  end
end

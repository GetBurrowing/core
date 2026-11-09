defmodule Platform.SignIn.DurableLinkTest do
  @moduledoc """
  The signed, multi-use sign-in link of the ready and invite emails: a round
  trip, expiry (a frozen `signed_at` past `max_age`), tampering, and the
  user checks (archived or sign-in disabled, no pocket-id identity).
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.SignIn.DurableLink

  defp user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(%{sub: "sub-#{n}", email: "dl-#{n}@example.test", name: "DL #{n}"}, overrides)

    {:ok, user} = Accounts.find_or_create_from_oidc(attrs)
    user
  end

  defp token_of(url) do
    %URI{path: "/auth/link", query: query} = URI.parse(url)
    URI.decode_query(query)["token"]
  end

  test "url is absolute, on the endpoint host, and round-trips both purposes" do
    user = user!()

    for purpose <- [:handover, :invite] do
      url = DurableLink.url(user, purpose)
      assert String.starts_with?(url, PlatformWeb.Endpoint.url() <> "/auth/link?token=")

      assert {:ok, %{user_id: id, purpose: ^purpose}} = url |> token_of() |> DurableLink.verify()
      assert id == user.id
    end
  end

  test "the link is multi-use: verifying twice succeeds both times" do
    token = user!() |> DurableLink.url(:handover) |> token_of()
    assert {:ok, _} = DurableLink.verify(token)
    assert {:ok, _} = DurableLink.verify(token)
  end

  test "expires after max_age and not before" do
    user = user!()
    now = System.system_time(:second)

    old = DurableLink.url(user, :handover, signed_at: now - DurableLink.max_age() - 5)
    assert {:error, :expired} = old |> token_of() |> DurableLink.verify()

    fresh = DurableLink.url(user, :handover, signed_at: now - DurableLink.max_age() + 60)
    assert {:ok, _} = fresh |> token_of() |> DurableLink.verify()
  end

  test "max_age is 14 days" do
    assert DurableLink.max_age() == 14 * 24 * 3600
  end

  test "a tampered, truncated or foreign token is invalid" do
    token = user!() |> DurableLink.url(:handover) |> token_of()
    last = if String.ends_with?(token, "A"), do: "B", else: "A"
    tampered = String.slice(token, 0..-2//1) <> last

    assert {:error, :invalid} = DurableLink.verify(tampered)
    assert {:error, :invalid} = DurableLink.verify(String.slice(token, 0, 20))
    assert {:error, :invalid} = DurableLink.verify("garbage")
    assert {:error, :invalid} = DurableLink.verify("")
    assert {:error, :invalid} = DurableLink.verify(nil)

    # A token signed with another salt (here the prototype grant's) is refused.
    other = Phoenix.Token.sign(PlatformWeb.Endpoint, "prototype grant v1", %{"u" => "x"})
    assert {:error, :invalid} = DurableLink.verify(other)
  end

  test "an archived (or sign-in disabled) user is refused" do
    user = user!()
    token = user |> DurableLink.url(:handover) |> token_of()
    assert {:ok, _} = DurableLink.verify(token)

    {:ok, archived} = Accounts.archive_user(user, reason: "sign-in disabled")
    assert {:error, :archived} = DurableLink.verify(token)

    # Unarchive the ARCHIVED struct: a changeset on the stale pre-archive struct
    # has no changes and would be a silent no-op.
    {:ok, _} = Accounts.unarchive_user(archived)
    assert {:ok, _} = DurableLink.verify(token)
  end

  test "a token for a user that no longer exists is refused" do
    token =
      Phoenix.Token.sign(PlatformWeb.Endpoint, "durable sign-in link v1", %{
        "u" => Ecto.UUID.generate(),
        "p" => "handover"
      })

    assert {:error, :not_found} = DurableLink.verify(token)
  end

  test "a token with an unknown purpose is invalid" do
    user = user!()

    token =
      Phoenix.Token.sign(PlatformWeb.Endpoint, "durable sign-in link v1", %{
        "u" => user.id,
        "p" => "admin"
      })

    assert {:error, :invalid} = DurableLink.verify(token)
  end
end

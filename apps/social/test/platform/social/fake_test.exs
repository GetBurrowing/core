defmodule Platform.Social.Publisher.FakeTest do
  @moduledoc """
  The Fake publisher records every call, forgets them on reset, returns a
  programmed next result once, and verifies its own HMAC signature over the
  RAW body. The call log is a global ETS table, hence `async: false`.
  """
  use ExUnit.Case, async: false

  alias Platform.Social.Publisher.Fake

  @secret "fake-test-secret-not-real"

  setup do
    Fake.reset()
    :ok
  end

  defp account, do: %Platform.Social.Account{id: Ecto.UUID.generate(), platform: "linkedin"}

  defp request(id) do
    %{
      body: "hello",
      link_url: nil,
      scheduled_at: nil,
      media: [],
      is_aigc: false,
      ai_disclosure: nil,
      platform: "linkedin",
      idempotency_key: id
    }
  end

  describe "call log" do
    test "records every callback as {fun, args, at}, oldest first" do
      acct = account()

      assert {:ok, %{external_id: "fake_p1", status: :scheduled, external_url: nil}} =
               Fake.publish(acct, request("p1"))

      assert :ok = Fake.delete(acct, "fake_p1")
      assert {:ok, %{status: :scheduled}} = Fake.status(acct, "fake_p1")

      assert [
               {:publish, [^acct, %{idempotency_key: "p1"}], %DateTime{}},
               {:delete, _, _},
               {:status, _, _}
             ] = Fake.calls()

      assert [{:delete, [^acct, "fake_p1"], _}] = Fake.calls(:delete)
      assert Fake.calls(:connect_url) == []
    end

    test "reset/0 forgets every call and every programmed result" do
      Fake.publish(account(), request("p2"))
      Fake.fail_next(:publish, :boom)
      assert Fake.reset() == :ok
      assert Fake.calls() == []
      assert {:ok, _} = Fake.publish(account(), request("p3"))
    end

    test "fail_next/2 applies to the next call only, and the call is still recorded" do
      Fake.fail_next(:publish, :vendor_down)
      assert {:error, :vendor_down} = Fake.publish(account(), request("p4"))
      assert {:ok, _} = Fake.publish(account(), request("p5"))
      assert length(Fake.calls(:publish)) == 2
    end

    test "ensure_profile/1 defaults to :not_required, invents no ref, and is recorded" do
      profile = %Platform.Social.Profile{id: Ecto.UUID.generate(), name: "Brand"}
      assert Fake.ensure_profile(profile) == :not_required
      assert [{:ensure_profile, [^profile], %DateTime{}}] = Fake.calls(:ensure_profile)

      Fake.fail_next(:ensure_profile, :vendor_down)
      assert {:error, :vendor_down} = Fake.ensure_profile(profile)
      assert Fake.ensure_profile(profile) == :not_required
    end

    test "list_accounts/1 defaults to {:ok, []}, invents no ids, and is recorded" do
      profile = %Platform.Social.Profile{id: Ecto.UUID.generate(), name: "Brand"}
      assert Fake.list_accounts(profile) == {:ok, []}
      assert [{:list_accounts, [^profile], %DateTime{}}] = Fake.calls(:list_accounts)

      listed = [%{ref: "zacct_1", platform: "x", profile_ref: "zp", username: nil, active?: true}]
      Fake.put_next(:list_accounts, {:ok, listed})
      assert {:ok, ^listed} = Fake.list_accounts(profile)

      Fake.fail_next(:list_accounts, :vendor_down)
      assert {:error, :vendor_down} = Fake.list_accounts(profile)
      assert Fake.list_accounts(profile) == {:ok, []}
    end

    test "platforms/0 is Account.platforms/0" do
      assert Fake.platforms() == Platform.Social.Account.platforms()
    end

    test "connect_url/2 carries the redirect url" do
      assert {:ok, url} =
               Fake.connect_url(account(), redirect_url: "https://suite.example.test/cb")

      assert url =~ URI.encode_www_form("https://suite.example.test/cb")
    end
  end

  describe "verify_webhook/2" do
    setup do
      body =
        Fake.webhook_body([
          %{
            event_id: "e1",
            external_id: "fake_p1",
            kind: "published",
            external_url: "https://x.test/1"
          }
        ])

      %{body: body}
    end

    defp delivery(body, headers), do: %{raw_body: body, headers: headers}

    test "a body signed with the secret round-trips into events", %{body: body} do
      headers = %{Fake.signature_header() => Fake.sign(body, @secret)}

      assert {:ok, [%{event_id: "e1", external_id: "fake_p1", kind: :published} = event]} =
               Fake.verify_webhook(delivery(body, headers), @secret)

      assert event.external_url == "https://x.test/1"
    end

    test "one changed byte in the body is refused", %{body: body} do
      headers = %{Fake.signature_header() => Fake.sign(body, @secret)}
      <<first, rest::binary>> = body
      tampered = <<Bitwise.bxor(first, 1), rest::binary>>
      assert tampered != body

      assert {:error, :invalid_signature} =
               Fake.verify_webhook(delivery(tampered, headers), @secret)
    end

    test "a wrong secret is refused", %{body: body} do
      headers = %{Fake.signature_header() => Fake.sign(body, "some-other-secret")}
      assert {:error, :invalid_signature} = Fake.verify_webhook(delivery(body, headers), @secret)
    end

    test "a missing header, or an empty secret, is refused", %{body: body} do
      assert {:error, :invalid_signature} = Fake.verify_webhook(delivery(body, %{}), @secret)

      headers = %{Fake.signature_header() => Fake.sign(body, "")}
      assert {:error, :invalid_signature} = Fake.verify_webhook(delivery(body, headers), "")
    end

    test "an unknown kind normalizes to :ignored" do
      body = Fake.webhook_body([%{event_id: "e2", external_id: "fake_p1", kind: "boosted"}])
      headers = %{Fake.signature_header() => Fake.sign(body, @secret)}

      assert {:ok, [%{kind: :ignored}]} = Fake.verify_webhook(delivery(body, headers), @secret)
    end
  end
end

defmodule Platform.Config.CanonicalHostTest do
  @moduledoc """
  Burrow rename (task 01a18dab stage 3): the install's `burrow.` host becomes
  canonical (PHX_HOST, APP_URL) and its old `suite.` host stays a working
  alias through OWN_HOST_ALIASES. The hosts here are example.net stand-ins:
  the real domain is on the install-identity denylist
  (test/support/install_identity_scanner.ex).

  Evaluates the real `config/runtime.exs` under `config_env() == :prod` with
  a controlled environment, so a regression in the file itself fails here.

  Pinned:

    * an OWN_HOST_ALIASES entry is admitted by `check_origin` as exactly
      `https://<alias>` (no www., no wildcard), so one knob makes an alias
      both link-recognised and socket-accepted;
    * with OWN_HOST_ALIASES unset, `check_origin` is exactly the list the
      pre-stage-3 code built, element for element;
    * the flip changes the endpoint's `url` and `check_origin` and nothing
      else the session depends on: `secret_key_base` and
      `session_cookie_domain` are identical before and after, so nobody is
      logged out by it.
  """

  # Mutates process-global OS env vars.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)

  # Everything the :prod branch of runtime.exs requires (it raises without
  # them) plus every name this test controls. Saved, cleared, restored.
  @required %{
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "VAULT_MASTER_KEY" => Base.encode64(String.duplicate("v", 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/canonical_host_test",
    "ATTACHMENT_SIGNING_KEY" => "attachment-test-key",
    "MEETING_GUEST_SIGNING_KEY" => "guest-test-key",
    "MEETING_CALENDAR_SIGNING_KEY" => "calendar-test-key"
  }

  @controlled [
    "PHX_HOST",
    "APP_URL",
    "OWN_HOST_ALIASES",
    "MEET_HOST",
    "CHAT_HOST",
    "EXTRA_ORIGIN_APEXES",
    "SESSION_COOKIE_DOMAIN",
    "PLATFORM_ROLE",
    "PLATFORM_CLUSTER_PEER",
    "VAPID_PUBLIC_KEY",
    "VAPID_PRIVATE_KEY"
  ]

  @suite "suite.example.net"
  @burrow "burrow.example.net"

  setup do
    names = Map.keys(@required) ++ @controlled
    saved = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(@controlled, &System.delete_env/1)
    Enum.each(@required, fn {name, value} -> System.put_env(name, value) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp read_prod(env) do
    Enum.each(@controlled, &System.delete_env/1)
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)
    Config.Reader.read!(@runtime_exs, env: :prod)
  end

  defp endpoint(config), do: get_in(config, [:platform, PlatformWeb.Endpoint])

  # The list the pre-stage-3 runtime.exs built, transcribed from it. With
  # OWN_HOST_ALIASES unset the new code must produce exactly this.
  defp legacy_check_origin(host, meet_host, chat_host, extra_apexes) do
    ["https://#{host}", "https://www.#{host}", "//*.#{host}"] ++
      if(meet_host, do: ["https://#{meet_host}"], else: []) ++
      if(chat_host, do: ["https://#{chat_host}"], else: []) ++
      Enum.flat_map(extra_apexes, fn apex ->
        ["https://#{apex}", "https://www.#{apex}", "//*.#{apex}"]
      end)
  end

  # The production shape after the flip, with stand-in sibling hosts.
  @flipped %{
    "PHX_HOST" => @burrow,
    "APP_URL" => "https://#{@burrow}",
    "OWN_HOST_ALIASES" => @suite,
    "MEET_HOST" => "meet.example.net",
    "CHAT_HOST" => "chat.example.net",
    "EXTRA_ORIGIN_APEXES" => "example.org",
    "SESSION_COOKIE_DOMAIN" => ".example.net"
  }

  describe "PHX_HOST=burrow with suite as an alias" do
    test "the endpoint URL is burrow, and check_origin admits burrow AND suite" do
      config = read_prod(@flipped)
      endpoint = endpoint(config)

      assert endpoint[:url] == [host: @burrow, port: 443, scheme: "https"]
      assert "https://#{@burrow}" in endpoint[:check_origin]
      assert "https://#{@suite}" in endpoint[:check_origin]
      assert get_in(config, [:platform, :own_host_aliases]) == [@suite]
      assert get_in(config, [:platform, :oidc, :app_url]) == "https://#{@burrow}"
    end

    test "an alias is admitted as exactly https://<alias>: no www., no wildcard" do
      origins = read_prod(@flipped) |> endpoint() |> Keyword.fetch!(:check_origin)

      refute "https://www.#{@suite}" in origins
      refute "//*.#{@suite}" in origins

      assert origins ==
               legacy_check_origin(@burrow, "meet.example.net", "chat.example.net", [
                 "example.org"
               ]) ++ ["https://#{@suite}"]
    end

    test "aliases are trimmed, lowercased, de-duplicated, and one already present is not repeated" do
      origins =
        read_prod(%{
          "PHX_HOST" => @burrow,
          "OWN_HOST_ALIASES" =>
            " Suite.Example.NET , #{@burrow},, suite.example.net ,other.example"
        })
        |> endpoint()
        |> Keyword.fetch!(:check_origin)

      assert origins ==
               legacy_check_origin(@burrow, nil, nil, []) ++
                 ["https://#{@suite}", "https://other.example"]
    end
  end

  describe "OWN_HOST_ALIASES unset: check_origin is unchanged" do
    test "with every sibling var set, the list is exactly the pre-stage-3 list" do
      origins =
        @flipped
        |> Map.delete("OWN_HOST_ALIASES")
        |> read_prod()
        |> endpoint()
        |> Keyword.fetch!(:check_origin)

      assert origins ==
               legacy_check_origin(@burrow, "meet.example.net", "chat.example.net", [
                 "example.org"
               ])
    end

    test "with only PHX_HOST set, the list is exactly the pre-stage-3 list" do
      origins = read_prod(%{"PHX_HOST" => @suite}) |> endpoint() |> Keyword.fetch!(:check_origin)
      assert origins == legacy_check_origin(@suite, nil, nil, [])
    end

    test "an empty OWN_HOST_ALIASES adds nothing either" do
      origins =
        read_prod(%{"PHX_HOST" => @suite, "OWN_HOST_ALIASES" => " , "})
        |> endpoint()
        |> Keyword.fetch!(:check_origin)

      assert origins == legacy_check_origin(@suite, nil, nil, [])
    end
  end

  describe "the flip does not log anybody out" do
    test "secret_key_base and the session cookie domain are identical before and after" do
      before =
        read_prod(%{
          "PHX_HOST" => @suite,
          "APP_URL" => "https://#{@suite}",
          "OWN_HOST_ALIASES" => "#{@suite},#{@burrow}",
          "SESSION_COOKIE_DOMAIN" => ".example.net"
        })

      after_flip =
        read_prod(@flipped |> Map.drop(["MEET_HOST", "CHAT_HOST", "EXTRA_ORIGIN_APEXES"]))

      assert endpoint(before)[:secret_key_base] == endpoint(after_flip)[:secret_key_base]

      assert get_in(before, [:platform, :session_cookie_domain]) == ".example.net"

      assert get_in(after_flip, [:platform, :session_cookie_domain]) ==
               get_in(before, [:platform, :session_cookie_domain])

      # The only endpoint keys the flip moves are the URL and the origin list.
      changed =
        for {key, value} <- endpoint(after_flip),
            Keyword.get(endpoint(before), key) != value,
            do: key

      assert Enum.sort(changed) == [:check_origin, :url]
    end
  end

  describe "VAPID subject" do
    test "runtime.exs sets no literal subject; the resolver derives it from the endpoint" do
      details =
        @flipped
        |> Map.merge(%{"VAPID_PUBLIC_KEY" => "pub", "VAPID_PRIVATE_KEY" => "priv"})
        |> read_prod()
        |> get_in([:web_push_encryption, :vapid_details])

      assert details[:public_key] == "pub"
      refute Keyword.has_key?(details, :subject)
    end
  end
end

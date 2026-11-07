defmodule PlatformWeb.Dev.FakeSecretarySeedsTest do
  @moduledoc """
  The dev secretary routes (task 01a1b721 stage 3): each seed runs through
  real context paths and yields something the evaluator pass can read; the
  inspector's prompt for C holds none of the privacy seed's secrets; the
  ceiling switch writes the person's setting; every route is 404 without the
  fake agent host.
  """
  use Platform.DataCase, async: false

  import Plug.Test
  import Platform.SecretaryFixtures, only: [eligible: 0, request: 1]

  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Secretary.{Pass, Settings, Store}
  alias PlatformWeb.Dev.{FakeSecretary, FakeSecretarySeeds}

  setup do
    previous = Application.get_env(:platform, :fake_agent_host)
    Application.put_env(:platform, :fake_agent_host, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:platform, :fake_agent_host),
        else: Application.put_env(:platform, :fake_agent_host, previous)
    end)

    :ok
  end

  defp call(method, path) do
    conn = conn(method, path) |> FakeSecretary.call([])
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "every seed answers 200 and base gives the pass something to read" do
    for seed <- FakeSecretarySeeds.seeds() -- ["clear"] do
      assert {200, %{"ok" => true}} = call(:post, "/seed/#{seed}"), seed
    end

    user = FakeSecretarySeeds.dev_user()
    payload = SecretaryPolicy.control()

    assert {:ok, :submitted} =
             Pass.run(user,
               eligible: eligible(),
               request: request(self()),
               payload: payload,
               install_payload: payload
             )

    tags = user.id |> Store.list_evaluations() |> Enum.map(& &1.tag) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(~w(decide waiting not_in_space todo)), tags)
    assert Enum.any?(Store.list_evaluations(user.id), & &1.family)

    assert {200, %{"result" => %{"dismissed" => n}}} = call(:post, "/seed/clear")
    assert n > 0
  end

  test "the inspector shows C nothing of the privacy seed's secrets, and A its own" do
    assert {200, %{"result" => %{"a" => a, "c" => c}}} = call(:post, "/seed/privacy")

    assert {200, %{"prompt" => prompt_c, "input_refs" => [_ | _]}} =
             call(:get, "/inspect?email=#{c}")

    assert prompt_c =~ "open-text"
    assert prompt_c =~ "allowed-xyz"

    for secret <- ~w(dm-secret-xyz grp-secret-xyz restricted-xyz exec-xyz denied-xyz) do
      refute prompt_c =~ secret, secret
    end

    assert {200, %{"prompt" => prompt_a}} = call(:get, "/inspect?email=#{a}")
    assert prompt_a =~ "dm-secret-xyz"
    assert prompt_a =~ "grp-secret-xyz"
  end

  test "the ceiling switch writes the person's setting, and default clears it" do
    assert {200, %{"daily_token_ceiling" => 1}} = call(:post, "/ceiling/1")
    assert Settings.get(FakeSecretarySeeds.dev_user())["daily_token_ceiling"] == 1
    assert {200, %{"daily_token_ceiling" => nil}} = call(:post, "/ceiling/default")
  end

  test "404 without the fake agent host" do
    Application.put_env(:platform, :fake_agent_host, false)
    assert {404, _} = call(:post, "/seed/base")
    assert {404, _} = call(:get, "/inspect")
  end
end

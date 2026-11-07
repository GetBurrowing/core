defmodule Platform.SupportAccessFixtures do
  @moduledoc """
  Test helpers for vendor support access (task 01a1b362 stage 1). Every key
  here is a throwaway generated in-process with
  `:crypto.generate_key(:eddsa, :ed25519)`; no key is committed.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.SupportAccess.Grant
  alias Platform.SupportAccess.Settings

  @install_id "11111111-2222-4333-8444-555555555555"

  def install_id, do: @install_id

  @doc """
  Configures support access for one test: a fresh keypair under `kid`, this
  install's id, and temp state/events paths. Restores the previous config on
  exit. Returns `%{private_key, kid, state_path, events_path}`.
  """
  def setup_support_access(context \\ %{}) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    kid = "test-kid-#{System.unique_integer([:positive])}"
    dir = Platform.TestTemp.mkdir!("support-access")
    state_path = Path.join(dir, "state.json")
    events_path = Path.join(dir, "events.jsonl")
    previous = Application.get_env(:platform, :support_access)

    Application.put_env(:platform, :support_access,
      vendor_keys: %{kid => public},
      install_id: @install_id,
      state_path: state_path,
      shell_events_path: events_path,
      max_duration_s: 14_400,
      max_validity_s: 300
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :support_access, previous),
        else: Application.delete_env(:platform, :support_access)

      File.rm_rf(dir)
    end)

    Platform.SupportAccess.JunkLimit.reset()

    Map.merge(context, %{
      private_key: private,
      kid: kid,
      state_path: state_path,
      events_path: events_path
    })
  end

  @doc "Sets the switch directly (no audit, no side effects)."
  def set_enabled!(enabled) do
    from(s in Settings, where: s.singleton == true)
    |> Repo.update_all(set: [enabled: enabled])
  end

  @doc "A grant body map with sane defaults, overridable."
  def grant_body(overrides \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "install_id" => @install_id,
        "kind" => "admin",
        "operator" => %{"name" => "Pat Operator", "email" => "pat.operator@support.test"},
        "duration_s" => 3600,
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        "issued_at" => now,
        "expires_at" => now + 120
      },
      overrides
    )
  end

  @doc "Encodes and signs `body` with `ctx`'s key. Returns `{raw, headers}`."
  def sign(body, %{private_key: private, kid: kid}, opts \\ []) do
    raw = body |> Map.put_new("kid", kid) |> Jason.encode!()
    key = Keyword.get(opts, :key, private)
    signature = :crypto.sign(:eddsa, :none, Grant.prefix() <> raw, [key, :ed25519])

    {raw,
     [
       {"content-type", "application/json"},
       {Grant.signature_header(), Base.url_encode64(signature, padding: false)}
     ]}
  end

  def state(%{state_path: path}), do: path |> File.read!() |> Jason.decode!()
end

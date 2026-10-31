defmodule Platform.Installs.Handover do
  @moduledoc """
  An install's DECRYPTED hand-over credentials (task 01a10315 stage 6):
  `ssh_private_key`, `static_api_key` and `oidc_client_secret`.

  The values are never held in a printable field. The struct's only field is
  a zero-arity closure that returns them, and `inspect/1` of a closure prints
  `#Function<...>` without its captured terms. So the struct prints as
  `#Handover<redacted>` through its `Inspect` implementation, and even
  `inspect(handover, structs: false)`, `Map.from_struct/1`, a changeset's
  `changes` or an exception that inspects its arguments show the closure,
  never a credential. A value leaves only through `fetch/2`, at its point of
  use.

  `Platform.Installs.Install.handover_sealed` is stored through
  `Platform.Installs.Handover.Type`, which encrypts on dump (the same AES-GCM
  `Platform.Vault.EncryptedBinary` the column always used, so existing rows
  read unchanged) and loads into this struct.
  """

  @enforce_keys [:secrets]
  defstruct [:secrets]

  @type t :: %__MODULE__{secrets: (-> %{optional(String.t()) => String.t()})}

  @doc """
  Wrap a credentials map, or the JSON object it is stored as. Anything that
  is not a JSON object of strings wraps to an empty hand-over: a decode error
  carries its input, so it is dropped rather than returned.
  """
  @spec wrap(map() | String.t()) :: t()
  def wrap(%{} = map) when not is_struct(map) do
    clean = for {k, v} <- map, is_binary(v), into: %{}, do: {to_string(k), v}
    %__MODULE__{secrets: fn -> clean end}
  end

  def wrap(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> wrap(map)
      _ -> wrap(%{})
    end
  end

  @doc "One value, or nil."
  @spec fetch(t(), String.t()) :: String.t() | nil
  def fetch(%__MODULE__{secrets: secrets}, key) when is_binary(key), do: Map.get(secrets.(), key)

  @doc "A new hand-over with `key` set to `value`."
  @spec put(t(), String.t(), String.t()) :: t()
  def put(%__MODULE__{secrets: secrets}, key, value) when is_binary(key) and is_binary(value),
    do: wrap(Map.put(secrets.(), key, value))

  @doc false
  # The plaintext JSON, for `Platform.Installs.Handover.Type.dump/1` only.
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{secrets: secrets}), do: Jason.encode!(secrets.())

  defimpl Inspect do
    def inspect(_handover, _opts), do: "#Handover<redacted>"
  end
end

defmodule Platform.Installs.Handover.Type do
  @moduledoc """
  Ecto type of `installs.handover_sealed`: `Platform.Vault.EncryptedBinary`
  ciphertext in the column, a `Platform.Installs.Handover` in the struct.
  Casts a `Handover`, a credentials map or its JSON.
  """

  use Ecto.Type

  alias Platform.Installs.Handover
  alias Platform.Vault.EncryptedBinary

  @impl true
  def type, do: EncryptedBinary.type()

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(%Handover{} = handover), do: {:ok, handover}
  def cast(%{} = map) when not is_struct(map), do: {:ok, Handover.wrap(map)}
  def cast(json) when is_binary(json), do: {:ok, Handover.wrap(json)}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(%Handover{} = handover), do: EncryptedBinary.dump(Handover.to_json(handover))
  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(ciphertext) do
    case EncryptedBinary.load(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, Handover.wrap(plaintext)}
      _ -> :error
    end
  end

  @impl true
  def equal?(%Handover{} = a, %Handover{} = b), do: Handover.to_json(a) == Handover.to_json(b)
  def equal?(a, b), do: a == b
end

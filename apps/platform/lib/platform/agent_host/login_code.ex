defmodule Platform.AgentHost.LoginCode do
  @moduledoc """
  The code an owner pastes from Anthropic's sign-in page, wrapped so it cannot
  be printed by accident (task 01a1b365 stage 2).

  It is inspected as `#LoginCode<redacted>`, so a GenServer crash report, a
  `FunctionClauseError` argument dump, a `Logger` call or `inspect/1`
  anywhere shows nothing of it. There is no `String.Chars` and no
  `Jason.Encoder`: interpolating or JSON-encoding it raises instead of
  printing it.

  The raw string is read with `reveal/1`, and only where the agent host's
  channel serialises the `agent.claude_login_code` push
  (`PlatformWeb.AgentHostChannel`) or where a stand-in host takes that push
  (`Platform.AgentHost.FakeHost`). `Platform.AgentHost.NoLoginRelayTest`
  names the only lib modules that may carry one.
  """

  @enforce_keys [:secret]
  defstruct [:secret]

  @type t :: %__MODULE__{secret: String.t()}

  # The agent host's own shape check (services/agent-host/src/claude_login.ts
  # CODE_SHAPE): printable ASCII, no whitespace, 1 to 512 bytes.
  @shape ~r/\A[\x21-\x7e]{1,512}\z/

  @doc """
  Wrap a pasted code, trimmed. `{:error, :bad_code}` for anything not shaped
  like one; the input is never echoed back.
  """
  @spec new(term()) :: {:ok, t()} | {:error, :bad_code}
  def new(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@shape, value),
      do: {:ok, %__MODULE__{secret: value}},
      else: {:error, :bad_code}
  end

  def new(_value), do: {:error, :bad_code}

  @doc false
  # The raw code. Called only where the push to the host is serialised.
  @spec reveal(t()) :: String.t()
  def reveal(%__MODULE__{secret: secret}), do: secret

  defimpl Inspect do
    def inspect(_code, _opts), do: "#LoginCode<redacted>"
  end
end

defmodule Platform.AgentHost.OneshotPrompt do
  @moduledoc """
  The prompt of one `agent.oneshot` (task 01a1b721 stage 2), wrapped so it
  cannot be printed by accident on its way to the agent host.

  Same shape as `Platform.AgentHost.LoginCode`: it inspects as
  `#OneshotPrompt<redacted>`, so a GenServer crash report (the reconciler
  carries it through one `GenServer.call`), a `FunctionClauseError` argument
  dump, a `Logger` call or `inspect/1` shows nothing of it. No `String.Chars`
  and no `Jason.Encoder`: interpolating or JSON-encoding it raises.

  `reveal/1` is called only where the agent host's channel serialises the
  push (`PlatformWeb.AgentHostChannel`) and where a stand-in host reads it
  (`Platform.AgentHost.FakeHost`).
  """

  @enforce_keys [:text]
  defstruct [:text]

  @type t :: %__MODULE__{text: String.t()}

  @doc "Wrap a prompt."
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{text: text}

  @doc false
  @spec reveal(t()) :: String.t()
  def reveal(%__MODULE__{text: text}), do: text

  defimpl Inspect do
    def inspect(_prompt, _opts), do: "#OneshotPrompt<redacted>"
  end
end

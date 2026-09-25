defmodule Platform.Test.ChatContextSummaryStub do
  @moduledoc """
  Test provider for `Platform.Chat.ContextSummary` (task 01a0d8de stage 1),
  installed through `:chat_context_summary_provider`. Same shape as
  `Platform.Test.ExperimentsLabelerStub`.

  `install!/2` also sets `:chat_context_summary` to a configured provider
  (default `:ollama`), because the summariser refuses before any provider
  call when the configured provider is `:none`. Every call sends
  `{:context_summary_stub_called, credentials, messages, opts}` to the
  installing pid and answers with the reply fun. Tests using it must be
  `async: false`; both env keys are restored on exit and the cache is
  cleared.
  """

  @behaviour Platform.Agents.Providers.Provider

  @env_key :chat_context_summary_stub

  @doc "Install the stub, reporting to `self()`, answering with `reply`."
  def install!(reply, config \\ %{}) when is_function(reply, 3) do
    prev_provider = Application.get_env(:platform, :chat_context_summary_provider)
    prev_config = Application.get_env(:platform, :chat_context_summary)

    Application.put_env(:platform, :chat_context_summary_provider, __MODULE__)

    Application.put_env(
      :platform,
      :chat_context_summary,
      Map.merge(%{provider: :ollama, model: "stub-model"}, config)
    )

    Application.put_env(:platform, @env_key, %{pid: self(), reply: reply})
    Platform.Chat.ContextSummaryCache.clear()

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:platform, @env_key)
      restore(:chat_context_summary_provider, prev_provider)
      restore(:chat_context_summary, prev_config)
      Platform.Chat.ContextSummaryCache.clear()
    end)

    :ok
  end

  @doc "Replace the reply fun without reinstalling."
  def reply!(reply) when is_function(reply, 3) do
    env = Application.fetch_env!(:platform, @env_key)
    Application.put_env(:platform, @env_key, %{env | reply: reply})
  end

  @doc "A reply fun answering with `text`."
  def text(text), do: fn _c, _m, _o -> {:ok, %{content: text}} end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  @impl true
  def chat(credentials, messages, opts) do
    case Application.get_env(:platform, @env_key) do
      %{pid: pid, reply: reply} ->
        send(pid, {:context_summary_stub_called, credentials, messages, opts})
        reply.(credentials, messages, opts)

      nil ->
        {:error, :no_stub_configured}
    end
  end

  @impl true
  def stream(_credentials, _messages, _opts), do: {:error, :not_implemented}

  @impl true
  def models(_credentials), do: {:ok, []}

  @impl true
  def validate_credentials(_credentials), do: :ok
end

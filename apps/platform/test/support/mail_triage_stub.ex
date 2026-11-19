defmodule Platform.Test.MailTriageStub do
  @moduledoc """
  Test provider for `Platform.Mail.Triage.Classifier` (task 01a1f426 stage 1),
  installed through `:mail_triage_provider`.

  The classifier may run in a `Task.Supervisor` child (the triage subscriber
  path), so this stub cannot use the process dictionary the way
  `Platform.Test.SecurityEnrichmentHelper` does. It reads its reply fun and
  the pid to report to from Application env instead; every call sends
  `{:mail_triage_stub_called, credentials, messages, opts}` to that pid. Tests
  using it must be `async: false`.
  """

  @behaviour Platform.Agents.Providers.Provider

  @env_key :mail_triage_stub

  @doc """
  Install the stub as the mail triage provider, reporting to `self()`, answering
  with `reply` (a `(credentials, messages, opts) -> result` fun). Restores
  the previous env on exit.
  """
  def install!(reply) when is_function(reply, 3) do
    prev = Application.get_env(:platform, :mail_triage_provider)
    Application.put_env(:platform, :mail_triage_provider, __MODULE__)
    Application.put_env(:platform, @env_key, %{pid: self(), reply: reply})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:platform, @env_key)

      if is_nil(prev),
        do: Application.delete_env(:platform, :mail_triage_provider),
        else: Application.put_env(:platform, :mail_triage_provider, prev)
    end)

    :ok
  end

  @doc "Replace the reply fun without reinstalling."
  def reply!(reply) when is_function(reply, 3) do
    env = Application.fetch_env!(:platform, @env_key)
    Application.put_env(:platform, @env_key, %{env | reply: reply})
  end

  @doc "A reply fun answering with `map` encoded as JSON."
  def json(map), do: fn _c, _m, _o -> {:ok, %{content: Jason.encode!(map)}} end

  @impl true
  def chat(credentials, messages, opts) do
    case Application.get_env(:platform, @env_key) do
      %{pid: pid, reply: reply} ->
        send(pid, {:mail_triage_stub_called, credentials, messages, opts})
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

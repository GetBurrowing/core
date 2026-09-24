defmodule Platform.Mail.TestAdapter do
  @moduledoc """
  Recording Swoosh adapter for the Email module's tests (task 01a0cf21
  stage 2). Never talks to a network.

  Each `deliver/2` sends `{:mail_test_adapter, email, config}` to the calling
  process (and its `$callers`), so a test can assert WHICH relay, port and
  username a send was configured with — `Swoosh.Adapters.Test` records only
  the email. Returns an SMTP-shaped 250 receipt.

  A test may install `Process.put(:mail_test_adapter_hook, fun)`; the adapter
  calls `fun.(email)` before answering, which is how the dispatch tests look
  at the database at the moment SMTP would be contacted.
  """
  use Swoosh.Adapter

  @impl true
  def deliver(email, config) do
    case Process.get(:mail_test_adapter_hook) do
      fun when is_function(fun, 1) -> fun.(email)
      _ -> :ok
    end

    for pid <- Enum.uniq([self() | Process.get(:"$callers", [])]) do
      send(pid, {:mail_test_adapter, email, config})
    end

    {:ok, "250 2.0.0 Ok: queued as TEST\r\n"}
  end
end

defmodule Platform.Mail.RaisingTestAdapter do
  @moduledoc """
  Swoosh adapter that raises on every send (task 01a0cf21 stage 2), for the
  "the audit row survives a failed send" tests. Sends
  `{:mail_raising_adapter, email}` first so a test can see it was reached.
  """
  use Swoosh.Adapter

  @impl true
  def deliver(email, _config) do
    send(self(), {:mail_raising_adapter, email})
    raise "simulated SMTP failure"
  end
end

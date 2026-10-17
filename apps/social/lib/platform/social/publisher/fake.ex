defmodule Platform.Social.Publisher.Fake do
  @moduledoc """
  The test and dev publisher (task 01a140a9, Social 2/7). It talks to no
  vendor: every callback call is recorded as `{fun, args, at}` in the named
  public ETS table `#{inspect(:social_fake_publisher)}`, which this module's
  GenServer owns from Social's own supervisor (`Platform.Social.Application`),
  never core's.

  ## Test API

    * `calls/0`, `calls/1` - the recorded calls, oldest first (all, or one callback's).
    * `reset/0` - forgets every call and every programmed result.
    * `put_next/2` - the next call to a callback returns this result instead.
    * `fail_next/2` - shorthand for `put_next(fun, {:error, reason})`.
    * `sign/2` - the signature header value for a raw body, so tests (and the
      webhook tests) can mint a valid delivery; `webhook_body/1` builds one.

  The table is global, so a test that reads `calls/0` runs `async: false`.

  ## Webhook format

  The Fake's delivery is JSON `{"events": [{"event_id", "external_id",
  "kind", "external_url", "error"}]}` signed with HMAC-SHA256 of the RAW
  body, lowercase hex, in header `#{"x-social-fake-signature"}`. The compare is
  `Plug.Crypto.secure_compare/2` (`Platform.Webhooks.GithubSignature`'s pattern).
  """

  @behaviour Platform.Social.Publisher

  use GenServer

  @table :social_fake_publisher
  @signature_header "x-social-fake-signature"

  # ── Table owner ──────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  # ── Test API ─────────────────────────────────────────────────────────

  @doc "Every recorded call, oldest first, as `{fun, args, at}`."
  @spec calls() :: [{atom(), list(), DateTime.t()}]
  def calls do
    @table
    |> :ets.select([{{{:call, :_}, :"$1"}, [], [:"$1"]}])
  end

  @doc "The recorded calls to one callback, oldest first."
  @spec calls(atom()) :: [{atom(), list(), DateTime.t()}]
  def calls(fun) when is_atom(fun), do: Enum.filter(calls(), &match?({^fun, _, _}, &1))

  @doc "Forgets every recorded call and programmed result."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "The next call to `fun` returns `result` (then the default again)."
  @spec put_next(atom(), term()) :: :ok
  def put_next(fun, result) when is_atom(fun) do
    :ets.insert(@table, {{:next, fun}, result})
    :ok
  end

  @doc "The next call to `fun` returns `{:error, reason}`."
  @spec fail_next(atom(), term()) :: :ok
  def fail_next(fun, reason), do: put_next(fun, {:error, reason})

  @doc "The signature header name the Fake checks."
  @spec signature_header() :: String.t()
  def signature_header, do: @signature_header

  @doc "The lowercase-hex HMAC-SHA256 of `raw_body` under `secret`."
  @spec sign(binary(), binary()) :: String.t()
  def sign(raw_body, secret) when is_binary(raw_body) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
  end

  @doc "A Fake webhook body for `events` (maps with the event keys)."
  @spec webhook_body([map()]) :: binary()
  def webhook_body(events) when is_list(events), do: Jason.encode!(%{events: events})

  # ── Publisher callbacks ──────────────────────────────────────────────

  @impl Platform.Social.Publisher
  def connect_url(account, opts) do
    record(:connect_url, [account, opts], fn ->
      redirect = Keyword.get(opts, :redirect_url, "")

      {:ok,
       "https://fake-publisher.example.test/connect/#{account.id}?" <>
         URI.encode_query(%{redirect_url: redirect})}
    end)
  end

  # The default is :not_required: no network, and no invented ref, since a
  # made-up ref stored under the Fake would break connect after a switch to
  # a real vendor.
  @impl Platform.Social.Publisher
  def ensure_profile(profile), do: record(:ensure_profile, [profile], fn -> :not_required end)

  # The default is an empty list: no network, and no invented account ids.
  @impl Platform.Social.Publisher
  def list_accounts(profile), do: record(:list_accounts, [profile], fn -> {:ok, []} end)

  @impl Platform.Social.Publisher
  def platforms, do: Platform.Social.Account.platforms()

  @impl Platform.Social.Publisher
  def publish(account, request) do
    record(:publish, [account, request], fn ->
      {:ok,
       %{external_id: "fake_" <> request.idempotency_key, status: :scheduled, external_url: nil}}
    end)
  end

  @impl Platform.Social.Publisher
  def status(account, external_id) do
    record(:status, [account, external_id], fn ->
      {:ok, %{status: :scheduled, external_url: nil, error: nil}}
    end)
  end

  @impl Platform.Social.Publisher
  def delete(account, external_id), do: record(:delete, [account, external_id], fn -> :ok end)

  @impl Platform.Social.Publisher
  def verify_webhook(%{raw_body: raw_body, headers: headers} = delivery, secret) do
    record(:verify_webhook, [delivery, secret], fn ->
      with true <- is_binary(raw_body) and is_binary(secret) and secret != "",
           signature when is_binary(signature) <- header(headers, @signature_header),
           true <- Plug.Crypto.secure_compare(sign(raw_body, secret), String.downcase(signature)),
           {:ok, events} <- decode(raw_body) do
        {:ok, events}
      else
        _ -> {:error, :invalid_signature}
      end
    end)
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp record(fun, args, default) do
    :ets.insert(
      @table,
      {{:call, System.unique_integer([:monotonic])}, {fun, args, DateTime.utc_now()}}
    )

    case :ets.take(@table, {:next, fun}) do
      [{_, result}] -> result
      [] -> default.()
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"events" => events}} when is_list(events) -> {:ok, Enum.map(events, &event/1)}
      _ -> :error
    end
  end

  defp event(map) when is_map(map) do
    %{
      event_id: map["event_id"],
      external_id: map["external_id"],
      kind: kind(map["kind"]),
      external_url: map["external_url"],
      error: map["error"]
    }
  end

  defp event(_),
    do: %{event_id: nil, external_id: nil, kind: :ignored, external_url: nil, error: nil}

  defp kind("published"), do: :published
  defp kind("failed"), do: :failed
  defp kind(_), do: :ignored
end

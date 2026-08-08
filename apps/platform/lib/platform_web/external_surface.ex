defmodule PlatformWeb.ExternalSurface do
  @moduledoc """
  Single answer to "which external surface is this request on?".

  Three surfaces share one Phoenix endpoint, distinguished only by the request
  hostname: the external CHAT host (`chat.<domain>`, task 019f9257), the guest
  MEET host (`MEET_HOST`), and the primary Suite APP host. Authorization
  decisions that depend on "which surface" must read that answer from HERE
  rather than re-deriving it from `conn.host` at each call site — two
  derivations that drift are two different fences.

  Resolution is fail-closed: anything that is not a positive, exact match for a
  known external surface is `:app`. There is no `||` default, no `rescue`, and
  no catch-all that admits — an unset or blank `:meet_host` means the meet
  surface DOES NOT EXIST, so every host resolves `:chat` or `:app`.

  TWO QUESTIONS, TWO FUNCTIONS. `for_conn/1` matches the CONFIGURED
  `:meet_host` exactly and decides WHETHER AN EXTERNAL USER IS ADMITTED —
  authorization. `router_surface/1` matches the `chat.` and `meet.` hostname
  PREFIXES and decides WHICH HOST SCOPE A REQUEST BELONGS TO — routing. It is
  the exact complement of the two `host:` scopes in `PlatformWeb.Router`.
  They diverge by design: with `:meet_host` unset, a `meet.` host is `:app`
  to `for_conn/1` and `:meet` to `router_surface/1`. Pick the one that
  matches the question being asked.

  `MEET_HOST` is exposed to request-time code as `:meet_host` in
  `config/runtime.exs` (unconditionally, so dev/CI can set it), mirroring how
  `CHAT_HOST` is exposed as `:chat_host` for `PlatformWeb.ExternalRedirect`.
  """

  alias PlatformWeb.ExternalRedirect

  @type surface :: :chat | :meet | :app

  @doc """
  Which external surface a request is on.

  Chat is checked FIRST and that order is load-bearing, not incidental: if
  `MEET_HOST` is ever set to a `chat.`-prefixed hostname, the request resolves
  `:chat` deterministically rather than by whichever clause happened to be
  written first. The shipped chat fence keys on the `chat.` prefix; a meet
  answer on a chat host would route around it.
  """
  @spec for_conn(Plug.Conn.t()) :: surface()
  def for_conn(%Plug.Conn{} = conn) do
    cond do
      on_chat_host?(conn) -> :chat
      on_meet_host?(conn) -> :meet
      true -> :app
    end
  end

  @doc """
  Which ROUTER host scope a request belongs to.

  This answers a DIFFERENT question from `for_conn/1` and the two must not be
  conflated:

    * `for_conn/1` matches the CONFIGURED `:meet_host` EXACTLY and decides
      WHETHER AN EXTERNAL USER IS ADMITTED. It is an authorization input.
    * `router_surface/1` matches the `chat.` and `meet.` hostname PREFIXES and
      decides WHICH HOST SCOPE A REQUEST BELONGS TO. It is the exact
      complement of the two `host:` scopes in `PlatformWeb.Router`, which
      Phoenix compiles as string PREFIX matches.

  The prefix, not the configured value, is the correct rule here precisely
  because `:meet_host` is unset in dev and test — `for_conn/1` therefore
  answers `:app` for a `meet.` host in those environments. A fence built on
  `for_conn/1` would be fail-open everywhere except production. A fence that
  is the complement of the router's mechanism must use the router's
  mechanism.
  """
  @spec router_surface(Plug.Conn.t()) :: surface()
  def router_surface(%Plug.Conn{} = conn) do
    cond do
      on_chat_host?(conn) -> :chat
      String.starts_with?(to_string(conn.host), "meet.") -> :meet
      true -> :app
    end
  end

  @doc """
  Is the request on the external chat host?

  The rule is the `chat.` hostname PREFIX. This is the one definition — the
  chat fence in `PlatformWeb.Plugs.ExternalUserScope` calls it rather than
  keeping a private copy, so the two cannot drift.
  """
  @spec on_chat_host?(Plug.Conn.t()) :: boolean()
  def on_chat_host?(%Plug.Conn{} = conn),
    do: String.starts_with?(to_string(conn.host), "chat.")

  @doc """
  Is a meet host configured? True only for a binary whose `String.trim/1` is
  non-empty — mirrors `ExternalRedirect.chat_host_configured?/0`. Unset or
  blank means the meet surface does not exist.
  """
  @spec meet_host_configured?() :: boolean()
  def meet_host_configured? do
    case meet_host() do
      host when is_binary(host) -> String.trim(host) != ""
      _ -> false
    end
  end

  @doc """
  Is a chat host configured? Delegates to `ExternalRedirect` rather than
  re-deriving — `:chat_host` has exactly one reader.
  """
  @spec chat_host_configured?() :: boolean()
  defdelegate chat_host_configured?(), to: ExternalRedirect

  # Exact match after normalisation, or nothing. Both sides are downcased, and
  # a `":" <> port` suffix is dropped from the CONFIGURED value only — a
  # dev-style value carries a port, `conn.host` never does. A host that merely
  # contains or is suffixed by the configured value (`meet.evil.example.com`)
  # is NOT the meet surface.
  defp on_meet_host?(conn) do
    meet_host_configured?() and
      normalize_host(conn.host) == normalize_configured(meet_host())
  end

  defp normalize_configured(host) do
    host
    |> String.trim()
    |> strip_port()
    |> normalize_host()
  end

  defp strip_port(host) do
    case String.split(host, ":", parts: 2) do
      [host_only, _port] -> host_only
      [host_only] -> host_only
    end
  end

  defp normalize_host(host), do: host |> to_string() |> String.downcase()

  defp meet_host, do: Application.get_env(:platform, :meet_host)
end

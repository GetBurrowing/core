defmodule PlatformWeb.TerminalFakeCli do
  @moduledoc """
  A stand-in for the agent-side terminal CLI and, for tests, for the browser
  (task 01a17b17, protocol v1). Compiled in dev and test only; it is not in
  `lib/` and never ships in a release.

  It is a pure state machine so ChannelTest and the `mix` task share it. Feed
  it what the relay pushes with `handle_event/3` and `handle_binary/3`; it
  returns the new state and a list of actions:

    * `{:push, event, payload_map}`
    * `{:push_binary, event, binary}`
    * `{:print, line}`

  Wire format, byte for byte as in the CLI's `src/terminal/crypto.ts`:

    * X25519, then HKDF-SHA256 (salt = session id, info `burrow-terminal v1
      cli->browser` / `burrow-terminal v1 browser->cli`) into two AES-256-GCM
      keys;
    * frame = `counter (8 bytes, big endian) || ciphertext || 16-byte tag`,
      nonce = `direction id (4 bytes) || counter (8 bytes)`, no AAD;
    * plaintext = `kind (1 byte) || body`, kind 0 raw bytes, kind 1 JSON.

  Unlike the real bridge, this fake does NOT drop `in` frames while read-only:
  it counts and echoes whatever reaches it, so a review agent can see whether
  the relay let one through.
  """

  @info_c2b "burrow-terminal v1 cli->browser"
  @info_b2c "burrow-terminal v1 browser->cli"
  @dir_c2b 1
  @dir_b2c 2

  # ── crypto, shared with tests acting as the browser ──

  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
    %{public: pub, private: priv}
  end

  def public_of(priv) do
    {pub, _} = :crypto.generate_key(:ecdh, :x25519, priv)
    pub
  end

  @doc "`{send_key, recv_key}` for `:cli` or `:browser`."
  def derive_keys(role, own_private, peer_public, session_id) when role in [:cli, :browser] do
    shared = :crypto.compute_key(:ecdh, peer_public, own_private, :x25519)
    c2b = hkdf(shared, session_id, @info_c2b)
    b2c = hkdf(shared, session_id, @info_b2c)
    if role == :cli, do: {c2b, b2c}, else: {b2c, c2b}
  end

  # One 32-byte block, so a single HKDF-expand round.
  defp hkdf(ikm, salt, info) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  def seal(key, direction, counter, plaintext) do
    nonce = <<direction::32, counter::64>>
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, <<>>, 16, true)
    <<counter::64, ct::binary, tag::binary>>
  end

  @doc "`{:ok, counter, plaintext}` or `:error`."
  def open(key, direction, <<counter::64, rest::binary>>) when byte_size(rest) >= 16 do
    ct_size = byte_size(rest) - 16
    <<ct::binary-size(^ct_size), tag::binary-size(16)>> = rest
    nonce = <<direction::32, counter::64>>

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ct, <<>>, tag, false) do
      plain when is_binary(plain) -> {:ok, counter, plain}
      _ -> :error
    end
  end

  def open(_key, _direction, _frame), do: :error

  def direction(:cli_to_browser), do: @dir_c2b
  def direction(:browser_to_cli), do: @dir_b2c

  # ── the CLI state machine ──

  def new(opts \\ []) do
    %{
      keypair: Keyword.get_lazy(opts, :keypair, &generate_keypair/0),
      folder: Keyword.get(opts, :folder, "/fake/folder"),
      session_id: nil,
      send_key: nil,
      recv_key: nil,
      next_out: 0,
      last_in: -1,
      in_count: 0,
      line_mode: Keyword.get(opts, :line_mode, false),
      line: ""
    }
  end

  def in_count(%{in_count: n}), do: n

  def handle_event(state, "open", %{"session_id" => sid}) when is_binary(sid) do
    state = %{
      new(keypair: state.keypair, folder: state.folder, line_mode: state.line_mode)
      | session_id: sid
    }

    {state, [{:push, "hello", %{"pub" => Base.encode64(state.keypair.public)}}]}
  end

  def handle_event(%{session_id: sid, send_key: nil} = state, "hello", %{"pub" => pub})
      when is_binary(sid) and is_binary(pub) do
    case Base.decode64(pub) do
      {:ok, peer} when byte_size(peer) == 32 ->
        {send_key, recv_key} = derive_keys(:cli, state.keypair.private, peer, sid)
        state = %{state | send_key: send_key, recv_key: recv_key}
        {state, cwd} = seal_out(state, 1, Jason.encode!(%{cwd: state.folder}))
        {state, ready} = seal_out(state, 0, "fake-cli ready\r\n")

        {state,
         [
           {:push_binary, "out", cwd},
           {:push_binary, "out", ready},
           {:print, "fake-cli ready"}
         ]}

      _ ->
        {state, [{:print, "hello rejected"}]}
    end
  end

  def handle_event(state, _event, _payload), do: {state, []}

  def handle_binary(%{recv_key: key} = state, "in", frame) when is_binary(key) do
    state = %{state | in_count: state.in_count + 1}
    counted = {:print, "in frames received: #{state.in_count}"}

    with {:ok, counter, <<0, text::binary>>} <- open(key, @dir_b2c, frame),
         true <- counter > state.last_in do
      state = %{state | last_in: counter}
      {state, replies} = echo(state, text)
      {state, [counted | Enum.map(replies, &{:push_binary, "out", &1})]}
    else
      _ -> {state, [counted]}
    end
  end

  def handle_binary(state, _event, _frame), do: {state, []}

  # Per frame by default: `echo:<text>`. In line mode (the mix task, where a
  # person types one key per frame) a line is echoed once Enter completes it, so
  # typing `xyz` and Enter reads `echo:xyz`.
  defp echo(%{line_mode: false} = state, text), do: seal_out_each(state, ["echo:" <> text])

  defp echo(%{line_mode: true} = state, text) do
    parts = String.split(state.line <> text, ["\r\n", "\r", "\n"])
    {done, [rest]} = Enum.split(parts, -1)
    lines = for l <- done, l != "", do: "echo:" <> l <> "\r\n"
    seal_out_each(%{state | line: rest}, lines)
  end

  defp seal_out_each(state, bodies) do
    Enum.reduce(bodies, {state, []}, fn body, {st, acc} ->
      {st, frame} = seal_out(st, 0, body)
      {st, acc ++ [frame]}
    end)
  end

  defp seal_out(state, kind, body) do
    frame = seal(state.send_key, @dir_c2b, state.next_out, <<kind, body::binary>>)
    {%{state | next_out: state.next_out + 1}, frame}
  end
end

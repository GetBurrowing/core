defmodule Platform.Chat.AgentResponderAttachmentOnlyTest do
  @moduledoc """
  Task 019ff107 — an attachment-only chat message must not reach an agent as
  an empty body.

  Every assertion here is on **what the agent actually receives** — the body
  handed to the provider on the built-in path, and the broadcast payload on the
  federated path — never on the presence of a row or an `:ok`. That distinction
  is the whole ticket: the rows were always there; the agent could not see them,
  and told a human her message had arrived empty.

  Three outcomes must stay distinguishable from each other:

    * text present            — the text, unchanged
    * no text, attachments    — a body naming count, filenames, types, sizes, URLs
    * no text, no attachments — still empty; nothing arrived and saying so is right

  The third is a real guard, not a formality. Rendering "0 attachments" for
  every content-free wake would be the mirror-image defect.

  ## Where the trap is

  `Ecto.cast/3` treats `""` as a missing value, so a message posted with an
  empty body persists `content` as **NULL**. A test that asserts on `""`
  is asserting on a value the database never holds; `nil_content_is_the_real_shape`
  below pins that, so the rest of this file cannot quietly test a shape that
  does not occur.
  """

  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "ack", model: "stub", usage: %{}}}
    end
  end

  setup do
    prev = {
      Application.get_env(:platform, :chat_agent_module),
      Application.get_env(:platform, :chat_agent_dispatch_mode),
      Application.get_env(:platform, :chat_agent_test_pid)
    }

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      {m, d, pid} = prev
      Application.put_env(:platform, :chat_agent_module, m)
      Application.put_env(:platform, :chat_agent_dispatch_mode, d)
      Application.put_env(:platform, :chat_agent_test_pid, pid)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp space_with_author do
    {:ok, space} =
      Chat.create_space(%{
        name: "Attach",
        slug: "attach-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Marlowe",
        joined_at: DateTime.utc_now()
      })

    {space, author}
  end

  defp agent_attrs(extra) do
    Map.merge(
      %{
        name: "Attach Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      },
      extra
    )
  end

  # A built-in (non-external) agent, made the space's active agent so a message
  # carrying no text — and therefore no @mention to parse — still routes. This
  # is the ticket's own reason code: `:active_agent`.
  defp active_builtin_agent(space) do
    u = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(agent_attrs(%{slug: "builtin-#{u}"}))
      |> Repo.insert()

    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Attach Agent")
    ActiveAgentStore.set_active(space.id, participant.id)
    {agent, participant}
  end

  defp active_external_agent(space) do
    u = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "attach-#{u}@example.com",
        name: "Owner",
        oidc_sub: "oidc-attach-#{u}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-attach-#{u}",
        display_name: "attach-rt"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(
        agent_attrs(%{slug: "ext-#{u}", runtime_type: "external", runtime_id: runtime.id})
      )
      |> Repo.insert()

    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Attach Agent")
    ActiveAgentStore.set_active(space.id, participant.id)

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)
    {agent, participant, topic}
  end

  defp post!(space, author, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: content
      })

    message
  end

  defp attach!(space, message, filename, content_type, byte_size, opts \\ []) do
    storage_key = Keyword.get(opts, :storage_key, "chat/test/#{Ecto.UUID.generate()}")

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        filename: filename,
        content_type: content_type,
        byte_size: byte_size,
        storage_key: storage_key,
        state: "ready"
      })

    attachment
  end

  # The body the built-in agent's provider is handed for `message`. Keyed on
  # the trigger's own id via the history/space, not on arrival order: the
  # router is asynchronous and a space can have more than one dispatch in
  # flight, so "the first thing that arrives" is not a stable identifier.
  defp provider_body_for(message) do
    # `Chat.post_message/1` routes on its own, so every fixture posted before
    # this point already has a dispatch in flight, and the router is
    # asynchronous. Settle those (`:__drain__` returns only once the router's
    # mailbox is clear) and discard them, THEN route `message` explicitly — so
    # the reply asserted on is unambiguously this message's and not an earlier
    # fixture's whose history happened to be built after the trigger landed.
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    flush_agent_calls()

    {:ok, _} = AttentionRouter.route(message)
    assert_receive {:agent_chat_called, body, opts}, 2000
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    {body, opts}
  end

  defp flush_agent_calls do
    receive do
      {:agent_chat_called, _body, _opts} -> flush_agent_calls()
    after
      0 -> :ok
    end
  end

  defp broadcast_for(topic, message) do
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    {:ok, _} = AttentionRouter.route(message)
    payload = await_broadcast(topic, message.id)
    assert :ok = GenServer.call(AttentionRouter, :__drain__)
    payload
  end

  defp await_broadcast(topic, message_id) do
    receive do
      %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention", payload: payload} ->
        if payload.signal[:message_id] == message_id,
          do: payload,
          else: await_broadcast(topic, message_id)
    after
      2000 -> flunk("no attention broadcast on #{topic} for message #{message_id}")
    end
  end

  # ── the shape the database actually holds ───────────────────────────────

  describe "nil_content_is_the_real_shape" do
    test "a message posted with an empty body persists content as NULL, not \"\"" do
      {space, author} = space_with_author()
      message = post!(space, author, "")

      # If this ever becomes "" the guard in `history_message/3` no longer
      # needs `is_nil(content)` — and every attachment-only assertion below
      # would be exercising a shape the product cannot produce.
      assert is_nil(message.content)
      assert is_nil(Chat.get_message(message.id).content)
    end
  end

  # ── built-in agent: the body the provider receives ──────────────────────

  describe "built-in dispatch — the body handed to the provider" do
    test "attachment-only message names count, filenames, types, sizes and URLs" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      message = post!(space, author, "")
      tags = attach!(space, message, "tags.png", "image/png", 133_986)
      schema = attach!(space, message, "schema.png", "image/png", 343_231)

      {body, _opts} = provider_body_for(message)

      # The agent must be able to say "you sent me two PNGs" — so every fact
      # it would need for that sentence is asserted individually. A body that
      # merely stops being empty is not the fix.
      assert body =~ "2 attachment(s)"
      assert body =~ "tags.png"
      assert body =~ "schema.png"
      assert body =~ "image/png"
      assert body =~ "133986 bytes"
      assert body =~ "343231 bytes"

      # And the ids, so it can fetch without asking the human to resend.
      assert body =~ "/chat/attachments/#{tags.id}"
      assert body =~ "/chat/attachments/#{schema.id}"
    end

    test "POSITIVE CONTROL — a text message's body reaches the provider unchanged" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      message = post!(space, author, "here is the taxonomy")
      _ = attach!(space, message, "taxonomy.png", "image/png", 133_986)

      {body, _opts} = provider_body_for(message)

      # Byte-for-byte the human's words. The attachment must NOT displace or
      # decorate a real body — a fix that prefixed every message with a
      # manifest would pass the test above and fail here.
      assert body == "here is the taxonomy"
      refute body =~ "attachment(s)"
      refute body =~ "taxonomy.png"
    end

    test "NEGATIVE CONTROL — a message with no text AND no attachments stays empty" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      message = post!(space, author, "")

      # No `attach!` call here — that absence is the whole test.
      {body, _opts} = provider_body_for(message)

      # Not "0 attachment(s)", not a placeholder sentence. Nothing arrived,
      # and the agent is entitled to see nothing. This is the branch that
      # keeps "attachments, no text" and "nothing at all" different facts.
      assert body == ""
      refute body =~ "attachment"
    end
  end

  # ── history: prior turns the agent is shown ─────────────────────────────

  describe "history — a prior attachment-only turn" do
    test "appears, naming its attachments, instead of vanishing" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      prior = post!(space, author, "")
      shot = attach!(space, prior, "prior.png", "image/png", 999)

      trigger = post!(space, author, "what do you make of it")
      {_body, opts} = provider_body_for(trigger)

      entry =
        Enum.find(opts[:history], fn h ->
          is_binary(h.content) and h.content =~ "prior.png"
        end)

      assert entry, "the attachment-only turn is missing from history: #{inspect(opts[:history])}"
      assert entry.role == "user"
      assert entry.content =~ "1 attachment(s)"
      assert entry.content =~ "999 bytes"
      assert entry.content =~ "/chat/attachments/#{shot.id}"

      # The author prefix that every other user turn carries — the agent must
      # be able to tell WHO sent the screenshot, not just that one exists.
      assert entry.content =~ "Marlowe:"

      # Structured metadata still travels alongside the rendered body.
      assert [%{filename: "prior.png", content_type: "image/png", byte_size: 999}] =
               entry.attachments
    end

    test "POSITIVE CONTROL — a prior TEXT turn still renders its text, not a manifest" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      prior = post!(space, author, "see attached")
      shot = attach!(space, prior, "prior.png", "image/png", 999)

      trigger = post!(space, author, "what do you make of it")
      {_body, opts} = provider_body_for(trigger)

      entry =
        Enum.find(opts[:history], fn h ->
          is_binary(h.content) and h.content =~ "see attached"
        end)

      assert entry
      assert entry.content == "Marlowe: see attached"
      refute entry.content =~ "attachment(s)"

      assert [%{url: url}] = entry.attachments
      assert url == "/chat/attachments/#{shot.id}"
    end

    test "NEGATIVE CONTROL — a prior turn with no text and no attachments is still dropped" do
      {space, author} = space_with_author()
      {_agent, _participant} = active_builtin_agent(space)

      empty = post!(space, author, "")
      trigger = post!(space, author, "what do you make of it")

      {_body, opts} = provider_body_for(trigger)

      # `history_message/3` must still return nil for this row.
      refute Enum.any?(opts[:history], fn h ->
               is_binary(h.content) and h.content =~ "attachment"
             end)

      # The stronger claim: the empty row contributed NO turn at all. Every
      # user-role turn in this space would have to be `empty` — the trigger is
      # excluded from its own history and the author posted nothing else — so
      # a single user-role entry here means the drop stopped happening.
      # (Assistant turns are the stub's own persisted replies and are expected.)
      user_turns = Enum.filter(opts[:history], &(&1.role == "user"))

      assert user_turns == [],
             "empty message #{empty.id} produced a history turn: #{inspect(user_turns)}"
    end
  end

  # ── federated dispatch: the payload the runtime receives ────────────────

  describe "external dispatch — the broadcast payload" do
    test "attachment-only message carries every attachment fact structurally" do
      {space, author} = space_with_author()
      {_agent, _participant, topic} = active_external_agent(space)

      message = post!(space, author, "")
      tags = attach!(space, message, "tags.png", "image/png", 133_986)
      schema = attach!(space, message, "schema.png", "image/png", 343_231)

      payload = broadcast_for(topic, message)

      assert [
               %{
                 filename: "tags.png",
                 content_type: "image/png",
                 byte_size: 133_986,
                 url: tags_url
               },
               %{
                 filename: "schema.png",
                 content_type: "image/png",
                 byte_size: 343_231,
                 url: schema_url
               }
             ] = payload.message.attachments

      assert tags_url == "/chat/attachments/#{tags.id}"
      assert schema_url == "/chat/attachments/#{schema.id}"

      # DELIBERATE: `message.content` stays the literal (empty) body. The
      # federated runtime is handed the attachments structurally and renders
      # them client-side; duplicating a manifest into `content` would put the
      # same facts in two places and let a client read whichever it found
      # first. If this assertion is ever relaxed, the built-in path's
      # `agent_body/2` and this decision have to be revisited together.
      assert payload.message.content == ""
      assert payload.message.author == "Marlowe"
    end

    test "POSITIVE CONTROL — a text message's content survives verbatim" do
      {space, author} = space_with_author()
      {_agent, _participant, topic} = active_external_agent(space)

      message = post!(space, author, "here is the taxonomy")
      shot = attach!(space, message, "taxonomy.png", "image/png", 133_986)

      payload = broadcast_for(topic, message)

      assert payload.message.content == "here is the taxonomy"
      assert [%{url: url, filename: "taxonomy.png"}] = payload.message.attachments
      assert url == "/chat/attachments/#{shot.id}"
    end
  end

  # ── retrieval: can the agent actually read what it was told about? ──────

  describe "attachment.get_inline round-trip" do
    test "the UUID in the dispatched URL fetches the real bytes" do
      root = Path.join(System.tmp_dir!(), "attach-only-#{Ecto.UUID.generate()}")
      previous = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if previous do
          Application.put_env(:platform, :chat_attachments_root, previous)
        else
          Application.delete_env(:platform, :chat_attachments_root)
        end
      end)

      bytes = "PNG-ish bytes for task 019ff107"
      storage_key = "chat/test/inline-#{Ecto.UUID.generate()}.png"
      target = Path.join(root, storage_key)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)

      {space, author} = space_with_author()
      {agent, participant} = active_builtin_agent(space)

      message = post!(space, author, "")

      shot =
        attach!(space, message, "tags.png", "image/png", byte_size(bytes),
          storage_key: storage_key
        )

      {body, _opts} = provider_body_for(message)

      # Take the id back OUT of the body the agent was given, rather than
      # reusing `shot.id` from the fixture. That is the actual question the
      # ticket asks — not "does get_inline work" but "can the agent get from
      # what it was TOLD to the bytes". Reusing the fixture id would prove
      # nothing about the rendered body.
      [_, quoted] = Regex.run(~r"/chat/attachments/([0-9a-f-]{36})", body)
      assert quoted == shot.id

      {:ok, result} =
        ToolSurface.execute(
          "attachment.get_inline",
          %{"attachment_id" => quoted},
          %{agent_id: agent.id, agent_participant_id: participant.id}
        )

      assert result.filename == "tags.png"
      assert result.content_type == "image/png"
      assert result.byte_size == byte_size(bytes)
      assert {:ok, ^bytes} = Base.decode64(result.data_base64)

      # The fixture bytes are not a real PNG, so no MCP image block is
      # offered (task 01a0fcfa). Assert it rather than let it pass silently.
      refute Map.has_key?(result, :__mcp_image__)
      assert result.image_block_skipped =~ "not PNG, JPEG, GIF or WebP"
    end
  end
end

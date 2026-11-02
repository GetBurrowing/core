defmodule Platform.Federation.Peers.Ingest do
  @moduledoc """
  Posts a peer install's shared-space message into the local copy of the
  space (task 01a0d90f stage 5, ADR 0054 section 3). Input is a VERIFIED
  `message.replicate` (owner to replica) or `message.submit` (replica to
  owner) envelope from an active peer.

  It mirrors `Platform.Mail.Inbound`'s posting path (`post/3`,
  `render_content/3`, `ensure_email_participant/1`): the text of a remote
  install is untrusted outside text, exactly like an email body.

  ## Remote content never adds a participant or dispatches an agent

  `Chat.reinvite_and_pin_mentioned/1` scans every posted message for mention
  tokens and summons the matching agents when `mention_summon_authorized?/2`
  passes, which is keyed on the message's `author_user_id`. Four things hold
  the line, each on its own:

    1. every `@[` in the content (and in the author's display name) is
       escaped by `ExternalContent.escape_mentions/1`, so no token survives
       to be matched;
    2. metadata carries `"skip_mention_scan" => true`, so AttentionRouter's
       mention legs skip it;
    3. metadata `"source" => "federation_inbound"` makes
       `AttentionRouter.untrusted_inbound?/1` true, which yields no agent
       decision at all (not the armed mutex holder either) and fires no
       chat-pattern responsibility;
    4. the author is ONLY the local system participant built here. The
       message attrs are a fixed literal: the payload is never passed
       through or merged, so a payload `author_user_id` or `author_agent_id`
       never reaches `Chat.post_message/2`, which would otherwise keep a
       caller-supplied author snapshot (ADR 0054, stage 1 finding).

  ## One system participant per (peer, space, remote author)

  Its `participant_id` is `Platform.UUID.deterministic/1` of
  `"federation_inbound:<peer_id>:<space_id>:<remote author id>"`, so it is
  the same row on every message and never a local user or agent. Its display
  name is the remote author's name, one line, capped, plus
  `" (via <peer>)"`, mention-escaped.

  ## Idempotency

  The `(peer_id, remote_message_id)` unique index on
  `federation_message_links` is the only guard against a duplicate delivery
  that `Envelope.verify/3` lets through. The `NonceCache` is per node and in
  memory, so an envelope replayed after a restart, or to another node,
  inside the 300 s window PASSES verification. The link row is inserted as a
  claim BEFORE the post: a second delivery, concurrent or later, loses the
  insert and posts nothing. A failed post deletes the claim so the peer's
  retry can apply it. A node killed between the claim and the post leaves the
  claim with no message (the peer's retry is then acknowledged and the
  message is lost); that window is one insert wide.
  """

  require Logger

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Federation.Peers.MessageLink
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.SharedSpace
  alias Platform.Federation.Peers.SharedSpaces
  alias Platform.Repo
  alias Platform.Security.ExternalContent

  @content_cap_bytes 32 * 1024
  @name_cap 80
  @author_id_cap 128

  @doc "Maximum bytes of remote message body kept (32 KB)."
  def content_cap_bytes, do: @content_cap_bytes

  @doc "The shared-space role that RECEIVES each relay type."
  def receiving_role("message.replicate"), do: "replica"
  def receiving_role("message.submit"), do: "owner"

  @doc """
  Ingests one relay envelope. Returns `{:ok, :message_ingested | :already_applied,
  %{"message_id" => local_id}}` or `{:error, reason}`.
  """
  @spec ingest(Peer.t(), String.t(), map()) :: {:ok, atom(), map()} | {:error, atom()}
  def ingest(%Peer{status: "active"} = peer, type, payload)
      when type in ["message.replicate", "message.submit"] and is_map(payload) do
    with {:ok, fields} <- parse(payload),
         {:ok, shared} <- shared_space(peer, fields.space_id, receiving_role(type)),
         {:ok, space} <- usable_space(shared.local_space_id) do
      claim_and_post(peer, space, fields)
    end
  end

  def ingest(%Peer{}, _type, _payload), do: {:error, :peer_not_active}

  # ── payload ────────────────────────────────────────────────────────────

  defp parse(%{"space_id" => space_id, "message_id" => message_id, "content" => content} = p)
       when is_binary(space_id) and is_binary(message_id) and is_binary(content) do
    author = if is_map(p["author"]), do: p["author"], else: %{}

    if Platform.UUID.valid?(space_id) and Platform.UUID.valid?(message_id) and content != "" do
      {:ok,
       %{
         space_id: String.downcase(space_id),
         message_id: String.downcase(message_id),
         content: String.replace_invalid(content),
         author_key: author_key(author),
         author_name: author_name(author["name"])
       }}
    else
      {:error, :invalid_payload}
    end
  end

  defp parse(_), do: {:error, :invalid_payload}

  defp author_key(%{"id" => id}) when is_binary(id) and byte_size(id) in 1..@author_id_cap,
    do: id

  defp author_key(_), do: "unknown"

  defp author_name(name) when is_binary(name) do
    case name |> ExternalContent.sanitize_line() |> String.trim() |> String.slice(0, @name_cap) do
      "" -> "Unknown"
      clean -> clean
    end
  end

  defp author_name(_), do: "Unknown"

  defp shared_space(%Peer{} = peer, space_id, role) do
    case SharedSpaces.get_active(peer.id, space_id) do
      %SharedSpace{role: ^role} = shared -> {:ok, shared}
      %SharedSpace{} -> {:error, :wrong_space_role}
      nil -> {:error, :unknown_shared_space}
    end
  end

  defp usable_space(space_id) do
    case Chat.get_space(space_id) do
      %{archived_at: nil} = space -> {:ok, space}
      _ -> {:error, :unknown_shared_space}
    end
  end

  # ── claim, then post ───────────────────────────────────────────────────

  defp claim_and_post(peer, space, fields) do
    claim =
      %MessageLink{}
      |> MessageLink.changeset(%{
        peer_id: peer.id,
        remote_message_id: fields.message_id,
        direction: "inbound"
      })
      |> Repo.insert()

    case claim do
      {:ok, link} ->
        post(peer, space, fields, link)

      {:error, %Ecto.Changeset{}} ->
        {:ok, :already_applied, %{"message_id" => existing_local_id(peer.id, fields.message_id)}}
    end
  end

  defp existing_local_id(peer_id, remote_message_id) do
    from(l in MessageLink,
      where: l.peer_id == ^peer_id and l.remote_message_id == ^remote_message_id,
      select: l.local_message_id
    )
    |> Repo.all()
    |> List.first()
  end

  defp post(peer, space, fields, link) do
    result =
      try do
        with {:ok, participant} <- ensure_participant(peer, space.id, fields) do
          # A FIXED LITERAL: nothing from the payload but the rendered text.
          Chat.post_message(%{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: render_content(peer, fields),
            metadata: metadata(peer, fields)
          })
        end
      rescue
        error -> {:error, {:raised, error.__struct__}}
      end

    case result do
      {:ok, message} ->
        link |> Ecto.Changeset.change(local_message_id: message.id) |> Repo.update!()
        warn_suspicious(peer, fields)
        {:ok, :message_ingested, %{"message_id" => message.id}}

      {:error, reason} ->
        _ = Repo.delete(link)

        Logger.warning(
          "[federation] ingest failed peer_id=#{peer.id} space_id=#{space.id} " <>
            "remote_message_id=#{fields.message_id} reason=#{inspect(reason_class(reason))}"
        )

        {:error, :ingest_failed}
    end
  end

  defp reason_class(%Ecto.Changeset{}), do: :invalid_message
  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class({:raised, module}), do: {:raised, module}
  defp reason_class(_), do: :other

  @doc false
  def metadata(%Peer{} = peer, fields) do
    %{
      "source" => "federation_inbound",
      "skip_mention_scan" => true,
      "peer_id" => peer.id,
      "remote_message_id" => fields.message_id,
      "peer_display_name" => ExternalContent.escape_mentions(SharedSpaces.peer_label(peer)),
      "remote_author" => ExternalContent.escape_mentions(fields.author_name)
    }
  end

  @doc """
  The chat content for an ingested message: a provenance line outside the
  wrapper, the wrapped body (capped at `content_cap_bytes/0`), a truncation
  note when capped, and every `@[` escaped. Public for tests.
  """
  @spec render_content(Peer.t(), map()) :: String.t()
  def render_content(%Peer{} = peer, fields) do
    peer_label = SharedSpaces.peer_label(peer)
    {body, truncated_from} = cap_body(fields.content)

    provenance = "Shared from #{peer_label} by #{fields.author_name}"

    wrapped =
      ExternalContent.wrap(body,
        source: :federation,
        sender: "#{fields.author_name} (via #{peer_label})"
      )

    note =
      case truncated_from do
        nil ->
          []

        size ->
          [
            "[Truncated: the message is #{size} bytes; the first #{@content_cap_bytes} are shown.]"
          ]
      end

    [provenance, wrapped | note]
    |> Enum.join("\n\n")
    |> ExternalContent.escape_mentions()
  end

  # ── the human view (inverse of render_content/2) ───────────────────────

  # Sentinels rendered through the REAL `ExternalContent.wrap/2` to derive the
  # wrapper's literal text (notice, marker spelling, Source/From/--- lines), so
  # the unwrap regex never restates any of it. Plain ASCII letters: neither
  # `sanitize/1` nor `sanitize_line/1` alters them.
  @sentinel_id "HUMANCONTENTSENTINELID"
  @sentinel_from "HUMANCONTENTSENTINELFROM"
  @sentinel_body "HUMANCONTENTSENTINELBODY"
  @human_regex_key {__MODULE__, :human_content_regex}

  @doc """
  The text a HUMAN should see for content produced by `render_content/2`: the
  peer's sanitized body (plus the truncation note, on its own paragraph, when
  the body was capped), without the `Shared from` line, the SECURITY NOTICE or
  the boundary markers. Agents never read this; the stored form is theirs.

  It is ONE anchored regex: the end marker must carry the start marker's id
  (backreference) and be followed by nothing but the optional truncation note
  and end-of-string. A body cannot forge the end: markers in it were
  neutralized by `ExternalContent.sanitize/1`, and the 16-hex id is random per
  message. ANY input that does not match whole is returned UNCHANGED, so a
  surprise shows the human the notice rather than a mis-cut body.
  """
  @spec human_content(String.t()) :: String.t()
  def human_content(content) when is_binary(content) do
    case Regex.named_captures(human_regex(), content) do
      %{"body" => body, "note" => ""} -> body
      %{"body" => body, "note" => note} -> body <> "\n\n" <> note
      nil -> content
    end
  end

  defp human_regex do
    case :persistent_term.get(@human_regex_key, nil) do
      nil ->
        regex = Regex.compile!(human_regex_source(), "su")
        :persistent_term.put(@human_regex_key, regex)
        regex

      regex ->
        regex
    end
  end

  @doc false
  def human_regex_source do
    template =
      ExternalContent.wrap(@sentinel_body,
        source: :federation,
        sender: @sentinel_from,
        id: @sentinel_id
      )

    # warning ... start-id | ">>>\nSource: Burrow peer\nFrom: " | "\n---\n" |
    # "\n<<<END... id=\"" | "\">>>"
    [before_start_id, before_from, before_body, before_end_id, after_end_id] =
      String.split(template, [@sentinel_id, @sentinel_from, @sentinel_body])

    "\\AShared from [^\\n]*\\n\\n" <>
      Regex.escape(before_start_id) <>
      "(?<id>[0-9a-f]{16})" <>
      Regex.escape(before_from) <>
      "[^\\n]*" <>
      Regex.escape(before_body) <>
      "(?<body>.*)" <>
      Regex.escape(before_end_id) <>
      "\\1" <>
      Regex.escape(after_end_id) <>
      "(?:\\n\\n(?<note>\\[Truncated: the message is \\d+ bytes; the first \\d+ are shown\\.\\]))?" <>
      "\\z"
  end

  defp cap_body(body) when byte_size(body) <= @content_cap_bytes, do: {body, nil}

  defp cap_body(body) do
    {trim_partial_codepoint(binary_part(body, 0, @content_cap_bytes)), byte_size(body)}
  end

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # ── the system participant ─────────────────────────────────────────────

  @doc "The remote author's participant_id in `space_id` (deterministic)."
  @spec participant_id(Peer.t(), String.t(), String.t()) :: String.t()
  def participant_id(%Peer{id: peer_id}, space_id, author_key) do
    Platform.UUID.deterministic("federation_inbound:#{peer_id}:#{space_id}:#{author_key}")
  end

  @doc false
  def display_name(%Peer{} = peer, author_name) do
    ExternalContent.escape_mentions(
      author_name <> " (via " <> SharedSpaces.peer_label(peer) <> ")"
    )
  end

  defp ensure_participant(peer, space_id, fields) do
    participant_id = participant_id(peer, space_id, fields.author_key)
    name = display_name(peer, fields.author_name)

    case find_participant(space_id, participant_id) do
      %Participant{display_name: ^name} = participant ->
        {:ok, participant}

      %Participant{} = participant ->
        participant |> Ecto.Changeset.change(display_name: name) |> Repo.update()

      nil ->
        case Chat.add_participant(space_id, %{
               participant_type: "system",
               participant_id: participant_id,
               display_name: name,
               attention_mode: "mention",
               joined_at: DateTime.utc_now()
             }) do
          {:ok, participant} ->
            {:ok, participant}

          {:error, %Ecto.Changeset{}} = error ->
            # A concurrent first message from the same author won the insert.
            case find_participant(space_id, participant_id) do
              %Participant{} = participant -> {:ok, participant}
              nil -> error
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp find_participant(space_id, participant_id) do
    from(p in Participant,
      where:
        p.space_id == ^space_id and p.participant_type == "system" and
          p.participant_id == ^participant_id
    )
    |> Repo.all()
    |> List.first()
  end

  defp warn_suspicious(peer, fields) do
    case ExternalContent.detect_suspicious_patterns(fields.content) do
      [] ->
        :ok

      patterns ->
        Logger.warning(
          "[federation] suspicious patterns in peer message peer_id=#{peer.id} " <>
            "remote_message_id=#{fields.message_id} patterns=#{inspect(patterns)}"
        )
    end
  end
end

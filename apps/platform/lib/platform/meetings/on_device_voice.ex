defmodule Platform.Meetings.OnDeviceVoice do
  @moduledoc """
  The Voice tab's on-device path (task 01a20dc5 stage 2): an iPhone that
  transcribes on the device (the `BurrowVoice` native plugin) sends each turn
  as TEXT, and the agent's reply comes back as an ordinary DM message that
  the phone speaks with the system voice.

  ## Why a plain DM message, not a voice row

  A turn recorded by `Platform.Meetings.VoiceSession.record_turn/5` carries
  `metadata.source = "voice"` and a `voice_session_id`, and
  `Platform.Chat.AttentionRouter` routes those rows to NOBODY (the voice
  worker already answered them out loud). This path has no voice worker, so
  a voice row would never be answered. The on-device turn is therefore a
  plain text message in the user<->agent DM, tagged only with
  `metadata.input = "on_device"` and the device's `client_turn_id`: it routes
  `:directed` to the agent exactly as a typed DM message does, and the agent
  answers in text.

  No LiveKit room, no token, no voice worker: `open/2` only finds the DM and
  authorises both sides as writers, as `VoiceSession.start/3` does.

  Known prototype limit: a turn goes to the DM even when the Voice tab has a
  context set.

  ## Streamed replies (task 01a20fdd stage 3)

  Speech can start before the reply is posted only if the agent streams it
  with `reply_chunk`. Core broadcasts `{:agent_reply_chunk, _}` solely from
  `PlatformWeb.RuntimeChannel`'s `reply_chunk`, and the channel plugins tell
  agents to stream only long replies, so a short spoken answer usually
  arrives as one posted message. So the agent is asked to stream: for a
  message with `metadata.input = "on_device"`, `agent_content/1` adds
  `instruction/0` after a blank line to the body the agent is HANDED
  (`Platform.Chat.AgentResponder`'s `user_message`, which both the built-in
  and the runtime dispatch read). The stored message keeps only the words
  the person said, so the DM, search, memory and exports never carry the
  instruction. `speakable_sentences/3` cuts the cumulative chunk text into
  the sentences the phone may speak.
  """

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.SpaceAccess

  @instruction "(Spoken on an iPhone: answer in short spoken-style sentences, plain text, no markdown. Stream it with burrow_reply_chunk, or suite_reply_chunk on a channel plugin older than 0.5.0.)"

  # Words a period ends without ending the sentence (compared lowercased,
  # without the final period).
  @abbreviations ~w(e.g i.e etc vs mr mrs ms dr prof sr jr st no approx dept est inc ltd co fig u.s a.m p.m)

  @type conn :: %{
          space_id: binary(),
          agent_id: binary(),
          user_participant_id: binary(),
          agent_participant_id: binary(),
          turn_at: DateTime.t() | nil
        }

  @doc """
  Opens the on-device conversation between `user` and `agent`: the DM, found
  or created, with both sides authorised to write.
  """
  @spec open(map(), Agent.t()) :: {:ok, conn()} | {:error, term()}
  def open(%{id: user_id} = user, %Agent{} = agent) do
    with {:ok, dm} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
         {:ok, user_participant} <- SpaceAccess.authorize_writer(dm.id, user),
         {:ok, agent_participant} <- SpaceAccess.authorize_writer(dm.id, {:agent, agent.id}) do
      {:ok,
       %{
         space_id: dm.id,
         agent_id: agent.id,
         user_participant_id: user_participant.id,
         agent_participant_id: agent_participant.id,
         turn_at: nil
       }}
    end
  end

  @doc """
  Posts one on-device turn as the user: a plain text DM message with
  `metadata.input = "on_device"` and the device's `client_turn_id`. Never
  `source: "voice"`, never a `voice_session_id`, never `route: :none`.

  Returns the conn with `turn_at` moved to the message's insert time, so
  `agent_reply?/2` only takes the agent's messages after it.
  """
  @spec send_turn(conn(), String.t(), String.t()) ::
          {:ok, conn(), Message.t()} | {:error, term()}
  def send_turn(conn, text, client_turn_id) when is_binary(text) and is_binary(client_turn_id) do
    case String.trim(text) do
      "" ->
        {:error, :blank}

      content ->
        attrs = %{
          space_id: conn.space_id,
          participant_id: conn.user_participant_id,
          content_type: "text",
          content: content,
          metadata: %{"input" => "on_device", "client_turn_id" => client_turn_id}
        }

        with {:ok, message} <- Chat.post_message(attrs) do
          {:ok, %{conn | turn_at: message.inserted_at}, message}
        end
    end
  end

  @doc "The line appended to every on-device turn: spoken-style sentences, streamed."
  @spec instruction() :: String.t()
  def instruction, do: @instruction

  @doc """
  The body an agent is handed for `message`: an on-device turn
  (`metadata.input = "on_device"`) gets `instruction/0` after a blank line;
  every other message is its content, unchanged. Never stored.

      iex> alias Platform.Meetings.OnDeviceVoice
      iex> body = OnDeviceVoice.agent_content(%{content: "Hi", metadata: %{"input" => "on_device"}})
      iex> {String.starts_with?(body, "Hi"), String.ends_with?(body, OnDeviceVoice.instruction())}
      {true, true}
      iex> OnDeviceVoice.agent_content(%{content: "Hi", metadata: %{"input" => "typed"}})
      "Hi"
  """
  @spec agent_content(map()) :: String.t() | nil
  def agent_content(%{content: content, metadata: %{"input" => "on_device"}})
      when is_binary(content) and content != "",
      do: content <> "\n\n" <> @instruction

  def agent_content(%{content: content}), do: content

  @doc """
  The user's turn already posted with `client_turn_id` in the conn's DM, or
  nil. A Retry after the socket dropped (a new LiveView, so its own dedupe
  map is empty) must not post the same turn twice.
  """
  @spec find_turn(conn(), String.t()) :: Message.t() | nil
  def find_turn(conn, client_turn_id) when is_binary(client_turn_id) do
    Chat.find_message_by_metadata(conn.space_id, conn.user_participant_id, %{
      "input" => "on_device",
      "client_turn_id" => client_turn_id
    })
  end

  @doc """
  Moves the conn's turn mark to `message`, an already-posted turn.
  """
  @spec mark_turn(conn(), Message.t()) :: conn()
  def mark_turn(conn, %Message{inserted_at: at}), do: %{conn | turn_at: at}

  @doc """
  Whether `message` is the agent's reply to the conn's last turn: posted in
  the conn's DM by the agent's participant, with text, at or after the turn
  (as `VoiceAsk.Accumulator` takes the target's next posted message as the
  answer). The user's own turn, echoed back by the broadcast, is never a
  reply. No turn yet means nothing is a reply.
  """
  @spec agent_reply?(conn() | nil, Message.t() | map()) :: boolean()
  def agent_reply?(%{turn_at: %DateTime{} = turn_at} = conn, %{} = message) do
    message.space_id == conn.space_id and
      message.participant_id == conn.agent_participant_id and
      is_binary(message.content) and String.trim(message.content) != "" and
      match?(%DateTime{}, message.inserted_at) and
      DateTime.compare(message.inserted_at, turn_at) != :lt
  end

  def agent_reply?(_conn, _message), do: false

  @doc """
  Whether `chunk` (a `{:agent_reply_chunk, chunk}` payload) is part of the
  agent's reply to the conn's last turn: in the conn's DM, from the agent's
  participant, with text, once a turn has been sent. Chunks carry no time, so
  which chunk id is the answer is the caller's rule (the first new id after
  the turn, as `VoiceAsk.Accumulator` takes it).
  """
  @spec agent_chunk?(conn() | nil, map()) :: boolean()
  def agent_chunk?(%{turn_at: %DateTime{}} = conn, %{} = chunk) do
    Map.get(chunk, :space_id) == conn.space_id and
      Map.get(chunk, :participant_id) == conn.agent_participant_id and
      is_binary(Map.get(chunk, :chunk_id)) and is_binary(Map.get(chunk, :text))
  end

  def agent_chunk?(_conn, _chunk), do: false

  @doc """
  The sentences of a streamed reply that may be spoken now, past the
  `spoken` already sent, and the new count.

  `text` is the CUMULATIVE reply so far, markdown and all
  (`speakable_text/1` is applied line by line). A sentence is complete when
  its terminal `.`, `?` or `!` (plus any closing quote or bracket) is
  followed by whitespace, or when its line ends with a newline. An unfinished
  tail waits for more text, or for `final?`, which flushes it. A period after
  an abbreviation ("e.g.", "Dr.") or a capital initial ("J.", never "I.") does not
  end a sentence, and a decimal ("3.5") never has whitespace after its point.

      iex> Platform.Meetings.OnDeviceVoice.speakable_sentences(0, "Sure. Dr. Lee has 3.5 hours, e.g. today. And", false)
      {["Sure.", "Dr. Lee has 3.5 hours, e.g. today."], 2}

      iex> Platform.Meetings.OnDeviceVoice.speakable_sentences(2, "Sure. Dr. Lee has 3.5 hours, e.g. today. And more", true)
      {["And more"], 3}
  """
  @spec speakable_sentences(non_neg_integer(), String.t() | nil, boolean()) ::
          {[String.t()], non_neg_integer()}
  def speakable_sentences(spoken, text, final?) when is_integer(spoken) and spoken >= 0 do
    all = complete_sentences(text || "", final?)
    {Enum.drop(all, spoken), max(length(all), spoken)}
  end

  defp complete_sentences(text, final?) do
    lines = String.split(text, ~r/\R/u)
    {done, [last]} = Enum.split(lines, -1)

    closed = Enum.flat_map(done, &(&1 |> speakable_line() |> split_sentences(true)))
    open = last |> speakable_line() |> split_sentences(final? or ends_a_sentence?(last))
    closed ++ open
  end

  # One raw line as speech, or "" for a fence or a rule.
  defp speakable_line(line) do
    if fence_or_rule?(line), do: "", else: line |> speakable_text() |> drop_stray_marks()
  end

  # An unclosed `**` or backtick in a partial chunk is never read aloud.
  defp drop_stray_marks(text), do: text |> String.replace(~r/[*`]|~~/u, "") |> String.trim()

  # The open line's last sentence is complete when its terminal mark is
  # followed by whitespace, or (task 01a20fdd stage 4) when the text ENDS on
  # it: an agent that streams one whole sentence per reply_chunk sends
  # "First one." with nothing after, and holding that until the next chunk
  # kept every reply one chunk behind (voice-0125-b on the iPhone: sentence 1
  # spoken only when chunk 2 arrived 4.5 s later; voice-0125-c, one chunk
  # then done, spoke nothing early). Still held at the very end: an
  # abbreviation or initial ("Dr.", "e.g.", "J.") and a digit before the
  # point ("3." may yet be "3.5"), where a token stream can stop mid-sentence.
  defp ends_a_sentence?(raw) do
    Regex.match?(~r/[.!?]+["'”’)\]*_]*\s+$/u, raw) or
      (Regex.match?(~r/[^\d\s.!?][.!?]+["'”’)\]*_]*$/u, raw) and
         not abbreviation?(String.trim(raw)))
  end

  # Sentences of one line. `complete?`: the line's last piece is a sentence
  # too (its line ended); otherwise it is the held-back tail.
  defp split_sentences("", _complete?), do: []

  defp split_sentences(line, complete?) do
    {sentences, tail} =
      ~r/[.!?]+["'”’)\]]*(?=\s)/u
      |> Regex.scan(line, return: :index)
      |> Enum.reduce({[], 0}, fn [{at, len}], {acc, from} ->
        stop = at + len
        piece = binary_part(line, from, stop - from)

        if abbreviation?(piece),
          do: {acc, from},
          else: {[String.trim(piece) | acc], stop}
      end)
      |> then(fn {acc, from} ->
        {Enum.reverse(acc), binary_part(line, from, byte_size(line) - from)}
      end)

    tail = String.trim(tail)
    if complete? and tail != "", do: sentences ++ [tail], else: sentences
  end

  defp abbreviation?(piece) do
    word =
      piece
      |> String.trim_trailing()
      |> String.replace(~r/["'”’)\]]+$/u, "")
      |> String.split(~r/\s+/u)
      |> List.last()
      |> Kernel.||("")

    String.ends_with?(word, ".") and
      (String.downcase(String.trim_trailing(word, ".")) in @abbreviations or
         Regex.match?(~r/^[A-HJ-Z]\.$/u, word))
  end

  @doc """
  The reply as the system voice should read it: markdown removed so the
  voice does not read symbols. Emphasis, headings, block quotes, list
  markers, code fences and inline code marks are dropped; a link or image
  becomes its text; lines join with spaces.

      iex> Platform.Meetings.OnDeviceVoice.speakable_text("**Three items:** the deck")
      "Three items: the deck"
  """
  @spec speakable_text(String.t() | nil) :: String.t()
  def speakable_text(nil), do: ""

  def speakable_text(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u)
    |> Enum.reject(&fence_or_rule?/1)
    |> Enum.map(&strip_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> strip_inline()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp fence_or_rule?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "```") or String.starts_with?(trimmed, "~~~") or
      Regex.match?(~r/^([-*_])(\s*\1){2,}$/u, trimmed)
  end

  defp strip_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\#{1,6}\s+/u, "")
    |> String.replace(~r/^(>\s?)+/u, "")
    |> String.replace(~r/^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/u, "")
  end

  defp strip_inline(text) do
    text
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/`+([^`]*)`+/u, "\\1")
    |> String.replace(~r/(\*\*|__)(.+?)\1/u, "\\2")
    |> String.replace(~r/~~(.+?)~~/u, "\\1")
    |> String.replace(~r/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/u, "\\1")
    |> String.replace(~r/(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])/u, "\\1")
  end
end

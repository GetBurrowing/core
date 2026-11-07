defmodule PlatformWeb.UxDevFixtureProvider do
  @moduledoc """
  A deterministic stand-in for the UX friction watch's model
  (`:ux_friction_watch_provider`), for the dev fixture
  (`PlatformWeb.UxDevFixture`, task 01a1af00 stage 4). Compiled in dev and
  test only; it is not in `lib/` and never ships in a release.

  It groups ONLY the signals it was sent: every signal mentioning direct
  messages becomes one `decision` group, every signal about timestamps one
  `fyi` group. A message the server never sent therefore can never reach a
  finding, which is what makes the fixture usable as a privacy check. The
  last user turn it saw is kept in `:persistent_term` (`last_seen/0`) so the
  fixture can show what was gathered.
  """

  @behaviour Platform.Agents.Providers.Provider

  @last_seen_key {__MODULE__, :last_seen}

  @doc "The decoded signals of the last call (`[%{\"id\", \"text\"}]`), or nil."
  @spec last_seen() :: [map()] | nil
  def last_seen, do: :persistent_term.get(@last_seen_key, nil)

  @doc "Forget the last call."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@last_seen_key)
    :ok
  end

  @impl true
  def chat(_credentials, messages, _opts) do
    user = Enum.find_value(messages, fn m -> if m.role == "user", do: m.content end) || "[]"
    signals = Jason.decode!(user)
    :persistent_term.put(@last_seen_key, signals)

    dm = ids(signals, ~r/direct message|\bDMs?\b/i)
    stamps = ids(signals, ~r/timestamp/i)

    groups =
      [
        dm != [] &&
          %{
            "group_key" => "dm-findability",
            "kind" => "decision",
            "question" => "Give DMs their own spot in the sidebar?",
            "similarity" => 0.93,
            "signal_ids" => dm,
            "options" => [
              %{
                "label" => "A Direct messages section pinned at the top of the sidebar",
                "recommended" => true,
                "detail" => "Same spot at both sizes; unread DMs show a count."
              },
              %{
                "label" => "A DMs tab in the bottom bar on phones",
                "recommended" => false,
                "detail" => "Desktop keeps today's sidebar."
              }
            ]
          },
        stamps != [] &&
          %{
            "group_key" => "timestamp-size",
            "kind" => "fyi",
            "question" => "Are message timestamps too small to read?",
            "similarity" => 0.9,
            "signal_ids" => stamps
          }
      ]
      |> Enum.filter(& &1)

    {:ok, %{content: Jason.encode!(%{"groups" => groups})}}
  end

  @impl true
  def stream(_credentials, _messages, _opts), do: {:error, :not_supported}

  @impl true
  def models(_credentials), do: {:ok, []}

  @impl true
  def validate_credentials(_credentials), do: :ok

  defp ids(signals, re), do: for(s <- signals, Regex.match?(re, s["text"] || ""), do: s["id"])
end

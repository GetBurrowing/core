defmodule Platform.AgentHost.Redact do
  @moduledoc """
  What a native agent's pane text must lose before Suite shows it as
  "Recent output" (task 01a10322 stage 6).

  The agent host already does this (`services/agent-host/src/pane.ts`, the
  same rules). Core does it again on the way out, so neither side has to be
  trusted alone.

    * **A login screen is withheld whole.** If any line shows Claude Code's
      login method chooser, sign-in URL or paste prompt, or its API-key
      confirmation, no line is shown and the result says `hidden: :login`.
      Suite never displays a login URL, code or key from a pane.
    * **Every other line is scrubbed** of anything shaped like a credential:
      `sk-ant-…` keys and tokens, the values of `ANTHROPIC_API_KEY`,
      `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_*`, OAuth `code` / `state`
      / `code_challenge` query values, and `Bearer` tokens.
    * At most #{200} lines of at most #{500} characters each.
  """

  @max_lines 200
  @max_line 500

  @login_markers [
    "Select login method",
    "Paste code here",
    "Browser didn't open? Use the url below to sign in",
    "/oauth/authorize",
    "/oauth/code/callback",
    "Detected a custom API key in your environment"
  ]

  @scrubs [
    # `+`, not `*`: an already-scrubbed "sk-ant-[redacted]" (the host scrubs
    # first) must not match again and grow a second "[redacted]".
    {~r/sk-ant-[A-Za-z0-9_.\-]+/, "sk-ant-[redacted]"},
    {~r/\b((?:ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_[A-Z_]+)\s*[:=]\s*)\S+/,
     "\\1[redacted]"},
    {~r/([?&](?:code|state|code_challenge)=)[^&\s]+/, "\\1[redacted]"},
    {~r/\b(Bearer\s+)\S+/i, "\\1[redacted]"}
  ]

  @doc "The markers that make a pane a login screen."
  def login_markers, do: @login_markers

  @doc """
  A host `agent.pane` payload (`%{"lines" => [...], "hidden" => ...}`) to
  `%{lines: [String.t()], hidden: nil | :login}`.
  """
  @spec pane(map()) :: %{lines: [String.t()], hidden: nil | :login}
  def pane(payload) when is_map(payload) do
    lines = payload |> Map.get("lines") |> List.wrap() |> Enum.filter(&is_binary/1)

    if Map.get(payload, "hidden") == "login" or login_screen?(lines) do
      %{lines: [], hidden: :login}
    else
      %{lines: lines(lines), hidden: nil}
    end
  end

  def pane(_), do: %{lines: [], hidden: nil}

  @doc "True when any line shows a Claude login screen."
  @spec login_screen?([String.t()]) :: boolean()
  def login_screen?(lines) when is_list(lines) do
    Enum.any?(lines, fn line ->
      is_binary(line) and Enum.any?(@login_markers, &String.contains?(line, &1))
    end)
  end

  @doc "Scrub and cap `lines`."
  @spec lines([String.t()]) :: [String.t()]
  def lines(lines) when is_list(lines) do
    lines
    |> Enum.filter(&is_binary/1)
    |> Enum.take(-@max_lines)
    |> Enum.map(&line/1)
  end

  @doc "Scrub one line."
  @spec line(String.t()) :: String.t()
  def line(line) when is_binary(line) do
    line = if String.valid?(line), do: line, else: :unicode.characters_to_binary(line, :latin1)

    @scrubs
    |> Enum.reduce(line, fn {re, replacement}, acc -> Regex.replace(re, acc, replacement) end)
    |> String.slice(0, @max_line)
  end
end

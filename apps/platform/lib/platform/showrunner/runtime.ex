defmodule Platform.Showrunner.Runtime do
  @moduledoc """
  What the three `showrunner.*` handlers share (task 01a1eaf6 stage 3): the
  acting context for a fire, the next-step fire seam, prompt rendering with a
  fallback, and reading the model's output.

  ## The fire seam

  `fire/3` is how one step starts the next (a written brief fires the run
  sheet; an invalid run sheet fires its one redraft; a failed post-show
  retries once). It calls `Platform.Responsibilities.Router.fire/2` unless
  the caller passes another 2-arity function. The function is an ARGUMENT,
  threaded down from each handler's `opts[:fire]`, never application
  config: a stray config value would silently stop the chain (task 01a1eaf6
  stage 4 replaced stage 3's `:showrunner_fire` app-env hook for that
  reason).
  """

  require Logger

  alias Platform.Chat
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Responsibility
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Config
  alias Platform.Showrunner.Memory

  @setup_refusals [:no_space_configured, :agent_not_in_space]
  @not_set_up_question "The showrunner isn't set up: it has no show space it can post in"

  @doc """
  The acting context for `responsibility`: its config, the assigned agent and
  that agent's participant row in the configured space.
  """
  @spec context(Responsibility.t()) :: {:ok, Board.ctx(), Config.t()} | {:error, term()}
  def context(%Responsibility{key: key} = responsibility) do
    config = Config.read(responsibility)

    with {:ok, ctx} <- Board.context(config.space_id, assignee(key), config.escalate_user_id) do
      {:ok, ctx, config}
    end
  end

  @doc "The Needs-you question a fire refused for missing setup raises."
  @spec not_set_up_question() :: String.t()
  def not_set_up_question, do: @not_set_up_question

  @doc """
  What every `showrunner.*` `handle_refusal/3` does with a refusal.

  A dispatch refused because the showrunner is not set up (no show space, or
  the agent is not in it) is a human decision, so it raises ONE Needs-you
  item, not just a log line: a message from the agent in its DM with the
  configured `escalate_user_id`, and one inbox row. There is no show space to
  post in, which is the problem being reported. Further refusals add nothing
  while that row is open. With no escalate user configured there is nobody to
  ask (only the configured escalate user is ever asked), so it only logs.
  The config is re-read from the row as it is now, not the caller's copy.
  Always `:ok`; never raises.
  """
  @spec refused(Responsibility.t(), term()) :: :ok
  def refused(%Responsibility{key: key} = responsibility, {:context_gather_refused, reason})
      when reason in @setup_refusals do
    live = Platform.Responsibilities.get_by_key(key) || responsibility
    config = Config.read(live)

    with user_id when is_binary(user_id) <- config.escalate_user_id || {:skip, :no_escalate_user},
         false <- Board.open_escalation?(user_id, @not_set_up_question),
         %{id: agent_id} <- assignee(key) || {:skip, :no_assignee},
         {:ok, dm} <- Chat.find_or_create_agent_dm(agent_id, user_id),
         %{id: participant_id} <- Chat.get_agent_participant(dm.id, agent_id) || {:skip, :no_dm} do
      Board.escalate(
        %{
          space_id: dm.id,
          agent_id: agent_id,
          participant_id: participant_id,
          escalate_user_id: user_id
        },
        %{question: @not_set_up_question, options: ["Provisioned again"]},
        detail:
          "#{key} was refused (#{reason}). Run `mix platform.showrunner.provision` with the " <>
            "show's space and make sure the showrunner agent is in it."
      )
    else
      true ->
        :ok

      other ->
        Logger.warning(
          "[showrunner] #{key} refused (#{inspect(reason)}) and nobody could be asked: " <>
            inspect(other)
        )
    end

    :ok
  rescue
    error ->
      Logger.warning("[showrunner] refusal handling raised: #{Exception.message(error)}")
      :ok
  end

  def refused(%Responsibility{key: key}, refusal) do
    Logger.info("[#{key}] refused: #{inspect(refusal)}")
    :ok
  end

  @doc """
  Starts `key` with `meta` through `fire_fun` (default
  `Platform.Responsibilities.Router.fire/2`). A raise is logged and returned
  as `{:error, :fire_failed}`.
  """
  @spec fire(String.t(), map(), (String.t(), map() -> term())) :: term()
  def fire(key, meta, fire_fun \\ &Router.fire/2)
      when is_binary(key) and is_map(meta) and is_function(fire_fun, 2) do
    fire_fun.(key, meta)
  rescue
    error ->
      Logger.warning("[showrunner] fire #{key} raised: #{Exception.message(error)}")
      {:error, :fire_failed}
  end

  @doc "The fire function in a handler's `opts` (`opts[:fire]`), else the Router's."
  @spec fire_fun(keyword()) :: (String.t(), map() -> term())
  def fire_fun(opts) when is_list(opts) do
    case Keyword.get(opts, :fire) do
      fun when is_function(fun, 2) -> fun
      _ -> &Router.fire/2
    end
  end

  @doc """
  Renders `slug`'s served row; falls back to `fallback_slug`'s row, then to
  `fallback_slug`'s `default_templates/0` content. `{:ok, body}` or
  `{:error, :not_found}`.
  """
  @spec render(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, :not_found}
  def render(slug, fallback_slug, assigns) do
    [
      fn -> PromptTemplates.render_template(slug, assigns) end,
      fn -> PromptTemplates.render_template(fallback_slug, assigns) end,
      fn -> PromptTemplates.render_default(fallback_slug, assigns) end
    ]
    |> Enum.find_value({:error, :not_found}, fn render ->
      case render.() do
        {:ok, body} when is_binary(body) and body != "" -> {:ok, body}
        _ -> nil
      end
    end)
  end

  @doc """
  The model's output as a string-keyed map: a map as given, or a JSON object
  in a string (a fenced ```json block is unwrapped). Anything else is
  `{:error, :not_an_object}`.
  """
  @spec decode(term()) :: {:ok, map()} | {:error, :not_an_object}
  def decode(output) when is_map(output) and not is_struct(output),
    do: {:ok, Map.new(output, fn {k, v} -> {to_string(k), v} end)}

  def decode(output) when is_binary(output) do
    text =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, output) do
        [_, json] -> json
        _ -> String.trim(output)
      end

    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :not_an_object}
    end
  end

  def decode(%{"text" => text}), do: decode(text)
  def decode(_output), do: {:error, :not_an_object}

  @doc "The last four episodes in the show journal, as prompt text."
  @spec episodes_text(String.t()) :: String.t()
  def episodes_text(space_id) do
    case Memory.recent_episodes(space_id, 4) do
      [] ->
        "(no earlier episodes in the show journal)"

      episodes ->
        Enum.map_join(episodes, "\n\n", fn %{number: n, lines: lines} ->
          "Episode #{n}:\n" <> Enum.map_join(lines, "\n", &"- #{&1}")
        end)
    end
  end

  @doc "The space's recent messages, oldest first, as prompt text."
  @spec messages_text(String.t(), pos_integer()) :: String.t()
  def messages_text(space_id, limit \\ 30) do
    space_id
    |> Chat.list_messages(limit: limit)
    |> Enum.reverse()
    |> Enum.reject(&(is_nil(&1.content) or &1.content == ""))
    |> case do
      [] ->
        "(no recent messages)"

      messages ->
        Enum.map_join(messages, "\n", fn m ->
          "#{m.author_display_name || "someone"}: #{String.slice(m.content, 0, 500)}"
        end)
    end
  rescue
    _ -> "(recent messages unavailable)"
  end

  @doc "A trigger/meta value by atom or string key."
  @spec meta(map() | nil, atom()) :: term()
  def meta(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  def meta(_map, _key), do: nil

  @doc """
  The episode board a fire is about: `meta[:canvas_id]` when it names one of
  the space's boards, else the space's newest board.
  """
  @spec board(String.t(), map() | nil) :: Platform.Chat.Canvas.t() | nil
  def board(space_id, meta) do
    with id when is_binary(id) <- meta(meta, :canvas_id),
         %{space_id: ^space_id} = canvas <- Chat.get_canvas(id),
         true <- Board.board?(canvas) do
      canvas
    else
      _ -> Board.current(space_id)
    end
  end

  defp assignee(key) do
    Roles.assignee_for(key)
  rescue
    _ -> nil
  end
end

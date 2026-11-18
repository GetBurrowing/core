defmodule Platform.Designer.Cards do
  @moduledoc """
  The designer's pattern cards: a best-practice store that learns (task
  01a1f048; Jordan, 2026-11-18).

  ## Where they live

  One memory page per card in the designer's PRIVATE namespace,
  `space/<home space>/private/<agent id>/patterns/<slug>.md` (the spec's
  store; `Platform.Org.Wiki.Routing` lets only the owning agent write there
  through the tools). The home space is the agent's
  `metadata["designer_home_space_id"]`, which `Platform.Designer.provision/1`
  sets to the digest space (else the first watch space) and joins the agent
  to, so the private path's participation rule holds.

  ## Card frontmatter

      title: "..."
      status: seeded | untested | tested
      weight: 0.0..1.0
      provenance: "where it came from: sources, date found"
      used_in_tasks: [task ids whose fix used this card]
      weighed_tasks: [task ids already applied to the weight]

  `untested` is what the scout writes (capped at 0.4); `seeded` is the
  starter set below (0.5); `tested` is a card that has met at least one
  post-ship outcome.

  ## How weight moves

  Only through OUTCOMES, deterministically, in `reweigh/2`: for every task
  in `used_in_tasks` not yet in `weighed_tasks` whose post-ship window has
  settled (`Platform.Ux.FrictionDrop.for_task/2`), the card gains
  `@step` when the pooled friction drop is at least `@gain_at`, and loses
  `@step` when friction did not fall at all. A task with no baseline is
  recorded as weighed with no change. Each move is appended to the card's
  weight log with its numbers. Reflection may propose moves (capped at 0.7
  by the manifest); agreement from a human never moves a card.

  ## Seed set

  About twenty generic interaction patterns ship in
  `priv/designer/pattern_cards/`. `seed/1` writes them create-only: an
  existing card, edited or not, is never overwritten.
  """

  alias Platform.Agents.Agent
  alias Platform.Org.Wiki
  alias Platform.Ux.FrictionDrop

  @home_key "designer_home_space_id"
  @seed_dir "designer/pattern_cards"
  @step 0.1
  @gain_at 0.25
  @floor 0.05
  @ceiling 0.95

  @doc "The agent metadata key naming the designer's home space."
  @spec home_key() :: String.t()
  def home_key, do: @home_key

  @doc "The card namespace for `agent`, or nil when it has no home space."
  @spec prefix(Agent.t()) :: String.t() | nil
  def prefix(%Agent{id: id, metadata: metadata}) do
    case Map.get(metadata || %{}, @home_key) do
      space_id when is_binary(space_id) and space_id != "" ->
        "space/#{space_id}/private/#{id}/patterns/"

      _ ->
        nil
    end
  end

  def prefix(_agent), do: nil

  @doc "The seed cards as `[{slug, content}]`."
  @spec seed_cards() :: [{String.t(), String.t()}]
  def seed_cards do
    dir = Application.app_dir(:platform, Path.join("priv", @seed_dir))

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.sort()
    |> Enum.map(fn file -> {Path.rootname(file), File.read!(Path.join(dir, file))} end)
  end

  @doc """
  Write the seed set into `agent`'s card namespace, create-only. Returns
  `{:ok, %{written: n, kept: n}}` or `{:error, :no_home_space}`.
  """
  @spec seed(Agent.t()) ::
          {:ok, %{written: non_neg_integer(), kept: non_neg_integer()}} | {:error, term()}
  def seed(%Agent{} = agent) do
    case prefix(agent) do
      nil ->
        {:error, :no_home_space}

      prefix ->
        Enum.reduce_while(seed_cards(), {:ok, %{written: 0, kept: 0}}, fn {slug, content},
                                                                          {:ok, acc} ->
          path = prefix <> slug <> ".md"

          if Wiki.get_page(path) do
            {:cont, {:ok, Map.update!(acc, :kept, &(&1 + 1))}}
          else
            case Wiki.upsert_page(path, %{content: content, updated_by: agent.id}) do
              {:ok, _page} -> {:cont, {:ok, Map.update!(acc, :written, &(&1 + 1))}}
              {:error, reason} -> {:halt, {:error, {:seed_failed, slug, reason}}}
            end
          end
        end)
    end
  end

  @doc """
  Apply settled post-ship outcomes to every card's weight (see the
  moduledoc). Returns `{:ok, [%{path, task_id, drop, from, to}]}`, one entry
  per weighed task, or `{:error, :no_home_space}`. `opts[:now]` fixes the
  clock.
  """
  @spec reweigh(Agent.t(), keyword()) :: {:ok, [map()]} | {:error, :no_home_space}
  def reweigh(agent, opts \\ [])

  def reweigh(%Agent{} = agent, opts) do
    case prefix(agent) do
      nil ->
        {:error, :no_home_space}

      prefix ->
        moves =
          prefix
          |> Wiki.list_pages_under()
          |> Enum.flat_map(&reweigh_page(&1, agent, opts))

        {:ok, moves}
    end
  end

  def reweigh(_agent, _opts), do: {:error, :no_home_space}

  @doc "The weight change for a task's pooled friction drop (nil: no baseline)."
  @spec delta(float() | nil) :: float()
  def delta(nil), do: 0.0
  def delta(drop) when drop >= @gain_at, do: @step
  def delta(drop) when drop <= 0.0, do: -@step
  def delta(_drop), do: 0.0

  # ── internals ──

  defp reweigh_page(page, agent, opts) do
    fm = page.frontmatter || %{}
    used = list(fm["used_in_tasks"])
    weighed = list(fm["weighed_tasks"])

    settled =
      (used -- weighed)
      |> Enum.flat_map(fn task_id ->
        case FrictionDrop.for_task(task_id, opts) do
          [] -> []
          outcomes -> [{task_id, pooled(outcomes)}]
        end
      end)

    if settled == [] do
      []
    else
      start = number(fm["weight"], 0.5)

      {moves, weight} =
        Enum.map_reduce(settled, start, fn {task_id, drop}, weight ->
          to = (weight + delta(drop)) |> max(@floor) |> min(@ceiling) |> Float.round(2)
          {%{path: page.file_key, task_id: task_id, drop: drop, from: weight, to: to}, to}
        end)

      content =
        page.content
        |> put_field("weight", to_string(weight))
        |> put_field("status", "tested")
        |> put_field("weighed_tasks", Jason.encode!(weighed ++ Enum.map(settled, &elem(&1, 0))))
        |> append_log(moves)

      case Wiki.upsert_page(page.file_key, %{content: content, updated_by: agent.id},
             expected_version: page.version
           ) do
        {:ok, _} -> moves
        {:error, _} -> []
      end
    end
  end

  defp pooled(outcomes) do
    with_base = Enum.filter(outcomes, &(&1.before > 0))
    before = Enum.sum(Enum.map(with_base, & &1.before))
    after_count = Enum.sum(Enum.map(with_base, & &1.after))
    if before > 0, do: Float.round(1 - after_count / before, 2), else: nil
  end

  # Replace (or add) one top-level key inside the leading frontmatter block.
  defp put_field(content, key, value) do
    case Regex.run(~r/\A---\n(.*?)\n---\n/s, content, return: :index) do
      [{0, len}, {fm_start, fm_len}] ->
        fm = binary_part(content, fm_start, fm_len)
        rest = binary_part(content, len, byte_size(content) - len)
        line = "#{key}: #{value}"
        re = Regex.compile!("^#{Regex.escape(key)}:.*$", "m")

        fm =
          if Regex.match?(re, fm),
            do: Regex.replace(re, fm, line, global: false),
            else: fm <> "\n" <> line

        "---\n" <> fm <> "\n---\n" <> rest

      _ ->
        content
    end
  end

  defp append_log(content, moves) do
    lines =
      Enum.map_join(moves, "\n", fn m ->
        "- #{Date.utc_today()}: task #{m.task_id}, friction drop " <>
          "#{if is_nil(m.drop), do: "n/a (no baseline)", else: m.drop}, weight #{m.from} -> #{m.to}"
      end)

    if String.contains?(content, "## Weight log"),
      do: String.trim_trailing(content) <> "\n" <> lines <> "\n",
      else: String.trim_trailing(content) <> "\n\n## Weight log\n\n" <> lines <> "\n"
  end

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(_value), do: []

  defp number(value, _default) when is_float(value), do: value
  defp number(value, _default) when is_integer(value), do: value * 1.0
  defp number(_value, default), do: default
end

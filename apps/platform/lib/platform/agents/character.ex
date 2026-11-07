defmodule Platform.Agents.Character do
  @moduledoc """
  An agent as a character (task 01a1b6ad): the builder's state, the text the
  builder previews, the three workspace files it writes, and the one
  transaction that brings it to life.

  ## One source for the preview and the files

  `first_line/2`, `voice_sample/1`, `v_reply/3` and `v_prompt_lines/1` are
  pure ports of the comp's `firstLine`, `voiceSample`, `vReply` and
  `vPromptLines` (burrow-agents.js). The builder's preview and the files
  written on create read the same functions, so what the user sees on the
  reveal card is what lands in `SOUL.md`. The comp copy that named real
  people is generic here (see `Platform.Agents.Archetypes`); where the comp
  greeted the viewer by name, these functions take the viewer's display name
  as an argument.

  ## State

  A character is a map:

    * `:cls`: an `Archetypes` id
    * `:n`: its name
    * `:color`: a `Platform.Agents.ColorPalette` slot id (stored as `agents.color`)
    * `:portrait`: an `Archetypes.portraits/0` id
    * `:sl`: the four dials, `%{"chatty" => 0..100, "bold" => .., "playful" => .., "collab" => ..}`
    * `:traits`: up to three of `Archetypes.traits/0`
    * `:toolkit`: `Archetypes.toolkit_ids/0` it starts with
    * `:line`: the class's first line
    * `:vc`: the voice, `%{p: 0..4, ov: %{knob => value}, q: sample id, free: nil | String.t()}`
    * `:touched`: the fields a class change must not overwrite

  ## Where it is stored

  No migration: `agents.color`, `agents.tools_config` (`"toolkit"` beside the
  template's `"profile"`/`"allow"`) and `agents.metadata["character"]`
  already exist. How it talks goes into `SOUL.md` under `## Voice`. It does
  NOT go into `agents.voice_config`, which is the TTS provider and voice id
  (`Platform.Agents.Voice`), nor into `VOICE.md`, which holds spoken
  personality.

  `WorkspaceBootstrap` only syncs files for the agent its mounted workspace
  configures, and a builder agent has no mount, so boot never overwrites
  these files.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Platform.Agents.{Agent, Archetypes, ColorPalette, MemoryContext, RoleTemplates}
  alias Platform.Chat
  alias Platform.Repo

  @files ["SOUL.md", "IDENTITY.md", "TOOLS.md"]
  @max_traits 3
  @max_name 24

  @emoji ~r/\p{Extended_Pictographic}\x{FE0F}?/u
  @sentence_break ~r/(?<=[.?!])\s/u
  @trailing_space ~r/\s+$/u

  @doc "The three workspace files a character owns."
  def files, do: @files

  # ── State ──────────────────────────────────────────────────────────

  @doc """
  A fresh character of class `class_id` (default Builder), as the comp's
  builder opens. `:used_names` skips names other agents already wear.
  """
  def new(class_id \\ "builder", opts \\ []) do
    a = Archetypes.fetch(class_id)
    used = Keyword.get(opts, :used_names, [])

    %{
      cls: a.id,
      n: Enum.find(a.names, &(&1 not in used)) || hd(a.names) <> " II",
      color: a.color,
      portrait: a.portrait,
      sl: a.sl,
      traits: a.traits,
      toolkit: a.toolkit,
      line: a.line,
      vc: v_new(Archetypes.class_voice(a.id)),
      touched: MapSet.new()
    }
  end

  @doc """
  Port of the comp's `applyClass`: a class change resets the toolkit and the
  first line, and every other field the user has not touched.
  """
  def apply_class(b, class_id, opts \\ []) do
    a = Archetypes.fetch(class_id)
    t = Map.get(b, :touched, MapSet.new())
    keep? = &MapSet.member?(t, &1)

    b
    |> Map.merge(%{cls: a.id, toolkit: a.toolkit, line: a.line})
    |> then(&if(keep?.("name"), do: &1, else: %{&1 | n: pick_name(a, opts)}))
    |> then(&if(keep?.("color"), do: &1, else: %{&1 | color: a.color}))
    |> then(&if(keep?.("portrait"), do: &1, else: %{&1 | portrait: a.portrait}))
    |> then(&if(keep?.("sl"), do: &1, else: %{&1 | sl: a.sl}))
    |> then(&if(keep?.("traits"), do: &1, else: %{&1 | traits: a.traits}))
    |> then(fn b ->
      if keep?.("voice"), do: b, else: put_in(b, [:vc, :p], Archetypes.class_voice(a.id))
    end)
  end

  @doc "Port of the comp's `pickName`: a random unused name, or the first with \" II\"."
  def pick_name(archetype, opts \\ []) do
    used = Keyword.get(opts, :used_names, [])
    skip = Keyword.get(opts, :skip)

    case Enum.reject(archetype.names, &(&1 in used or &1 == skip)) do
      [] -> hd(archetype.names) <> " II"
      pool -> Enum.random(pool)
    end
  end

  @doc "A character rebuilt from a stored agent, or nil if the agent was not built as one."
  def from_agent(%Agent{metadata: %{"character" => c}} = agent) when is_map(c) do
    a = Archetypes.fetch(c["archetype"])
    voice = c["voice"] || %{}

    %{
      cls: a.id,
      n: agent.name,
      color: agent.color || a.color,
      portrait: c["portrait"] || a.portrait,
      sl: c["sliders"] || a.sl,
      traits: c["traits"] || a.traits,
      toolkit: (agent.tools_config || %{})["toolkit"] || a.toolkit,
      line: a.line,
      vc: %{
        p: Archetypes.voice_index(voice["preset"]) || Archetypes.class_voice(a.id),
        ov: voice["overrides"] || %{},
        q: "pr",
        free: nil
      },
      touched: MapSet.new()
    }
  end

  def from_agent(_), do: nil

  # ── Pure ports of the comp ─────────────────────────────────────────

  @doc "Port of `firstLine`. `viewer` is the viewer's display name, or nil."
  def first_line(b, viewer \\ nil) do
    sl = b.sl
    t = Map.get(b, :line) || Archetypes.fetch(b.cls).line
    t = if sl["chatty"] < 30, do: hd(Regex.split(@sentence_break, t, parts: 2)), else: t
    t = if sl["playful"] < 25, do: "Good morning" <> viewer_suffix(viewer) <> ". " <> t, else: t

    t =
      if sl["playful"] > 75 and "emoji-free" not in b.traits, do: t <> " ✨", else: t

    if sl["chatty"] > 78, do: t <> " Happy to walk through it whenever.", else: t
  end

  defp viewer_suffix(viewer) when is_binary(viewer) and viewer != "", do: ", " <> viewer
  defp viewer_suffix(_), do: ""

  @doc "Port of `voiceSample`: how it would tell you a PR is ready."
  def voice_sample(p) do
    sl = p.sl
    formal = sl["playful"] < 40
    terse = sl["chatty"] < 40
    bold = sl["bold"] > 60

    base =
      case {terse, bold} do
        {true, true} ->
          "PR #207 merged. Moving to step D."

        {true, false} ->
          "PR #207 is up. Want me to merge, or hold?"

        {false, true} ->
          "PR #207 is merged and shipping — I went ahead and started step D, shout if you'd rather I didn't."

        {false, false} ->
          "PR #207 is ready. I can merge it now, or hold until the reviewer has looked — your call."
      end

    t =
      cond do
        formal -> String.replace(base, "shout", "let me know", global: false)
        sl["playful"] > 70 and "emoji-free" not in p.traits -> base <> " 🚀"
        true -> base
      end

    if sl["collab"] > 65, do: t <> " Looping in #product.", else: t
  end

  @doc "Port of `vNew`: a voice on preset `p` (default Balanced), no overrides."
  def v_new(p \\ nil), do: %{p: p || 2, ov: %{}, q: "pr", free: nil}

  @doc "Port of `vEff`: the preset's knob defaults with the overrides on top."
  def v_eff(vc), do: Map.merge(Enum.at(Archetypes.vdef(), vc.p), vc.ov || %{})

  @doc "Port of `vPromptLines`: the style block written to `SOUL.md` under `## Voice`."
  def v_prompt_lines(vc) do
    e = v_eff(vc)
    v = Archetypes.voice(vc.p)

    [
      "Voice: " <> v.key <> ".",
      v.rule,
      Enum.at(Archetypes.len_rules(), e["len"]),
      if(e["emoji"] == 1, do: "Emoji sparingly, at most one per reply.", else: "No emoji."),
      Enum.at(Archetypes.why_rules(), e["why"]),
      if(e["greet"] == 1,
        do: "Open with a short greeting and sign off with your name.",
        else: "No greeting or sign-off."
      )
    ]
  end

  @doc "Port of `vPrompt`: the style block as one line."
  def v_prompt(vc), do: Enum.join(v_prompt_lines(vc), " ")

  @doc "Port of `vFree`: each preset's reply to a prompt the user typed."
  def v_free(p, q) do
    s = if String.length(q) > 60, do: String.slice(q, 0, 57) <> "…", else: q

    Enum.at(
      [
        ["on it — \"#{s}\". will ping you when i've got something"],
        [
          "Sure — I'll dig into \"#{s}\" and get back to you shortly. Anything I should know first?"
        ],
        [
          "Got it. I'll look into \"#{s}\" and come back with what I find, plus a recommendation."
        ],
        [
          "Understood. I'll look into \"#{s}\" and report back with my findings and a recommended next step.",
          "If there's a deadline, let me know and I'll prioritise accordingly."
        ],
        [
          "Understood. Here is how I will approach \"#{s}\":",
          "1. Confirm the scope and what a good outcome looks like.",
          "2. Gather the relevant context from our spaces, tasks and org memory.",
          "3. Report back with a structured summary, the options, and a recommendation.",
          "If there is a deadline or a constraint I should be aware of, please let me know."
        ]
      ],
      p
    )
  end

  @doc """
  Port of `vReply`: the reply lines `who` (the agent's name) gives to the
  voice's current Try-it prompt. `viewer` is the viewer's display name for
  the greeting, or nil.
  """
  def v_reply(vc, who, viewer \\ nil) do
    sample =
      if vc[:free],
        do: nil,
        else:
          Enum.find(Archetypes.samples(), &(&1.id == vc[:q])) || Enum.at(Archetypes.samples(), 1)

    e = v_eff(vc)
    formal = if vc.p >= 3, do: 1, else: 0
    default_len = Enum.at(Archetypes.vdef(), vc.p)["len"]
    lines = if sample, do: Enum.at(sample.r, vc.p), else: v_free(vc.p, vc.free)

    lines =
      if e["len"] < default_len do
        n = length(lines)

        keep =
          if e["len"] == 0,
            do: min(2, ceil_int(n / 2)),
            else: ceil_int(n * 0.6)

        lines = Enum.take(lines, keep)

        if length(lines) > 1 and String.ends_with?(List.last(lines), ":"),
          do: Enum.drop(lines, -1),
          else: lines
      else
        lines
      end

    lines =
      if e["len"] > default_len and sample,
        do: lines ++ [Enum.at(sample.more, formal)],
        else: lines

    lines =
      if sample && (e["why"] == 2 or (e["why"] == 1 and sample.useful)),
        do: lines ++ [Enum.at(sample.why, formal)],
        else: lines

    lines =
      if e["emoji"] == 1 do
        if Enum.any?(lines, &Regex.match?(@emoji, &1)) do
          lines
        else
          List.update_at(lines, 0, &(&1 <> " " <> if(sample, do: sample.em, else: "👍")))
        end
      else
        Enum.map(lines, fn l ->
          @emoji |> Regex.replace(l, "") |> then(&Regex.replace(@trailing_space, &1, ""))
        end)
      end

    lines =
      if e["greet"] == 1,
        do: [greet(vc.p, viewer)] ++ lines ++ [sign(vc.p, who)],
        else: lines

    if vc.p == 0,
      do: Enum.map(lines, &String.downcase/1),
      else: Enum.map(lines, &capitalize_first/1)
  end

  defp ceil_int(x), do: x |> Float.ceil() |> trunc()

  defp capitalize_first(""), do: ""

  defp capitalize_first(s) do
    {first, rest} = String.split_at(s, 1)
    String.upcase(first) <> rest
  end

  @doc "Each preset's greeting; the comp greeted the viewer by name."
  def greet(p, viewer) when is_binary(viewer) and viewer != "" do
    Enum.at(
      [
        "hey " <> viewer,
        "Hey " <> viewer <> "!",
        "Hi " <> viewer <> ",",
        "Hi " <> viewer <> ",",
        "Good afternoon, " <> viewer <> "."
      ],
      p
    )
  end

  def greet(p, _viewer), do: Enum.at(["hey", "Hey!", "Hi,", "Hi,", "Good afternoon."], p)

  @doc "Each preset's sign-off, in the agent's name."
  def sign(p, name) when p in [0, 1, 2], do: "— " <> name
  def sign(3, name), do: "Best, " <> name
  def sign(4, name), do: "Kind regards, " <> name

  @doc "A dial's lean: its high label at 50 and over, else its low label."
  def lean(%{lo: lo, hi: hi}, v), do: if(v >= 50, do: hi, else: lo)

  @doc """
  The trading card's fields (the comp's `cardHTML`), for the preview and the
  reveal. `:number` is the card's №, `:viewer` the viewer's display name.
  """
  def card(b, opts \\ []) do
    a = Archetypes.fetch(b.cls)
    palette = Enum.find(ColorPalette.all(), &(&1.id == ColorPalette.slot_for(b.color)))
    v = Archetypes.voice(b.vc.p)

    %{
      name: if(b.n in [nil, ""], do: "…", else: b.n),
      class: a.glyph <> " " <> a.n,
      slot: palette.id,
      colour: palette.label,
      portrait: b.portrait,
      template:
        if(a.template_label == "Create Custom",
          do: "custom",
          else: "template · " <> a.template_label
        ),
      type: "Agent · " <> a.n,
      vibe: a.vibe |> String.split(".") |> hd(),
      stats:
        Enum.map(Archetypes.sliders(), fn s ->
          value = b.sl[s.k]
          %{k: s.k, label: lean(s, value), value: if(value >= 50, do: value, else: 100 - value)}
        end),
      traits: b.traits,
      toolkit:
        Archetypes.toolkit()
        |> Enum.filter(&(&1.id in b.toolkit))
        |> Enum.take(6)
        |> Enum.map(&(&1.ic <> " " <> &1.t)),
      talks_like: v.ic <> " " <> v.s,
      quote: first_line(b, Keyword.get(opts, :viewer)),
      footer: "Burrow",
      number: opts |> Keyword.get(:number, 1) |> Integer.to_string() |> String.pad_leading(3, "0")
    }
  end

  # ── The three files ────────────────────────────────────────────────

  @doc "`SOUL.md`: the four dials, the three traits and the first line, then `## Voice`."
  def soul_md(b) do
    dials =
      Enum.map_join(Archetypes.sliders(), "\n", fn s ->
        v = b.sl[s.k]
        "- #{s.lo} ↔ #{s.hi}: #{v} (#{lean(s, v)})"
      end)

    """
    # SOUL.md

    ## Personality

    #{dials}

    Traits: #{Enum.join(b.traits, ", ")}

    First line: “#{first_line(b)}”

    ## Voice

    #{Enum.join(v_prompt_lines(b.vc), "\n")}
    """
  end

  @doc "`IDENTITY.md`: name, handle, class, portrait and colour slot."
  def identity_md(b) do
    a = Archetypes.fetch(b.cls)

    """
    # IDENTITY.md

    - Name: #{b.n}
    - Handle: @#{b.n}
    - Class: #{a.glyph} #{a.n}
    - Portrait: #{b.portrait}
    - Colour: #{ColorPalette.slot_for(b.color)}
    """
  end

  @doc "`TOOLS.md`: the toolkit labels, in toolkit order."
  def tools_md(b) do
    tools =
      Archetypes.toolkit()
      |> Enum.filter(&(&1.id in b.toolkit))
      |> Enum.map_join("\n", &"- #{&1.ic} #{&1.t} (`#{&1.id}`)")

    """
    # TOOLS.md

    #{tools}
    """
  end

  defp file_contents(b) do
    %{"SOUL.md" => soul_md(b), "IDENTITY.md" => identity_md(b), "TOOLS.md" => tools_md(b)}
  end

  # ── Persistence ────────────────────────────────────────────────────

  @doc """
  Bring a character to life: insert the agent, write `SOUL.md`,
  `IDENTITY.md` and `TOOLS.md`, and open the creator's DM with it, as one
  transaction. If any step fails nothing persists.

  `creator` is the user (anything with an `:id`). `:fail_after` names a step
  (`:agent`, `:soul`, `:identity`, `:tools`, `:dm`) after which the
  transaction is forced to fail; it exists so the rollback is testable.

  Returns `{:ok, %{agent: agent, files: %{key => file}, dm: space}}`, or
  `{:error, step, reason}`.
  """
  def create(attrs, creator, opts \\ []) do
    with {:ok, b} <- validate(attrs) do
      b = %{b | n: unique_name(clean_name(b.n))}
      fail_after = Keyword.get(opts, :fail_after)

      Multi.new()
      |> Multi.insert(:agent, Agent.changeset(%Agent{}, agent_attrs(b)))
      |> maybe_fail(:agent, fail_after)
      |> write_file(:soul, "SOUL.md", b)
      |> maybe_fail(:soul, fail_after)
      |> write_file(:identity, "IDENTITY.md", b)
      |> maybe_fail(:identity, fail_after)
      |> write_file(:tools, "TOOLS.md", b)
      |> maybe_fail(:tools, fail_after)
      |> Multi.run(:dm, fn _repo, %{agent: agent} ->
        Chat.find_or_create_dm(creator.id, "agent", agent.id)
      end)
      |> maybe_fail(:dm, fail_after)
      |> Repo.transaction()
      |> case do
        {:ok, r} ->
          {:ok,
           %{
             agent: r.agent,
             files: %{"SOUL.md" => r.soul, "IDENTITY.md" => r.identity, "TOOLS.md" => r.tools},
             dm: r.dm
           }}

        {:error, step, reason, _} ->
          {:error, step, reason}
      end
    else
      {:error, reason} -> {:error, :validate, reason}
    end
  end

  @doc """
  Give a character the face its creator uploaded in the builder (stage 2):
  the `avatar_url` and `avatar_storage_key` that
  `PlatformWeb.ControlCenter.AgentAvatarUpload.consume/2` returns. An empty
  map (nothing uploaded) leaves the agent as it is.
  """
  def put_avatar(%Agent{} = agent, attrs) when attrs == %{}, do: {:ok, agent}

  def put_avatar(%Agent{} = agent, %{} = attrs) do
    agent
    |> Agent.changeset(Map.take(attrs, [:avatar_url, :avatar_storage_key]))
    |> Repo.update()
  end

  defp write_file(multi, step, key, b) do
    Multi.run(multi, step, fn _repo, %{agent: agent} ->
      MemoryContext.upsert_workspace_file(agent.id, key, Map.fetch!(file_contents(b), key))
    end)
  end

  defp maybe_fail(multi, step, step) do
    Multi.run(multi, :forced_failure, fn _repo, _ -> {:error, {:forced_after, step}} end)
  end

  defp maybe_fail(multi, _step, _fail_after), do: multi

  @doc """
  Change a character: rewrite whichever of `SOUL.md`, `IDENTITY.md` and
  `TOOLS.md` the change alters, and the agent row (name, colour, toolkit,
  `metadata["character"]`), in one transaction.

  Each file is written with `:expected_version`. Pass
  `expected_versions: %{"SOUL.md" => n}` with the versions the caller read;
  a file that has moved since returns `{:error, :stale_workspace_file}` and
  nothing is written. The slug never changes, so the agent's URL survives a
  rename.
  """
  def update(%Agent{} = agent, changes, opts \\ []) do
    with %{} = b0 <- from_agent(agent) || {:error, :not_a_character},
         {:ok, b} <- validate(Map.merge(b0, Map.take(changes, editable_keys()))) do
      b = %{b | n: clean_name(b.n)}
      expected = Keyword.get(opts, :expected_versions, %{})
      contents = file_contents(b)

      Multi.new()
      |> Multi.run(:current, fn _repo, _ ->
        {:ok,
         agent.id
         |> MemoryContext.list_workspace_files(keys: @files)
         |> Map.new(&{&1.file_key, &1})}
      end)
      |> Multi.run(:check, fn _repo, %{current: current} ->
        stale? =
          Enum.any?(expected, fn {key, v} ->
            case current[key] do
              nil -> v not in [nil, 0]
              file -> file.version != v
            end
          end)

        if stale?, do: {:error, :stale_workspace_file}, else: {:ok, :fresh}
      end)
      |> Multi.run(:files, fn _repo, %{current: current} ->
        Enum.reduce_while(@files, {:ok, %{}}, fn key, {:ok, acc} ->
          file = current[key]

          if file && file.content == contents[key] do
            {:cont, {:ok, Map.put(acc, key, file)}}
          else
            version = Map.get(expected, key, file && file.version)

            case MemoryContext.upsert_workspace_file(agent.id, key, contents[key],
                   expected_version: version
                 ) do
              {:ok, written} -> {:cont, {:ok, Map.put(acc, key, written)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end)
      end)
      |> Multi.update(:agent, Agent.changeset(agent, update_attrs(agent, b0, b)))
      |> Repo.transaction()
      |> case do
        {:ok, r} -> {:ok, %{agent: r.agent, files: r.files}}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  defp editable_keys, do: [:cls, :n, :color, :portrait, :sl, :traits, :toolkit, :vc]

  # ── Validation and row attrs ───────────────────────────────────────

  @doc """
  Check a character map: a known class, colour slot, portrait, dials in
  0..100, at most three known traits, known toolkit ids and a valid voice.
  """
  def validate(attrs) when is_map(attrs) do
    a = Archetypes.get(attrs[:cls])
    vc = attrs[:vc] || %{}

    cond do
      is_nil(a) ->
        {:error, {:invalid, :cls}}

      not is_binary(attrs[:n]) ->
        {:error, {:invalid, :n}}

      attrs[:color] not in ColorPalette.ids() ->
        {:error, {:invalid, :color}}

      attrs[:portrait] not in Archetypes.portraits() ->
        {:error, {:invalid, :portrait}}

      not valid_sliders?(attrs[:sl]) ->
        {:error, {:invalid, :sl}}

      not valid_subset?(attrs[:traits], Archetypes.traits(), @max_traits) ->
        {:error, {:invalid, :traits}}

      not valid_subset?(attrs[:toolkit], Archetypes.toolkit_ids(), 10) ->
        {:error, {:invalid, :toolkit}}

      not valid_voice?(vc) ->
        {:error, {:invalid, :vc}}

      true ->
        {:ok,
         %{
           cls: a.id,
           n: attrs[:n],
           color: attrs[:color],
           portrait: attrs[:portrait],
           sl: attrs[:sl],
           traits: attrs[:traits],
           toolkit: Enum.filter(Archetypes.toolkit_ids(), &(&1 in attrs[:toolkit])),
           line: attrs[:line] || a.line,
           vc: %{p: vc[:p], ov: vc[:ov] || %{}, q: vc[:q] || "pr", free: vc[:free]},
           touched: attrs[:touched] || MapSet.new()
         }}
    end
  end

  def validate(_), do: {:error, {:invalid, :attrs}}

  defp valid_sliders?(sl) when is_map(sl) do
    Enum.all?(Archetypes.sliders(), fn s ->
      v = sl[s.k]
      is_integer(v) and v >= 0 and v <= 100
    end)
  end

  defp valid_sliders?(_), do: false

  defp valid_subset?(list, allowed, max) when is_list(list) do
    length(list) <= max and Enum.all?(list, &(&1 in allowed)) and Enum.uniq(list) == list
  end

  defp valid_subset?(_, _, _), do: false

  defp valid_voice?(%{p: p} = vc) when is_integer(p) and p >= 0 and p <= 4 do
    ov = vc[:ov] || %{}

    is_map(ov) and
      Enum.all?(ov, fn {k, v} ->
        case Enum.find(Archetypes.knobs(), &(&1.k == k)) do
          nil -> false
          knob -> is_integer(v) and v >= 0 and v < length(knob.options)
        end
      end)
  end

  defp valid_voice?(_), do: false

  @doc "Port of the comp's name clean-up: word characters, hyphens and spaces, at most 24."
  def clean_name(n) do
    n
    |> String.replace(~r/[^\w\- ]/, "")
    |> String.trim()
    |> String.slice(0, @max_name)
    |> String.trim()
    |> case do
      "" -> "Agent"
      clean -> clean
    end
  end

  @doc "The slug an agent name gets, the Control Center's rule."
  def slugify(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  # The comp's dedupe: a name another agent wears gets " II" until it is free.
  defp unique_name(name) do
    slug = slugify(name)

    if Repo.exists?(from(a in Agent, where: a.slug == ^slug)),
      do: unique_name(name <> " II"),
      else: name
  end

  defp agent_attrs(b) do
    a = Archetypes.fetch(b.cls)
    template = RoleTemplates.get(a.template)

    %{
      slug: slugify(b.n),
      name: b.n,
      status: "active",
      color: b.color,
      model_config:
        if(template,
          do: %{"primary" => template.suggested_model, "fallbacks" => []},
          else: %{}
        ),
      tools_config: template_tools(template) |> Map.put("toolkit", b.toolkit),
      metadata: %{"character" => character_meta(b)}
    }
  end

  defp template_tools(nil), do: %{"profile" => "minimal", "allow" => []}

  defp template_tools(template),
    do: %{"profile" => template.tool_profile, "allow" => template.tools_allow}

  defp update_attrs(agent, b0, b) do
    tools =
      if b.cls == b0.cls,
        do: agent.tools_config || %{},
        else:
          Map.merge(
            agent.tools_config || %{},
            template_tools(RoleTemplates.get(Archetypes.fetch(b.cls).template))
          )

    %{
      name: b.n,
      color: b.color,
      tools_config: Map.put(tools, "toolkit", b.toolkit),
      metadata: Map.put(agent.metadata || %{}, "character", character_meta(b))
    }
  end

  defp character_meta(b) do
    %{
      "archetype" => b.cls,
      "template_id" => Archetypes.fetch(b.cls).template,
      "portrait" => b.portrait,
      "sliders" => b.sl,
      "traits" => b.traits,
      "voice" => %{"preset" => Archetypes.voice(b.vc.p).key, "overrides" => b.vc.ov}
    }
  end
end

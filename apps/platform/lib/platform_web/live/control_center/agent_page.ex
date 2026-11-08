defmodule PlatformWeb.ControlCenter.AgentPage do
  @moduledoc """
  The living agent page (task 01a1b6ad stages 3 and 4): the comp's
  `renderPage()` head, `TABS` and all seven tab bodies (burrow-agents.js),
  rendered at `/control/:agent_slug` on both layouts.

  It replaces the old agent detail panel. Everything that panel held (the
  runtime controls, delete with runtime revocation, the "Answers chat
  messages" checkbox, the config form and its Color family swatches, voice
  provider fields, workspace editor, memory browser, vault and federation
  panels) renders in the `:settings` slot, behind ⋯ → "Advanced settings":
  the one structure the comp does not draw.

  The comp's `.desk` class is a 768px media query in app.css, so one render
  serves the phone page and the desktop page. The data comes from
  `PlatformWeb.ControlCenter.AgentPageData`; the events go to
  `PlatformWeb.ControlCenterLive`. The Connections graph is
  `PlatformWeb.ControlCenter.AgentGraph`.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.AgentPortrait, only: [agent_portrait: 1]

  alias Platform.Agents.{Archetypes, Character, ColorPalette}
  alias PlatformWeb.ControlCenter.AgentGraph
  alias PlatformWeb.ControlCenter.AgentPageData
  alias PlatformWeb.ControlCenter.CharacterBuilder

  @tabs [
    {"overview", "Overview"},
    {"voice", "Voice"},
    {"connections", "Connections"},
    {"abilities", "Abilities"},
    {"personality", "Personality"},
    {"memory", "Memory & notes"},
    {"stats", "Stats"}
  ]

  # The comp's per-tool line on the Abilities tab.
  @tool_lines %{
    "read" => "sees spaces it's in, replies",
    "tasks" => "creates & moves tasks",
    "canvases" => "drafts & edits canvases",
    "meetings" => "joins calls, answers Ask",
    "email" => "drafts only — you send",
    "prs" => "opens PRs on linked repos",
    "deploy" => "merges to main (= ships)",
    "web" => "searches the open web",
    "memory" => "reads & writes org memory",
    "files" => "reads files in its spaces"
  }

  @doc "The seven tab ids, in the comp's order."
  def tab_ids, do: Enum.map(@tabs, &elem(&1, 0))

  @doc "A tab id from the URL, or Overview."
  def normalize_tab(tab) when is_binary(tab) do
    if tab in tab_ids(), do: tab, else: "overview"
  end

  def normalize_tab(_), do: "overview"

  attr :agent, :map, required: true
  attr :page, :map, required: true
  attr :tab, :string, default: "overview"
  attr :advanced, :boolean, default: false
  attr :can_manage?, :boolean, default: false
  attr :mine?, :boolean, default: false
  attr :viewer, :string, default: nil
  attr :try, :map, default: %{}
  attr :saved, :atom, default: nil
  attr :show_card, :boolean, default: false
  attr :vault, :integer, default: 0
  attr :filter, :string, default: "all"
  attr :node, :string, default: nil
  attr :bar, :integer, default: nil
  slot :settings

  def page(assigns) do
    b = assigns.page.character

    b =
      b && %{b | vc: Map.merge(b.vc, assigns.try)}

    status = assigns.page.status

    assigns =
      assigns
      |> assign(:b, b)
      |> assign(:a, b && Archetypes.fetch(b.cls))
      |> assign(:slot, ColorPalette.slot_for(assigns.agent.color))
      |> assign(:status, status)
      |> assign(:tabs, @tabs)

    ~H"""
    <div
      id="agent-page"
      class="ba ba-page ba-alive"
      data-agent-slot={@slot}
      data-agent={@agent.name}
    >
      <div class="ba-ptop">
        <.link patch={~p"/control"} class="ib" aria-label="Back" data-a="back">
          <svg viewBox="0 0 24 24"><path d="m15 5-7 7 7 7" /></svg>
        </.link>
        <b>Agent</b>
        <button
          id="agent-more"
          type="button"
          class="ib"
          data-a="more"
          aria-label="More"
          aria-expanded={to_string(@advanced)}
          aria-controls="agent-advanced"
          phx-click="toggle_advanced"
        >
          <svg viewBox="0 0 24 24">
            <circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle
              cx="19"
              cy="12"
              r="1"
            />
          </svg>
        </button>
      </div>
      <div class="ba-pscroll" id="ba-pscroll">
        <div class="ba-phead">
          <button
            id="agent-more-desk"
            type="button"
            class="ba-pmore"
            aria-label="More"
            aria-expanded={to_string(@advanced)}
            aria-controls="agent-advanced"
            phx-click="toggle_advanced"
          >
            <svg viewBox="0 0 24 24">
              <circle cx="5" cy="12" r="1" /><circle cx="12" cy="12" r="1" /><circle
                cx="19"
                cy="12"
                r="1"
              />
            </svg>
          </button>
          <div class={["ba-avwrap", @status]} data-status={@status}>
            <.agent_portrait agent={@agent} portrait={@b && @b.portrait} size={120} />
            <span class="ring"></span><span class="ring r2"></span><span class="st"></span>
          </div>
          <div class="ba-pinfo">
            <div class="ba-pname">{@agent.name}</div>
            <div class="ba-pmeta">
              <span :if={@mine?} class="ba-pill mine">your agent</span>
              <span :if={@a} class="ba-pill" data-pill="class">{@a.glyph} {@a.n}</span>
              <span class={["ba-pill st", @status]} data-pill="status"><i></i>{@status}</span>
            </div>
            <div class="ba-doing">
              <span :if={@status == "working"} class="ba-typing"><i></i><i></i><i></i></span><span>{if @status == "idle", do: "", else: "now: "}<b>{@page.doing}</b></span>
            </div>
            <div class="ba-pacts">
              <.link
                navigate={~p"/voice?#{[partner: @agent.id]}"}
                class="ba-btn ag"
                data-a="talk"
              >
                🎙 Talk
              </.link>
              <button type="button" class="ba-btn" data-a="dm" phx-click="page_dm">
                💬 Message
              </button>
              <button
                type="button"
                class="ba-btn aw"
                data-a="awake"
                role="switch"
                aria-checked={to_string(@agent.accepts_chat == true)}
                phx-click="set_accepts_chat"
                phx-value-awake={to_string(@agent.accepts_chat != true)}
                disabled={!@can_manage?}
              >
                Awake <span class="ba-sw"></span>
              </button>
            </div>
          </div>
        </div>
        <div class="ba-ptabs" role="tablist">
          <button
            :for={{k, l} <- @tabs}
            type="button"
            role="tab"
            data-tab={k}
            aria-selected={to_string(@tab == k and not @advanced)}
            phx-click="page_tab"
            phx-value-tab={k}
          >
            {l}
          </button>
        </div>
        <div class={["ba-pbody", @advanced && "hidden"]} id="ba-pbody">
          <.overview :if={@tab == "overview"} page={@page} />
          <.voice
            :if={@tab == "voice"}
            agent={@agent}
            b={@b}
            viewer={@viewer}
            saved={@saved}
            can_manage?={@can_manage?}
          />
          <.personality
            :if={@tab == "personality"}
            agent={@agent}
            b={@b}
            page={@page}
            viewer={@viewer}
            show_card={@show_card}
            can_manage?={@can_manage?}
          />
          <.abilities
            :if={@tab == "abilities"}
            agent={@agent}
            page={@page}
            vault={@vault}
            can_manage?={@can_manage?}
          />
          <.connections
            :if={@tab == "connections"}
            agent={@agent}
            page={@page}
            filter={@filter}
            node={@node}
          />
          <.memory :if={@tab == "memory"} page={@page} can_manage?={@can_manage?} />
          <.stats :if={@tab == "stats"} page={@page} a={@a} bar={@bar} />
        </div>
        <section
          id="agent-advanced"
          class={["ba-advanced", !@advanced && "hidden"]}
          aria-label="Advanced settings"
        >
          <div class="ba-advhead">
            <div class="ba-lbl">Advanced settings</div>
            <button type="button" class="ba-link" phx-click="toggle_advanced">Done</button>
          </div>
          {render_slot(@settings)}
        </section>
      </div>
    </div>
    """
  end

  # ── Overview ───────────────────────────────────────────────────────

  attr :page, :map, required: true

  defp overview(assigns) do
    ~H"""
    <div class="ba-cols ba-step" data-body="overview">
      <div>
        <div class="ba-lbl" style="margin-top:0">Working on now</div>
        <div class="ba-now">
          <.link :for={x <- @page.now} navigate={~p"/tasks/#{x.id}"} data-now={x.id}>
            <span>☑</span><span><b>{x.title}</b><small>{x.where}</small></span><span class="stc">{x.status}</span>
          </.link>
          <div :if={@page.now == []} class="ba-gempty">
            Nothing assigned. @ it in any channel to hand it something.
          </div>
        </div>
        <div class="ba-lbl">Where it is</div>
        <div class="ba-chips">
          <.link
            :for={sp <- @page.spaces}
            navigate={~p"/chat/#{sp.slug}"}
            class="ba-chip"
            data-sp={sp.slug}
          >
            {sp.name} <small style="color:var(--color-subtle)">· {mode_short(sp.mode)}</small>
          </.link>
        </div>
        <div class="ba-lbl">At a glance</div>
        <div class="ba-tiles">
          <div class="ba-tile" data-tile="shipped">
            <b>{@page.shipped}</b><span>tasks shipped</span>
          </div>
          <div class="ba-tile" data-tile="first-reply">
            <b>{@page.first_reply}</b><span>median first reply</span>
          </div>
          <div class="ba-tile" data-tile="memories"><b>{@page.memories}</b><span>memories</span></div>
        </div>
      </div>
      <div>
        <div class="ba-lbl" style="margin-top:0">Today</div>
        <div class="ba-tl">
          <div :for={{x, i} <- Enum.with_index(@page.today)} class={x.live && "live"}>
            <time
              :if={x.at}
              id={"ba-tl-#{i}"}
              datetime={DateTime.to_iso8601(x.at)}
              data-local-time={DateTime.to_iso8601(x.at)}
              phx-hook="LocalTime"
            >
              {Calendar.strftime(x.at, "%H:%M")}
            </time>
            <time :if={!x.at}>now</time>{x.ic} {x.t}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp mode_short(mode) do
    case AgentPageData.mode(mode) do
      nil -> mode
      m -> m.short
    end
  end

  # ── Voice ──────────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :b, :map, default: nil
  attr :viewer, :string, default: nil
  attr :saved, :atom, default: nil
  attr :can_manage?, :boolean, default: false

  defp voice(assigns) do
    ~H"""
    <div class="ba-step" data-body="voice">
      <div class="ba-vhead">
        <div class="ba-lbl">How {@agent.name} talks</div>
        <span class={["ba-vsaved", @saved == :voice && "on"]} role="status">
          ✓ Saved · applies to new replies
        </span>
      </div>
      <fieldset :if={@b} disabled={!@can_manage?} class="ba-fs">
        <CharacterBuilder.voice_block b={@b} viewer={@viewer} agent={@agent} cols idp="ap-" />
      </fieldset>
      <.legacy :if={!@b} />
    </div>
    """
  end

  defp legacy(assigns) do
    ~H"""
    <div class="ba-gempty" data-legacy>
      Built before characters, so it has no dials or voice here. Its SOUL.md is under ⋯ → Advanced settings.
    </div>
    """
  end

  # ── Personality ────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :b, :map, default: nil
  attr :page, :map, required: true
  attr :viewer, :string, default: nil
  attr :show_card, :boolean, default: false
  attr :can_manage?, :boolean, default: false

  defp personality(%{b: nil} = assigns) do
    ~H"""
    <div class="ba-step" data-body="personality"><.legacy /></div>
    """
  end

  defp personality(assigns) do
    said =
      case assigns.page.said do
        %{content: c} when is_binary(c) and c != "" -> c
        _ -> Character.first_line(assigns.b, assigns.viewer)
      end

    assigns = assign(assigns, :said, said)

    ~H"""
    <div class="ba-cols ba-step" data-body="personality">
      <div>
        <div class="ba-lbl" style="margin-top:0">Dials</div>
        <form id="ap-dials-form" phx-change="page_dials">
          <fieldset disabled={!@can_manage?} class="ba-fs">
            <div :for={s <- Archetypes.sliders()} class="ba-slider">
              <div class="ends">
                <span class={@b.sl[s.k] < 50 && "lean"}>{s.lo}</span>
                <span class={@b.sl[s.k] >= 50 && "lean"}>{s.hi}</span>
              </div>
              <input
                type="range"
                min="0"
                max="100"
                name={"sl[#{s.k}]"}
                value={@b.sl[s.k]}
                data-psl={s.k}
                aria-label={"#{s.lo} to #{s.hi}"}
                phx-debounce="250"
              />
            </div>
          </fieldset>
        </form>
        <div class="ba-lbl">Traits · pick three</div>
        <div class="ba-chips">
          <button
            :for={t <- Archetypes.traits()}
            type="button"
            class="ba-chip"
            data-ptr={t}
            aria-pressed={to_string(t in @b.traits)}
            phx-click="page_trait"
            phx-value-tr={t}
            disabled={!@can_manage?}
          >
            {t}
          </button>
        </div>
      </div>
      <div>
        <div class="ba-lbl" style="margin-top:0">Its voice</div>
        <div class="ba-says" id="ba-voice">
          <small>HOW IT WOULD TELL YOU A PR IS READY</small>“{Character.voice_sample(@b)}”
        </div>
        <div class="ba-says" id="ba-said" style="margin-top:10px">
          <small>SOMETHING IT ACTUALLY SAID</small>“{@said}”
        </div>
        <div style="display:flex;gap:8px;margin-top:12px">
          <button
            type="button"
            class="ba-btn sm"
            data-a="hear"
            phx-click="page_hear"
            disabled={is_nil(@page.hear)}
          >
            ▶ Hear it
          </button>
          <button type="button" class="ba-btn sm" data-a="card" phx-click="page_card">
            🃏 Show its card
          </button>
        </div>
        <p class="ba-sub" style="font-size:11px">
          Dials and traits are written to its <code style="font-family:var(--font-mono)">SOUL.md</code>. Changes apply from its next turn.
        </p>
        <div id="ba-cardslot" style="display:flex;justify-content:center;margin-top:10px">
          <CharacterBuilder.card
            :if={@show_card}
            b={@b}
            number={@page.number}
            viewer={@viewer}
            agent={@agent}
            reveal
            w={300}
            prefix="page"
          />
        </div>
      </div>
    </div>
    """
  end

  # ── Abilities ──────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :page, :map, required: true
  attr :vault, :integer, default: 0
  attr :can_manage?, :boolean, default: false

  defp abilities(assigns) do
    toolkit = (assigns.agent.tools_config || %{})["toolkit"] || []

    assigns =
      assigns
      |> assign(:on, toolkit)
      |> assign(:tools, Archetypes.toolkit())
      |> assign(:tool_lines, @tool_lines)
      |> assign(:modes, AgentPageData.modes())

    ~H"""
    <div class="ba-cols ba-step" data-body="abilities">
      <div>
        <div class="ba-lbl" style="margin-top:0">Toolkit</div>
        <div class="ba-group ba-tk">
          <button
            :for={t <- @tools}
            type="button"
            class="ba-row"
            role="switch"
            data-tk={t.id}
            aria-checked={to_string(t.id in @on)}
            phx-click="page_toolkit"
            phx-value-tk={t.id}
            disabled={!@can_manage?}
          >
            <span class="ic">{t.ic}</span><span class="tx"><b>{t.t}</b><small>{@tool_lines[t.id]}</small></span><span class="ba-sw"></span>
          </button>
        </div>
        <p class="ba-sub" style="font-size:11px">
          Stored on the agent as <code style="font-family:var(--font-mono)">tools_config</code>; credentials stay in the vault ({@vault} granted).
        </p>
      </div>
      <div>
        <div class="ba-lbl" style="margin-top:0">Mode, per channel</div>
        <div class="ba-chmode">
          <div :for={sp <- @page.spaces} class="r" data-space={sp.slug}>
            <b>{sp.name}<small>{mode_line(sp.mode)}</small></b>
            <div class="ba-seg">
              <button
                :for={m <- @modes}
                type="button"
                data-chm={sp.slug}
                data-m={m.id}
                aria-pressed={to_string(sp.mode == m.id)}
                phx-click="page_mode"
                phx-value-space={sp.space_id}
                phx-value-mode={m.id}
                disabled={!@can_manage?}
              >
                {m.label}
              </button>
            </div>
          </div>
          <div :if={@page.spaces == []} class="ba-gempty">Not in any channel yet.</div>
        </div>
        <button
          :if={@can_manage?}
          type="button"
          class="ba-btn sm"
          data-a="addsp"
          style="margin-top:10px"
          phx-click="show_add_space_modal"
        >
          ＋ Add to a channel
        </button>
      </div>
    </div>
    """
  end

  defp mode_line(mode) do
    case AgentPageData.mode(mode) do
      nil -> ""
      m -> m.line |> String.split(".") |> hd()
    end
  end

  # ── Connections ────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :page, :map, required: true
  attr :filter, :string, default: "all"
  attr :node, :string, default: nil

  defp connections(assigns) do
    nodes = assigns.page.graph || []

    present =
      Enum.map(AgentPageData.kinds(), &elem(&1, 0))
      |> Enum.filter(fn k -> Enum.any?(nodes, &(&1.k == k)) end)

    sel = Enum.find(nodes, &(&1.id == assigns.node))

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:kinds, ["all" | present])
      |> assign(:present, present)
      |> assign(:sel, sel)

    ~H"""
    <div class="ba-step" data-body="connections">
      <div class="ba-gfilters">
        <button
          :for={k <- @kinds}
          type="button"
          class="ba-chip"
          data-gf={k}
          aria-pressed={to_string(@filter == k)}
          phx-click="page_filter"
          phx-value-k={k}
        >
          {AgentPageData.filter_label(k)}
          <small style="color:var(--color-subtle)">{kind_count(@nodes, k)}</small>
        </button>
      </div>
      <div class="ba-graph" id="ba-graph">
        <AgentGraph.graph nodes={@nodes} name={@agent.name} filter={@filter} sel={@node} mob />
        <AgentGraph.graph nodes={@nodes} name={@agent.name} filter={@filter} sel={@node} />
      </div>
      <div class="ba-glegend">
        <span :for={k <- @present} data-legend={k}>
          <i style={"border-color:#{legend_color(k)}"}></i>{AgentGraph.glyph(k)} {AgentGraph.kind_label(
            k
          )}
        </span>
        <span style="margin-left:auto">line weight = how much they work together</span>
      </div>
      <div id="ba-nodecard">
        <div :if={is_nil(@sel)} class="ba-gempty">Tap a node to see what they do together.</div>
        <.node_card :if={@sel} n={@sel} />
      </div>
    </div>
    """
  end

  defp kind_count(nodes, "all"), do: length(nodes)
  defp kind_count(nodes, k), do: Enum.count(nodes, &(&1.k == k))

  # The comp's legend ring colour per kind, on the app's tokens.
  defp legend_color("channel"), do: "var(--color-info)"
  defp legend_color("project"), do: "var(--color-primary)"
  defp legend_color("repo"), do: "var(--color-subtle)"
  defp legend_color("tool"), do: "var(--color-subtle)"
  defp legend_color("person"), do: "var(--color-base-content)"
  defp legend_color(_), do: "var(--ag)"

  attr :n, :map, required: true

  # The comp's nodeDetail(): kind, title, sub, the kind's lines, strength,
  # then the actions. A channel opens or changes mode; a project opens its
  # tasks. A person has no profile page here, so no action.
  defp node_card(assigns) do
    ~H"""
    <div class="ba-node" data-node-card={@n.id}>
      <div class="k">{AgentGraph.kind_label(@n.k)}</div>
      <h4>
        {if @n.k == "channel" and String.starts_with?(@n.l, ["#", "D"]),
          do: "",
          else: AgentGraph.glyph(@n.k) <> " "}{@n.l}
      </h4>
      <p>{@n.sub}</p>
      <ul>
        <li :for={{a, b} <- @n.lines}>
          <span style="color:var(--color-subtle)">{a}</span><small>{b}</small>
        </li>
        <li>
          <span style="color:var(--color-subtle)">strength</span><small>{String.duplicate("●", @n.w)}{String.duplicate("○", 3 - @n.w)}</small>
        </li>
      </ul>
      <div class="acts">
        <.link
          :if={@n.k == "channel"}
          navigate={~p"/chat/#{@n.slug}"}
          class="ba-btn sm ag"
          data-open-space={@n.space_id}
        >
          Open {@n.l}
        </.link>
        <button
          :if={@n.k == "channel"}
          type="button"
          class="ba-btn sm"
          data-a="tab-abilities"
          phx-click="page_tab"
          phx-value-tab="abilities"
        >
          Change mode
        </button>
        <.link
          :if={@n.k == "project"}
          navigate={~p"/tasks?#{[project: @n.project_id]}"}
          class="ba-btn sm ag"
          data-a="tasks"
        >
          Open tasks
        </.link>
      </div>
    </div>
    """
  end

  # ── Memory & notes ─────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :can_manage?, :boolean, default: false

  defp memory(assigns) do
    ~H"""
    <div class="ba-cols ba-step" data-body="memory">
      <div>
        <div class="ba-lbl" style="margin-top:0">What it remembers about you</div>
        <div class="ba-mems" id="ba-mems">
          <div :for={m <- @page.remembers || []} class="ba-memc" data-memory={m.id}>
            <span>📌</span>
            <div class="tx">{m.t}<small>{m.src}</small></div>
            <button
              type="button"
              data-forget={m.id}
              phx-click="page_forget"
              phx-value-id={m.id}
              disabled={!@can_manage?}
            >
              Forget
            </button>
          </div>
        </div>
        <form class="ba-addnote" id="ba-addnote" phx-submit="page_note">
          <input
            id="ba-note"
            name="note"
            placeholder="Tell it something to remember…"
            aria-label="Add a note"
            autocomplete="off"
            disabled={!@can_manage?}
          />
          <button type="submit" class="ba-btn sm ag" data-a="note" disabled={!@can_manage?}>
            Add
          </button>
        </form>
      </div>
      <div>
        <div class="ba-lbl" style="margin-top:0">Org memory it reads</div>
        <div class="ba-group" data-pages>
          <.link
            :for={pg <- @page.pages || []}
            navigate={~p"/org_memory/#{String.split(pg.file_key, "/")}"}
            class="ba-row"
            data-page={pg.file_key}
          >
            <span class="ic">🧠</span><span class="tx"><b>{pg.title}</b><small>{pg.sub}</small></span><span style="color:var(--color-subtle)">›</span>
          </.link>
          <div :if={(@page.pages || []) == []} class="ba-gempty" data-pages-empty>
            No pages yet.
          </div>
        </div>
        <p class="ba-sub" style="font-size:11px" data-pages-note>
          Pages it has written or edited. Nothing records what it reads.
        </p>
        <div class="ba-lbl">Its workspace</div>
        <div class="ba-group" data-files>
          <button
            :for={f <- @page.files || []}
            type="button"
            class="ba-row"
            data-file={f.key}
            phx-click="page_file"
            phx-value-key={f.key}
          >
            <span class="ic">📄</span><span class="tx"><b style="font-family:var(--font-mono);font-size:13px">{f.key}</b><small>{f.desc}</small></span>
          </button>
          <div :if={(@page.files || []) == []} class="ba-gempty" data-files-empty>
            No files yet.
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Stats ──────────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :a, :map, default: nil
  attr :bar, :integer, default: nil

  defp stats(assigns) do
    s = assigns.page.stats
    pts = s.tasks * 40 + s.prs * 25 + s.meetings * 15
    mx = max(1, Enum.max(s.spark))

    bars =
      s.spark
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        %{
          i: i,
          v: v,
          height: max(2.0, v / mx * 100),
          title: "#{v} shipped · #{if 14 - i == 1, do: "today", else: "#{14 - i - 1}d ago"}"
        }
      end)

    tip =
      case Enum.find(bars, &(&1.i == assigns.bar)) do
        nil -> "Hover or tap a bar."
        b -> b.title
      end

    badges =
      [
        s.prs > 0 && {"⑂", "First PR"},
        s.prs >= 20 && {"🏗️", "20 PRs merged"},
        s.meetings >= 10 && {"🎥", "Meeting regular"},
        s.streak >= 7 && {"🔥", "Week streak"},
        {"✨", "Brought to life"}
      ]
      |> Enum.filter(& &1)

    assigns =
      assigns
      |> assign(:s, s)
      |> assign(:lvl, 1 + div(pts, 350))
      |> assign(:xp, rem(pts, 350))
      |> assign(:bars, bars)
      |> assign(:tip, tip)
      |> assign(:badges, badges)

    ~H"""
    <div class="ba-step" data-body="stats" id="ba-stats" phx-hook="AgentStatsBars">
      <div class="ba-tiles">
        <div class="ba-tile" data-tile="shipped">
          <b>{@s.tasks}</b><span>tasks shipped</span><small>since {Calendar.strftime(@s.since, "%b %-d")}</small>
        </div>
        <div class="ba-tile" data-tile="prs">
          <b>{@s.prs}</b><span>PRs merged</span><small>merged = shipped</small>
        </div>
        <div class="ba-tile" data-tile="meetings">
          <b>{@s.meetings}</b><span>meetings attended</span><small>joined as a participant</small>
        </div>
        <div class="ba-tile" data-tile="first-reply">
          <b>{@s.resp}</b><span>median first reply</span><small>no source records it</small>
        </div>
        <div class="ba-tile" data-tile="messages">
          <b>{@s.msgs}</b><span>messages</span><small>all spaces</small>
        </div>
        <div class="ba-tile" data-tile="streak">
          <b>{@s.streak}d</b><span>streak</span><small>days with a shipped task</small>
        </div>
      </div>
      <div class="ba-lbl">Shipped per day · last 14 days</div>
      <div class="ba-bars" id="ba-bars">
        <i
          :for={b <- @bars}
          data-i={b.i}
          class={b.i == @bar && "hl"}
          style={"height:#{AgentGraph.f2(b.height)}%"}
          title={b.title}
          phx-click="page_bar"
          phx-value-i={b.i}
        >
        </i>
      </div>
      <div class="ba-barax"><span>14d ago</span><span>today</span></div>
      <div class="ba-bartip" id="ba-bartip">{@tip}</div>
      <div class="ba-lbl">Level</div>
      <div class="ba-xp">
        <div class="sbar"><i style={"width:#{AgentGraph.f2(@xp / 3.5)}%"}></i></div>
        <div>
          <span><b>Level {@lvl}</b> {if @a, do: @a.n, else: "Agent"}</span><span>{@xp} / 350 xp to level {@lvl + 1}</span>
        </div>
      </div>
      <div class="ba-lbl">Badges</div>
      <div class="ba-badges">
        <span :for={{i, t} <- @badges}>{i} {t}</span>
      </div>
    </div>
    """
  end
end

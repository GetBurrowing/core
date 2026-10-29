defmodule PlatformWeb.AdminThemesLive do
  @moduledoc """
  `/admin/themes`, the theme editor (task 01a1557a-fe9b, Burrow redesign 24,
  stage 2). A port of the masters' `theme.html` onto `Platform.Theming`
  (stage 1).

  ## Shape

  Full-bleed, with no shell sidebar: the masters page has its own 56px top
  bar, so the view mounts with the chrome-less `:holding` layout. The top bar
  holds the library (the five presets, then every org's saved themes) and the
  actions; the left column edits one variant (dark or light) of the working
  copy; the right pane frames the real app at `/chat?theme_preview=1`, a
  375x812 phone and a 1280x800 desktop scaled to fit.

  ## The working copy

  `@work` is the theme being edited: a preset or an org theme, plus any
  unsaved edits. Edits stay in the socket until Save as…, Rename, Duplicate,
  Import or Apply writes them through `Platform.Theming`, which re-checks
  `Tenancy.root_admin?/1` on every write, so this page's gate is not the only
  one. A preset is never written: Rename and Delete are disabled on it and
  Apply asks for a Save as… first.

  An unedited preset is measured and painted from its declared variants
  (`Platform.Theming.Presets`); once edited it is measured the way a saved
  draft will be, through `Platform.Theming.Tokens.variant/2`.

  ## Live preview

  Every change recomputes `Tokens.declarations/2` and pushes
  `theme-preview` (`%{vars, mode}`) for each mode on show. The `ThemeEditor`
  hook (assets/js/hooks/theme_editor.js) posts it to the frames with
  `targetOrigin` set to this page's origin; the receiver in the frame
  (assets/js/hooks/theme_preview_receiver.js) checks the origin and applies
  only allowlisted custom properties. As in the masters, the editor previews
  the draft too: the same declarations sit on the `data-theme-preview`
  wrapper.

  ## Contrast

  `Platform.Theming.ledger/2` is the one measurement. The summary counts the
  edited variant, and adds the other variant's fail count when it is
  non-zero ("· light: 3 fail"); Apply counts both, because
  `Theming.publish/2` refuses a theme with any failing row in either mode,
  and is disabled with the count and its mode(s) written beside it.
  """
  use PlatformWeb, :live_view

  alias Platform.Tenancy
  alias Platform.Theming
  alias Platform.Theming.OrgTheme
  alias Platform.Theming.Presets
  alias Platform.Theming.Tokens

  @modes ["dark", "light"]

  # The masters' groups (theme.js COLOR_GROUPS), restricted to the keys that
  # have an app slot (`Tokens.color_keys/0`): desk, faint, bubbleMe,
  # dangerDim, scrim and shade have none.
  @groups [
    %{
      id: "grounds",
      label: "Grounds",
      keys: [
        {"ground", "Base", "page backdrop, rail"},
        {"surface", "Raised", "app shell, cards, sheets"},
        {"raised", "Overlay", "hover / selected fill, popovers"},
        {"edge", "Edge", "borders, dividers"}
      ]
    },
    %{
      id: "text",
      label: "Text",
      keys: [{"ink", "Primary", "body text"}, {"muted", "Secondary", "meta, labels"}]
    },
    %{
      id: "accent",
      label: "Accent",
      keys: [
        {"accent", "Accent", "the one “click this” colour"},
        {"interactive", "Interactive", "hover / focus / links"},
        {"onAccent", "On accent", "text on an accent fill"}
      ]
    },
    %{
      id: "agents",
      label: "Agent colours",
      keys: [
        {"agTeal", "Teal slot", "agent hue 1"},
        {"agGreen", "Green slot", "agent hue 2"},
        {"agAmber", "Amber slot", "agent hue 3"},
        {"agOrange", "Orange slot", "agent hue 4 (Burrow)"},
        {"agBlue", "Blue slot", "agent hue 5"},
        {"agPurple", "Purple slot", "agent hue 6"},
        {"agBrick", "Brick slot", "agent hue 7"},
        {"agRose", "Rose slot", "agent hue 8"},
        {"agIndigo", "Indigo slot", "agent hue 9"},
        {"agLime", "Lime slot", "agent hue 10"}
      ]
    },
    %{
      id: "status",
      label: "Status colours",
      keys: [
        {"info", "Info", "teal · presence"},
        {"infoDim", "Info dim", "badge fill"},
        {"active", "Success", "green · running / done"},
        {"activeDim", "Success dim", "badge fill"},
        {"warning", "Warning", "amber · attention"},
        {"warningDim", "Warning dim", "badge fill"},
        {"danger", "Error", "red · destructive"}
      ]
    },
    %{
      id: "misc",
      label: "Overlays",
      keys: [
        {"viewer", "Viewer", "full-screen viewer backdrop"},
        {"stage", "Game stage", "game stage backdrop"}
      ]
    }
  ]

  # The masters' per-group contrast rows (paintContrast), by ledger label.
  # "Muted on base" measured `faint`, a retired tier: it now measures the
  # painted --subtle on base-200, the ledger's "subtle on base-200" row.
  @contrast_rows %{
    "text" => [
      {"Primary on base", "Primary on base"},
      {"Primary on raised", "Primary on raised"},
      {"Primary on overlay", "Primary on overlay"},
      {"Secondary on base", "Secondary on base"},
      {"Secondary on raised", "Secondary on raised"},
      {"Muted on base", "subtle on base-200"}
    ],
    "accent" => [
      {"Accent on base", "Accent on base"},
      {"Accent on raised", "Accent on raised"},
      {"Interactive on base", "Interactive on base"},
      {"On-accent on accent", "On-accent on accent"}
    ],
    "agents" =>
      Enum.flat_map(~w(Teal Green Amber Orange), fn n ->
        [{"#{n} on base", "#{n} on base"}, {"#{n} on raised", "#{n} on raised"}]
      end) ++
        for(n <- ~w(Blue Purple Brick Rose Indigo Lime), do: {"#{n} on raised", "#{n} on raised"}),
    "status" => [
      {"Info on raised", "Info on raised"},
      {"Success on raised", "Success on raised"},
      {"Warning on raised", "Warning on raised"},
      {"Error on raised", "Error on raised"}
    ]
  }

  @font_labels ~w(Inter System Serif Mono Avenir)

  @toast_ms 2500

  @doc "The colour groups the control column renders, in order."
  def groups, do: @groups

  @doc "The masters' contrast rows of group `id`: `[{label, ledger_label}]`."
  def contrast_rows(id), do: Map.get(@contrast_rows, id, [])

  @doc "`--kebab` of a master key, as the masters print it."
  def kebab(key), do: "--" <> String.replace(key, ~r/[A-Z]/, &("-" <> String.downcase(&1)))

  @doc """
  The name a duplicate of `name` takes among `taken`: "<name> (copy)", then
  "<name> (copy 2)", "<name> (copy 3)" and so on. Never over 80 characters.
  """
  @spec copy_name(String.t(), [String.t()]) :: String.t()
  def copy_name(name, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> fit(name, " (copy)")
      n -> fit(name, " (copy #{n})")
    end)
    |> Enum.find(&(&1 not in taken))
  end

  defp fit(name, suffix), do: String.slice(name, 0, 80 - String.length(suffix)) <> suffix

  @doc "The verdict word for a ratio: AA (4.5), AA large (3) or fail."
  def verdict(ratio) when ratio >= 4.5, do: "AA"
  def verdict(ratio) when ratio >= 3.0, do: "AA large"
  def verdict(_), do: "fail"

  @doc "A floored ledger ratio as the page prints it: `16.29:1`."
  def format_ratio(ratio), do: :erlang.float_to_binary(ratio / 1, decimals: 2) <> ":1"

  @doc "The `theme-preview` vars for `theme` in `mode`: slot => value."
  @spec preview_vars(map(), String.t()) :: %{String.t() => String.t()}
  def preview_vars(theme, mode) do
    theme
    |> Tokens.declarations(mode)
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [name, value] = String.split(line, ": ", parts: 2)
      {name, String.trim_trailing(value, ";")}
    end)
  end

  # ── mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    root = Tenancy.get_root_org()
    orgs = Tenancy.list_orgs() |> Enum.sort_by(&{&1.id != root.id, &1.name})

    socket =
      socket
      |> assign(:page_title, "Theme admin")
      |> assign(:root_org, root)
      |> assign(:orgs, orgs)
      |> assign(:presets, Presets.all())
      |> assign(:pv_mode, "dark")
      |> assign(:both?, false)
      |> assign(:reload, 0)
      |> assign(:modal, nil)
      |> assign(:modal_error, nil)
      |> assign(:toast, nil)
      |> assign(:toast_n, 0)
      |> load_library()
      |> load_work(preset_work(Presets.base()))

    {:ok, socket, layout: {PlatformWeb.Layouts, :holding}}
  end

  # ── events: library and modes ───────────────────────────────────────────

  @impl true
  def handle_event("load", %{"id" => "preset:" <> id}, socket) do
    case Presets.get(id) do
      nil -> {:noreply, socket}
      preset -> {:noreply, load_work(socket, preset_work(preset))}
    end
  end

  def handle_event("load", %{"id" => "org:" <> id}, socket) do
    case Enum.find(socket.assigns.org_themes, &(&1.id == id)) do
      nil -> {:noreply, socket}
      theme -> {:noreply, load_work(socket, org_work(theme))}
    end
  end

  def handle_event("load", _params, socket), do: {:noreply, socket}

  def handle_event("ed_mode", %{"mode" => mode}, socket) when mode in @modes,
    do: {:noreply, socket |> assign(:ed_mode, mode) |> assign_ledgers()}

  def handle_event("default_mode", _params, socket) do
    mode = if socket.assigns.work.default_mode == "dark", do: "light", else: "dark"
    {:noreply, socket |> update_work(&Map.put(&1, :default_mode, mode)) |> preview()}
  end

  def handle_event("pv_mode", %{"mode" => "both"}, socket),
    do: {:noreply, socket |> assign(:both?, true) |> preview()}

  def handle_event("pv_mode", %{"mode" => mode}, socket) when mode in @modes,
    do: {:noreply, socket |> assign(both?: false, pv_mode: mode) |> preview()}

  def handle_event("reload_frames", _params, socket),
    do: {:noreply, socket |> update(:reload, &(&1 + 1)) |> preview()}

  # ── events: tokens and shape ────────────────────────────────────────────

  def handle_event("token", %{"key" => key} = params, socket) do
    if key in Tokens.color_keys() do
      raw =
        case params["_target"] do
          ["pick"] -> params["pick"]
          _ -> params["value"]
        end

      {:noreply, set_token(socket, key, raw)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("shape", params, socket) do
    work = socket.assigns.work

    candidate =
      for key <- ["radius", "density", "glass_alpha", "glass_blur", "font"],
          Map.has_key?(params, key),
          into: work.shape,
          do: {key, params[key]}

    {:noreply, set_shape(socket, candidate)}
  end

  def handle_event("font_chip", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 and i < 5 ->
        {:noreply,
         set_shape(
           socket,
           Map.put(socket.assigns.work.shape, "font", Enum.at(Tokens.font_chips(), i))
         )}

      _ ->
        {:noreply, socket}
    end
  end

  # ── events: modals ──────────────────────────────────────────────────────

  def handle_event("open", %{"modal" => modal}, socket)
      when modal in ~w(save_as rename delete export import apply) do
    {:noreply, assign(socket, modal: modal, modal_error: nil)}
  end

  def handle_event("close_modal", _params, socket),
    do: {:noreply, assign(socket, modal: nil, modal_error: nil)}

  def handle_event("save_as", %{"name" => name, "org_id" => org_id}, socket) do
    if Enum.any?(socket.assigns.orgs, &(&1.id == org_id)) do
      case Theming.create_draft(actor(socket), org_id, draft_attrs(socket.assigns.work, name)) do
        {:ok, theme} ->
          {:noreply, socket |> saved(theme) |> toast("Saved · #{theme.name}")}

        {:error, reason} ->
          {:noreply, assign(socket, :modal_error, describe(reason))}
      end
    else
      {:noreply, assign(socket, :modal_error, "Choose an org")}
    end
  end

  def handle_event("rename", %{"name" => name}, socket) do
    with {:ok, theme} <- current_theme(socket),
         {:ok, renamed} <- Theming.rename(actor(socket), theme, name) do
      socket =
        socket
        |> load_library()
        |> update_work(&Map.merge(&1, %{name: renamed.name, theme: renamed}), dirty: false)
        |> assign(modal: nil, modal_error: nil)

      {:noreply, toast(socket, "Renamed")}
    else
      {:error, reason} -> {:noreply, assign(socket, :modal_error, describe(reason))}
    end
  end

  def handle_event("delete", %{"confirm" => confirm}, socket) do
    with :ok <- if(confirm == "DELETE", do: :ok, else: {:error, "Type DELETE to confirm"}),
         {:ok, theme} <- current_theme(socket),
         {:ok, _} <- Theming.delete(actor(socket), theme) do
      socket =
        socket
        |> load_library()
        |> load_work(preset_work(Presets.base()))
        |> assign(modal: nil, modal_error: nil)

      {:noreply, toast(socket, "Deleted")}
    else
      {:error, reason} -> {:noreply, assign(socket, :modal_error, describe(reason))}
    end
  end

  def handle_event("duplicate", _params, socket) do
    work = socket.assigns.work
    org_id = work.org_id || socket.assigns.root_org.id
    taken = for t <- socket.assigns.org_themes, t.org_id == org_id, do: t.name

    case Theming.create_draft(
           actor(socket),
           org_id,
           draft_attrs(work, copy_name(work.name, taken))
         ) do
      {:ok, theme} -> {:noreply, socket |> saved(theme) |> toast("Duplicated")}
      {:error, reason} -> {:noreply, toast(socket, describe(reason))}
    end
  end

  def handle_event("import", %{"json" => text}, socket) do
    socket = assign(socket, modal: nil, modal_error: nil)

    with {:ok, %{} = decoded} <- decode(text),
         {:ok, theme} <-
           Theming.create_draft(actor(socket), socket.assigns.root_org.id, import_attrs(decoded)) do
      {:noreply, socket |> saved(theme) |> toast("Imported · #{theme.name}")}
    else
      {:error, reason} -> {:noreply, toast(socket, "Invalid JSON: " <> describe(reason))}
    end
  end

  def handle_event("apply", _params, socket) do
    if apply_block(socket.assigns) do
      {:noreply, assign(socket, :modal, nil)}
    else
      do_apply(socket)
    end
  end

  def handle_event("reset", _params, socket) do
    socket =
      socket
      |> assign(both?: false, pv_mode: "dark")
      |> load_work(preset_work(Presets.base()))

    {:noreply, toast(socket, "Reset to Burrow dark")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:clear_toast, n}, %{assigns: %{toast_n: n}} = socket),
    do: {:noreply, assign(socket, :toast, nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── working copy ────────────────────────────────────────────────────────

  defp preset_work(preset) do
    %{
      key: "preset:" <> preset.id,
      builtin?: true,
      preset: preset,
      theme: nil,
      name: preset.name,
      org_id: nil,
      status: nil,
      default_mode: preset.default_mode,
      light: preset.light,
      dark: preset.dark,
      shape: preset.shape
    }
  end

  defp org_work(%OrgTheme{} = theme) do
    %{
      key: "org:" <> theme.id,
      builtin?: false,
      preset: nil,
      theme: theme,
      name: theme.name,
      org_id: theme.org_id,
      status: theme.status,
      default_mode: theme.default_mode,
      light: theme.light,
      dark: theme.dark,
      shape: theme.shape
    }
  end

  defp load_work(socket, work) do
    socket
    |> assign(:work, work)
    |> assign(:dirty?, false)
    |> assign(:ed_mode, work.default_mode)
    |> assign(:errors, %{})
    |> assign_ledgers()
    |> preview()
  end

  defp update_work(socket, fun, opts \\ []) do
    socket
    |> assign(:work, fun.(socket.assigns.work))
    |> assign(:dirty?, Keyword.get(opts, :dirty, true))
    |> assign_ledgers()
  end

  # What is measured and painted: an unedited preset's declared variants,
  # else the working palette through Tokens.variant/2.
  defp measured(%{work: %{preset: preset}, dirty?: false}) when not is_nil(preset), do: preset
  defp measured(%{work: work}), do: %{light: work.light, dark: work.dark, shape: work.shape}

  defp assign_ledgers(socket) do
    theme = measured(socket.assigns)
    ledgers = Map.new(@modes, &{&1, Theming.ledger(theme, &1)})

    socket
    |> assign(:ledgers, ledgers)
    |> assign(:wrapper_style, Tokens.declarations(theme, wrapper_mode(socket.assigns)))
  end

  defp wrapper_mode(%{both?: true, work: work}), do: work.default_mode
  defp wrapper_mode(%{pv_mode: mode}), do: mode

  defp set_token(socket, key, raw) do
    mode = socket.assigns.ed_mode

    case OrgTheme.normalise_color(raw) do
      {:ok, hex} ->
        socket
        |> assign(:errors, Map.delete(socket.assigns.errors, {mode, key}))
        |> update_work(fn work ->
          Map.update!(work, palette_field(mode), &(&1 |> Map.put(key, hex) |> drop_override(key)))
        end)
        |> preview()

      {:error, why} ->
        assign(socket, :errors, Map.put(socket.assigns.errors, {mode, key}, why))
    end
  end

  # Editing the key a carried override follows drops the override
  # (`Tokens.override_slots/0`): an agent's text then reads its new rail
  # colour, and the focus ring its new accent / interactive, as in the
  # masters' editor; the ledger measures that.
  defp drop_override(palette, "ag" <> _ = key), do: Map.delete(palette, key <> "Text")

  defp drop_override(palette, key) when key in ["accent", "interactive"],
    do: Map.delete(palette, "focusRing")

  defp drop_override(palette, _key), do: palette

  defp set_shape(socket, candidate) do
    case OrgTheme.normalise_shape(candidate) do
      {:ok, shape} ->
        socket
        |> assign(:errors, Map.delete(socket.assigns.errors, :shape))
        |> update_work(&Map.put(&1, :shape, shape))
        |> preview()

      {:error, why} ->
        assign(socket, :errors, Map.put(socket.assigns.errors, :shape, why))
    end
  end

  defp preview(socket) do
    theme = measured(socket.assigns)
    modes = if socket.assigns.both?, do: @modes, else: [socket.assigns.pv_mode]

    socket =
      assign(socket, :wrapper_style, Tokens.declarations(theme, wrapper_mode(socket.assigns)))

    Enum.reduce(modes, socket, fn mode, acc ->
      push_event(acc, "theme-preview", %{vars: preview_vars(theme, mode), mode: mode})
    end)
  end

  # ── writes ──────────────────────────────────────────────────────────────

  defp actor(socket), do: socket.assigns[:current_user_record]

  defp draft_attrs(work, name) do
    %{
      "name" => name,
      "default_mode" => work.default_mode,
      "light" => work.light,
      "dark" => work.dark,
      "shape" => work.shape
    }
  end

  # Only the theme's own fields are taken; the changeset refuses anything
  # unknown inside them. No key becomes an atom.
  defp import_attrs(decoded), do: Map.take(decoded, ~w(name default_mode light dark shape))

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, "expected an object"}
      {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
    end
  end

  defp current_theme(%{assigns: %{work: %{theme: %OrgTheme{} = theme}}}), do: {:ok, theme}
  defp current_theme(_), do: {:error, "Presets can't be changed"}

  defp saved(socket, theme) do
    socket
    |> assign(modal: nil, modal_error: nil)
    |> load_library()
    |> load_work(org_work(theme))
  end

  defp do_apply(socket) do
    actor = actor(socket)
    work = socket.assigns.work

    saved =
      if socket.assigns.dirty?,
        do: Theming.update_draft(actor, work.theme, draft_attrs(work, work.name)),
        else: {:ok, work.theme}

    with {:ok, theme} <- saved,
         {:ok, published} <- Theming.publish(actor, theme) do
      org = org_name(socket.assigns.orgs, published.org_id)

      socket =
        socket
        |> assign(modal: nil, modal_error: nil)
        |> load_library()
        |> load_work(org_work(published))

      {:noreply,
       toast(socket, "Applied · members of #{org} can choose #{published.name} in Appearance")}
    else
      {:error, reason} -> {:noreply, assign(socket, :modal_error, describe(reason))}
    end
  end

  defp load_library(socket) do
    themes =
      Enum.flat_map(socket.assigns.orgs, fn org ->
        case Theming.list_org_themes(actor(socket), org.id) do
          {:ok, themes} -> themes
          {:error, _} -> []
        end
      end)

    assign(socket, :org_themes, themes)
  end

  defp toast(socket, text) do
    n = socket.assigns.toast_n + 1
    if connected?(socket), do: Process.send_after(self(), {:clear_toast, n}, @toast_ms)
    assign(socket, toast: text, toast_n: n)
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(inspect_value(v)))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp describe({:contrast, rows}) do
    by_mode = Enum.frequencies_by(rows, & &1.mode)
    below_aa(Enum.map(@modes, &{&1, Map.get(by_mode, &1, 0)}))
  end

  defp describe(:unauthorized), do: "Only a root admin can change themes"
  defp describe(:not_found), do: "That theme no longer exists"
  defp describe(:published), do: "A published theme can't be edited; Save as… first"
  defp describe(text) when is_binary(text), do: text
  defp describe(other), do: inspect(other)

  defp inspect_value(v) when is_binary(v) or is_number(v) or is_atom(v), do: v
  defp inspect_value(v), do: inspect(v)

  # ── view helpers ────────────────────────────────────────────────────────

  @doc """
  Why Apply is disabled, or nil when it is not: a preset (or a published
  theme with edits, which `update_draft/3` refuses) needs a Save as… first;
  otherwise any failing ledger row, in either mode, blocks it, and the
  reason names the mode(s) it fails in: "3 pairs below AA (light)", or
  "5 pairs below AA (dark 2 · light 3)".
  """
  def apply_block(%{work: work, dirty?: dirty?, ledgers: ledgers}) do
    counts = fail_counts(ledgers)

    cond do
      work.builtin? -> "Save as… first"
      work.status == "published" and dirty? -> "Save as… first"
      Enum.any?(counts, fn {_mode, n} -> n > 0 end) -> below_aa(counts)
      true -> nil
    end
  end

  # `[{mode, failing rows}]` in `@modes` order.
  defp fail_counts(ledgers),
    do: for(mode <- @modes, do: {mode, Enum.count(Map.fetch!(ledgers, mode), &(not &1.pass?))})

  defp below_aa(counts) do
    failing = for {mode, n} <- counts, n > 0, do: {mode, n}
    total = failing |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    where =
      case failing do
        [{mode, _}] -> mode
        many -> Enum.map_join(many, " · ", fn {mode, n} -> "#{mode} #{n}" end)
      end

    "#{total} pairs below AA (#{where})"
  end

  defp other_mode("dark"), do: "light"
  defp other_mode("light"), do: "dark"

  defp org_name(orgs, id) do
    case Enum.find(orgs, &(&1.id == id)) do
      nil -> "this org"
      org -> org.name
    end
  end

  defp work_org_name(assigns),
    do: org_name(assigns.orgs, assigns.work.org_id || assigns.root_org.id)

  defp swatch_style(colors), do: "background:#{colors}"

  # "dark" / "light" to the field holding that palette; no atom is minted.
  defp palette_field("light"), do: :light
  defp palette_field("dark"), do: :dark

  defp palette(theme, mode), do: Map.fetch!(theme, palette_field(mode))

  defp chip_swatches(theme, mode) do
    palette = palette(theme, mode)
    [palette["ground"], palette["accent"], palette["agTeal"]]
  end

  # `[{masters label, ledger row}]` for one group's contrast block.
  defp group_contrast(ledgers, mode, group_id) do
    rows = Map.fetch!(ledgers, mode)

    for {label, ledger_label} <- contrast_rows(group_id),
        row = Enum.find(rows, &(&1.label == ledger_label)),
        not is_nil(row),
        do: {label, row}
  end

  defp dot_class("AA"), do: "bg-success"
  defp dot_class("AA large"), do: "bg-warning"
  defp dot_class(_), do: "bg-error"

  defp shape_sliders(shape) do
    [
      {"radius", "Radius", "--radius-box · --radius-field", 4, 28, 1, "#{shape["radius"]}px"},
      {"density", "Density", "--density · spacing and row heights", 0.8, 1.3, 0.05,
       "#{shape["density"]}×"},
      {"glass_alpha", "Glass alpha", "--glass-alpha · surface at alpha",
       OrgTheme.glass_alpha_floor(), 1, 0.01, "#{shape["glass_alpha"]}"},
      {"glass_blur", "Glass blur", "--glass-blur", 0, 40, 1, "#{shape["glass_blur"]}px"}
    ]
  end

  defp font_chips, do: Enum.zip([Enum.with_index(Tokens.font_chips()), @font_labels])

  # ── render ──────────────────────────────────────────────────────────────

  @ghost "inline-flex h-[30px] shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-edge bg-base-100 px-[11px] text-xs text-base-content focus-visible-ring lg:hover:bg-base-300 aria-pressed:border-transparent aria-pressed:bg-base-300 disabled:cursor-not-allowed disabled:text-subtle lg:hover:disabled:bg-base-100"

  @primary "inline-flex h-[30px] shrink-0 items-center gap-1.5 rounded-full bg-primary px-[13px] text-xs font-semibold text-primary-content focus-visible-ring"

  defp ghost, do: @ghost
  defp primary, do: @primary

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:block, apply_block(assigns))
      |> assign(:summary_rows, Map.fetch!(assigns.ledgers, assigns.ed_mode))
      |> assign(:fails, Enum.count(Map.fetch!(assigns.ledgers, assigns.ed_mode), &(not &1.pass?)))
      |> assign(:other_mode, other_mode(assigns.ed_mode))
      |> assign(
        :other_fails,
        Enum.count(Map.fetch!(assigns.ledgers, other_mode(assigns.ed_mode)), &(not &1.pass?))
      )
      |> assign(:palette, palette(assigns.work, assigns.ed_mode))
      |> assign(:frame_modes, if(assigns.both?, do: ["dark", "light"], else: [assigns.pv_mode]))

    ~H"""
    <div
      id="theme-editor"
      data-role="theme-editor"
      data-theme={wrapper_mode(assigns)}
      data-theme-preview
      style={@wrapper_style}
      class="flex h-dvh flex-col overflow-hidden bg-base-200 font-sans text-sm text-base-content"
      phx-window-keydown="close_modal"
      phx-key="Escape"
    >
      <header
        class="flex h-14 shrink-0 items-center gap-2 border-b border-edge bg-base-100 px-4"
        data-role="theme-top"
      >
        <.link navigate={~p"/admin"} class="shrink-0 rounded focus-visible-ring" aria-label="Admin">
          <%!-- Picked by the wrapper's mode, not the dark: variant: <html>
               carries the viewer's own data-theme, which would match too. --%>
          <img
            src={
              if wrapper_mode(assigns) == "dark",
                do: ~p"/images/burrow-lockup.svg",
                else: ~p"/images/burrow-lockup-darktext.svg"
            }
            alt="Burrow"
            class="block h-[22px]"
          />
        </.link>
        <h1 class="ml-1 mr-3 whitespace-nowrap text-base font-semibold">Theme admin</h1>
        <div class="flex min-w-0 items-center gap-1.5 overflow-x-auto" data-role="theme-library">
          <button
            :for={preset <- @presets}
            type="button"
            class={chip_class()}
            phx-click="load"
            phx-value-id={"preset:" <> preset.id}
            aria-pressed={to_string(@work.key == "preset:" <> preset.id)}
            title="preset"
            data-role="theme-chip"
          >
            <.swatches colors={chip_swatches(preset, @pv_mode)} />{preset.name}
          </button>
          <button
            :for={theme <- @org_themes}
            type="button"
            class={chip_class()}
            phx-click="load"
            phx-value-id={"org:" <> theme.id}
            aria-pressed={to_string(@work.key == "org:" <> theme.id)}
            title={"#{org_name(@orgs, theme.org_id)} · #{theme.status}"}
            data-role="theme-chip"
          >
            <.swatches colors={chip_swatches(theme, @pv_mode)} />{theme.name}
          </button>
        </div>
        <span :if={@dirty?} class="shrink-0 text-xs text-subtle" data-role="theme-dirty">
          unsaved edits
        </span>
        <span class="flex-1"></span>
        <span
          :if={@block}
          class="shrink-0 whitespace-nowrap text-xs text-subtle"
          data-role="theme-apply-reason"
        >
          {@block}
        </span>
        <button
          type="button"
          class={ghost()}
          phx-click="open"
          phx-value-modal="apply"
          disabled={not is_nil(@block)}
          data-role="theme-apply"
        >
          Apply
        </button>
        <button type="button" class={ghost()} phx-click="open" phx-value-modal="save_as">
          Save as…
        </button>
        <button
          type="button"
          class={ghost()}
          phx-click="open"
          phx-value-modal="rename"
          disabled={@work.builtin?}
          data-role="theme-rename"
        >
          Rename
        </button>
        <button type="button" class={ghost()} phx-click="duplicate" data-role="theme-duplicate">
          Duplicate
        </button>
        <button
          type="button"
          class={ghost()}
          phx-click="open"
          phx-value-modal="delete"
          disabled={@work.builtin?}
          data-role="theme-delete"
        >
          <.icon name="hero-trash" class="size-3.5 text-error" /> Delete
        </button>
        <button type="button" class={ghost()} phx-click="open" phx-value-modal="export">
          Export JSON
        </button>
        <button type="button" class={ghost()} phx-click="open" phx-value-modal="import">
          Import JSON
        </button>
        <button type="button" class={ghost()} phx-click="reset" data-role="theme-reset">
          Reset to Burrow dark
        </button>
      </header>

      <div class="grid min-h-0 flex-1 grid-cols-[380px_1fr] max-[1100px]:grid-cols-[320px_1fr]">
        <aside
          class="overflow-y-auto border-r border-edge bg-base-100 px-3.5 pb-16 pt-3"
          data-role="theme-controls"
        >
          <div
            class="mb-2.5 mt-1 flex flex-wrap gap-1.5 text-xs text-subtle"
            data-role="theme-summary"
          >
            <span>
              <b class="text-base-content">{@work.name}</b>{if @work.builtin?,
                do: " · preset",
                else: " · yours"}
            </span>
            <span>default <b class="text-base-content">{@work.default_mode}</b></span>
            <span>
              {Enum.count(@summary_rows, & &1.pass?)}/{length(@summary_rows)} AA pass ({@ed_mode})
            </span>
            <span :if={@fails > 0} class="inline-flex items-center gap-1 text-base-content">
              <span class="size-2 rounded-full bg-error" aria-hidden="true"></span>{@fails} fail
            </span>
            <span :if={@fails == 0} class="inline-flex items-center gap-1 text-base-content">
              <span class="size-2 rounded-full bg-success" aria-hidden="true"></span>all pass
            </span>
            <span
              :if={@other_fails > 0}
              class="inline-flex items-center gap-1 text-base-content"
              data-role="theme-summary-other"
            >
              · {@other_mode}: {@other_fails} fail
            </span>
          </div>

          <div class="mb-2.5 flex items-center gap-1.5 text-xs text-subtle">
            Editing variant:
            <button
              :for={mode <- ["dark", "light"]}
              type="button"
              class={ghost()}
              phx-click="ed_mode"
              phx-value-mode={mode}
              aria-pressed={to_string(@ed_mode == mode)}
            >
              {String.capitalize(mode)}
            </button>
            <span class="flex-1"></span>
            Default mode:
            <button
              type="button"
              class={ghost()}
              phx-click="default_mode"
              data-role="theme-default-mode"
            >
              {@work.default_mode}
            </button>
          </div>

          <details
            :for={group <- groups()}
            open
            class="mb-2 rounded-xl border border-edge bg-base-200"
            data-group={group.id}
          >
            <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 font-semibold">
              {group.label}<small class="text-xs font-normal text-subtle">{length(group.keys)} tokens</small>
            </summary>
            <div class="flex flex-col gap-1.5 px-3 pb-2.5 pt-1">
              <form
                :for={{key, label, desc} <- group.keys}
                id={"tok-#{@ed_mode}-#{key}"}
                class="grid grid-cols-[1fr_34px_92px] items-center gap-2 text-xs"
                phx-change="token"
                phx-submit="token"
                data-role="theme-token"
                data-key={key}
              >
                <input type="hidden" name="key" value={key} />
                <label for={"tok-#{key}-text"} class="flex min-w-0 flex-col">
                  {label}
                  <small class="truncate text-xs text-subtle">{kebab(key)} · {desc}</small>
                </label>
                <input
                  type="color"
                  name="pick"
                  value={@palette[key]}
                  aria-label={"#{label} colour"}
                  phx-debounce="60"
                  class="h-[26px] w-[34px] cursor-pointer rounded-md border border-edge bg-transparent p-0 focus-visible-ring"
                />
                <input
                  id={"tok-#{key}-text"}
                  type="text"
                  name="value"
                  value={@palette[key]}
                  phx-debounce="blur"
                  spellcheck="false"
                  aria-invalid={to_string(Map.has_key?(@errors, {@ed_mode, key}))}
                  class="h-[26px] min-w-0 rounded-md border border-edge bg-base-100 px-2 font-mono text-xs text-base-content outline-none focus:border-focus-ring aria-[invalid=true]:border-error"
                />
                <p
                  :if={Map.has_key?(@errors, {@ed_mode, key})}
                  class="col-span-3 flex items-center gap-1 text-xs text-base-content"
                  data-role="theme-token-error"
                >
                  <span class="size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>{@errors[
                    {@ed_mode, key}
                  ]}
                </p>
              </form>
              <div
                :if={contrast_rows(group.id) != []}
                class="mt-1 flex flex-col gap-0.5 text-xs text-subtle"
                data-contrast={group.id}
              >
                <b class="text-base-content">Contrast · {@ed_mode}</b>
                <div
                  :for={{label, row} <- group_contrast(@ledgers, @ed_mode, group.id)}
                  class="flex items-center justify-between gap-2"
                  data-role="theme-contrast-row"
                  data-verdict={verdict(row.ratio)}
                >
                  <span class="flex items-center">
                    <i
                      class="mr-1 inline-block size-3.5 rounded-[3px] border border-edge"
                      style={swatch_style(row.bg)}
                    >
                    </i>
                    <i
                      class="mr-1.5 inline-block size-3.5 rounded-[3px] border border-edge"
                      style={swatch_style(row.fg)}
                    >
                    </i>
                    {label}
                  </span>
                  <span class="flex items-center gap-1.5 font-mono">
                    {format_ratio(row.ratio)}
                    <span
                      class={["size-2 rounded-full", dot_class(verdict(row.ratio))]}
                      aria-hidden="true"
                    >
                    </span>
                    <span class="font-sans font-semibold text-base-content">
                      {verdict(row.ratio)}
                    </span>
                  </span>
                </div>
              </div>
            </div>
          </details>

          <details open class="mb-2 rounded-xl border border-edge bg-base-200" data-group="shape">
            <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 font-semibold">
              Shape · Density · Type · Glass<small class="text-xs font-normal text-subtle">mode-independent</small>
            </summary>
            <form
              id="theme-shape"
              class="flex flex-col gap-1.5 px-3 pb-2.5 pt-1"
              phx-change="shape"
              phx-submit="shape"
            >
              <div
                :for={{key, label, desc, min, max, step, out} <- shape_sliders(@work.shape)}
                class="grid grid-cols-[1fr_60px] items-center gap-2 text-xs"
              >
                <label class="flex flex-col">
                  {label}<small class="text-xs text-subtle">{desc}</small>
                  <input
                    type="range"
                    name={key}
                    min={min}
                    max={max}
                    step={step}
                    value={@work.shape[key]}
                    class="w-full accent-primary focus-visible-ring"
                  />
                </label>
                <output class="text-right font-mono text-xs text-subtle">{out}</output>
              </div>
              <label class="flex flex-col text-xs">
                Font family<small class="text-xs text-subtle">--font-sans</small>
                <input
                  type="text"
                  name="font"
                  value={@work.shape["font"]}
                  phx-debounce="blur"
                  class="h-7 w-full rounded-md border border-edge bg-base-100 px-2 font-mono text-xs text-base-content outline-none focus:border-focus-ring"
                />
              </label>
              <p
                :if={@errors[:shape]}
                class="flex items-center gap-1 text-xs text-base-content"
                data-role="theme-shape-error"
              >
                <span class="size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>{@errors[
                  :shape
                ]}
              </p>
            </form>
            <div class="flex flex-wrap gap-1.5 px-3 pb-3">
              <button
                :for={{{stack, i}, label} <- font_chips()}
                type="button"
                class={chip_class()}
                phx-click="font_chip"
                phx-value-index={i}
                aria-pressed={to_string(@work.shape["font"] == stack)}
              >
                {label}
              </button>
            </div>
          </details>
        </aside>

        <main
          id="theme-preview-pane"
          class="flex flex-col gap-[18px] overflow-auto bg-base-200 p-[18px]"
          phx-hook="ThemeEditor"
          data-role="theme-preview"
        >
          <div class="flex items-center gap-1.5 text-xs text-subtle">
            Preview:
            <button
              :for={{mode, label} <- [{"dark", "Dark"}, {"light", "Light"}, {"both", "Side by side"}]}
              type="button"
              class={ghost()}
              phx-click="pv_mode"
              phx-value-mode={mode}
              aria-pressed={
                to_string(if mode == "both", do: @both?, else: not @both? and @pv_mode == mode)
              }
            >
              {label}
            </button>
            <span class="flex-1"></span>
            <button type="button" class={ghost()} phx-click="reload_frames">Reload frames</button>
          </div>
          <div class="flex flex-col gap-[18px]">
            <div :for={mode <- @frame_modes} class="flex flex-wrap items-start gap-[18px]">
              <div class="shrink-0">
                <div class="mb-1.5 flex items-center justify-between text-xs text-subtle">
                  <span>mobile · {mode} · 375×812</span>
                  <a
                    href={~p"/chat"}
                    {Platform.Chat.LinkTargets.open_attrs(~p"/chat")}
                    class="text-base-content underline"
                  >
                    open ↗
                  </a>
                </div>
                <div class="h-[812px] w-[375px] overflow-hidden rounded-[44px] bg-base-200 ring-8 ring-base-300">
                  <iframe
                    id={"theme-frame-mobile-#{mode}-#{@reload}"}
                    data-mode={mode}
                    src={"/chat?theme_preview=1&r=#{@reload}"}
                    title={"mobile #{mode}"}
                    class="block h-[812px] w-[375px] border-0"
                  >
                  </iframe>
                </div>
              </div>
              <div class="shrink-0">
                <div class="mb-1.5 flex items-center justify-between text-xs text-subtle">
                  <span>desktop · {mode} · 1280×800 scaled</span>
                  <a
                    href={~p"/chat"}
                    {Platform.Chat.LinkTargets.open_attrs(~p"/chat")}
                    class="text-base-content underline"
                  >
                    open ↗
                  </a>
                </div>
                <div class="h-[calc(800px*var(--theme-desk-scale,0.36))] w-[calc(1280px*var(--theme-desk-scale,0.36))] overflow-hidden rounded-xl border border-edge bg-base-200">
                  <iframe
                    id={"theme-frame-desktop-#{mode}-#{@reload}"}
                    data-mode={mode}
                    src={"/chat?theme_preview=1&r=#{@reload}"}
                    title={"desktop #{mode}"}
                    class="block h-[800px] w-[1280px] origin-top-left border-0 [transform:scale(var(--theme-desk-scale,0.36))]"
                  >
                  </iframe>
                </div>
              </div>
            </div>
          </div>
        </main>
      </div>

      <.modal
        :if={@modal}
        modal={@modal}
        work={@work}
        orgs={@orgs}
        root_org={@root_org}
        error={@modal_error}
        org_name={work_org_name(assigns)}
      />

      <div
        :if={@toast}
        id={"theme-toast-#{@toast_n}"}
        role="status"
        class="pointer-events-none fixed bottom-[22px] left-1/2 z-10 -translate-x-1/2 whitespace-nowrap rounded-full border border-edge bg-base-300 px-3.5 py-1.5 text-xs text-base-content"
        data-role="theme-toast"
      >
        {@toast}
      </div>
    </div>
    """
  end

  defp chip_class,
    do:
      "inline-flex h-7 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-edge bg-base-100 px-2.5 text-xs text-base-content focus-visible-ring lg:hover:bg-base-300 aria-pressed:border-primary aria-pressed:ring-1 aria-pressed:ring-primary"

  attr(:colors, :list, required: true)

  defp swatches(assigns) do
    ~H"""
    <i
      :for={color <- @colors}
      class="inline-flex size-3 rounded-[3px] border border-edge"
      style={swatch_style(color)}
      aria-hidden="true"
    >
    </i>
    """
  end

  attr(:modal, :string, required: true)
  attr(:work, :map, required: true)
  attr(:orgs, :list, required: true)
  attr(:root_org, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:org_name, :string, required: true)

  defp modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-20 flex items-center justify-center bg-scrim"
      data-role="theme-modal-scrim"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="theme-modal-title"
        class="w-[520px] max-w-[92vw] rounded-2xl border border-edge bg-base-100 p-4 text-base-content shadow-lg"
        data-role={"theme-modal-#{@modal}"}
        phx-click-away="close_modal"
      >
        <%= case @modal do %>
          <% "save_as" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">Save as…</h3>
            <form id="theme-save-as" phx-submit="save_as" class="flex flex-col gap-2">
              <input
                name="name"
                value={if @work.builtin?, do: "#{@work.name} (copy)", else: @work.name}
                aria-label="Name"
                class={modal_input()}
                phx-mounted={Phoenix.LiveView.JS.focus()}
              />
              <label class="flex items-center gap-2 text-xs text-subtle">
                Org
                <select name="org_id" class={modal_input()}>
                  <option
                    :for={org <- @orgs}
                    value={org.id}
                    selected={org.id == (@work.org_id || @root_org.id)}
                  >
                    {org.name}
                  </option>
                </select>
              </label>
              <.modal_error error={@error} />
              <.modal_actions ok="Save" />
            </form>
          <% "rename" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">Rename</h3>
            <form id="theme-rename" phx-submit="rename" class="flex flex-col gap-2">
              <input name="name" value={@work.name} aria-label="Name" class={modal_input()} />
              <.modal_error error={@error} />
              <.modal_actions ok="OK" />
            </form>
          <% "delete" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">
              Delete "{@work.name}"? Type DELETE to confirm
            </h3>
            <form id="theme-delete" phx-submit="delete" class="flex flex-col gap-2">
              <input
                name="confirm"
                value=""
                aria-label="Type DELETE to confirm"
                autocomplete="off"
                class={modal_input()}
              />
              <.modal_error error={@error} />
              <.modal_actions ok="Delete" />
            </form>
          <% "export" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">Export · {@work.name}</h3>
            <textarea readonly class={modal_textarea()} data-role="theme-export">{export_json(@work)}</textarea>
            <div class="mt-2.5 flex justify-end gap-2">
              <button type="button" class={primary()} phx-click="close_modal">Close</button>
            </div>
          <% "import" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">Import JSON</h3>
            <form id="theme-import" phx-submit="import" class="flex flex-col gap-2">
              <textarea name="json" aria-label="Theme JSON" class={modal_textarea()}></textarea>
              <.modal_actions ok="Import" />
            </form>
          <% "apply" -> %>
            <h3 id="theme-modal-title" class="mb-2.5 text-lg font-semibold">Apply {@work.name}</h3>
            <p class="text-sm" data-role="theme-apply-confirm">
              Members of {@org_name} can choose {@work.name} in Appearance.
            </p>
            <form id="theme-apply-form" phx-submit="apply" class="flex flex-col gap-2">
              <.modal_error error={@error} />
              <.modal_actions ok="Apply" />
            </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:error, :string, default: nil)

  defp modal_error(assigns) do
    ~H"""
    <p
      :if={@error}
      class="flex items-center gap-1 text-xs text-base-content"
      data-role="theme-modal-error"
    >
      <span class="size-2 shrink-0 rounded-full bg-error" aria-hidden="true"></span>{@error}
    </p>
    """
  end

  attr(:ok, :string, required: true)

  defp modal_actions(assigns) do
    ~H"""
    <div class="mt-2.5 flex justify-end gap-2">
      <button type="button" class={ghost()} phx-click="close_modal">Cancel</button>
      <button type="submit" class={primary()}>{@ok}</button>
    </div>
    """
  end

  defp modal_input,
    do:
      "h-8 w-full rounded-lg border border-edge bg-base-200 px-2.5 text-sm text-base-content outline-none focus:border-focus-ring"

  defp modal_textarea,
    do:
      "h-[280px] w-full resize-y rounded-lg border border-edge bg-base-200 p-2.5 font-mono text-xs text-base-content outline-none focus:border-focus-ring"

  defp export_json(work) do
    Jason.encode!(
      %{
        "name" => work.name,
        "default_mode" => work.default_mode,
        "light" => work.light,
        "dark" => work.dark,
        "shape" => work.shape
      },
      pretty: true
    )
  end
end

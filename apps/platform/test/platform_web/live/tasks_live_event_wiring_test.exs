defmodule PlatformWeb.TasksLiveEventWiringTest do
  @moduledoc """
  Static guard against ORPHANED events on the /tasks surface (task 01a008f6
  stage 8).

  Task 01a008f6 renamed ~129 events across eight stages with no back-compat
  aliases. A missed call site is silent — `mix test` was green while the
  sidebar's "All Projects" button pushed `clear_filters`, an event with no
  handler anywhere in `lib/`, crashing the LiveView on click. Behavioural
  tests only catch the buttons they happen to click; this walks EVERY event
  push on the surface and asserts it reaches a `handle_event/3` clause in the
  module that will actually receive it.

  ## What is checked

    * Literal `phx-click` / `phx-change` / `phx-submit` / `phx-keyup` /
      `phx-keydown` / `phx-blur` / `phx-focus` / `phx-window-keyup` /
      `phx-window-keydown` attributes in `tasks_live.html.heex` and every
      component under `live/tasks/`.
    * `data-submit-event` / `data-event` attributes (hooks such as `InlineEdit`
      read the event name from the dataset and honour the element's
      `phx-target`).
    * `JS.push("name")` composed inside attributes, including `target:`.
    * Literal `pushEvent` / `pushEventTo` calls in every JS hook referenced by
      `phx-hook` from the tasks markup. A hook's `pushEvent` IGNORES
      `phx-target` and always lands on the parent LiveView — this guard models
      that, because that landmine was live across five stages of this task.

  ## Routing model

    * no `phx-target` -> `PlatformWeb.TasksLive` (the shell). This is the rule
      the "All Projects" bug violated.
    * `phx-target={@myself}` -> the module that renders the markup.
    * `phx-target="#some-id"` -> the module mounted at that id (`@component_ids`).
      An unknown id fails: adding a live_component means updating the map.
    * hook `pushEvent(...)` -> `PlatformWeb.TasksLive`.
    * hook `pushEventTo("#id", ...)` -> `@component_ids`.

  ## What this guard does NOT cover (stated, not implied)

    * Dynamic event names: `phx-click={@event}` / `phx-click={"foo_" <> x}`.
      Only string literals are extracted.
    * Dynamic `phx-target={@target}` (a target passed in as an assign). The
      event name is still required to resolve somewhere on the surface, but not
      to a specific module — a "weak" check.
    * Dynamic hook targets (`pushEventTo(this.el.dataset.boardTarget, ...)`,
      `pushEventTo(target, ...)`). Same weak check.
    * Dynamic hook event names read from the dataset are picked up only where
      the markup spells them out in `data-submit-event` / `data-event`.
      Concretely UNCOVERED today: `ComposeInput` pushes `this.el.dataset`-derived
      event names (`data-mention-*`) that never appear as a literal in either
      the JS or the tasks markup, so its mention events are invisible to this
      guard. `InlineEdit` IS covered, because its markup carries
      `data-submit-event="detail_update_task_title"`.
    * Handler REACHABILITY only, not parameter shape: a clause that exists but
      pattern-matches params the caller never sends is not detected here.
      (`filter_clear` takes `_params`, so `%{"value" => ""}` from a bare button
      is fine.)
    * Surfaces other than /tasks.

  The weak cases are enumerated in `@weakly_checked` so the set cannot grow
  silently — a new dynamic target fails the test until it is listed and
  justified.
  """

  use ExUnit.Case, async: true

  @web_root Path.expand("../../../lib/platform_web", __DIR__)
  @assets_hooks Path.expand("../../../assets/js/hooks", __DIR__)

  @shell_module "PlatformWeb.TasksLive"

  # id => module rendering at that id (from tasks_live.html.heex live_components)
  @component_ids %{
    "#tasks-sidebar" => "PlatformWeb.TasksLive.SidebarComponent",
    "#tasks-filters" => "PlatformWeb.Tasks.FiltersComponent",
    "#tasks-board" => "PlatformWeb.Tasks.BoardComponent",
    "#tasks-detail" => "PlatformWeb.Tasks.TaskDetailComponent",
    "#tasks-steering" => "PlatformWeb.Tasks.SteeringComponent",
    "#tasks-merge-control" => "PlatformWeb.Tasks.MergeControlComponent",
    "#tasks-stacks" => "PlatformWeb.Tasks.StacksComponent",
    "#tasks-supersede" => "PlatformWeb.Tasks.SupersedeComponent",
    "#tasks-create" => "PlatformWeb.Tasks.TaskCreateComponent",
    "#tasks-assignees" => "PlatformWeb.Tasks.AssigneesComponent"
  }

  @event_attrs ~w(
    phx-click phx-change phx-submit phx-keyup phx-keydown phx-blur phx-focus
    phx-window-keyup phx-window-keydown data-submit-event data-event
  )

  # Pushes whose destination module cannot be derived statically. Each entry is
  # {event_name, why}. These still must resolve to SOME handler on the surface.
  @weakly_checked %{
    "board_drop" => "KanbanDragDrop pushes to this.el.dataset.boardTarget",
    "plan_approve" => "GatePanelComponent renders with phx-target={@target} (passed-in)",
    "plan_submit_reject_with_feedback" => "GatePanelComponent phx-target={@target}",
    "plan_toggle_reject_feedback" => "GatePanelComponent phx-target={@target}",
    "plan_update_reject_feedback_text" => "GatePanelComponent phx-target={@target}",
    "detail_open_deploy_target_config" => "rendered with phx-target={@target}"
  }

  describe "every event pushed from the /tasks surface has a handler" do
    test "markup-declared events resolve to a handle_event/3 clause" do
      handlers = handler_index()

      orphans =
        markup_pushes()
        |> Enum.reject(&resolves?(&1, handlers))
        |> Enum.map(&describe_orphan/1)
        |> Enum.uniq()

      assert orphans == [],
             "Orphaned events on the /tasks surface — these crash the LiveView on interaction:\n" <>
               Enum.join(orphans, "\n")
    end

    test "hook-pushed events resolve to a handle_event/3 clause" do
      handlers = handler_index()

      orphans =
        hook_pushes()
        |> Enum.reject(&resolves?(&1, handlers))
        |> Enum.map(&describe_orphan/1)
        |> Enum.uniq()

      assert orphans == [],
             "Orphaned hook-pushed events on the /tasks surface:\n" <> Enum.join(orphans, "\n")
    end

    test "the set of weakly-checked (dynamically targeted) pushes has not grown" do
      weak =
        (markup_pushes() ++ hook_pushes())
        |> Enum.filter(&(&1.owner == :unknown))
        |> Enum.map(& &1.event)
        |> Enum.uniq()
        |> Enum.sort()

      assert weak == Enum.sort(Map.keys(@weakly_checked)),
             inspect(weak) <>
               """

               A push with a dynamic target appeared (or disappeared). Dynamic targets
               can only be checked weakly — the event must exist somewhere on the
               surface, but not that it reaches the right module. Add it to
               @weakly_checked with a justification, or give it a static target.
               """
    end

    test "the guard sees a non-trivial number of events (it is not silently scanning nothing)" do
      pushes = markup_pushes()
      assert length(pushes) > 100, "expected the tasks surface to yield >100 pushes"
      assert Enum.any?(hook_pushes()), "expected hook pushes to be discovered"
    end
  end

  # --- extraction -----------------------------------------------------------

  defp template_files do
    [Path.join(@web_root, "live/tasks_live.html.heex")] ++
      Path.wildcard(Path.join(@web_root, "live/tasks/*.ex"))
  end

  defp source_module(path) do
    cond do
      String.ends_with?(path, "tasks_live.html.heex") ->
        @shell_module

      true ->
        case Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(path)) do
          [_, mod] -> mod
          _ -> nil
        end
    end
  end

  defp markup_pushes do
    Enum.flat_map(template_files(), fn path ->
      source = path |> File.read!() |> strip_comments()
      self_module = source_module(path)
      attr_pushes(path, source, self_module) ++ js_push_pushes(path, source, self_module)
    end)
  end

  # Comments are prose: stage 6's own explanatory comment quotes the retired
  # `phx-click="scope_filter"`, which is not a call site. Blank them out while
  # preserving byte offsets so reported line numbers stay accurate.
  defp strip_comments(source) do
    source
    |> blank_out(~r/<%!--.*?--%>/s)
    |> blank_out(~r/^[ \t]*#[^\n]*/m)
  end

  defp blank_out(source, regex) do
    Regex.replace(regex, source, fn match ->
      match |> String.graphemes() |> Enum.map(&if(&1 == "\n", do: "\n", else: " ")) |> Enum.join()
    end)
  end

  defp attr_pushes(path, source, self_module) do
    # `event="..."` (with a sibling `target=`) is how function components such
    # as `scope_pill/1` take their event — a real push site with no `phx-` prefix.
    pattern =
      ~r/(#{Enum.join(@event_attrs, "|")}|(?<![-\w])event)="([a-z0-9_\-]+)"/

    Regex.scan(pattern, source, return: :index)
    |> Enum.map(fn [{start, len}, _attr, {ev_start, ev_len}] ->
      event = binary_part(source, ev_start, ev_len)

      %{
        event: event,
        owner: owner_for(element_window(source, start, len), self_module),
        file: path,
        line: line_of(source, start)
      }
    end)
  end

  defp js_push_pushes(path, source, self_module) do
    ~r/JS\.push\(\s*"([a-z0-9_\-]+)"([^)]*)\)/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, len}, {ev_start, ev_len}, {opt_start, opt_len}] ->
      event = binary_part(source, ev_start, ev_len)
      opts = binary_part(source, opt_start, opt_len)

      owner =
        case Regex.run(~r/target:\s*(?:"([^"]+)"|@myself)/, opts) do
          [_, id] -> Map.get(@component_ids, id, :bad_id)
          [_] -> self_module
          nil -> owner_for(element_window(source, start, len), self_module)
        end

      %{event: event, owner: owner, file: path, line: line_of(source, start)}
    end)
  end

  # The opening tag an attribute belongs to: from the "<" preceding it up to the
  # next "<". Attribute values never contain "<" in this codebase, so this is a
  # stable window without a full HEEx parse.
  defp element_window(source, start, len) do
    before = binary_part(source, 0, start)
    tag_start = last_index_of(before, "<") || 0
    rest_start = start + len
    rest = binary_part(source, rest_start, byte_size(source) - rest_start)
    tail = List.first(String.split(rest, "<")) || ""
    binary_part(source, tag_start, start - tag_start) <> binary_part(source, start, len) <> tail
  end

  defp owner_for(window, self_module) do
    cond do
      Regex.match?(~r/(?<![-\w])(phx-)?target=\{@myself\}/, window) ->
        self_module

      match = Regex.run(~r/(?<![-\w])(?:phx-)?target="([^"]+)"/, window) ->
        Map.get(@component_ids, Enum.at(match, 1), :bad_id)

      Regex.match?(~r/(?<![-\w])(phx-)?target=\{/, window) ->
        :unknown

      true ->
        # No phx-target: the push lands on the shell LiveView, whatever module
        # rendered the markup. This is the "All Projects" bug in one line.
        @shell_module
    end
  end

  # --- hooks ----------------------------------------------------------------

  defp tasks_hook_names do
    template_files()
    |> Enum.flat_map(fn path ->
      ~r/phx-hook="([A-Za-z0-9_]+)"/
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, name] -> name end)
    end)
    |> Enum.uniq()
  end

  defp hook_file(hook_name) do
    snake =
      hook_name
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()

    path = Path.join(@assets_hooks, snake <> ".js")
    if File.exists?(path), do: path, else: nil
  end

  defp hook_pushes do
    tasks_hook_names()
    |> Enum.map(&hook_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      # Static target: pushEventTo("#tasks-filters", "filter_clear", ...)
      static_targeted =
        ~r/pushEventTo\(\s*"([^"]+)"\s*,\s*"([a-z0-9_\-]+)"/
        |> Regex.scan(source, return: :index)
        |> Enum.map(fn [{start, _}, {i_start, i_len}, {e_start, e_len}] ->
          %{
            event: binary_part(source, e_start, e_len),
            owner: Map.get(@component_ids, binary_part(source, i_start, i_len), :bad_id),
            file: path,
            line: line_of(source, start)
          }
        end)

      # Dynamic target: pushEventTo(this.el.dataset.boardTarget, "board_drop", ...)
      dynamic_targeted =
        ~r/pushEventTo\(\s*[^"\s][^,]*,\s*"([a-z0-9_\-]+)"/
        |> Regex.scan(source, return: :index)
        |> Enum.map(fn [{start, _}, {e_start, e_len}] ->
          %{
            event: binary_part(source, e_start, e_len),
            owner: :unknown,
            file: path,
            line: line_of(source, start)
          }
        end)

      # A hook's pushEvent ALWAYS lands on the parent LiveView, ignoring
      # phx-target. That is the landmine this project kept stepping on.
      untargeted =
        ~r/(?<!To)\bpushEvent\(\s*"([a-z0-9_\-]+)"/
        |> Regex.scan(source, return: :index)
        |> Enum.map(fn [{start, _}, {e_start, e_len}] ->
          %{
            event: binary_part(source, e_start, e_len),
            owner: @shell_module,
            file: path,
            line: line_of(source, start)
          }
        end)

      targeted = static_targeted ++ dynamic_targeted

      targeted ++ untargeted
    end)
  end

  # --- handler index --------------------------------------------------------

  defp handler_index do
    files = [Path.join(@web_root, "live/tasks_live.ex")] ++ template_files()

    files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reduce(%{}, fn path, acc ->
      source = File.read!(path)
      mod = source_module(path)

      events =
        ~r/def handle_event\(\s*"([a-z0-9_\-]+)"/
        |> Regex.scan(source)
        |> Enum.map(fn [_, ev] -> ev end)
        |> MapSet.new()

      Map.update(acc, mod, events, &MapSet.union(&1, events))
    end)
  end

  defp resolves?(%{owner: :unknown, event: event}, handlers) do
    Enum.any?(handlers, fn {_mod, evs} -> MapSet.member?(evs, event) end)
  end

  defp resolves?(%{owner: :bad_id}, _handlers), do: false

  defp resolves?(%{owner: owner, event: event}, handlers) do
    handlers |> Map.get(owner, MapSet.new()) |> MapSet.member?(event)
  end

  defp describe_orphan(%{event: event, owner: owner, file: file, line: line}) do
    where = if line > 0, do: "#{relative(file)}:#{line}", else: relative(file)

    target =
      case owner do
        :bad_id -> "phx-target points at an id with no live_component (see @component_ids)"
        :unknown -> "dynamic target — no handler for this event anywhere on the surface"
        mod -> "expected #{mod}.handle_event/3"
      end

    "  #{where} — \"#{event}\": #{target}"
  end

  defp relative(path), do: String.replace(path, Path.expand("../../..", __DIR__) <> "/", "")

  defp line_of(source, index) do
    source |> binary_part(0, index) |> :binary.matches("\n") |> length() |> Kernel.+(1)
  end

  defp last_index_of(binary, needle) do
    case :binary.matches(binary, needle) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end

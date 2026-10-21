defmodule PlatformWeb.InboxLive.BriefingCopy do
  @moduledoc """
  Every word the briefing detail shows, as pure functions of the read model
  `Platform.Memory.Insights.Briefings.view/2` returns (task 01a15ee1
  stage 5). `PlatformWeb.InboxLive.BriefingComponent` only paints what
  these return; a later list renderer (the shared Inbox list) can call them
  as they are.

  Nothing here reads the database or the socket. Links are paths, never
  rendered markup. The copy follows the stage 5 fidelity inventory
  (prototype 01a15ec9 v1 and direction canvas 01a15ee2 rev 2) verbatim,
  with three glyph substitutions under the Heroicons-only rule: the
  prototype's sun and reroute arrow are hero icons (`:icon` below), so the
  strings here carry only the words. The check mark is a plain text glyph,
  not an emoji, and stays in the words.

  ## Shapes

    * `header/2` — `%{title, meta}`.
    * `progress/1` — `%{handled, total, label}`.
    * `section_heading/2` — `"Needs your call · 3"`.
    * `kind_tag/1` — `%{label, class}` (the tag's fill slot).
    * `receipt/1` — `%{icon, verb, rest, link, inverses}`; `link` is
      `{label, path}` or nil, `inverses` a list of `%{action, label, tone}`
      in the order they are shown (`action` is `:undo`, `:revert`,
      `:delete` or `:move`; `tone` is `:error` for Delete, else `:link`).
    * `toast/2` — `%{message, undo?}` for a verb that just succeeded.
    * `error_text/2` — the line under a card's buttons when an action
      failed; the card stays where it is.
    * `settings_note/2` — `%{lead, flags}`.
  """

  alias Platform.Memory.Insight

  @doc """
  The detail header. `title` is the row's title ("Today's briefing", or
  "Briefing · Mon, Oct 20" for an earlier day); `meta` is the date line.
  """
  @spec header(Date.t(), Date.t()) :: %{title: String.t(), meta: String.t()}
  def header(%Date{} = date, %Date{} = today) do
    %{
      title: PlatformWeb.Components.BriefingRow.title(date, today),
      meta: short_date(date) <> " · prepared from yesterday's journals and chat"
    }
  end

  @doc ~S|"Tue, Oct 21".|
  @spec short_date(Date.t()) :: String.t()
  def short_date(%Date{} = date), do: Calendar.strftime(date, "%a, %b %-d")

  @doc """
  The progress line: `"<n> of <M> handled"`, plus `" · you're clear for
  today"` once nothing is open. The bar beside it is decorative.
  """
  @spec progress(map()) :: %{handled: integer(), total: integer(), label: String.t()}
  def progress(%{total: total, open: open} = counts) do
    handled = Map.get(counts, :handled, total - open)
    clear = if total > 0 and open == 0, do: " · you're clear for today", else: ""
    %{handled: handled, total: total, label: "#{handled} of #{total} handled" <> clear}
  end

  @doc "A section heading with its count."
  @spec section_heading(:needs_call | :fyi | :done, non_neg_integer()) :: String.t()
  def section_heading(:needs_call, n), do: "Needs your call · #{n}"
  def section_heading(:fyi, n), do: "For your information · #{n}"
  def section_heading(:done, n), do: "Done today · #{n}"

  @doc """
  The kind tag: its word and its fill. Tag text is always `base-content`.
  """
  @spec kind_tag(atom()) :: %{label: String.t(), class: String.t()}
  def kind_tag(:question), do: %{label: "Question", class: "bg-warning-dim"}
  def kind_tag(:page_edit), do: %{label: "Page edit", class: "bg-info-dim"}
  def kind_tag(:task), do: %{label: "Task", class: "bg-success-dim"}
  def kind_tag(:outside), do: %{label: "Email draft", class: "bg-base-300"}
  def kind_tag(_briefing), do: %{label: "FYI", class: "bg-base-300"}

  @doc """
  An insight's text as a title and the rest: the first sentence is the
  title, anything after it is the body (nil when there is none).
  """
  @spec title_and_body(Insight.t() | nil) :: {String.t(), String.t() | nil}
  def title_and_body(%{} = insight) do
    text = PlatformWeb.OrgMemoryLive.InsightPreview.sentence(insight)

    case Regex.run(~r/^(.+?[.?!])\s+(\S.*)$/s, text) do
      [_, title, rest] -> {title, rest}
      _ -> {text, nil}
    end
  end

  def title_and_body(_insight), do: {"", nil}

  @doc """
  The evidence the disclosure lists: the insight's `evidence` split on
  `;`, then its `source_ref`.
  """
  @spec evidence(Insight.t() | nil) :: [String.t()]
  def evidence(%{} = insight) do
    split =
      case Map.get(insight, :evidence) do
        text when is_binary(text) -> String.split(text, ";", trim: true)
        _ -> []
      end

    source = Map.get(insight, :source_ref)

    (split ++ List.wrap(if is_binary(source) and source != "", do: "source: " <> source))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def evidence(_insight), do: []

  @doc ~S|"Dreaming · high confidence", or "Dreaming" with no confidence.|
  @spec from_line(Insight.t() | nil) :: String.t()
  def from_line(%{confidence: c}) when is_binary(c) and c != "", do: "Dreaming · #{c} confidence"
  def from_line(_insight), do: "Dreaming"

  @doc "The outside-message card's address line."
  @spec outside_to(String.t() | nil) :: String.t()
  def outside_to(email) when is_binary(email), do: "To: #{email} (outside your org)"
  def outside_to(_email), do: "To: someone outside your org"

  @doc "What the outside card says when nothing was drafted."
  @spec mail_off() :: String.t()
  def mail_off, do: "Email wasn't set up yet, so nothing was drafted or sent."

  @doc "The path an outside message's draft opens at."
  @spec draft_path(map() | nil) :: String.t() | nil
  def draft_path(%{id: id}) when is_binary(id), do: "/email/drafts/" <> id
  def draft_path(_draft), do: nil

  # ── Receipts ──────────────────────────────────────────────────────────

  @doc """
  The receipt line of a Done today item and its way back. `item` is one
  item of `Briefings.view/2`'s `done` list.
  """
  @spec receipt(map()) :: map()
  def receipt(%{receipt: %{} = receipt} = item) do
    {icon, verb, rest, link} = line(item.kind, receipt, item)
    %{icon: icon, verb: verb, rest: rest, link: link, inverses: inverses(item)}
  end

  def receipt(_item), do: nil

  defp line(kind, %{verb: verb} = r, item)
       when kind == :page_edit and verb in ["apply", "edit_apply", "applied"] do
    path = r.detail[:path]
    version = r.detail[:version]
    rest = " · " <> (path || "the page") <> if(version, do: " v#{version}", else: "")
    {:check, "✓ Applied", rest, page_link(path, item)}
  end

  defp line(:task, %{verb: verb} = r, item) when verb in ["apply", "file", "filed", "move"] do
    project = (item.project && item.project.name) || "a project"
    {:check, "✓ Task filed", " in " <> project, task_link(r.detail[:task_id])}
  end

  defp line(_kind, %{verb: "answer"} = r, _item),
    do: {:check, "✓ Answered", " · saved to org memory", journal_link(r.at)}

  defp line(_kind, %{verb: "reroute"} = r, _item),
    do:
      {:reroute, "Sent to " <> (r.detail[:name] || "someone else"),
       " · it'll be in their briefing", nil}

  defp line(_kind, %{verb: "got_it"}, _item), do: {:check, "✓ Seen", "", nil}
  defp line(_kind, %{verb: "dismiss"}, _item), do: {nil, "Dismissed", "", nil}

  defp line(_kind, %{verb: "not_useful"}, _item),
    do: {nil, "Marked not useful", " · dreaming will learn from it", nil}

  defp line(_kind, %{verb: "revert"} = r, _item),
    do: {:check, "✓ Reverted", path_rest(r.detail[:path]), nil}

  defp line(_kind, %{verb: "delete"}, _item), do: {:check, "✓ Task deleted", "", nil}
  defp line(_kind, _receipt, _item), do: {:check, "✓ Done", "", nil}

  defp path_rest(path) when is_binary(path), do: " · " <> path
  defp path_rest(_path), do: ""

  defp page_link(path, _item) when is_binary(path), do: {"Open page", "/org_memory/" <> path}
  defp page_link(_path, _item), do: nil

  defp task_link(id) when is_binary(id), do: {"Open task", "/tasks/" <> id}
  defp task_link(_id), do: nil

  # The answer is a journal entry dated the UTC day it was written.
  defp journal_link(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} ->
        {"View", "/org_memory/org/journal/#{Date.to_iso8601(DateTime.to_date(dt))}.md"}

      _ ->
        nil
    end
  end

  defp journal_link(_at), do: nil

  # The buttons on the receipt, from the view's `actions`.
  defp inverses(%{actions: actions, receipt: receipt}) do
    Enum.flat_map(actions, fn
      :undo -> [inverse_for(receipt.undo)]
      :revert -> [%{action: :revert, label: "Revert", tone: :link}]
      :delete -> [%{action: :delete, label: "Delete", tone: :error}]
      :move -> [%{action: :move, label: "Move to another project", tone: :link}]
      _ -> []
    end)
  end

  defp inverse_for(%{"verb" => "revert"}), do: %{action: :undo, label: "Revert", tone: :link}
  defp inverse_for(%{"verb" => "delete"}), do: %{action: :undo, label: "Delete", tone: :error}
  defp inverse_for(%{"verb" => "move"}), do: %{action: :undo, label: "Move back", tone: :link}

  defp inverse_for(%{"verb" => "unanswer"}),
    do: %{action: :undo, label: "Undo answer", tone: :link}

  defp inverse_for(%{"verb" => "restore"}), do: %{action: :undo, label: "Restore", tone: :link}
  defp inverse_for(_undo), do: %{action: :undo, label: "Undo", tone: :link}

  # ── Toasts and errors ─────────────────────────────────────────────────

  @doc """
  The toast for `verb` that just succeeded on `item` (the item as it was
  before the click; `project_name` / `name` come from the new receipt).
  `undo?` is false for Revert and Delete, which have no inverse.
  """
  @spec toast(String.t(), map()) :: %{message: String.t(), undo?: boolean()}
  def toast("answer", _ctx), do: %{message: "Answer sent", undo?: true}

  def toast("reroute", ctx),
    do: %{message: "Rerouted to " <> (ctx[:name] || "someone else"), undo?: ctx[:undo?] != false}

  def toast("apply", %{kind: :task} = ctx), do: toast("file", ctx)

  def toast("apply", ctx),
    do: %{message: "Edit applied to " <> (ctx[:path] || "the page"), undo?: true}

  def toast("edit_apply", _ctx), do: %{message: "Your version applied", undo?: true}

  def toast("file", ctx),
    do: %{message: "Task filed in " <> (ctx[:project_name] || "the project"), undo?: true}

  def toast("got_it", _ctx), do: %{message: "Marked as seen", undo?: true}
  def toast("dismiss", _ctx), do: %{message: "Dismissed", undo?: true}

  def toast("not_useful", _ctx),
    do: %{message: "Thanks, dreaming will learn from that", undo?: true}

  def toast("revert", _ctx), do: %{message: "Edit reverted", undo?: false}
  def toast("delete", _ctx), do: %{message: "Task deleted", undo?: false}

  def toast("move", ctx),
    do: %{message: "Task moved to " <> (ctx[:project_name] || "the project"), undo?: true}

  def toast(_verb, _ctx), do: %{message: "Done", undo?: false}

  @doc """
  The line under a card's buttons when `verb` failed with `reason`. The
  card does not move.
  """
  @spec error_text(String.t() | :undo, term()) :: String.t()
  def error_text("file", :no_project), do: "Pick a project to file this."
  def error_text("not_useful", :blank), do: "Say what made this not useful first."
  def error_text(_verb, :expired), do: "This item has expired."
  def error_text(verb, _reason), do: "Couldn't #{phrase(verb)}. Try again."

  defp phrase("answer"), do: "send the answer"
  defp phrase("reroute"), do: "reroute this"
  defp phrase(verb) when verb in ["apply", "edit_apply"], do: "apply the edit"
  defp phrase("file"), do: "file the task"
  defp phrase("got_it"), do: "mark this as seen"
  defp phrase("dismiss"), do: "dismiss this"
  defp phrase("not_useful"), do: "mark this not useful"
  defp phrase("revert"), do: "revert the edit"
  defp phrase("delete"), do: "delete the task"
  defp phrase("move"), do: "move the task"
  defp phrase(:undo), do: "undo that"
  defp phrase(_verb), do: "do that"

  # ── Foot ──────────────────────────────────────────────────────────────

  @doc "The all-caught-up line (the sun is a hero icon beside it)."
  @spec all_caught_up() :: String.t()
  def all_caught_up, do: "All caught up. Tomorrow's briefing arrives at 7:00."

  @doc """
  The settings note: the lead sentence and the live flags from
  `Platform.Memory.Insights.Settings.get/0` (✓ on, ✗ off).
  """
  @spec settings_note(map()) :: %{lead: String.t(), flags: String.t()}
  def settings_note(settings) do
    mark = fn on -> if on, do: "✓", else: "✗" end

    %{
      lead:
        "Briefings arrive in your Inbox each morning. Items you don't handle expire after 7 days.",
      flags:
        " · deliver at 7:00 · include page edits #{mark.(Map.get(settings, :apply_page_edits))}" <>
          " · tasks #{mark.(Map.get(settings, :file_tasks))}" <>
          " · questions #{mark.(Map.get(settings, :deliver_questions))}"
    }
  end
end

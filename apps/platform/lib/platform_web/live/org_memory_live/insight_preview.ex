defmodule PlatformWeb.OrgMemoryLive.InsightPreview do
  @moduledoc """
  The action preview of one insight on the Insights tab: the artefact the
  primary button will produce, rendered as that artefact (task
  `01a13867-3213-7001-a128-6b4c6b34283f` stage 5; direction canvas
  `01a14a73-9058-7000-8695-d0753117c384`, "Signature element: the action
  preview"). Replaces `ProposalBody`, which rendered a proposal body as an
  additive diff of a description.

    * `page_edit`: the real diff, removed lines on `error` and added lines
      on `success`, both at low alpha with the text staying
      `base-content`, the page path in mono and the cited source under it.
    * `question`: `to <name>` and the exact question as they will receive it.
    * `briefing`: the line as it will appear in the target's briefing.
    * `task`: the backlog title and its sponsor.

  Every value here is agent-written text and renders as escaped HEEx text,
  never as markdown or HTML.

  No fixed DOM ids: the desktop and mobile branches render into the same
  document, so everything is keyed on `data-role`.
  """

  use Phoenix.Component

  @hunk_regex ~r/<old>[\s\S]*?<\/old>\s*<new>[\s\S]*?<\/new>/

  @doc "The insight's one sentence: its body without page_edit hunk markup."
  @spec sentence(map()) :: String.t()
  def sentence(%{body: body}) when is_binary(body) do
    body
    |> String.replace(@hunk_regex, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def sentence(_insight), do: ""

  @doc "The JetBrains Mono action-type label."
  @spec type_label(String.t() | nil) :: String.t()
  def type_label("page_edit"), do: "PAGE EDIT"
  def type_label("question"), do: "QUESTION"
  def type_label("briefing"), do: "BRIEFING"
  def type_label("task"), do: "TASK"
  def type_label(_), do: "INSIGHT"

  @doc "The primary button's name: the action it performs, 'Do this' only as the fallback."
  @spec primary_label(String.t() | nil) :: String.t()
  def primary_label("page_edit"), do: "Apply edit"
  def primary_label("question"), do: "Ask"
  def primary_label("briefing"), do: "Add to briefing"
  def primary_label("task"), do: "File task"
  def primary_label(_), do: "Do this"

  @doc "The hunks of a page_edit as `[{old, new}]`; anything malformed is skipped."
  @spec hunks(map()) :: [{String.t(), String.t()}]
  def hunks(%{action: %{"hunks" => hunks}}) when is_list(hunks) do
    Enum.flat_map(hunks, fn
      %{"old" => old, "new" => new} when is_binary(old) and is_binary(new) -> [{old, new}]
      _ -> []
    end)
  end

  def hunks(_insight), do: []

  @doc "A hunk side as its lines; one trailing newline does not make an empty line."
  @spec diff_lines(String.t()) :: [String.t()]
  def diff_lines(text) when is_binary(text),
    do: text |> String.trim_trailing("\n") |> String.split("\n")

  @doc "The task title an act would file (mirrors `Actions.task_title/1`)."
  @spec task_title(map()) :: String.t()
  def task_title(%{action: action} = insight) do
    case action do
      %{"title" => title} when is_binary(title) and title != "" -> String.trim(title)
      _ -> sentence(insight)
    end
  end

  attr(:insight, :map, required: true)
  attr(:names, :map, default: %{}, doc: "user_id => display name")

  def preview(%{insight: %{action_type: "page_edit"}} = assigns) do
    assigns =
      assigns
      |> assign(:target, Map.get(assigns.insight.action || %{}, "target"))
      |> assign(:hunks, hunks(assigns.insight))
      |> assign(:source, assigns.insight.source_ref || assigns.insight.evidence)

    ~H"""
    <div
      class="mt-2 overflow-hidden rounded-lg border border-edge bg-base-100"
      data-role="insight-preview"
      data-preview-type="page_edit"
    >
      <div class="border-b border-edge px-3 py-1.5 font-mono text-xs text-base-content">
        <span data-role="insight-preview-path">{@target || "(no page named)"}</span>
      </div>
      <div class="font-mono text-xs leading-relaxed">
        <%= for {old, new} <- @hunks do %>
          <div
            :for={line <- diff_lines(old)}
            :if={String.trim(old) != ""}
            class="whitespace-pre-wrap break-words bg-error/10 px-3 text-base-content"
            data-role="insight-diff-removed"
            phx-no-format
          >- {line}</div>
          <div
            :for={line <- diff_lines(new)}
            :if={String.trim(new) != ""}
            class="whitespace-pre-wrap break-words bg-success/10 px-3 text-base-content"
            data-role="insight-diff-added"
            phx-no-format
          >+ {line}</div>
        <% end %>
      </div>
      <div
        :if={is_binary(@source) and @source != ""}
        class="border-t border-edge px-3 py-1.5 text-xs text-subtle"
        data-role="insight-preview-source"
      >
        Source: <span class="font-mono">{@source}</span>
      </div>
    </div>
    """
  end

  def preview(%{insight: %{action_type: "question"}} = assigns) do
    assigns = assign(assigns, :to, addressee_name(assigns.insight, assigns.names))

    ~H"""
    <div class="mt-2 text-sm" data-role="insight-preview" data-preview-type="question">
      <p class="text-xs text-subtle" data-role="insight-preview-to">
        to <span class="font-medium text-base-content">{@to}</span>
      </p>
      <p class="mt-1 rounded-lg border border-edge bg-base-100 px-3 py-2 text-base-content">
        “{sentence(@insight)}”
      </p>
    </div>
    """
  end

  def preview(%{insight: %{action_type: "briefing"}} = assigns) do
    assigns = assign(assigns, :to, addressee_name(assigns.insight, assigns.names))

    ~H"""
    <div class="mt-2 text-sm" data-role="insight-preview" data-preview-type="briefing">
      <p class="text-xs text-subtle" data-role="insight-preview-to">
        In <span class="font-medium text-base-content">{@to}</span>’s briefing
      </p>
      <p class="mt-1 rounded-lg border border-edge bg-base-100 px-3 py-2 text-base-content">
        {sentence(@insight)}
      </p>
    </div>
    """
  end

  def preview(%{insight: %{action_type: "task"}} = assigns) do
    assigns = assign(assigns, :sponsor, addressee_name(assigns.insight, assigns.names))

    ~H"""
    <div
      class="mt-2 rounded-lg border border-edge bg-base-100 px-3 py-2 text-sm"
      data-role="insight-preview"
      data-preview-type="task"
    >
      <p class="font-medium text-base-content" data-role="insight-preview-title">
        {task_title(@insight)}
      </p>
      <p class="mt-0.5 text-xs text-subtle">
        Sponsor: <span class="text-base-content">{@sponsor}</span>
      </p>
    </div>
    """
  end

  def preview(assigns) do
    ~H"""
    <div class="mt-2 text-sm text-base-content" data-role="insight-preview">
      {sentence(@insight)}
    </div>
    """
  end

  @doc "The addressee's display name, or a plain 'no one yet' when unrouted."
  @spec addressee_name(map(), map()) :: String.t()
  def addressee_name(%{addressee_user_id: id}, names) when is_binary(id),
    do: Map.get(names, id, "someone")

  def addressee_name(%{action: %{"addressee" => raw}}, _names) when is_binary(raw) and raw != "",
    do: raw

  def addressee_name(_insight, _names), do: "no one yet"
end

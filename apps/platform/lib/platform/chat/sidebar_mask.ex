defmodule Platform.Chat.SidebarMask do
  @moduledoc """
  Placeholder names for the chat rail's sub-org sections while someone is
  sharing their screen — "Workspace A", "Workspace B", ... in place of the real
  org names.

  PURE VIEW STATE. Every function here is a pure function of its arguments.
  This module must never touch `chat_spaces`, `channel_sections`, org records,
  or any other row; it performs no Ecto query, no write, and no PubSub
  broadcast. Masking is one viewer's presentation mode for the duration of one
  LiveView session — it is not a preference, not shared state, and must never
  become visible to another session.

  THIS IS A COSMETIC PRESENTATION AID, NOT A SECURITY CONTROL. Message bodies,
  canvases, task titles and uploaded file names all still carry real names, and
  no rule here changes that. A rail reading `Workspace B` beside a tab reading
  the real org name has failed at its only job, so the browser tab title and the
  chat header both mask through `space_label/3` (stage 5) and every surface that
  remains uncovered is enumerated explicitly rather than implied.

  ## Why `Workspace` and not `Client`

  `Client A` leaks the category: it tells a viewer that these are clients and
  how many there are. `Workspace` is neutral about the relationship. The word
  binds code as well as rendered output — there is no `client_*` identifier,
  assign, class or data attribute anywhere in this feature.

  ## How letters are assigned

  Strictly by the given list's TOP-TO-BOTTOM DISPLAY ORDER — not by id, not
  alphabetically by real name. The caller passes the already-resolved,
  already-ordered output of `Platform.Chat.Sidebar.resolve_for_user/2`, so the
  letter is a position in the rail rather than a stable cipher for a name.
  Past 26 sections the letters roll over to `AA`, `AB`, and so on.

  Known, accepted leak: the letters still publish the section COUNT and the
  rail's order. That is listed as uncovered rather than papered over.

  ## Which channel rows mask

  A channel masks when its normalised name IS its org's name/slug, or begins
  with it as a leading token — `#wayne-tech`, `#cyberdyne-builds`,
  `#sxi-crosspost` all render as `#workspace-f`. See `names_org?/2` for the
  exact rule. Fail-closed: when in doubt, mask.

  ACCEPTED FALSE POSITIVE: a channel that merely begins with an org's name
  token but is unrelated to that org is masked too — an org named `Atlas`
  makes `#atlas-migration` (a database channel) read `#workspace-c` while the
  mode is on. That is the direction to be wrong in. Over-masking costs one
  click of per-item reveal; under-masking puts a real client name on a shared
  screen, which is the whole failure this feature exists to prevent.

  ## What this does NOT cover — the complete enumeration

  This list is the ONLY artifact carrying it (there is no PR description for
  this branch). Keep it complete; an unstated leak is the failure condition.

    * **Project-code channels.** `#orion`, `#stark-industries` — names
      that contain no token of any org name, so no rule can infer the link.
      A hardcoded keyword list is refused on purpose: it is stale the day a
      new client arrives and reads as coverage the feature does not have.
      `#orion` renders verbatim while masked, deliberately, and there is a
      test pinning that so a keyword list cannot be quietly added.
    * **Cross-section rail rows.** A channel named after org B filed under
      org A's section renders verbatim IN THE RAIL. `space_label/3` (header
      and tab) matches across the whole rail and does catch it; only the rail
      row, which has a section in hand and must not be wrong about it, does
      not.
    * **DOM-only attributes.** `class`, `phx-value-scope`, `href`, and the
      space slug in the URL bar still carry real slugs. Rendered text,
      `aria-label`s and the accessibility tree do not.
    * **The letter sequence.** `Workspace A..F` publishes the section COUNT
      and the rail's display ORDER. Explicitly accepted by Sam Taylor.
    * **Colour dots.** Section colours are unchanged and are a weak
      fingerprint across sessions.
    * **Message bodies, canvases, task titles, uploaded file names.** Out of
      scope entirely — see the security-control disclaimer above.

  Surfaces that were checked and found clean, recorded here so their absence
  from the list above is not read as an oversight:

    * **The meeting participant rail.** Checked in stage 5: it renders
      participant display names only, and no org name reaches it.
    * **The browser tab title.** Masked via `space_label/3` since stage 5 and
      correct for derived channel names as of stage 6 — `#cyberdyne-builds`
      now titles as `# workspace-f`, matching the header beside it.

  ## Boundary note — TWO consumers now, and why this still lives in Chat

  This is a presentational concept living in the Chat domain context, following
  the precedent of `Platform.Chat.Sidebar.flatten_sections/1` — also
  presentation-shaped, also pure, also in this module family.

  It is NO LONGER single-caller. The Tasks rail (task 01a00cf1) is a second
  consumer, reaching it through `PlatformWeb.Tasks.TaskDisplay.mask_labels/3`.
  Two things about the Tasks rail differ genuinely from chat, which is why the
  generic arities below exist rather than a forked copy:

    * Tasks orgs are NOT structs. The identity key is a SLUG STRING and the
      display name comes from a FUNCTION CALL (`Tenancy.scope_label/1`), not
      from a `.name` field. `placeholders/1` and `label/4` both reach into
      `section.id` / `section.name`, so neither fits.
    * Tasks has TWO entity kinds in one rail — orgs and their projects, each
      lettered independently with its own prefix. Chat had one.

  The generalisation is `placeholders/2` and `label/5`, keyed on a plain id and
  a caller-supplied prefix. `placeholders/1` and `label/4` are now thin
  delegates onto them; chat's behaviour is unchanged by construction, and the
  chat test file passes unmodified.

  The module keeps its `Platform.Chat` namespace DELIBERATELY. Moving it to a
  neutral home would touch `chat_live` and every chat render site inside a
  Tasks-scoped task, which is a worse trade than the misleading namespace. That
  is recorded debt, not an oversight.
  """

  alias Platform.Chat.Section

  @placeholder_prefix "Workspace"

  @typedoc "A resolved sidebar entry — `Platform.Chat.Sidebar.resolved/0`."
  @type resolved :: %{required(:section) => map(), optional(any()) => any()}

  @doc """
  Build the `%{section_id => "Workspace A"}` map for one rail render.

  Letters follow the order of the list as given. Calling this again with the
  same list yields the same map, so a section keeps its letter for as long as
  the rail's order is unchanged within the session.
  """
  @spec placeholders([resolved()]) :: %{optional(binary()) => binary()}
  def placeholders(sections) when is_list(sections) do
    sections
    |> Enum.map(fn %{section: section} -> {section.id, section.name} end)
    |> placeholders(@placeholder_prefix)
  end

  @doc """
  The id/prefix form of `placeholders/1`, for a rail whose rows are not chat
  section structs.

  `entries` is a list of `{id, _name}` two-tuples or `%{id: _, name: _}` maps;
  only the id is read, the name is accepted so a caller can pass one list to
  both this and `label/5`. `prefix` is the placeholder word — `"Workspace"` for
  orgs, `"Project"` for projects.

  Letters follow the GIVEN DISPLAY ORDER, exactly as in `placeholders/1`, and
  roll over past 26 to `AA`. Two entity kinds sharing one rail call this once
  each, so each kind letters from `A` independently.
  """
  @spec placeholders([{binary(), any()} | map()], binary()) :: %{optional(binary()) => binary()}
  def placeholders(entries, prefix) when is_list(entries) and is_binary(prefix) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {entry, index} -> {entry_id(entry), prefix <> " " <> letters(index)} end)
  end

  defp entry_id({id, _name}), do: id
  defp entry_id(%{id: id}), do: id

  @doc """
  The string to render for one section header.

  Returns the section's real display name (`Platform.Chat.Section.display_name/1`:
  its label override, else its org's current name) when masking is off, or
  when this section's id has been individually revealed while masking is
  still on. Otherwise the placeholder. A section missing from `placeholders` falls back to the generic
  `"Workspace"` rather than leaking the real name.
  """
  @spec label(%{optional(binary()) => binary()}, map(), boolean(), MapSet.t() | [binary()]) ::
          binary()
  def label(placeholders, section, masked?, revealed_ids)

  def label(placeholders, section, masked?, revealed_ids) when is_map(section),
    do: label(placeholders, section.id, Section.display_name(section), masked?, revealed_ids)

  @doc """
  The id/name form of `label/4`, for a caller with no section struct in hand —
  the Tasks rail, whose org identity is a slug string and whose display name
  comes from `Tenancy.scope_label/1` rather than a field.

  FAIL-CLOSED, and this branch is the whole point of the function: an id with
  no entry in `placeholders` returns the BARE PREFIX, never `real_name`. The
  prefix is recovered from the map's own values (they all share it), falling
  back to `"Workspace"` for an empty map. Echoing `real_name` back on a miss
  would leak exactly the name the mode was turned on to hide, and a miss is
  precisely the case where the caller was wrong about what is in the rail.
  """
  @spec label(
          %{optional(binary()) => binary()},
          binary(),
          binary(),
          boolean(),
          MapSet.t()
          | [
              binary()
            ]
        ) :: binary()
  def label(placeholders, id, real_name, masked?, revealed_ids)

  def label(_placeholders, _id, real_name, false, _revealed_ids), do: real_name

  def label(placeholders, id, real_name, true, revealed_ids) do
    if id_revealed?(revealed_ids, id) do
      real_name
    else
      Map.get_lazy(placeholders, id, fn -> fallback_prefix(placeholders) end)
    end
  end

  # All values in one `placeholders/2` map share the prefix they were built
  # with, so any value recovers it. An empty map has nothing to recover from
  # and falls back to the chat default — still not the real name, which is the
  # only property that matters here.
  defp fallback_prefix(placeholders) when map_size(placeholders) == 0, do: @placeholder_prefix

  defp fallback_prefix(placeholders) do
    placeholders
    |> Map.values()
    |> List.first()
    |> String.split(" ")
    |> Enum.drop(-1)
    |> case do
      [] -> @placeholder_prefix
      parts -> Enum.join(parts, " ")
    end
  end

  @doc """
  Bundle the three things every masked render site needs into one value.

  Every call site needs the same trio (placeholders, the mode flag, the
  reveal set) and the mobile drawer reaches the name through four derived
  strings plus a search filter. Threading three arguments through all of
  them is how one site gets missed, so they travel together.

  Placeholders are always derived from the FULL section list the caller
  passes — never from a filtered subset — so a scope filter or a drawer
  search narrowing the rail cannot relabel the sections that remain.
  """
  @spec context([resolved()], boolean(), MapSet.t() | [binary()]) :: map()
  def context(sections, masked?, revealed_ids) when is_list(sections) do
    %{
      placeholders: placeholders(sections),
      masked?: masked?,
      revealed_ids: revealed_ids
    }
  end

  @doc """
  The string to render for one section header, from a `context/3` bundle.
  """
  @spec label(map(), map()) :: binary()
  def label(%{placeholders: placeholders, masked?: masked?, revealed_ids: revealed_ids}, section),
    do: label(placeholders, section, masked?, revealed_ids)

  @doc """
  True when this section is currently showing its real name under an active
  mask — the per-item reveal state, which drives the revealed row treatment.
  """
  @spec revealed?(map(), map()) :: boolean()
  def revealed?(%{masked?: masked?, revealed_ids: revealed_ids}, section),
    do: masked? and id_revealed?(revealed_ids, section.id)

  @doc """
  The string to render for one CHANNEL row inside `section`.

  Some channels are named after the org whose section they sit in —
  `#wayne-tech` under Wayne-Tech, or derived from it — `#cyberdyne-builds` under
  Cyberdyne. Masking the header and leaving those rows is the same leak with
  an extra step, so a row whose NORMALISED name matches its own section per
  `names_org?/2` renders as the section's placeholder in channel form
  (`workspace-b`).

  ## Named limitation

  This deliberately does NOT catch project-code channels like `#orion` or
  `#stark-industries`, which share no token with any org name. That
  residual is a NAMED LIMITATION, not something to paper over with a
  hardcoded keyword list: a hardcoded list is stale the day a new client
  arrives, and it would read as coverage the feature does not have.
  """
  @spec channel_label(map(), map(), binary()) :: binary()
  def channel_label(%{masked?: false}, _section, channel_name), do: channel_name

  def channel_label(ctx, section, channel_name) when is_binary(channel_name) do
    cond do
      revealed?(ctx, section) ->
        channel_name

      names_org?(channel_name, section) ->
        ctx |> label(section) |> to_channel_form()

      true ->
        channel_name
    end
  end

  @doc """
  The label for the OPEN channel — the chat header's title and the browser
  tab's `<title>`, neither of which is rendered from inside a rail section.

  The rail masks `#wayne-tech` because it can see the section that row sits in.
  The header and the tab have no section in hand, so this looks the name up
  across the WHOLE rail: a channel whose normalised name matches ANY section
  per `names_org?/2` renders as that section's placeholder in channel form.

  Matching across the rail rather than within one section is deliberate and is
  strictly wider than `channel_label/3`: it also catches the cross-section case
  (a channel named after org B that happens to be filed under org A's section),
  which the rail itself still renders unmasked. That residual is listed as
  uncovered for the rail; it is covered here because here there is no section
  to be wrong about.

  Same named limitation as `channel_label/3`: a project-code channel
  (`#orion`) names no org and so is not caught.
  """
  @spec space_label(map(), [resolved()], binary()) :: binary()
  def space_label(%{masked?: false}, _sections, channel_name), do: channel_name

  def space_label(ctx, sections, channel_name) when is_binary(channel_name) do
    case Enum.find(sections, fn %{section: section} -> names_org?(channel_name, section) end) do
      %{section: section} -> channel_label(ctx, section, channel_name)
      nil -> channel_name
    end
  end

  @doc """
  True when `channel_name` is the section's org name or slug, or is a channel
  DERIVED from it by a leading token — `#cyberdyne-builds` under Cyberdyne.

  Exact equality was the stage-2..5 rule and it under-masked badly: stage 6's
  review found `#cyberdyne-builds` and `#sxi-crosspost` rendering verbatim in
  the rail, the drawer, the drawer's SEARCH RESULTS, the composer placeholder
  and the browser tab — the tab read `# cyberdyne-builds` directly above a
  chat header reading `Workspace F`. The rule is now:

      normalise(channel_name) == candidate
      or String.starts_with?(normalise(channel_name), candidate <> "-")

  for each of the section's displayed name, its org's current name and its
  colour slug. The org name is a candidate in its own right (task 01a08212):
  a section carrying a custom label must still match a bucket or channel that
  names its ORG, which is what the hidden drawer and the scope pill hand in.
  When that comparison ran against a stale stored copy, the lookup missed and
  a masked pill fell back to the bare `"Workspace"` (the 01a0938b symptom). Leading token only, not a
  free `contains`: `#builds-cyberdyne` and `#retro-cyberdyne-notes` still
  render verbatim. A bare `contains` would mask on any coincidental substring
  anywhere in a name (an org called `Ex` would swallow half the rail), which
  is a different failure, not a stronger one.
  """
  @spec names_org?(binary(), map()) :: boolean()
  def names_org?(channel_name, section) when is_binary(channel_name) do
    normalised = normalise(channel_name)

    normalised != "" and
      [Section.display_name(section), Map.get(section, :org_name), Map.get(section, :color)]
      |> Enum.map(&normalise/1)
      |> Enum.any?(fn candidate ->
        candidate != "" and
          (normalised == candidate or String.starts_with?(normalised, candidate <> "-"))
      end)
  end

  @doc """
  The label for an org named by its DISPLAY NAME rather than by a section
  struct — the hidden-channels drawer groups by org bucket, and the chat
  header's scope pill knows only a scope atom's name.

  Fails closed: a bucket that matches no section in the rail renders the bare
  `"Workspace"`, never the name it was handed. A bucket can name an org that
  has no rail section at all (hidden-drawer buckets derive from the orgs
  table), and that is exactly the case where echoing the input back would
  leak the name the mode was turned on to hide.
  """
  @spec label_for_bucket(map(), [resolved()], binary() | nil) :: binary() | nil
  def label_for_bucket(%{masked?: false}, _sections, bucket), do: bucket
  def label_for_bucket(_ctx, _sections, nil), do: nil

  def label_for_bucket(ctx, sections, bucket) when is_binary(bucket) do
    case Enum.find(sections, fn %{section: section} -> names_org?(bucket, section) end) do
      %{section: section} -> label(ctx, section)
      nil -> @placeholder_prefix
    end
  end

  @doc """
  A label in slug form — `"Workspace B"` -> `"workspace-b"`.

  For the attribute surface (`data-section-slug`) and for channel rows, which
  read as `#name` and so need the placeholder in the same shape as the names
  beside them.
  """
  @spec slug(binary()) :: binary()
  def slug(label) when is_binary(label), do: normalise(label)

  # Downcase and collapse hyphens / underscores / whitespace to a single
  # hyphen, so "Wayne-Tech", "wayne_tech" and "pro tect" all compare equal.
  defp normalise(nil), do: ""

  defp normalise(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[-_\s]+/u, "-")
    |> String.trim("-")
  end

  # "Workspace B" -> "workspace-b": a channel row reads as `#name`, so the
  # placeholder has to arrive in the same shape as the names beside it.
  defp to_channel_form(label), do: slug(label)

  defp id_revealed?(%MapSet{} = revealed_ids, id), do: MapSet.member?(revealed_ids, id)
  defp id_revealed?(revealed_ids, id) when is_list(revealed_ids), do: id in revealed_ids
  defp id_revealed?(_revealed_ids, _id), do: false

  # 0 -> "A", 25 -> "Z", 26 -> "AA", 27 -> "AB" — bijective base-26.
  defp letters(index) when index < 26, do: <<?A + index>>

  defp letters(index) do
    letters(div(index, 26) - 1) <> <<?A + rem(index, 26)>>
  end
end

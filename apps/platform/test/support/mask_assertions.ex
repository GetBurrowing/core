defmodule Platform.MaskAssertions do
  @moduledoc """
  Absence assertions for screen-share name masking (task 01a00c66).

  ## The hole this closes

  `refute html =~ "Wayne-Tech"` PASSES while `data-section-slug="wayne-tech"` sits
  in the DOM in plain sight. Org slugs are stored underscored (`wayne_tech`) and
  rendered hyphenated (`wayne-tech`), so an assertion written against the display
  form proves nothing whatsoever about the attribute surface — and the
  attribute surface is exactly where a masked name survives, because it is the
  surface no one is looking at. Stage 3 found this hole in its own stage-2
  assertions rather than in a review.

  So every absence assertion goes through `refute_name_anywhere/2`, which
  checks all three spellings, case-insensitively, over the whole rendered blob
  including attributes.

  ## The three excluded attributes

  `class`, `phx-value-scope` and `href` are stripped before matching, and only
  those three. Each is a machine identifier that cannot follow the label
  without breaking what it identifies, and each is invisible on a screen share
  — which is this feature's entire threat model:

    * `class` — the scope-colour utilities are named after the org slug
      (`bg-wayne-tech`, `text-wayne-tech-label`). CSS class names cannot be
      re-generated per session.
    * `phx-value-scope` — the scope pill's event payload. It IS the filter
      argument; mask it and the pill filters by nothing.
    * `href` — a channel URL carries its slug, and the address bar shows it
      regardless. The URL bar is already on this feature's enumerated list of
      surfaces it does not cover.

  This is a NAMED LIMITATION, not an amnesty: rendered text, `aria-label`,
  `title`, `data-*` and every other `phx-value-*` are all in scope.
  `data-section-slug` was a residual until stage 3 and is not any more —
  nothing reads it, so it follows the label.
  """

  import ExUnit.Assertions

  @dom_only_attrs ~w(class phx-value-scope href)

  @doc """
  The three spellings one org name can appear in: display form, hyphen slug,
  underscore slug — all downcased.
  """
  @spec forms(binary()) :: [binary()]
  def forms(name) do
    base = String.downcase(name)

    Enum.uniq([base, String.replace(base, "-", "_"), String.replace(base, "_", "-")])
  end

  @doc """
  Fail if `name` appears in `html` in ANY of its three spellings, outside the
  three excluded attributes.

  `extra_excluded` adds surface-specific machine identifiers to the exclusion
  list FOR ONE CALL ONLY, and is how the Tasks rail (task 01a00cf1) is
  asserted. It is a per-call argument rather than a fourth entry in
  `@dom_only_attrs` on purpose: widening the module-level list would silently
  weaken every chat assertion that already passes, whereas a Tasks caller who
  forgets the argument gets a FAILURE. Over-strict is the safe direction for a
  default.

  The Tasks rail passes `~w(phx-value-id phx-value-key data-menu-key)`. Each is
  the same class as `phx-value-scope` above — the ARGUMENT of the action the
  control performs, not a label:

    * `phx-value-id` — the org slug the lifecycle menu archives / schedules for
      deletion, and the id the per-item reveal reveals. Mask it and the control
      acts on nothing, or on the wrong org.
    * `phx-value-key` / `data-menu-key` — `"org:<slug>"`, the open-state key
      matched against `@lifecycle_menu_key`. The two must be the same string or
      the menu never opens.

  Named limitation, same as the other three: they are invisible on a screen
  share, which is this feature's entire threat model.
  """
  @spec refute_name_anywhere(binary(), binary(), [binary()]) :: :ok
  def refute_name_anywhere(html, name, extra_excluded \\ []) do
    haystack = normalise(html, extra_excluded)

    for form <- forms(name) do
      refute String.contains?(haystack, form),
             """
             Masked name leaked as #{inspect(form)}.

             A masked surface must not carry the real name in ANY of its three
             spellings — display form, hyphen slug, underscore slug — in text
             OR in an attribute. `refute html =~ "#{name}"` alone passes this
             leak, which is why this helper exists.
             """
    end

    :ok
  end

  @doc """
  The anti-vacuity companion: assert the real name IS here, so an absence
  assertion elsewhere is known to be testing a surface that ever carried it.
  """
  @spec assert_name_anywhere(binary(), binary()) :: :ok
  def assert_name_anywhere(html, name) do
    haystack = normalise(html)

    assert Enum.any?(forms(name), &String.contains?(haystack, &1)),
           "Expected the real name #{inspect(name)} to be present here, and it is not — " <>
             "an absence assertion against this surface would prove nothing."

    :ok
  end

  defp normalise(html, extra_excluded \\ []) do
    (@dom_only_attrs ++ extra_excluded)
    |> Enum.reduce(html, fn attr, acc ->
      Regex.replace(~r/\s#{Regex.escape(attr)}="[^"]*"/, acc, " ")
    end)
    |> String.downcase()
  end
end

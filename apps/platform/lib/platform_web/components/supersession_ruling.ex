defmodule PlatformWeb.Components.SupersessionRuling do
  @moduledoc """
  The supersession ruling affordance on the Files surface (task
  01a0008c stage 5).

  Two pieces on `PlatformWeb.FilesLive`, both built to the ratified
  design direction for this task ("The ruling belongs on the document,
  not in a queue"):

    * `supersession_badge/1` — the **ghost badge**, on the row of the
      document being superseded: `Superseded by <v1.3> — unconfirmed`.
      A claim ruled not true draws nothing, because the list must not
      keep implying a supersession a person has already denied.

    * `supersession_panel/1` — a hairline and two verbs in the detail
      pane of that same document, **beside its own preview**. Judging
      "is v1.0 really dead?" next to v1.0 is a different act from
      judging it in a list of pending claims, and it is the reason
      there is no queue anywhere in this feature.

  ## The treatment: confidence, not colour

  The direction pins the palette and the reasoning behind it, and both
  survive contact with what this surface had already spent:

    * `--color-base-content` at **60%** for an unconfirmed claim —
      quiet on purpose, because the machine's guess must not look like
      a finding until a person agrees with it;
    * `--color-base-content` at **full weight** once confirmed — the
      badge slot does not change, only its confidence does;
    * `--color-error` and `--color-warning` are named to rule out. Red
      on this table already means an ingest failed (and task `01a0008b`
      is landing more of it), amber is the in-flight ingest pill. A
      superseded document is correct and old, not broken.

  So the ghost badge is the only badge on this surface carrying **no
  hue at all**. `FilesLive.status_badge_class/1` spends
  `badge-success` / `badge-error` / `badge-warning` / `badge-ghost` on
  ingest status; this one is base-content on an outline, and the only
  thing that changes between its two states is weight. That reads as
  provisional-then-verified, and it survives a viewer who cannot
  separate red from amber — the difference is opacity, not colour.

  ## Events the host LiveView must handle

    * `"rule_supersession"` — `%{"id" => superseded_file_id,
      "ruling" => ruling}` where `ruling` is `"confirmed"` or
      `"rejected"`; persists through
      `Platform.Files.Supersession.rule_claim/3`, which writes to the
      CLAIMANT's card.
  """

  use Phoenix.Component

  alias Platform.Files.Supersession

  @doc """
  The row badge, on the superseded document's row.

  Renders nothing when nothing claims to supersede this document, and
  nothing when the claim was ruled not true.
  """
  attr(:claim, :map, default: nil)
  attr(:class, :string, default: nil)

  def supersession_badge(assigns) do
    ~H"""
    <span
      :if={badge?(@claim)}
      class={[badge_class(@claim.ruling), @class]}
      data-role="files-supersession-badge"
      data-supersession-ruling={@claim.ruling}
      title={badge_title(@claim)}
    >
      {badge_label(@claim)}
    </span>
    """
  end

  @doc """
  The detail-pane ruling: what the card says, and the two verbs.

  A hairline above rather than a boxed card — the pane's existing
  convention for separating a control group, and the direction's own
  `--color-base-300`.

  Both verbs stay on screen in every state, in both directions. A
  ruling is a judgement a person can get wrong, and hiding the opposite
  verb after the first click would make a mis-click permanent from the
  UI.
  """
  attr(:claim, :map, default: nil)
  attr(:file_id, :string, required: true)
  attr(:can_rule, :boolean, default: false)
  attr(:suffix, :string, default: "")

  def supersession_panel(assigns) do
    ~H"""
    <div
      :if={@claim}
      class="mt-4 border-t border-edge pt-3"
      data-role={"files-supersession-panel" <> @suffix}
      data-supersession-ruling={@claim.ruling}
    >
      <p class={[
        "text-xs",
        if(Supersession.unruled?(@claim), do: "text-base-content/60", else: "text-base-content")
      ]}>
        <span data-role={"files-supersession-claim" <> @suffix}>{claim_sentence(@claim)}</span>
      </p>

      <p :if={Supersession.unruled?(@claim)} class="mt-1 text-[11px] text-base-content/50">
        Recorded automatically. Both documents stay published and searchable either way —
        a ruling only decides whether the claim is authoritative.
      </p>

      <div class="mt-2 flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click="rule_supersession"
          phx-value-id={@file_id}
          phx-value-ruling="confirmed"
          disabled={not @can_rule}
          class={"btn btn-sm " <> if(@claim.ruling == "confirmed", do: "btn-neutral", else: "btn-outline")}
          data-role={"files-supersession-confirm" <> @suffix}
        >
          Confirm
        </button>
        <button
          type="button"
          phx-click="rule_supersession"
          phx-value-id={@file_id}
          phx-value-ruling="rejected"
          disabled={not @can_rule}
          class={"btn btn-sm " <> if(@claim.ruling == "rejected", do: "btn-neutral", else: "btn-ghost")}
          data-role={"files-supersession-reject" <> @suffix}
        >
          Not true
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The badge classes for a ruling.

  One slot, two confidences: base-content at 60% while unruled, full
  weight once confirmed. No hue in either — `badge-success` /
  `badge-error` / `badge-warning` / `badge-ghost` are all already spent
  on ingest status by `FilesLive.status_badge_class/1`, and a
  superseded document is correct and old rather than broken.
  """
  def badge_class("confirmed"),
    do: "badge badge-outline badge-sm text-base-content border-base-content/50"

  def badge_class(_unruled),
    do: "badge badge-outline badge-sm font-normal text-base-content/60 border-base-content/25"

  @doc false
  def badge_label(%{claimant_filename: name, ruling: "confirmed"}),
    do: "Superseded by #{name}"

  def badge_label(%{claimant_filename: name}),
    do: "Superseded by #{name} — unconfirmed"

  # A rejected claim is still shown in the DETAIL pane (a person ruled;
  # that ruling is worth seeing) but never on the row: a list caption
  # saying "not true" is noise about a relationship that does not exist.
  defp badge?(%{ruling: "rejected"}), do: false
  defp badge?(%{ruling: _}), do: true
  defp badge?(_), do: false

  defp badge_title(%{claimant_filename: name, ruling: "confirmed"}),
    do: "Confirmed: #{name} supersedes this document."

  defp badge_title(%{claimant_filename: name}),
    do: "#{name}'s card claims it supersedes this document. Nobody has ruled on it yet."

  defp claim_sentence(%{claimant_filename: name, ruling: "confirmed"}),
    do: "Superseded by #{name}."

  defp claim_sentence(%{claimant_filename: name, ruling: "rejected"}),
    do: "The claim that #{name} supersedes this document was ruled not true."

  defp claim_sentence(%{claimant_filename: name}),
    do: "Card says: superseded by #{name}."
end

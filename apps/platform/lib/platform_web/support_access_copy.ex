defmodule PlatformWeb.SupportAccessCopy do
  @moduledoc """
  Every owner-facing string for vendor support access (task 01a1b362 stage
  2; design canvas 01a1b362-e9b9). One module, so a wording change is one
  edit.

  The wording is ADVISORY: the product owner confirms it, and it is checked
  against the customer terms. Those are human decisions, not gates in code.

  ## The vendor's name

  Core never spells it (`install_identity_scanner`). It comes from
  `SUPPORT_VENDOR_NAME` (`Platform.SupportAccess.Config.vendor_name/0`).
  With no name set, the support side is called "Vendor support" and every
  phrase is built so that reads naturally ("Vendor support access", never
  "Vendor support support access").

  ## Words owners never see

  No string here contains "SSH", "certificate", "grant" or "impersonation"
  (`excluded_words/0`; a test renders every surface and checks). Shell access
  is a "repair session".
  """

  alias Platform.SupportAccess.Config

  @fallback "Vendor support"

  @doc "Words no owner-facing string may contain (case-insensitive)."
  def excluded_words, do: ~w(ssh certificate grant impersonation)

  @doc "The vendor's display name, or \"Vendor support\" when none is set."
  @spec who() :: String.t()
  def who, do: Config.vendor_name() || @fallback

  # "<name> support" / "Vendor support".
  defp support_noun do
    case Config.vendor_name() do
      nil -> @fallback
      name -> name <> " support"
    end
  end

  # ── Settings ─────────────────────────────────────────────────────────

  def section_label, do: "Support"

  def card_title, do: support_noun() <> " access"

  def idle_sentence do
    "#{who()} can sign in as an admin or open a repair session on your server " <>
      "for a few hours, to help you. Every visit is recorded below. Turn this off " <>
      "and #{who()} can't get in at all."
  end

  @doc """
  The active sentence, split around the end time so the time can be set in
  mono: `{lead, trail}` with the time between them. `operators` is the
  operators' names, deduplicated.
  """
  @spec active_sentence([String.t()]) :: {String.t(), String.t()}
  def active_sentence(operators) do
    {"#{who()} (#{Enum.join(operators, ", ")}) is helping right now, until ", "."}
  end

  def off_sentence do
    "Off. #{who()} can't sign in or open a repair session. " <>
      "Turn it back on any time if you need help."
  end

  def end_session, do: "End session"

  def switch_label, do: card_title()

  def save_failed, do: "Couldn't save. Your setting hasn't changed."

  def end_failed, do: "Couldn't end the session. Try again."

  def state_file_pending do
    "Your server hasn't picked up this change yet. It tries again every minute."
  end

  def history_heading, do: "Recent support visits"

  def history_empty, do: "No support visits yet."

  def view_all, do: "View all support activity →"

  def activity_title, do: "All support activity"

  def activity_empty, do: "Nothing recorded yet."

  # ── Visit rows ───────────────────────────────────────────────────────

  def kind_label("admin"), do: "admin sign-in"
  def kind_label("repair"), do: "repair session"
  def kind_label(_), do: "visit"

  def status_active, do: "helping now"

  def end_reason_label("expired"), do: "ended"
  def end_reason_label("ended_by_owner"), do: "ended early"
  def end_reason_label("access_turned_off"), do: "ended when support access was turned off"
  def end_reason_label(_), do: "ended"

  @doc "A refused request's status, with its reason in plain words."
  def refused_label(reason), do: "refused: " <> refusal_reason(reason)

  defp refusal_reason("support_access_off"), do: "support access was off"
  defp refusal_reason("grant_expired"), do: "the request had expired"
  defp refusal_reason("replayed_nonce"), do: "the request was a repeat"
  defp refusal_reason("duration_too_long"), do: "asked for too long"
  defp refusal_reason("wrong_install"), do: "meant for a different server"
  defp refusal_reason("operator_email_taken"), do: "that email belongs to one of your users"
  defp refusal_reason(_), do: "the request wasn't valid"

  # ── All activity (stands in for the audit-log link) ──────────────────

  @doc "One line for a `support.*` audit row (`Platform.Audit.Event`)."
  def activity_line(%{event_type: type, metadata: metadata}) do
    metadata = metadata || %{}

    case type do
      "support.access_changed" ->
        if metadata["to"] == true,
          do: "Support access turned on",
          else: "Support access turned off"

      "support.grant_requested" ->
        "#{operator(metadata)} asked to start a #{kind_label(metadata["kind"])}"

      "support.grant_issued" ->
        "#{operator(metadata)} started a #{kind_label(metadata["kind"])}"

      "support.grant_refused" ->
        "#{operator(metadata)} was " <> refused_label(metadata["reason"])

      "support.session_ended" ->
        String.capitalize(kind_label(metadata["kind"])) <>
          " " <> end_reason_label(metadata["reason"])

      "support.action" ->
        "Made a change in the app"

      "support.shell_opened" ->
        "Repair session opened on your server"

      "support.shell_command" ->
        "Ran a command on your server"

      "support.shell_closed" ->
        "Repair session closed on your server"

      "support.shell_unmatched" ->
        "Unrecognised repair session record"

      _ ->
        "Support activity"
    end
  end

  defp operator(%{"operator_name" => name}) when is_binary(name) and name != "", do: name
  defp operator(%{"operator_email" => email}) when is_binary(email), do: email
  defp operator(_), do: who()

  # ── Banner ───────────────────────────────────────────────────────────

  @doc "`{lead, trail}` around the end time, as `active_sentence/1`."
  def banner_admin, do: {support_noun() <> " is signed in to help, until ", "."}

  def banner_repair, do: {support_noun() <> " is working on your server to help, until ", "."}

  def banner_details, do: "Details"

  # ── Member lists ─────────────────────────────────────────────────────

  def marker, do: who()

  def leaves_at, do: "leaves at "
end

defmodule PlatformWeb.Components.Meetings.IntentsCollapseTest do
  @moduledoc """
  Unit tests for the pure half of the `.intents-collapse` bar
  (task 019f70b8 stage 7).

  The rendered half is exercised end-to-end through the real mount in
  `PlatformWeb.MeetingLiveTest` — constructing assigns here and calling
  the component directly would prove the template renders a list, not
  that a producer ever sees one. What lives here is the presentation
  vocabulary the LiveView and the corpus BOTH depend on: the status
  mapping, the control matrix, and the outcome capture.
  """
  use ExUnit.Case, async: true

  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentQueue
  alias PlatformWeb.Components.Meetings.IntentsCollapse, as: Bar

  describe "status presentation" do
    test "covers every status the queue can produce — no silent fallback" do
      # A status the bar doesn't know would render as `:queued`, which is
      # the worst possible lie: a failed intent shown as still waiting.
      # The queue is the authority on the enum, so it is the fixture.
      assert Enum.sort(Bar.statuses()) == Enum.sort(IntentQueue.statuses())
    end

    test "the error split is amber for :timed_out, red for the two hard failures" do
      # `:timed_out` means "we waited and got nothing"; the others mean
      # "something is broken". Three different operator actions.
      assert Bar.status_tone(:timed_out) == "warning"
      assert Bar.status_tone(:dispatch_failed) == "error"
      assert Bar.status_tone(:no_ack_spawn_failed) == "error"
    end

    test ":timed_out and :no_ack_spawn_failed never share a chip" do
      refute Bar.status_tone(:timed_out) == Bar.status_tone(:no_ack_spawn_failed)
      refute Bar.status_icon(:timed_out) == Bar.status_icon(:no_ack_spawn_failed)
      refute Bar.status_label(:timed_out) == Bar.status_label(:no_ack_spawn_failed)
    end

    test "the in-flight progression reads neutral -> info, success is green, cancelled is muted" do
      assert Bar.status_tone(:queued) == "neutral"
      assert Bar.status_tone(:dispatched) == "info"
      assert Bar.status_tone(:acked) == "info"
      assert Bar.status_tone(:completed) == "success"
      assert Bar.status_tone(:cancelled) == "neutral"
      assert Bar.status_tone(:cancelled_late) == "neutral"
    end

    test "every status carries a distinct glyph AND a distinct label" do
      # Colourblind-safe: colour reinforces, it never carries the signal
      # alone. Two statuses sharing a glyph would put the whole meaning
      # back on the hue.
      glyphs = Enum.map(IntentQueue.statuses(), &Bar.status_icon/1)
      labels = Enum.map(IntentQueue.statuses(), &Bar.status_label/1)

      assert Enum.uniq(glyphs) == glyphs
      assert Enum.uniq(labels) == labels
    end

    test "every glyph class is a LITERAL in the source, so Tailwind can find it" do
      # `app.css` scans `lib/platform_web` as plain text. A class built at
      # render time (`"hero-" <> suffix`) is invisible to that scan, its
      # rule never reaches the bundle, and the chip ships an empty box —
      # silently, and only for the icons no other file happens to write
      # out. This shipped exactly that way for `hero-bug-ant` and
      # `hero-queue-list` before it was caught in a screenshot.
      source = File.read!("lib/platform_web/components/meetings/intents_collapse.ex")

      for status <- IntentQueue.statuses() do
        icon = Bar.status_icon(status)

        assert String.starts_with?(icon, "hero-"),
               "#{status} must return a complete hero-* class, got #{inspect(icon)}"

        assert source =~ "\"#{icon}\"",
               "#{icon} is not a string literal in the component source — " <>
                 "Tailwind will drop the rule and the chip renders glyphless"
      end
    end

    test "every status carries a hint, and :cancelled_late's names the race" do
      # `:cancelled_late` is a race, not a misclassification. A producer
      # who reads it as one will keep correcting a classifier that was
      # right — so the tooltip has to say what happened.
      for status <- IntentQueue.statuses() do
        hint = Bar.status_hint(status)
        assert is_binary(hint) and hint != ""
      end

      assert Bar.status_hint(:cancelled_late) =~ "finished before the cancel"
      refute Bar.status_hint(:cancelled_late) == Bar.status_hint(:cancelled)
      refute Bar.status_hint(:timed_out) == Bar.status_hint(:no_ack_spawn_failed)
    end

    test "groups partition the enum into in-flight / success / cancelled / error" do
      grouped = Enum.group_by(IntentQueue.statuses(), &Bar.status_group/1)

      assert Enum.sort(grouped[:in_flight]) == Enum.sort([:queued, :dispatched, :acked])
      assert grouped[:success] == [:completed]
      assert Enum.sort(grouped[:cancelled]) == Enum.sort([:cancelled, :cancelled_late])

      assert Enum.sort(grouped[:error]) ==
               Enum.sort([:timed_out, :dispatch_failed, :no_ack_spawn_failed])
    end

    test "string statuses resolve identically to atoms" do
      # ETS rows carry atoms, but a `data-*` round-trip or a serialized
      # payload can arrive as a string. Both must render the same chip.
      for status <- IntentQueue.statuses() do
        assert Bar.status_tone(Atom.to_string(status)) == Bar.status_tone(status)
        assert Bar.status_label(Atom.to_string(status)) == Bar.status_label(status)
      end
    end
  end

  describe "control matrix" do
    test "terminal success and cancelled rows are read-only history" do
      # Retroactively relabelling a completed intent is out of scope, so
      # those rows carry no controls rather than controls that no-op.
      for status <- [:completed, :cancelled, :cancelled_late] do
        refute Bar.removable?(status)
        refute Bar.correctable?(status)
      end
    end

    test "failures stay actionable" do
      for status <- [:timed_out, :dispatch_failed, :no_ack_spawn_failed] do
        assert Bar.removable?(status)
      end

      # A `:timed_out` row is NOT re-targetable: nobody answered, so
      # there is no evidence the classifier picked the wrong target —
      # only that the target was silent.
      refute Bar.correctable?(:timed_out)
      assert Bar.correctable?(:dispatch_failed)
      assert Bar.correctable?(:no_ack_spawn_failed)
    end

    test "only in-flight rows confirm before acting" do
      # Confirmation is for interrupting running work, not for tidying a
      # queue. Confirming a `:queued` removal would train the producer to
      # click through dialogs.
      assert Bar.confirm_required?(:dispatched)
      assert Bar.confirm_required?(:acked)

      for status <- IntentQueue.statuses() -- [:dispatched, :acked] do
        refute Bar.confirm_required?(status)
      end
    end
  end

  describe "dispatch_outcome/1" do
    test ":queued has no dispatch outcome" do
      # A row pulled before it ever left the queue never dispatched.
      # Stamping one would poison the corpus with a dispatch that did
      # not happen.
      assert Bar.dispatch_outcome(:queued) == nil
    end

    test "every other status maps onto a value the corpus enum accepts" do
      for status <- IntentQueue.statuses() -- [:queued] do
        outcome = Bar.dispatch_outcome(status)
        assert outcome == status
        assert outcome in IntentCorrection.dispatch_outcomes()
      end
    end
  end

  describe "summary/1" do
    test "an empty queue says so rather than reading '0 intents'" do
      assert Bar.summary([]) == "No intents yet"
    end

    test "counts pluralize and surface how many need attention" do
      assert Bar.summary([intent(:queued)]) == "1 intent"
      assert Bar.summary([intent(:queued), intent(:completed)]) == "2 intents"

      assert Bar.summary([intent(:queued), intent(:timed_out), intent(:dispatch_failed)]) ==
               "2 need attention · 3 intents"
    end

    test "cancelled rows are not 'attention' — they are the producer's own doing" do
      assert Bar.summary([intent(:cancelled), intent(:cancelled_late)]) == "2 intents"
    end
  end

  describe "summary_parts/1 — the severity fragment is the last thing to truncate" do
    test "severity is written FIRST, so a clip eats the count and not the signal" do
      # The whole reason the collapsed state exists is to answer "is
      # anything wrong?" without expanding. `10 intents · 3 need…` fails
      # that in exactly the case it singles out.
      intents = [intent(:queued), intent(:acked), intent(:dispatch_failed)]

      assert Bar.summary_parts(intents) == %{severity: "1 needs attention", tail: "· 3 intents"}

      summary = Bar.summary(intents)
      severity_at = :binary.match(summary, "needs attention") |> elem(0)
      count_at = :binary.match(summary, "3 intents") |> elem(0)

      assert severity_at < count_at,
             "the severity fragment must precede the count, or truncation eats it first"
    end

    test "the verb agrees with the attention count" do
      assert Bar.summary_parts([intent(:timed_out)]).severity == "1 needs attention"

      assert Bar.summary_parts([intent(:timed_out), intent(:dispatch_failed)]).severity ==
               "2 need attention"
    end

    test "no severity fragment at all when nothing needs attention" do
      # Nothing to protect, so the tail may truncate freely — and it
      # carries no leading separator to dangle.
      assert Bar.summary_parts([intent(:queued), intent(:completed)]) ==
               %{severity: nil, tail: "2 intents"}

      assert Bar.summary_parts([]) == %{severity: nil, tail: "No intents yet"}
    end

    test "summary/1 is exactly the two parts joined, in that order" do
      for intents <- [
            [],
            [intent(:queued)],
            [intent(:queued), intent(:completed)],
            [intent(:timed_out)],
            [intent(:timed_out), intent(:no_ack_spawn_failed), intent(:acked)]
          ] do
        parts = Bar.summary_parts(intents)

        expected =
          case parts do
            %{severity: nil, tail: tail} -> tail
            %{severity: severity, tail: tail} -> "#{severity} #{tail}"
          end

        assert Bar.summary(intents) == expected
      end
    end

    test "the protection is STRUCTURAL, not a copy convention" do
      # Mutation guard. Re-wording the summary must not be able to
      # un-protect the severity fragment, so the two fragments render as
      # separate spans with opposite shrink behaviour: the tail gives up
      # its width (`min-w-0 truncate`), the severity keeps its own
      # (`shrink-0 whitespace-nowrap`). Deleting either class — or
      # collapsing the two spans back into one interpolated string —
      # fails here.
      source = File.read!("lib/platform_web/components/meetings/intents_collapse.ex")

      [severity_span] =
        Regex.run(~r/<span[^>]*data-role="intents-summary-severity"[^>]*>/s, source)

      [tail_span] = Regex.run(~r/<span[^>]*data-role="intents-summary-tail"[^>]*>/s, source)

      assert severity_span =~ "shrink-0"
      assert severity_span =~ "whitespace-nowrap"
      refute severity_span =~ "truncate"

      assert tail_span =~ "truncate"
      assert tail_span =~ "min-w-0"

      assert :binary.match(source, ~s(data-role="intents-summary-severity")) |> elem(0) <
               :binary.match(source, ~s(data-role="intents-summary-tail")) |> elem(0),
             "the severity span must be rendered before the tail"
    end
  end

  describe "format_confidence/1" do
    test "renders two decimals, or an em-dash when the classifier gave none" do
      assert Bar.format_confidence(0.8712) == "0.87"
      assert Bar.format_confidence(1) == "1.00"
      assert Bar.format_confidence(nil) == "—"
      assert Bar.format_confidence("nope") == "—"
    end
  end

  describe "low-confidence emphasis" do
    test "the threshold is 0.70, and the comparison is strictly below it" do
      assert Bar.low_confidence_threshold() == 0.70

      assert Bar.low_confidence?(0.55)
      assert Bar.low_confidence?(0.6999)
      refute Bar.low_confidence?(0.70)
      refute Bar.low_confidence?(0.87)
      refute Bar.low_confidence?(1)
    end

    test "no reading is not a bad reading" do
      # `nil` means the classifier made no claim. Tinting that as low
      # would invent a judgement the model never offered.
      refute Bar.low_confidence?(nil)
      refute Bar.low_confidence?("nope")
      assert Bar.confidence_readout(nil) == "—"
      assert Bar.confidence_tone_classes(nil) == Bar.confidence_tone_classes(0.96)
      assert Bar.confidence_aria_label(nil) == "Confidence not reported"
    end

    test "all THREE parts land together, and only below the threshold" do
      # Tone, the `~` prefix, and the spoken label. Colour alone would
      # break the rule every status chip in this bar already keeps.
      assert Bar.confidence_readout(0.55) == "~0.55"
      assert Bar.confidence_tone_classes(0.55) =~ "text-warning"
      assert Bar.confidence_aria_label(0.55) =~ "low confidence"
      assert Bar.confidence_aria_label(0.55) =~ "0.55"

      assert Bar.confidence_readout(0.96) == "0.96"
      refute Bar.confidence_tone_classes(0.96) =~ "text-warning"
      refute Bar.confidence_aria_label(0.96) =~ "low confidence"
    end

    test "0.55 and 0.96 do not render identically on ANY of the three axes" do
      # The defect this closes: a producer deciding whether to trust a
      # dispatch saw the two the same. Mutation guard — reverting any
      # single part still fails.
      refute Bar.confidence_readout(0.55) == Bar.confidence_readout(0.96)
      refute Bar.confidence_tone_classes(0.55) == Bar.confidence_tone_classes(0.96)
      refute Bar.confidence_aria_label(0.55) == Bar.confidence_aria_label(0.96)
    end

    test "the `~` marks emphasis without lying about the number" do
      # It reads as "approximately/soft", not as an extra digit — the
      # two decimals underneath are still the classifier's own value.
      assert Bar.confidence_readout(0.55) == "~" <> Bar.format_confidence(0.55)
    end

    test "every tone class is a LITERAL in the source, so Tailwind can find it" do
      # Same trap as the hero glyphs: `"text-" <> tone` compiles, renders
      # a correct-looking class attribute, and ships no rule. The failure
      # is silent, partial, and invisible to a DOM assertion — so the
      # assertion has to be about the source text.
      source = File.read!("lib/platform_web/components/meetings/intents_collapse.ex")

      for confidence <- [0.10, 0.55, 0.6999, 0.70, 0.87, 1.0, nil] do
        for class <- String.split(Bar.confidence_tone_classes(confidence)) do
          assert source =~ "\"#{Bar.confidence_tone_classes(confidence)}\"",
                 "#{class} is not part of a complete literal class string in the source — " <>
                   "Tailwind will drop the rule and the emphasis silently disappears"
        end
      end
    end
  end

  describe "reason_label/1" do
    test "labels every reason the corpus accepts, from atom or string" do
      for reason <- IntentCorrection.reasons() do
        label = Bar.reason_label(reason)
        assert is_binary(label) and label != ""
        assert Bar.reason_label(Atom.to_string(reason)) == label
      end
    end
  end

  defp intent(status), do: %{id: Ecto.UUID.generate(), status: status}
end

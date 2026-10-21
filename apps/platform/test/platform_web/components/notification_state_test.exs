defmodule PlatformWeb.Components.NotificationStateTest do
  @moduledoc """
  DOM contract tests for the `/inbox` notification-state row (task 019ffb7b
  stage 4, revised after Robin's review).

  Most of these moved here from `icon_rail_test.exs`: they were written
  against the rail bell, but their subject was the BEHAVIOUR per permission
  state, not the rail. Only the two tests whose entire subject was rail
  placement were dropped. See the module-level note in that file.

  The trap this block is written against: an "absence" test ("denied has no
  enable button") plus a render-only positive control ("the row renders") both
  pass for a row wired to nothing at all. So the prompt/denied pair below
  asserts the row EXISTS in both states and differs only in whether it carries
  an action — a component that rendered nothing fails several assertions in
  that one test rather than passing on absence.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.NotificationState

  # Real user-agent strings, kept verbatim rather than minimised: every browser
  # lies in this header (Edge and Opera both claim "Chrome", Chrome claims
  # "Safari"), and a trimmed fixture would stop exercising the ordering that
  # keeps those lies from being believed.
  @chrome_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  @edge_ua "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0"
  @safari_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
  @firefox_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:127.0) Gecko/20100101 Firefox/127.0"
  @opera_ua "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 OPR/112.0.0.0"
  @ios_chrome_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0.0.0 Mobile/15E148 Safari/604.1"
  @ios_safari_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
  @nonsense_ua "SomeBrowser/1.0 (An OS Nobody Has Heard Of)"

  @generic_line "Allow them in your browser's site settings for this page."
  @os_line "If your computer is silencing the browser itself, no site setting will help."

  defp row_doc(permission, opts \\ []) do
    assigns = %{
      push_permission: permission,
      user_agent: Keyword.get(opts, :user_agent),
      auto_denied: Keyword.get(opts, :auto_denied, false),
      registration_failed: Keyword.get(opts, :registration_failed),
      native_platform: Keyword.get(opts, :native_platform)
    }

    rendered_to_string(~H"""
    <.notification_state_row
      push_permission={@push_permission}
      user_agent={@user_agent}
      auto_denied={@auto_denied}
      registration_failed={@registration_failed}
      native_platform={@native_platform}
    />
    """)
    |> LazyHTML.from_fragment()
  end

  defp row_text(doc),
    do: doc |> LazyHTML.query(~s([data-role="notification-state"])) |> LazyHTML.text()

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  # --- which states render anything at all ------------------------------

  test "unknown renders NOTHING — nothing appears before the client reports" do
    doc = row_doc("unknown")

    assert count(doc, ~s([data-role="notification-state"])) == 0
    assert count(doc, "button") == 0
  end

  test "unsupported renders NOTHING — the browser could never honour it" do
    doc = row_doc("unsupported")

    assert count(doc, ~s([data-role="notification-state"])) == 0
    assert count(doc, "button") == 0
  end

  test "granted renders NOTHING — the healthy case adds nothing to the page" do
    doc = row_doc("granted")

    assert count(doc, ~s([data-role="notification-state"])) == 0
    assert count(doc, "button") == 0
  end

  # --- granted-but-not-registered (task 019ffe52 stage 3) ---------------
  #
  # The state fix B made visible: the browser said yes and Suite failed to
  # record the device. Two variants, because the two ways to get here need
  # opposite instructions.
  #
  # This block first shipped as ONE variant behind a boolean and Robin rejected
  # the copy: "If we are going to tell the user something is broken, we need to
  # tell them how to fix (whether they need to do something, or we need to do
  # something)." A boolean cannot answer that when it is set by two failures
  # whose answers are opposites, which is why the discriminating tests below
  # exist rather than one test that passes for either reason.

  describe "granted with a failed registration" do
    @no_participant_first "Notifications are on, but you are not in any conversations yet."
    @no_participant_second "Start a conversation in Chat and they will switch on."

    @subscribe_failed_first "Your browser allowed notifications, but this device could not be registered."
    @subscribe_failed_second "Reload the page to try again."

    # Positive and healthy control in ONE test per variant, on purpose. Split
    # into "the row renders" and "the healthy case renders nothing", a variant
    # wired to nothing passes the second and only fails the first; here they
    # share a case, so a component that renders nothing detonates inside the
    # same test that proves the reason matters.
    test "no_participant says there is nothing for the user to do" do
      failed = row_doc("granted", registration_failed: :no_participant)
      healthy = row_doc("granted", registration_failed: nil)

      assert count(failed, ~s([data-role="notification-state"])) == 1,
             "granted + :no_participant must render the row"

      assert count(healthy, ~s([data-role="notification-state"])) == 0,
             "granted with the registration stored must still render nothing"

      text = row_text(failed)

      # Exact text. The words are the thing under review, and a paraphrase here
      # would let approved copy drift silently.
      assert text =~ @no_participant_first
      assert text =~ @no_participant_second
    end

    test "subscribe_failed tells the user to reload" do
      failed = row_doc("granted", registration_failed: :subscribe_failed)
      healthy = row_doc("granted", registration_failed: nil)

      assert count(failed, ~s([data-role="notification-state"])) == 1,
             "granted + :subscribe_failed must render the row"

      assert count(healthy, ~s([data-role="notification-state"])) == 0

      text = row_text(failed)

      assert text =~ @subscribe_failed_first
      assert text =~ @subscribe_failed_second
    end

    # THE test the boolean could not express, and the reason this rework
    # happened. Each reason must render ITS OWN words and not the other's. A
    # single "the row says something about notifications" assertion passes for
    # either, which is the vacuity that let unactionable copy through review.
    test "the two reasons do not borrow each other's words" do
      no_participant = row_text(row_doc("granted", registration_failed: :no_participant))
      subscribe_failed = row_text(row_doc("granted", registration_failed: :subscribe_failed))

      # Positive control, and it earns its place: without it every assertion
      # below is a refute, and refutes all pass against the single vague
      # variant this rework replaced, which contained neither phrase. Verified
      # by running this file against the previous implementation: the refutes
      # stayed green there while these two asserts went red.
      assert no_participant =~ @no_participant_first
      assert subscribe_failed =~ @subscribe_failed_first

      refute no_participant =~ @subscribe_failed_first,
             ":no_participant must not claim the device could not be registered"

      refute no_participant =~ "Reload",
             ":no_participant must not ask for a reload, which cannot help"

      refute subscribe_failed =~ @no_participant_first,
             ":subscribe_failed must not blame an empty conversation list"

      refute subscribe_failed =~ "Start a conversation",
             ":subscribe_failed is not about conversations; a reload is the fix"
    end

    # Robin's actual question. Each variant has to answer "who acts": one says
    # outright that the user does not, the other gives them the single step
    # that can change the outcome.
    test "each variant says who has to act" do
      assert row_text(row_doc("granted", registration_failed: :no_participant)) =~
               "Start a conversation in Chat"

      assert row_text(row_doc("granted", registration_failed: :subscribe_failed)) =~ "Reload"
    end

    # The line that would have shipped if nobody had thought about who reaches
    # this state. After fix A the only users who get here have NO conversations
    # at all, so an instruction to open one addresses exactly the population
    # that cannot follow it.
    test "does not tell the user to open a conversation" do
      text = row_text(row_doc("granted", registration_failed: :no_participant))

      refute text =~ "Open any conversation",
             "the imperative form addresses users who have no conversation to open"

      refute text =~ "Open a conversation"

      # And it does not fall back on the vague line Robin rejected.
      refute text =~ "could not finish setting them up"
    end

    # No control on either variant. The permission is already granted, so a
    # button here re-runs the same path; "Reload the page" is instruction text
    # and a reload button would duplicate the browser's own.
    test "carries no button and nothing else focusable, in BOTH variants" do
      for reason <- [:no_participant, :subscribe_failed] do
        doc = row_doc("granted", registration_failed: reason)

        # Positive control first: there IS a row here to be empty of controls.
        assert count(doc, ~s([data-role="notification-state"])) == 1,
               "expected a row for #{reason}"

        assert count(doc, "button") == 0, "#{reason} must carry no button"
        assert count(doc, "a") == 0
        assert count(doc, "input") == 0
        assert count(doc, ~s([phx-click])) == 0
        assert count(doc, ~s([tabindex])) == 0
        assert count(doc, ~s([data-role="notification-enable"])) == 0
      end
    end

    test "announces itself, since it appears after connect rather than on paint" do
      for reason <- [:no_participant, :subscribe_failed] do
        assert row_doc("granted", registration_failed: reason)
               |> LazyHTML.query(~s([data-role="notification-state"]))
               |> LazyHTML.attribute("role") == ["status"],
               "expected role=status for #{reason}"
      end
    end

    # Same rule the `auto_denied` flag follows: `data-permission` is the
    # five-value vocabulary other code keys on by string, and an extra fact
    # rides beside it rather than renaming the state.
    test "the reason does not become a sixth permission value" do
      for reason <- [:no_participant, :subscribe_failed] do
        assert row_doc("granted", registration_failed: reason)
               |> LazyHTML.query(~s([data-role="notification-state"]))
               |> LazyHTML.attribute("data-permission") == ["granted"]
      end

      # And it cannot conjure a row in a state where it has no meaning: the
      # browser has not granted, so there was no registration to fail.
      for state <- ["unknown", "unsupported", "prompt", "denied"],
          reason <- [:no_participant, :subscribe_failed] do
        row = row_doc(state, registration_failed: reason)

        assert count(row, ~s([data-role="notification-state"][data-permission="granted"])) == 0,
               "expected no granted row for push_permission=#{state} reason=#{reason}"
      end
    end

    # Tailwind compiles `hover:` and `group-hover:` inside
    # `@media (hover: hover)`, which never matches on a touch device, so a
    # visibility rule written that way makes the row absent on a phone rather
    # than merely quiet.
    test "no hover variant gates anything here" do
      for reason <- [:no_participant, :subscribe_failed] do
        doc = row_doc("granted", registration_failed: reason)

        # Control: without this the refutes below are satisfied by an empty
        # string, which is exactly what a variant that renders nothing produces.
        assert count(doc, ~s([data-role="notification-state"])) == 1

        html =
          doc
          |> LazyHTML.query(~s([data-role="notification-state"]))
          |> LazyHTML.to_html()

        refute html =~ "hover:"
        refute html =~ "group-hover"
        refute html =~ "opacity-0"
      end
    end

    # The colour is decoration. `--color-warning` is roughly 1.9:1 against
    # base-100 and would fail WCAG 1.4.11 if any meaning depended on seeing
    # it, so the words and the glyph carry the message at full strength.
    # `--color-error` stays reserved for real errors; notifications not being
    # on is a configuration state.
    test "uses the warning accent, never error, and never as the only signal" do
      for reason <- [:no_participant, :subscribe_failed] do
        html =
          row_doc("granted", registration_failed: reason)
          |> LazyHTML.query(~s([data-role="notification-state"]))
          |> LazyHTML.to_html()

        assert html =~ "border-l-warning"
        refute html =~ "error"
      end

      # The sentences survive with no colour at all, which is the actual test
      # of whether the colour is load-bearing.
      assert row_text(row_doc("granted", registration_failed: :no_participant)) =~
               @no_participant_first

      assert row_text(row_doc("granted", registration_failed: :subscribe_failed)) =~
               @subscribe_failed_first
    end
  end

  # --- the pair the anti-vacuity requirement turns on -------------------

  test "prompt renders exactly one row WITH an action; denied exactly one WITHOUT" do
    prompt = row_doc("prompt")
    denied = row_doc("denied")

    # Positive control on BOTH halves: each state renders a real row. Without
    # these two, the "denied has no button" assertion below would pass just as
    # happily against a component that renders nothing at all.
    assert count(prompt, ~s([data-role="notification-state"])) == 1
    assert count(denied, ~s([data-role="notification-state"])) == 1

    assert prompt
           |> LazyHTML.query(~s([data-role="notification-state"]))
           |> LazyHTML.attribute("data-permission") == ["prompt"]

    assert denied
           |> LazyHTML.query(~s([data-role="notification-state"]))
           |> LazyHTML.attribute("data-permission") == ["denied"]

    # ...and they differ in exactly one way.
    assert count(prompt, ~s([phx-click="enable_notifications"])) == 1
    assert count(denied, ~s([phx-click="enable_notifications"])) == 0

    # No control of any kind on the denied row, not merely no
    # `enable_notifications` one — a differently-named dead control is the
    # same defect. No web API can re-prompt after a browser-level block, so
    # any button here would silently do nothing every time it was pressed.
    assert count(denied, "button") == 0
    assert count(denied, "a") == 0
  end

  test "the prompt row carries the design's copy and the primary action slot" do
    doc = row_doc("prompt")

    text = doc |> LazyHTML.query(~s([data-role="notification-state"])) |> LazyHTML.text()
    assert text =~ "Notifications are off for this browser."
    assert text =~ "Turn them on to hear about mentions and replies when Burrow is not open."

    [class] =
      doc
      |> LazyHTML.query(~s([data-role="notification-enable"]))
      |> LazyHTML.attribute("class")

    assert class =~ "btn-primary"
    refute class =~ "btn-info"
    refute class =~ ~r/#[0-9a-fA-F]{3,6}/

    text = doc |> LazyHTML.query(~s([data-role="notification-enable"])) |> LazyHTML.text()
    assert String.trim(text) == "Turn on notifications"
  end

  test "the denied row explains the block and how to undo it, with no action" do
    doc = row_doc("denied")

    text = doc |> LazyHTML.query(~s([data-role="notification-state"])) |> LazyHTML.text()
    assert text =~ "Your browser is blocking notifications from Burrow."
    assert text =~ "Allow them in your browser's site settings for this page."

    # Guarded here as well as in the prompt/denied pair above. Putting an
    # enable button back into this row is the single most likely regression —
    # it reads as a consistency fix — and it does nothing every time.
    assert count(doc, "button") == 0

    # The instruction line is utility type at 60%, per the design.
    classes =
      doc
      |> LazyHTML.query(~s([data-role="notification-state"] p))
      |> LazyHTML.attribute("class")
      |> Enum.join(" ")

    assert classes =~ "text-xs"
    assert classes =~ "text-subtle"
  end

  # --- colour, announcement, and what the row must NOT carry ------------

  test "the accent uses the warning slot, never error, and never a raw hex" do
    [class] =
      row_doc("denied")
      |> LazyHTML.query(~s([data-role="notification-state"]))
      |> LazyHTML.attribute("class")

    # --color-error is reserved for real failures; notifications being off is
    # a configuration state and must not compete with them.
    assert class =~ "border-l-warning"
    refute class =~ "error"
    refute class =~ ~r/#[0-9a-fA-F]{3,6}/

    # prompt is an offer, not an exception, so it gets no accent bar.
    [prompt_class] =
      row_doc("prompt")
      |> LazyHTML.query(~s([data-role="notification-state"]))
      |> LazyHTML.attribute("class")

    refute prompt_class =~ "border-l-warning"
  end

  test "the whole subtree uses semantic slots — no raw hex anywhere" do
    for permission <- ["prompt", "denied"] do
      classes =
        row_doc(permission)
        |> LazyHTML.query(~s([data-role="notification-state"] *))
        |> LazyHTML.attribute("class")
        |> Enum.join(" ")

      refute classes =~ ~r/#[0-9a-fA-F]{3,6}/,
             "raw hex found in the row for push_permission=#{permission}"
    end
  end

  test "nothing in the row is revealed by a hover variant" do
    # `hover:` / `group-hover:` compile inside `@media (hover: hover)`, which
    # never matches on touch, so a control gated that way goes invisible
    # rather than quiet (2026-08-11 record around the `.channel-row-*` rules
    # in app.css). Nothing here is hover-revealed; this keeps it that way.
    for permission <- ["prompt", "denied"] do
      doc = row_doc(permission)

      classes =
        [~s([data-role="notification-state"]), ~s([data-role="notification-state"] *)]
        |> Enum.flat_map(&(doc |> LazyHTML.query(&1) |> LazyHTML.attribute("class")))
        |> Enum.join(" ")

      refute classes =~ "hover:hidden"
      refute classes =~ "group-hover:"
      refute classes =~ "hover:opacity"
    end
  end

  test "the row announces on appearance — it flips in after the hook reports" do
    for permission <- ["prompt", "denied"] do
      assert row_doc(permission)
             |> LazyHTML.query(~s([data-role="notification-state"]))
             |> LazyHTML.attribute("role") == ["status"],
             "expected role=status for push_permission=#{permission}"
    end
  end

  test "the row carries no count badge — this is a state, not a number" do
    for permission <- ["prompt", "denied"] do
      doc = row_doc(permission)

      assert count(doc, ~s([data-role="notification-state"] .badge)) == 0
      assert count(doc, ~s([data-role="inbox-badge"])) == 0

      # And no digits anywhere in the row's own text.
      text = doc |> LazyHTML.query(~s([data-role="notification-state"])) |> LazyHTML.text()

      refute text =~ ~r/\d/,
             "expected no numerals on the row for push_permission=#{permission}"
    end
  end

  test "the denied row uses the bell-slash glyph, the prompt row the plain bell" do
    assert count(row_doc("prompt"), ".hero-bell") == 1
    assert count(row_doc("denied"), ".hero-bell-slash") == 1
  end

  # --- naming the browser (Robin's review, 2026-08-13) -------------------
  #
  # "Allow them in your browser's site settings" is wrong or useless for most
  # people who read it: they do not know their browser has site settings, let
  # alone where. The row now names the browser and gives the actual clicks.

  describe "browser-specific instruction" do
    test "each recognised family renders its own instruction, naming itself" do
      chrome = row_text(row_doc("denied", user_agent: @chrome_ua))
      edge = row_text(row_doc("denied", user_agent: @edge_ua))
      safari = row_text(row_doc("denied", user_agent: @safari_ua))
      firefox = row_text(row_doc("denied", user_agent: @firefox_ua))

      assert chrome =~
               "In Chrome, click the icon at the left of the address bar, then Notifications, then Allow."

      assert edge =~
               "In Edge, click the icon at the left of the address bar, then Notifications, then Allow."

      assert safari =~
               "In Safari, open Settings, then Websites, then Notifications, and allow this site."

      assert firefox =~
               "In Firefox, click the padlock in the address bar, then clear the notifications permission."

      # None of them falls through to the generic line, and no two families
      # share an instruction. Edge is Chromium and claims "Chrome" in its own
      # user agent, so the ordering that separates them is the fragile part.
      for {name, text} <- [
            {"chrome", chrome},
            {"edge", edge},
            {"safari", safari},
            {"firefox", firefox}
          ] do
        refute text =~ @generic_line,
               "expected #{name} to render its own line, not the generic one"
      end

      assert [chrome, edge, safari, firefox] |> Enum.uniq() |> length() == 4
    end

    test "the family lands on the row as data-browser" do
      for {ua, family} <- [
            {@chrome_ua, "chrome"},
            {@edge_ua, "edge"},
            {@safari_ua, "safari"},
            {@firefox_ua, "firefox"}
          ] do
        assert row_doc("denied", user_agent: ua)
               |> LazyHTML.query(~s([data-role="notification-state"]))
               |> LazyHTML.attribute("data-browser") == [family]
      end
    end

    test "an unrecognised user agent falls back to the generic line" do
      # The fallback is the correct default, not a failure: a wrong set of
      # clicks is worse than a vague but true sentence.
      for {label, ua} <- [
            {"nonsense", @nonsense_ua},
            {"no user agent at all", nil},
            {"empty string", ""},
            # Chromium skins whose UI does not match Chrome's, and iOS
            # re-skins where the permission lives in the iOS Settings app
            # rather than in any site menu.
            {"opera", @opera_ua},
            {"chrome on ios", @ios_chrome_ua},
            {"safari on ios", @ios_safari_ua}
          ] do
        text = row_text(row_doc("denied", user_agent: ua))

        assert text =~ @generic_line, "expected the generic line for #{label}"
        refute text =~ "In Chrome,", "expected no Chrome steps for #{label}"
        refute text =~ "In Safari,", "expected no Safari steps for #{label}"
        refute text =~ "In Firefox,", "expected no Firefox steps for #{label}"
        refute text =~ "In Edge,", "expected no Edge steps for #{label}"
      end
    end

    test "the case the browser cannot fix is named once, on the site-settings row" do
      # If the OS is silencing the browser, every instruction above is a dead
      # end. Said on the rows that give site-settings steps...
      for ua <- [@chrome_ua, @safari_ua, @firefox_ua, @edge_ua, @nonsense_ua, nil] do
        assert row_text(row_doc("denied", user_agent: ua)) =~ @os_line
      end

      # ...and NOT on the auto-denied row, where the cause is already known
      # and a fourth line would bury the sentence that matters.
      refute row_text(row_doc("denied", user_agent: @chrome_ua, auto_denied: true)) =~ @os_line
    end
  end

  # --- the browser refused without ever asking --------------------------
  #
  # Robin clicked enable in a private window. Chrome refuses a notification
  # prompt there outright, so she was never shown a dialog and was then told
  # to change a site setting that was not the problem. The hook reports that
  # refusal by TIMING (a human choosing Block cannot answer in single-digit
  # milliseconds), and it arrives as a flag ALONGSIDE the permission, never as
  # a sixth permission value.

  describe "auto-denied" do
    test "the row says the browser never asked, and drops the site-settings copy" do
      doc = row_doc("denied", user_agent: @chrome_ua, auto_denied: true)
      text = row_text(doc)

      assert text =~ "Your browser turned notifications down without asking you."

      assert text =~
               "That usually means a private window, or notifications are switched off for every site."

      # The whole point: the site-settings instruction is wrong here, so it
      # must be gone: the generic one AND the browser-specific one.
      refute text =~ @generic_line
      refute text =~ "In Chrome,"
      refute text =~ "Your browser is blocking notifications from Burrow."
    end

    test "without the flag the same permission renders the site-settings copy" do
      # The control for the test above: identical inputs but for the flag.
      text = row_text(row_doc("denied", user_agent: @chrome_ua))

      assert text =~ "Your browser is blocking notifications from Burrow."
      assert text =~ "In Chrome,"
      refute text =~ "Your browser turned notifications down without asking you."
    end

    test "the flag lands on the row as data-auto-denied" do
      assert row_doc("denied", auto_denied: true)
             |> LazyHTML.query(~s([data-role="notification-state"]))
             |> LazyHTML.attribute("data-auto-denied") == ["true"]

      assert row_doc("denied")
             |> LazyHTML.query(~s([data-role="notification-state"]))
             |> LazyHTML.attribute("data-auto-denied") == ["false"]
    end

    test "the flag does not become a sixth permission value" do
      # `data-permission` is the five-value vocabulary other code keys on.
      # The extra fact rides beside it; it must never rename the state.
      assert row_doc("denied", auto_denied: true)
             |> LazyHTML.query(~s([data-role="notification-state"]))
             |> LazyHTML.attribute("data-permission") == ["denied"]

      # And it cannot conjure a row in a state that renders nothing.
      for state <- ["unknown", "unsupported", "granted"] do
        assert count(row_doc(state, auto_denied: true), ~s([data-role="notification-state"])) == 0,
               "expected auto_denied to render nothing for push_permission=#{state}"
      end
    end
  end

  # --- the invariant every variant has to keep --------------------------

  test "the blocked state renders zero controls in EVERY variant" do
    # No web API re-prompts after a browser-level denial, so a button here
    # does nothing every time it is pressed, the defect this whole task
    # exists to remove. Guarded once per variant rather than once overall,
    # because the auto-denied copy is the one most likely to attract a
    # helpful "Try again" button later.
    for ua <- [@chrome_ua, @edge_ua, @safari_ua, @firefox_ua, @nonsense_ua, nil],
        auto_denied <- [true, false] do
      doc = row_doc("denied", user_agent: ua, auto_denied: auto_denied)
      label = "user_agent=#{inspect(ua)} auto_denied=#{auto_denied}"

      # Positive control first: an absence assertion over a row that never
      # rendered would pass on nothing at all.
      assert count(doc, ~s([data-role="notification-state"])) == 1,
             "expected exactly one row for #{label}"

      assert count(doc, "button") == 0, "expected no button for #{label}"
      assert count(doc, "a") == 0, "expected no link for #{label}"
      assert count(doc, "input") == 0, "expected no input for #{label}"
      assert count(doc, ~s([phx-click])) == 0, "expected nothing clickable for #{label}"
    end
  end

  test "every variant keeps the warning slot, never error, never a raw hex" do
    for ua <- [@chrome_ua, @edge_ua, @safari_ua, @firefox_ua, @nonsense_ua, nil],
        auto_denied <- [true, false] do
      doc = row_doc("denied", user_agent: ua, auto_denied: auto_denied)
      label = "user_agent=#{inspect(ua)} auto_denied=#{auto_denied}"

      classes =
        [~s([data-role="notification-state"]), ~s([data-role="notification-state"] *)]
        |> Enum.flat_map(&(doc |> LazyHTML.query(&1) |> LazyHTML.attribute("class")))
        |> Enum.join(" ")

      assert classes =~ "border-l-warning", "expected the warning bar for #{label}"
      refute classes =~ "error", "expected no error slot for #{label}"
      refute classes =~ ~r/#[0-9a-fA-F]{3,6}/, "raw hex found for #{label}"
      refute classes =~ "group-hover:", "hover-gated class found for #{label}"
    end
  end

  # --- inside Burrow Android (task 01a10d8e stage 6) --------------------

  # The Android WebView's user agent says Chrome, which is what put "click the
  # icon at the left of the address bar" in front of an app with no address bar.
  @android_webview_ua "Mozilla/5.0 (Linux; Android 15; sdk_gphone64_x86_64 Build/AE3A.240806.043; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.6367.219 Mobile Safari/537.36"

  describe "inside Burrow Android" do
    test "denied offers the re-ask: one row, one enable button, no browser steps" do
      for auto_denied <- [false, true] do
        doc =
          row_doc("denied",
            native_platform: "android",
            user_agent: @android_webview_ua,
            auto_denied: auto_denied
          )

        assert count(doc, ~s([data-role="notification-state"])) == 1
        assert count(doc, ~s([phx-click="enable_notifications"])) == 1
        assert count(doc, "button") == 1

        row = LazyHTML.query(doc, ~s([data-role="notification-state"]))
        assert LazyHTML.attribute(row, "data-permission") == ["denied"]
        assert LazyHTML.attribute(row, "data-native") == ["android"]

        text = row_text(doc)
        assert text =~ "Notifications are off for Burrow on this phone."
        refute text =~ "address bar"
        refute text =~ "Chrome"
        refute text =~ "browser"
      end
    end

    test "prompt renders the same native row, never the browser one" do
      doc = row_doc("prompt", native_platform: "android", user_agent: @android_webview_ua)

      assert count(doc, ~s([data-role="notification-state"])) == 1
      assert count(doc, ~s([phx-click="enable_notifications"])) == 1
      refute row_text(doc) =~ "this browser"
    end

    test "granted, unknown and unsupported still render nothing" do
      for state <- ["granted", "unknown", "unsupported"] do
        doc = row_doc(state, native_platform: "android")
        assert count(doc, ~s([data-role="notification-state"])) == 0, state
      end
    end

    test "iOS and the browser keep the button-less denied row" do
      for platform <- ["ios", nil] do
        doc = row_doc("denied", native_platform: platform, user_agent: @chrome_ua)
        assert count(doc, ~s([data-role="notification-state"])) == 1
        assert count(doc, "button") == 0, inspect(platform)
        assert row_text(doc) =~ "Your browser is blocking notifications from Burrow."
      end
    end
  end
end

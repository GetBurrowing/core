defmodule Platform.People.PrivacyTest do
  use ExUnit.Case, async: true

  alias Platform.People.Privacy

  test "phone numbers in three shapes are redacted" do
    text = "call 904-555-0100 or (904) 555 0100 or +44 20 7946 0958 today"

    assert {scrubbed, [%{kind: :phone, count: 3}]} = Privacy.scrub(text)
    assert scrubbed == "call [REDACTED: phone] or [REDACTED: phone] or [REDACTED: phone] today"
    refute scrubbed =~ ~r/\d{3}/
  end

  test "a street address is redacted" do
    text = "she lives at 1200 Harbor View Lane, Springfield 32202 and 42 Elm St. in town"

    assert {scrubbed, [%{kind: :address, count: 2}]} = Privacy.scrub(text)
    assert scrubbed == "she lives at [REDACTED: address] and [REDACTED: address] in town"
  end

  test "a Luhn card number is redacted, a UUID and a sha are not" do
    uuid = "01a1aa47-837b-7000-ba1b-83ab03ec3265"
    sha = "4a3900748f2a9c1e0b7d6e5f4a3b2c1d0e9f8a7b"
    text = "card 4539 1488 0343 6467 id #{uuid} sha #{sha} iban GB82 WEST 1234 5698 7654 32"

    assert {scrubbed, [%{kind: :financial, count: 2}]} = Privacy.scrub(text)

    assert scrubbed ==
             "card [REDACTED: financial] id #{uuid} sha #{sha} iban [REDACTED: financial]"

    # A 13-digit run that fails Luhn is left alone.
    assert {"ref 1234567890123", []} = Privacy.scrub("ref 1234567890123")

    # Money is only financial next to a salary/owes/paid/invoice/net-worth cue.
    assert {"her salary is [REDACTED: financial] a year", [%{kind: :financial, count: 1}]} =
             Privacy.scrub("her salary is $120,000 a year")

    assert {"the licence costs $12 a seat", []} = Privacy.scrub("the licence costs $12 a seat")
  end

  test "benign text is byte-identical" do
    text =
      "shipped 4a3900748f2a9c1e0b7d6e5f4a3b2c1d0e9f8a7b for 01a1aa47-837b-7000-ba1b-83ab03ec3265 " <>
        "on 2026-11-04 at 14:05, bumped to v1.20.4, 3 PRs open, meets at 10:30 on 2026-12-01"

    assert {^text, []} = Privacy.scrub(text)
    assert {"", []} = Privacy.scrub("")
  end

  test "trait language is detected and plain role text is not" do
    assert Privacy.trait_language?("Marisol is clearly the kind of person who ships")
    assert Privacy.trait_language?("he was Passive-Aggressive in the thread")
    assert Privacy.trait_language?("seems like a slow playing move")
    assert Privacy.trait_language?("motivated by status")

    refute Privacy.trait_language?("Marisol leads the platform team and owns the deploy pipeline")
    refute Privacy.trait_language?("2026-10-02 meeting: Deploy review [cite: msg-1]")
    # Whole words only: substrings do not count.
    refute Privacy.trait_language?("laziness is not a word on the list; nor is geniuses")
    refute Privacy.trait_language?("")
  end

  test "the subject-reads-it note states the contract" do
    note = Privacy.subject_reads_it_note()
    assert note =~ "OWN statements"
    assert note =~ "When in doubt, leave it out"
    assert note =~ "health, family, money"
  end
end

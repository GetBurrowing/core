defmodule PlatformWeb.TimeEntryTest do
  use ExUnit.Case, async: true

  alias PlatformWeb.TimeEntry

  doctest PlatformWeb.TimeEntry

  @accepted [
    {"1pm", ~T[13:00:00]},
    {"1 PM", ~T[13:00:00]},
    {"1:00 PM", ~T[13:00:00]},
    {"1:00p.m.", ~T[13:00:00]},
    {"13:00", ~T[13:00:00]},
    {"13", ~T[13:00:00]},
    {"00:30", ~T[00:30:00]},
    {"12am", ~T[00:00:00]},
    {"12pm", ~T[12:00:00]},
    {"13:00:00", ~T[13:00:00]},
    {"  9:45 a.m.  ", ~T[09:45:00]},
    {"11:30A", ~T[11:30:00]}
  ]

  @refused [
    {"01:00", :needs_meridiem},
    {"1:00", :needs_meridiem},
    {"12:00", :needs_meridiem},
    {"9", :needs_meridiem},
    {"", :blank},
    {"  ", :blank},
    {nil, :blank},
    {"25:00", :invalid},
    {"1:60", :invalid},
    {"13pm", :invalid},
    {"0am", :invalid},
    {"abc", :invalid}
  ]

  describe "parse/1 accepts" do
    for {input, expected} <- @accepted do
      test "#{inspect(input)} as #{expected}" do
        assert TimeEntry.parse(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end
  end

  describe "parse/1 refuses" do
    for {input, reason} <- @refused do
      test "#{inspect(input)} with #{reason}" do
        assert TimeEntry.parse(unquote(input)) == {:error, unquote(reason)}
      end
    end
  end

  describe "format/1" do
    test "writes 12-hour text with AM/PM" do
      assert TimeEntry.format(~T[13:00:00]) == "1:00 PM"
      assert TimeEntry.format(~T[00:15:00]) == "12:15 AM"
      assert TimeEntry.format(~T[12:00:00]) == "12:00 PM"
      assert TimeEntry.format(~T[10:07:00]) == "10:07 AM"
    end

    test "round-trips through parse/1 for every quarter hour of the day" do
      times = for hour <- 0..23, minute <- [0, 15, 30, 45], do: Time.new!(hour, minute, 0)

      assert length(times) == 96

      for time <- times do
        assert TimeEntry.parse(TimeEntry.format(time)) == {:ok, time},
               "#{inspect(time)} formatted as #{TimeEntry.format(time)}"
      end
    end
  end

  describe "message/2" do
    test "gives the shared inline copy" do
      assert TimeEntry.message(:start, :needs_meridiem) ==
               "Start time is incomplete — pick AM or PM."

      assert TimeEntry.message(:end, :needs_meridiem) ==
               "End time is incomplete — pick AM or PM."

      assert TimeEntry.message(:start, :invalid) == "Start time isn't a time — try 1:00 PM."
      assert TimeEntry.message(:end, :invalid) == "End time isn't a time — try 1:00 PM."
    end
  end
end

defmodule Chebit.HandbookTest do
  @moduledoc """
  Guards the format of `docs/HANDBOOK.md` and its copy for the landing.

  The MCP server (`mcp/chebit_mcp.exs`) and the landing (`landing/handbook.js`) find a
  practice by its heading `### N. Title` and its line `**Status:**`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @handbook File.read!(Path.join(@root, "docs/HANDBOOK.md"))
  @prefix "window.CHEBIT_HANDBOOK = "

  @sync """
  landing/handbook-data.js is not the current docs/HANDBOOK.md. Run from the root of the repository:

      mise exec -- elixir -e 'File.write!("landing/handbook-data.js", "window.CHEBIT_HANDBOOK = " <> JSON.encode!(File.read!("docs/HANDBOOK.md")) <> ";\\n")'
  """

  test "the practices are numbered from 1 with no gap" do
    ids =
      for [_all, id] <- Regex.scan(~r/^### (\d+)\. .+$/m, @handbook), do: String.to_integer(id)

    assert length(ids) >= 37
    assert ids == Enum.to_list(1..length(ids))
  end

  test "each practice has one status that the readers know" do
    practices = @handbook |> String.split(~r/^### \d+\. /m) |> tl()

    for practice <- practices do
      title = practice |> String.split("\n") |> hd()
      statuses = Regex.scan(~r/^\*\*Status:\*\* (Done|Partial|Not yet)/m, practice)

      assert length(statuses) == 1,
             "practice '#{title}' needs one line: **Status:** Done, Partial or Not yet"
    end
  end

  test "the copy for the landing is the current handbook" do
    data = File.read!(Path.join(@root, "landing/handbook-data.js"))

    assert String.starts_with?(data, @prefix), @sync

    json =
      data
      |> String.replace_prefix(@prefix, "")
      |> String.trim_trailing()
      |> String.trim_trailing(";")

    assert Jason.decode!(json) == @handbook, @sync
  end
end

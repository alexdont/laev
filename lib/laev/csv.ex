defmodule Laev.Csv do
  @moduledoc """
  Just enough CSV to read an export somebody downloaded.

  RFC 4180: fields separated by commas, any field may be quoted, a quoted field
  may contain commas and newlines, and a doubled quote inside one is a literal
  quote. That last rule is the reason this is a parser and not a `String.split`
  — an IMDb export has rows like `"Dog Day Afternoon"` and
  `"Animation, Sci-Fi"` in the same line, and a film called `The "Burbs` would
  quietly eat the rest of its row.

  Not a dependency, because a terminal application should not grow one for
  twenty lines, and not a general CSV library either: it reads a file into rows
  of strings and stops there.
  """

  @doc """
  Parse CSV text into rows of fields. The first row is usually a header; this
  does not treat it specially.

  A byte-order mark is dropped — exports from Windows carry one, and it would
  otherwise become part of the first column's name.
  """
  def rows(text) when is_binary(text) do
    text
    |> strip_bom()
    |> String.replace("\r\n", "\n")
    |> parse([], [], "", false)
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  # field: what has been read of the field in hand · quoted?: inside quotes
  defp parse(<<>>, rows, fields, field, _quoted?) do
    finish(rows, fields, field)
  end

  defp parse(<<?", ?", rest::binary>>, rows, fields, field, true),
    do: parse(rest, rows, fields, field <> ~s("), true)

  defp parse(<<?", rest::binary>>, rows, fields, field, quoted?),
    do: parse(rest, rows, fields, field, not quoted?)

  defp parse(<<?,, rest::binary>>, rows, fields, field, false),
    do: parse(rest, rows, [field | fields], "", false)

  defp parse(<<?\n, rest::binary>>, rows, fields, field, false),
    do: parse(rest, [Enum.reverse([field | fields]) | rows], [], "", false)

  defp parse(<<char::utf8, rest::binary>>, rows, fields, field, quoted?),
    do: parse(rest, rows, fields, field <> <<char::utf8>>, quoted?)

  # An invalid byte is kept rather than crashing the parse: one bad character in
  # a title is not a reason to refuse somebody's ten years of ratings.
  defp parse(<<byte, rest::binary>>, rows, fields, field, quoted?),
    do: parse(rest, rows, fields, field <> <<byte>>, quoted?)

  defp finish(rows, [], ""), do: Enum.reverse(rows)
  defp finish(rows, fields, field), do: Enum.reverse([Enum.reverse([field | fields]) | rows])

  @doc """
  Parse into maps keyed by the header row: `[%{"Const" => "tt0133093", …}]`.

  Rows with a different number of fields than the header are kept and zipped as
  far as they go, because a truncated last line is common and the rows above it
  are perfectly good.
  """
  def maps(text) when is_binary(text) do
    case rows(text) do
      [header | rest] -> Enum.map(rest, &Enum.zip(header, &1) |> Map.new())
      _ -> []
    end
  end
end

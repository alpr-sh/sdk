defmodule Alpr.Multipart do
  @moduledoc """
  The `multipart/form-data` body the photo calls send: one file and the text
  fields beside it, written by hand so the SDK depends on nothing.
  """

  @typedoc "A text field, or a file given as its bytes. A nil value is a field left out."
  @type part :: {:text, String.t(), term()} | {:file, String.t(), binary() | nil}

  @doc "The parts that were given: a field whose value is nil is left out."
  @spec compact([part()]) :: [part()]
  def compact(parts), do: Enum.reject(parts, fn {_kind, _name, value} -> is_nil(value) end)

  @doc """
  The body and its `Content-Type`, boundary included. A file is named and typed
  by what its first bytes say it is: see `image_type/1`.
  """
  @spec encode([part()]) :: {binary(), String.t()}
  def encode(parts) do
    boundary = "alpr-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    body =
      for part <- parts, into: "" do
        "--" <> boundary <> "\r\n" <> field(part)
      end

    {body <> "--" <> boundary <> "--\r\n", "multipart/form-data; boundary=" <> boundary}
  end

  @doc """
  The file name and content type of a photo: JPEG and PNG are what the API
  reads, and anything else goes as bytes for the API to refuse.
  """
  @spec image_type(binary()) :: {String.t(), String.t()}
  def image_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {"photo.jpg", "image/jpeg"}

  def image_type(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>),
    do: {"photo.png", "image/png"}

  def image_type(_data), do: {"photo", "application/octet-stream"}

  @doc "A text field's value as the API reads it: a number in its shortest decimal form."
  @spec text(term()) :: String.t()
  def text(value) when is_binary(value), do: value
  def text(value) when is_integer(value), do: Integer.to_string(value)
  def text(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  def text(value) when is_boolean(value), do: Atom.to_string(value)
  def text(value) when is_atom(value), do: Atom.to_string(value)

  defp field({:file, name, data}) when is_binary(data) do
    {filename, type} = image_type(data)

    "Content-Disposition: form-data; name=\"#{escape(name)}\"; filename=\"#{filename}\"\r\n" <>
      "Content-Type: #{type}\r\n\r\n" <> data <> "\r\n"
  end

  defp field({:file, name, _other}),
    do: raise(ArgumentError, "alpr: the #{name} must be the file's bytes, a binary")

  defp field({:text, name, value}),
    do: "Content-Disposition: form-data; name=\"#{escape(name)}\"\r\n\r\n#{text(value)}\r\n"

  # A field name sits between quotes in a header.
  defp escape(name), do: name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end

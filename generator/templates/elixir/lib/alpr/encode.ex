defmodule Alpr.Encode do
  @moduledoc false

  # A value as JSON writes it: params as their wire map, models as maps, lists
  # and maps of them walked.
  def value(%module{} = struct) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_map, 1),
      do: module.to_map(struct),
      else: struct |> Map.from_struct() |> value()
  end

  def value(values) when is_list(values), do: Enum.map(values, &value/1)

  def value(%{} = values),
    do: Map.new(values, fn {key, each} -> {to_string(key), value(each)} end)

  def value(other), do: other

  # Puts an optional field only when it was given.
  def put_optional(map, _wire, nil), do: map
  def put_optional(map, wire, value), do: Map.put(map, wire, value)
end

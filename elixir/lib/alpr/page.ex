defmodule Alpr.Page do
  @moduledoc "One page of a list: its items, and the cursor of the next page."

  @enforce_keys [:items]
  defstruct [:items, :next]

  @typedoc "`next` is the cursor to ask the next page with; nil on the last page."
  @type t(item) :: %__MODULE__{items: [item], next: String.t() | nil}
  @type t :: t(term())

  @doc "Builds a page from the API's `{\"data\": [...], \"next\": cursor}`, each item through `item`."
  @spec from_map(map(), (map() -> item)) :: t(item) when item: term()
  def from_map(%{} = data, item) do
    next =
      case data["next"] do
        next when is_binary(next) and next != "" -> next
        _ -> nil
      end

    %__MODULE__{items: Enum.map(data["data"] || [], item), next: next}
  end

  @doc """
  Walks pages from the cursor `first` (the newest page when nil) until the
  last one, emitting every item; `fetch` answers the page of the cursor it is
  given. It stops when the cursor does not move, which would ask for the same
  page forever, and at the first refusal, which is raised as `Alpr.Error`
  while the stream runs.
  """
  @spec stream(
          String.t() | nil,
          (String.t() | nil -> {:ok, t(item)} | {:error, Alpr.Error.t()})
        ) :: Enumerable.t(item)
        when item: term()
  def stream(first, fetch) do
    Stream.resource(
      fn -> {:fetch, first} end,
      fn
        :done ->
          {:halt, :done}

        {:fetch, cursor} ->
          case fetch.(cursor) do
            {:ok, %__MODULE__{items: items, next: next}} when next in [nil, ""] ->
              {items, :done}

            {:ok, %__MODULE__{items: items, next: ^cursor}} ->
              {items, :done}

            {:ok, %__MODULE__{items: items, next: next}} ->
              {items, {:fetch, next}}

            {:error, error} ->
              raise error
          end
      end,
      fn _state -> :ok end
    )
  end
end

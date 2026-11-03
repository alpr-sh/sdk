defmodule Alpr.Page do
  @moduledoc "One page of a list, and where the list ends."

  @enforce_keys [:items, :pagination]
  defstruct [:items, :pagination]

  @type t(item) :: %__MODULE__{items: [item], pagination: Alpr.Pagination.t()}
  @type t :: t(term())

  @doc "Builds a page from the API's map, each item through `item`."
  @spec from_map(map(), (map() -> item)) :: t(item) when item: term()
  def from_map(%{} = data, item) do
    %__MODULE__{
      items: Enum.map(data["items"] || [], item),
      pagination: Alpr.Pagination.from_map(Map.fetch!(data, "pagination"))
    }
  end

  @doc """
  Walks pages from `first` (1 when nil) until the last one, as Polar's SDKs
  do, emitting every item; `fetch` answers the page it is given. A refusal
  raises `Alpr.Error` while the stream runs.
  """
  @spec stream(pos_integer() | nil, (pos_integer() -> {:ok, t(item)} | {:error, Alpr.Error.t()})) ::
          Enumerable.t(item)
        when item: term()
  def stream(first, fetch) do
    Stream.resource(
      fn -> max(first || 1, 1) end,
      fn
        :done ->
          {:halt, :done}

        page ->
          case fetch.(page) do
            {:ok, %__MODULE__{items: items, pagination: pagination}} ->
              {items, if(page >= pagination.max_page, do: :done, else: page + 1)}

            {:error, error} ->
              raise error
          end
      end,
      fn _page -> :ok end
    )
  end
end

defmodule Alpr.Error do
  @moduledoc """
  A request the API refused.

  `code` is the API's: `invalid_credential`, `forbidden`, `not_found`,
  `invalid_request`, `conflict`, `idempotency_conflict`, `body_too_large` or
  `unavailable`. `message` is the API's explanation, `fields` says, for
  `invalid_request`, what is wrong with each field, and `retry_after` is how
  many seconds to wait on a 429.

  A request that never got an answer has no `status` and the code `transport`.
  """

  defexception [:status, code: "", message: "", fields: %{}, retry_after: nil]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          code: String.t(),
          message: String.t(),
          fields: %{optional(String.t()) => [String.t()]},
          retry_after: non_neg_integer() | nil
        }

  @impl true
  def message(%__MODULE__{status: status, code: code, message: ""}),
    do: "alpr: #{status} #{code}"

  def message(%__MODULE__{status: status, code: code, message: message}),
    do: "alpr: #{status} #{code}: #{message}"

  @doc "The error a response with a status of 300 or more is."
  @spec from_response(non_neg_integer(), [{String.t(), String.t()}], binary()) :: t()
  def from_response(status, headers, body) do
    data =
      case JSON.decode(body) do
        {:ok, %{} = data} -> data
        # A refusal without a JSON body is still a refusal.
        _ -> %{}
      end

    %__MODULE__{
      status: status,
      code: string(data["error"]),
      message: string(data["message"]),
      fields: data["fields"] || %{},
      retry_after: retry_after(headers)
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp retry_after(headers) do
    with {_name, value} <- List.keyfind(headers, "retry-after", 0),
         {seconds, ""} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end
end

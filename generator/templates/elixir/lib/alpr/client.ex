defmodule Alpr.Client do
  @moduledoc """
  Alpr.sh's API with one workspace's API key.

  The key (`alpr_live_…`) says the workspace and the scopes its calls may use.

      client = Alpr.Client.new(System.fetch_env!("ALPR_API_KEY"))
      {:ok, cameras} = Alpr.Cameras.list(client)
  """

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    base_url: Alpr.default_base_url(),
    timeout: 30_000,
    transport: &Alpr.Client.httpc/5
  ]

  @typedoc """
  Sends one request: `(method, url, headers, body, timeout_ms)` answers
  `{:ok, {status, headers_in_lower_case, body}}` or `{:error, reason}`.
  """
  @type transport ::
          (String.t(), String.t(), [{String.t(), String.t()}], binary() | nil, timeout() ->
             {:ok, {non_neg_integer(), [{String.t(), String.t()}], binary()}} | {:error, term()})

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: timeout(),
          transport: transport()
        }

  @doc """
  A client for the workspace `api_key` belongs to.

  Options: `:base_url` (another address, such as a local server: https, or
  http only for localhost, 127.0.0.0/8 and ::1, or `ArgumentError`), `:timeout`
  in milliseconds (30 seconds) and `:transport` (see `t:transport/0`).
  """
  @spec new(String.t(), keyword()) :: t()
  def new(api_key, opts \\ []) when is_binary(api_key) do
    base_url =
      opts |> Keyword.get(:base_url, Alpr.default_base_url()) |> String.trim_trailing("/")

    check_base_url!(base_url)

    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: Keyword.get(opts, :timeout, 30_000),
      transport: Keyword.get(opts, :transport, &__MODULE__.httpc/5)
    }
  end

  @doc """
  Calls the API and answers the JSON it decoded.

  Options: `:query` (a keyword list; a nil or empty value is left out),
  `:multipart` (the parts of `Alpr.Multipart`) and `:api_key`, another
  workspace's key for this call. A redirect is never followed, so the key
  cannot travel: the 3xx is the answer, and an `Alpr.Error`.
  """
  @spec request(t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Alpr.Error.t()}
  def request(%__MODULE__{} = client, method, path, opts \\ []) do
    {body, content_type} =
      case opts[:multipart] do
        nil -> {nil, nil}
        parts -> Alpr.Multipart.encode(parts)
      end

    headers =
      [
        {"Authorization", "Bearer " <> key(opts[:api_key], client.api_key)},
        {"Accept", "application/json"},
        {"User-Agent", "alpr-elixir/" <> Alpr.version()}
      ]
      |> put_header("Content-Type", content_type)

    url = client.base_url <> path <> query(opts[:query])

    case client.transport.(method, url, headers, body, client.timeout) do
      {:ok, {204, _response_headers, _raw}} ->
        {:ok, nil}

      {:ok, {status, response_headers, raw}} when status >= 300 ->
        {:error, Alpr.Error.from_response(status, response_headers, raw)}

      {:ok, {status, _response_headers, raw}} ->
        case JSON.decode(raw) do
          {:ok, data} ->
            {:ok, data}

          {:error, _reason} ->
            {:error,
             %Alpr.Error{
               status: status,
               code: "invalid_response",
               message: "the answer is not JSON"
             }}
        end

      {:error, reason} ->
        {:error, %Alpr.Error{status: nil, code: "transport", message: inspect(reason)}}
    end
  end

  @doc false
  # A path parameter, escaped.
  @spec segment(String.t()) :: String.t()
  def segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp key(override, _default) when is_binary(override) and override != "", do: override
  defp key(_override, default), do: default

  # The base URL must be https; http is accepted only for localhost,
  # 127.0.0.0/8 and ::1.
  defp check_base_url!(base_url) do
    %URI{scheme: scheme, host: host} = URI.parse(base_url)
    scheme = String.downcase(scheme || "")
    host = String.downcase(host || "")

    loopback? =
      host == "localhost" or
        match?(
          {:ok, {127, _, _, _}},
          :inet.parse_address(String.to_charlist(host))
        ) or
        match?(
          {:ok, {0, 0, 0, 0, 0, 0, 0, 1}},
          :inet.parse_address(String.to_charlist(host))
        )

    unless scheme == "https" or (scheme == "http" and loopback?) do
      raise ArgumentError,
            "alpr: the base URL must be https (http is accepted only for localhost, 127.0.0.0/8 and ::1), so the API key is never sent in clear text"
    end
  end

  defp put_header(headers, _name, value) when value in [nil, false, ""], do: headers
  defp put_header(headers, name, value), do: headers ++ [{name, value}]

  defp query(nil), do: ""

  defp query(values) do
    case Enum.reject(values, fn {_name, value} -> value in [nil, ""] end) do
      [] -> ""
      kept -> "?" <> URI.encode_query(kept)
    end
  end

  @doc """
  The standard library's HTTP, `:httpc`, so the SDK depends on nothing. HTTPS
  verifies the server against the operating system's certificates.
  """
  @spec httpc(String.t(), String.t(), [{String.t(), String.t()}], binary() | nil, timeout()) ::
          {:ok, {non_neg_integer(), [{String.t(), String.t()}], binary()}} | {:error, term()}
  def httpc(method, url, headers, body, timeout) do
    {:ok, _started} = Application.ensure_all_started([:inets, :ssl])
    {content_type, headers} = List.keytake(headers, "Content-Type", 0) || {nil, headers}

    headers =
      for {name, value} <- headers, do: {String.to_charlist(name), String.to_charlist(value)}

    url = String.to_charlist(url)

    request =
      case {body, content_type} do
        {nil, _} when method in ["GET", "DELETE"] -> {url, headers}
        {nil, _} -> {url, headers, ~c"", ""}
        {body, {_name, type}} -> {url, headers, String.to_charlist(type), body}
      end

    options = [timeout: timeout, connect_timeout: timeout, autoredirect: false, ssl: ssl(url)]

    case :httpc.request(verb(method), request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, raw}} ->
        {:ok,
         {status, for({name, value} <- response_headers, do: {to_string(name), to_string(value)}),
          raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verb("GET"), do: :get
  defp verb("POST"), do: :post
  defp verb("PUT"), do: :put
  defp verb("PATCH"), do: :patch
  defp verb("DELETE"), do: :delete

  defp ssl(~c"https://" ++ _rest) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl(_url), do: []
end

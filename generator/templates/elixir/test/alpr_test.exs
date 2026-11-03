# Alpr.sh's Elixir SDK tests, with nothing to install: mix test

defmodule AlprTest.Server do
  @moduledoc false

  # A local HTTP server for one test. Every request is sent to the test
  # process as `{tag, request}` and answered with what `handler` returns:
  # `{status, body, headers}`. It speaks the real protocol, so the SDK's own
  # HTTP client is the one under test.
  def start(tag, handler) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept(listen, test, tag, handler) end)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listen) end)
    "http://127.0.0.1:#{port}"
  end

  defp accept(listen, test, tag, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, test, tag, handler) end)
        accept(listen, test, tag, handler)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, test, tag, handler) do
    request = read(socket, "")
    send(test, {tag, request})
    {status, body, headers} = handler.(request)
    body = body || ""

    head =
      ["HTTP/1.1 #{status} Answer", "Content-Length: #{byte_size(body)}", "Connection: close"] ++
        for {name, value} <- headers, do: "#{name}: #{value}"

    :gen_tcp.send(socket, Enum.join(head, "\r\n") <> "\r\n\r\n" <> body)
    :gen_tcp.close(socket)
  end

  defp read(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [line | lines] = String.split(head, "\r\n")
        [method, target | _version] = String.split(line, " ")

        headers =
          Map.new(lines, fn each ->
            [name, value] = String.split(each, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")

        %{
          method: method,
          target: target,
          uri: URI.parse(target),
          headers: headers,
          body: read_body(socket, rest, length)
        }

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read(socket, buffer <> more)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> more, length)
  end
end

defmodule AlprTest do
  use ExUnit.Case, async: true

  @key "alpr_live_" <> "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  # JPEG and PNG start with the bytes the API tells them by.
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01>>
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, "IHDR">>

  @recognized ~S|{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}|

  # A client of a local server that answers each request with `handler`.
  defp client(handler) do
    Alpr.new(@key, base_url: AlprTest.Server.start(:request, handler))
  end

  defp requests(tag \\ :request) do
    receive do
      {^tag, request} -> [request | requests(tag)]
    after
      0 -> []
    end
  end

  defp query(request), do: URI.decode_query(request.uri.query || "")

  # The parts of a multipart body: name, file name, content type and data.
  defp parts(request) do
    "multipart/form-data; boundary=" <> boundary = request.headers["content-type"]
    [_before, rest] = :binary.split(request.body, "--" <> boundary <> "\r\n")
    [last, _after] = :binary.split(rest, "\r\n--" <> boundary <> "--\r\n")

    for part <- :binary.split(last, "\r\n--" <> boundary <> "\r\n", [:global]) do
      [head, data] = :binary.split(part, "\r\n\r\n")
      [_, name] = Regex.run(~r/name="([^"]*)"/, head)

      %{
        name: name,
        filename: Regex.run(~r/filename="([^"]*)"/, head) |> List.wrap() |> List.last(),
        type: Regex.run(~r/Content-Type: (.*)/, head) |> List.wrap() |> List.last(),
        data: data
      }
    end
  end

  defp part(request, name), do: Enum.find(parts(request), &(&1.name == name))

  test "a call carries the key, the headers and no idempotency key, and unwraps the list" do
    alpr =
      client(fn _request ->
        {200,
         ~S|{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}|,
         []}
      end)

    assert {:ok, [first, second]} = Alpr.Cameras.list(alpr)
    assert %Alpr.Camera{id: "cam_1", enabled: true, name: "Portão", reading_area: nil} = first

    assert %Alpr.Camera{
             id: "cam_2",
             reading_area: %Alpr.ReadingArea{
               box: %Alpr.ReadingAreaBox{x: 0.1, y: 0.2, width: 0.5, height: 0.5},
               points: [[0.1, 0.2], [0.6, 0.2], [0.6, 0.7]]
             }
           } = second

    assert [seen] = requests()
    assert seen.method == "GET"
    assert seen.uri.path == "/api/v1/cameras"
    assert seen.headers["authorization"] == "Bearer " <> @key
    assert seen.headers["accept"] == "application/json"
    assert String.starts_with?(seen.headers["user-agent"], "alpr-elixir/")
    refute Map.has_key?(seen.headers, "idempotency-key")
  end

  test "a photo goes as multipart" do
    alpr = client(fn _request -> {200, @recognized, []} end)

    assert {:ok, result} =
             Alpr.Photos.recognize(alpr, %Alpr.PhotosRecognizeParams{
               image: @jpeg,
               lpr_confidence: 0.5
             })

    assert result.credits_remaining == 41

    assert [%Alpr.RecognizedPlate{plate: "BRA2E19", conf: 97.3, coordinate_left: 120}] =
             result.plates

    assert hd(result.plates).char_confs =~ "0.99"

    assert [seen] = requests()
    assert seen.method == "POST"
    assert seen.uri.path == "/api/v1/recognize"
    assert "multipart/form-data; boundary=" <> _ = seen.headers["content-type"]

    image = part(seen, "image")
    assert image.data == @jpeg
    assert image.filename == "photo.jpg"
    assert image.type == "image/jpeg"
    assert part(seen, "lpr_confidence").data == "0.5"
    assert part(seen, "lpr_confidence").filename == nil
    assert part(seen, "min_ocr_confidence") == nil
  end

  test "a photo is named by its bytes" do
    alpr =
      client(fn _request ->
        {200, ~S|{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}|, []}
      end)

    for {data, filename, type} <- [
          {@jpeg, "photo.jpg", "image/jpeg"},
          {@png, "photo.png", "image/png"},
          {"not an image", "photo", "application/octet-stream"}
        ] do
      assert {:ok, %Alpr.PhotoDetection{image_width: 20, plates: []}} =
               Alpr.Photos.detect(alpr, image: data)

      assert [seen] = requests()
      assert seen.uri.path == "/api/v1/detect"
      image = part(seen, "image")
      assert {image.data, image.filename, image.type} == {data, filename, type}
    end
  end

  test "an optional number is written in its shortest decimal form" do
    alpr = client(fn _request -> {200, @recognized, []} end)

    assert {:ok, _result} =
             Alpr.Photos.recognize(alpr, image: @png, lpr_confidence: 0.25, min_ocr_confidence: 1)

    assert [seen] = requests()
    assert part(seen, "lpr_confidence").data == "0.25"
    assert part(seen, "min_ocr_confidence").data == "1"
  end

  test "a photo that is not bytes is refused before anything is sent" do
    alpr = client(fn _request -> {200, @recognized, []} end)
    assert_raise ArgumentError, ~r/bytes/, fn -> Alpr.Photos.ocr(alpr, image: 42) end
    assert requests() == []
  end

  test "a plate image is read by OCR, with a null detection id" do
    alpr =
      client(fn _request ->
        {200,
         ~S|{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}|,
         []}
      end)

    assert {:ok, %Alpr.PlateReading{plate: "ABC1234", detection_id: nil, confidence: 0.91}} =
             Alpr.Photos.ocr(alpr, %Alpr.PhotosOCRParams{image: @png})

    assert [%{uri: %URI{path: "/api/v1/ocr"}}] = requests()
  end

  test "a detection image is a link, and its id is escaped in the path" do
    alpr =
      client(fn _request ->
        {200,
         ~S|{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}|,
         []}
      end)

    assert {:ok, image} = Alpr.Recognitions.image(alpr, "a/b")
    assert image.expires_in == 300
    assert image.detection_id == "a/b"
    assert String.starts_with?(image.image_url, "https://alpr.sh/")
    assert [%{target: "/api/v1/detections/a%2Fb/image"}] = requests()
  end

  defp reading(id, camera \\ "null") do
    ~s|{"cameraId":#{camera},"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"#{id}","plate":"BRA2E19","source":"api"}|
  end

  test "walking the stream follows the cursor and carries the filters" do
    alpr =
      client(fn request ->
        case query(request)["before"] do
          nil -> {200, ~s|{"data":[#{reading("r3")},#{reading("r2")}],"next":"c2"}|, []}
          "c2" -> {200, ~s|{"data":[#{reading("r1")}],"next":null}|, []}
        end
      end)

    ids =
      alpr
      |> Alpr.Recognitions.list_stream(plate: "BRA", source: "api")
      |> Enum.map(& &1.id)

    assert ids == ["r3", "r2", "r1"]

    assert [first, second] = requests()
    assert Map.has_key?(query(first), "before") == false
    assert Map.take(query(first), ["plate", "source"]) == %{"plate" => "BRA", "source" => "api"}
    assert query(second) == %{"before" => "c2", "plate" => "BRA", "source" => "api"}
  end

  test "a single list call asks for the cursor it is given" do
    alpr =
      client(fn _request -> {200, ~s|{"data":[#{reading("r1")}],"next":null}|, []} end)

    assert {:ok, %Alpr.Page{items: [item], next: nil}} =
             Alpr.Recognitions.list(alpr, before: "c2", camera: "cam_1")

    assert %Alpr.Recognition{id: "r1", camera_id: nil, conf: 90, source: "api"} = item
    assert [seen] = requests()
    assert seen.uri.path == "/api/v1/recognitions"
    assert query(seen) == %{"before" => "c2", "camera" => "cam_1"}
  end

  test "the stream starts from the cursor it is given" do
    alpr =
      client(fn _request -> {200, ~s|{"data":[#{reading("r1")}],"next":null}|, []} end)

    assert ["r1"] =
             alpr |> Alpr.Recognitions.list_stream(before: "c9") |> Enum.map(& &1.id)

    assert [%{uri: %URI{query: "before=c9"}}] = requests()
  end

  test "a cursor that does not move ends the walk" do
    alpr =
      client(fn _request ->
        {200, ~s|{"data":[#{reading("r1", ~s|"cam_1"|)}],"next":"same"}|, []}
      end)

    items = alpr |> Alpr.Recognitions.list_stream() |> Enum.to_list()
    assert [%Alpr.Recognition{camera_id: "cam_1"}, %Alpr.Recognition{}] = items
    assert length(requests()) == 2
  end

  test "the stream ends at the first error" do
    alpr =
      client(fn request ->
        if query(request)["before"] do
          {429, ~S|{"error":"rate_limited","message":"Too many requests."}|, []}
        else
          {200, ~s|{"data":[#{reading("r1")}],"next":"c2"}|, []}
        end
      end)

    seen = :counters.new(1, [])

    error =
      assert_raise Alpr.Error, fn ->
        alpr
        |> Alpr.Recognitions.list_stream()
        |> Enum.each(fn _item -> :counters.add(seen, 1, 1) end)
      end

    assert error.code == "rate_limited"
    assert :counters.get(seen, 1) == 1
    assert length(requests()) == 2
  end

  test "a refusal is a typed error" do
    alpr =
      client(fn request ->
        case request.uri.path do
          "/api/v1/recognize" ->
            {402,
             ~S|{"error":"insufficient_credits","message":"This workspace has no credits left."}|,
             []}

          "/api/v1/cameras" ->
            {429, ~S|{"error":"rate_limited","message":"Too many requests."}|,
             [{"Retry-After", "7"}]}
        end
      end)

    assert {:error, %Alpr.Error{} = refused} = Alpr.Photos.recognize(alpr, image: @jpeg)
    assert refused.status == 402
    assert refused.code == "insufficient_credits"
    assert refused.message == "This workspace has no credits left."
    assert refused.fields == %{}
    assert refused.retry_after == nil
    assert Exception.message(refused) =~ "402 insufficient_credits"

    assert {:error, %Alpr.Error{status: 429, code: "rate_limited", retry_after: 7}} =
             Alpr.Cameras.list(alpr)
  end

  test "an error body that is not JSON is still an error" do
    alpr = client(fn _request -> {502, "<html>bad gateway</html>", []} end)

    assert {:error, %Alpr.Error{status: 502, code: "", message: "", fields: %{}}} =
             Alpr.Cameras.list(alpr)
  end

  test "an error body can name fields" do
    alpr =
      client(fn _request ->
        {400,
         ~S|{"error":"invalid_option","message":"No.","fields":{"lpr_confidence":["must be 0..1"]}}|,
         []}
      end)

    assert {:error, %Alpr.Error{fields: %{"lpr_confidence" => ["must be 0..1"]}}} =
             Alpr.Cameras.list(alpr)
  end

  test "a call can use another key" do
    alpr = client(fn _request -> {200, ~S|{"data":[]}|, []} end)
    assert {:ok, []} = Alpr.Cameras.list(alpr, api_key: "alpr_live_other")
    assert {:ok, []} = Alpr.Cameras.list(alpr)
    assert [other, own] = requests()
    assert other.headers["authorization"] == "Bearer alpr_live_other"
    assert own.headers["authorization"] == "Bearer " <> @key
  end

  test "a redirect is refused and the key never follows it" do
    elsewhere = AlprTest.Server.start(:elsewhere, fn _request -> {200, ~S|{"data":[]}|, []} end)

    alpr =
      client(fn _request -> {302, "", [{"Location", elsewhere <> "/steal"}]} end)

    assert {:error, %Alpr.Error{status: 302}} = Alpr.Cameras.list(alpr)
    assert length(requests()) == 1
    assert requests(:elsewhere) == []
  end

  test "a transport failure is an error with no status" do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    alpr = Alpr.new(@key, base_url: "http://127.0.0.1:#{port}", timeout: 2_000)
    assert {:error, %Alpr.Error{status: nil, code: "transport"}} = Alpr.Cameras.list(alpr)
  end

  test "a base URL must be https unless it is loopback" do
    for base <- [
          "https://alpr.sh",
          "http://localhost:8080",
          "http://LOCALHOST",
          "http://127.0.0.1:1",
          "http://127.255.0.3",
          "http://[::1]:8080"
        ] do
      assert %Alpr.Client{} = Alpr.new("k", base_url: base)
    end

    for base <- [
          "http://alpr.sh",
          "http://localhost.evil.test",
          "http://127.0.0.1.evil.test",
          "http://10.0.0.1",
          "ftp://localhost",
          "alpr.sh",
          "",
          "http://[::2]"
        ] do
      assert_raise ArgumentError, ~r/must be https/, fn -> Alpr.new("k", base_url: base) end
    end

    assert Alpr.default_base_url() == "https://alpr.sh"
  end

  # The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
  # Alpr.sh events signed under two secrets, as while one is rotated.
  @new_secret "whsec_SDK-test-secret-new-0123456789"
  @old_secret "whsec_SDK-test-secret-old-0123456789"
  @other_secret "whsec_SDK-test-secret-other-012345678"
  @signed_at "1792670400"
  @now 1_792_670_400 + 120

  @recognition_body ~S|{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}|
  @recognition_new "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623"
  @recognition_old "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781"
  @alert_body ~S|{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}|
  @alert_new "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a"
  @test_body ~S|{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}|
  @test_new "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245"
  @unknown_body ~S|{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}|
  @unknown_new "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6"
  @plus_signature "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771"

  # The headers of a delivery as a plain list of pairs, names in any case.
  defp headers(id, stamp, signatures) do
    [{"x-alprsh-delivery-id", id}, {"X-Alprsh-Timestamp", stamp}] ++
      for signature <- List.wrap(signatures), do: {"X-Alprsh-Signature", signature}
  end

  defp sign(secret, id, stamp, body) do
    "sha256=" <>
      Base.encode16(:crypto.mac(:hmac, :sha256, secret, [stamp, ".", id, ".", body]),
        case: :lower
      )
  end

  defp signature(secret, headers, body, now \\ @now),
    do: Alpr.verify_webhook_signature(secret, headers, body, now: now)

  test "the signing of the vectors is reproduced" do
    assert sign(@new_secret, "del_0001", @signed_at, @recognition_body) == @recognition_new
    assert sign(@old_secret, "del_0001", @signed_at, @recognition_body) == @recognition_old
  end

  test "the webhook vector verifies, and nothing else does" do
    header = headers("del_0001", @signed_at, @recognition_new)
    bad = {:error, %Alpr.WebhookVerificationError{}}

    assert :ok = signature(@new_secret, header, @recognition_body)
    assert signature(@new_secret, header, @recognition_body <> " ") == bad

    assert signature(
             @new_secret,
             headers("del_0009", @signed_at, @recognition_new),
             @recognition_body
           ) == bad

    assert signature(@new_secret, header, @recognition_body, 1_792_670_400 + 301) == bad
    assert signature(@new_secret, header, @recognition_body, 1_792_670_400 - 301) == bad
    assert :ok = signature(@new_secret, header, @recognition_body, 1_792_670_400 + 300)
    assert :ok = signature(@new_secret, header, @recognition_body, 1_792_670_400 - 300)
    assert signature(@other_secret, header, @recognition_body) == bad
    assert signature(@new_secret, [], @recognition_body) == bad
    assert Alpr.Webhook.tolerance_seconds() == 300
  end

  test "headers can be a map, and a DateTime can be the clock" do
    map = %{
      "X-ALPRSH-DELIVERY-ID" => "del_0001",
      "x-alprsh-timestamp" => @signed_at,
      "X-Alprsh-Signature" => @recognition_new
    }

    assert :ok = signature(@new_secret, map, @recognition_body, DateTime.from_unix!(@now))
    assert :ok = Alpr.Webhook.verify_signature(@new_secret, map, @recognition_body, now: @now)
  end

  test "the real clock is the default" do
    stamp = Integer.to_string(System.os_time(:second))
    signed = sign(@new_secret, "del_1", stamp, @recognition_body)
    header = headers("del_1", stamp, signed)
    assert :ok = Alpr.verify_webhook_signature(@new_secret, header, @recognition_body)

    assert {:ok, %Alpr.RecognitionCreatedWebhookEvent{}} =
             Alpr.verify_webhook(@new_secret, header, @recognition_body)
  end

  test "an empty secret is a configuration error, not a signature error" do
    header = headers("del_0001", @signed_at, @recognition_new)

    assert_raise ArgumentError, ~r/secret is empty/, fn ->
      signature("", header, @recognition_body)
    end

    assert_raise ArgumentError, fn ->
      Alpr.verify_webhook("", header, @recognition_body, now: @now)
    end
  end

  test "a timestamp that is not plain digits is refused" do
    for stamp <- ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 ", "1792670400\n"] do
      assert {:error, %Alpr.WebhookVerificationError{}} =
               signature(
                 @new_secret,
                 headers("del_0001", stamp, @plus_signature),
                 @recognition_body
               ),
             "#{inspect(stamp)} verified"
    end

    assert {:error, %Alpr.WebhookVerificationError{}} =
             signature(
               @new_secret,
               [{"x-alprsh-timestamp", @signed_at}, {"x-alprsh-signature", @recognition_new}],
               @recognition_body
             )
  end

  test "more than one signature verifies during a rotation" do
    rotated = %{
      "one value" => headers("del_0001", @signed_at, @recognition_old <> "," <> @recognition_new),
      "two lines" => headers("del_0001", @signed_at, [@recognition_old, @recognition_new]),
      "with spaces" =>
        headers("del_0001", @signed_at, @recognition_old <> ", " <> @recognition_new)
    }

    for {name, header} <- rotated do
      for secret <- [@new_secret, @old_secret] do
        assert :ok = signature(secret, header, @recognition_body), "#{name} under #{secret}"
      end

      assert {:error, %Alpr.WebhookVerificationError{}} =
               signature(@other_secret, header, @recognition_body),
             "#{name}: a secret that signed nothing verified"
    end

    refused = %{
      "a malformed one beside a good one" => "sha256=zz," <> @recognition_new,
      "no prefix" => String.replace_prefix(@recognition_new, "sha256=", ""),
      "a short one" => "sha256=97de",
      "an empty one" => @recognition_new <> ",",
      "too many" => String.duplicate(@recognition_old <> ",", 6) <> @recognition_new
    }

    for {name, value} <- refused do
      assert {:error, %Alpr.WebhookVerificationError{}} =
               signature(@new_secret, headers("del_0001", @signed_at, value), @recognition_body),
             "#{name} verified"
    end

    six = Enum.join(List.duplicate(@recognition_old, 5) ++ [@recognition_new], ",")
    assert :ok = signature(@new_secret, headers("del_0001", @signed_at, six), @recognition_body)
  end

  test "a webhook answers its typed event" do
    verify = fn id, signed, body ->
      Alpr.verify_webhook(@new_secret, headers(id, @signed_at, signed), body, now: @now)
    end

    assert {:ok, %Alpr.RecognitionCreatedWebhookEvent{} = read} =
             verify.("del_0001", @recognition_new, @recognition_body)

    assert %{
             event: "recognition.created",
             id: "rec_1",
             plate: "BRA2E19",
             confidence: 0.97,
             camera_id: "cam_1",
             source: "camera",
             tenant_id: "ws_1",
             captured_at: "2026-10-22T11:59:58Z"
           } = read

    assert {:ok, %Alpr.AlertTriggeredWebhookEvent{} = alert} =
             verify.("del_0002", @alert_new, @alert_body)

    assert %{
             event: "alert.triggered",
             rule_name: "Veículo bloqueado",
             recognition_id: "rec_1",
             rule_id: "rule_1"
           } = alert

    assert {:ok,
            %Alpr.TestWebhookEvent{event: "webhook.test", sent_at: "2026-10-22T12:00:00Z"}} =
             verify.("del_0003", @test_new, @test_body)

    assert {:ok, %Alpr.UnknownWebhookEvent{} = unknown} =
             verify.("del_0004", @unknown_new, @unknown_body)

    assert unknown.event == "payout.sent"
    assert unknown.id == "po_1"
    assert unknown.raw == @unknown_body
    assert unknown.body == %{"event" => "payout.sent", "id" => "po_1", "tenant_id" => "ws_1"}

    assert {:error, %Alpr.WebhookVerificationError{}} =
             verify.("del_0005", "sha256=" <> String.duplicate("0", 64), ~S|{"id":"x"}|)
  end

  test "an unknown event with no string id has an empty id" do
    body = ~S|{"event":"payout.sent","id":7}|
    signed = sign(@new_secret, "del_1", @signed_at, body)

    assert {:ok, %Alpr.UnknownWebhookEvent{event: "payout.sent", id: ""}} =
             Alpr.verify_webhook(@new_secret, headers("del_1", @signed_at, signed), body,
               now: @now
             )
  end

  test "a verified body that is not an event is a parse error" do
    for body <- ["[1]", ~S|{"id":"x"}|, ~S|{"event":7}|, "not json"] do
      signed = sign(@new_secret, "del_1", @signed_at, body)

      assert {:error, %Alpr.WebhookParseError{}} =
               Alpr.verify_webhook(@new_secret, headers("del_1", @signed_at, signed), body,
                 now: @now
               ),
             "#{body} is not an event"
    end
  end
end

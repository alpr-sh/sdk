# frozen_string_literal: true

# Alpr.sh's Ruby SDK tests, with nothing to install: ruby -w -Ilib -Itest test/alpr_test.rb

require "minitest/autorun"
require "json"
require "openssl"
require "socket"
require "uri"
require "alpr"

# A server on 127.0.0.1 that records every request it gets and answers what the
# block says: [status, headers, body].
class FakeServer
  Request = Struct.new(:method, :target, :path, :query, :headers, :body)

  attr_reader :requests, :base_url

  def initialize(&answer)
    @answer = answer
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      socket = @server.accept
      begin
        handle(socket)
      ensure
        socket.close
      end
    end
  end

  def handle(socket)
    line = socket.gets.to_s
    verb, target, = line.split(" ", 3)
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s
    path, query = target.split("?", 2)
    request = Request.new(verb, target, path, URI.decode_www_form(query.to_s).to_h, headers, body)
    @requests << request
    status, extra, payload = @answer.call(request)
    lines = (extra || {}).map { |name, value| "#{name}: #{value}\r\n" }.join
    payload = payload.to_s.b
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n#{lines}Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(payload)
  end
end

class AlprTest < Minitest::Test
  KEY = "alpr_live_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  JPEG = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01].pack("C*")
  PNG = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52].pack("C*")

  RECOGNIZED = '{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}'

  def teardown
    (@servers || []).each(&:stop)
  end

  # Starts a server answering with the block, and a client pointed at it.
  def client(&answer)
    server = FakeServer.new(&answer)
    (@servers ||= []) << server
    [Alpr::Client.new(KEY, base_url: server.base_url), server]
  end

  def ok(body)
    [200, {}, body]
  end

  # The parts of a multipart body: name, file name, content type and data.
  def parts(request)
    boundary = request.headers["content-type"][/\Amultipart\/form-data; boundary=(.+)\z/, 1]
    refute_nil boundary, "multipart content type with a boundary"
    chunks = request.body.b.split("--#{boundary}".b)
    assert_equal "--\r\n".b, chunks.last
    chunks[1...-1].map do |chunk|
      head, data = chunk.delete_prefix("\r\n".b).delete_suffix("\r\n".b).split("\r\n\r\n".b, 2)
      lines = head.split("\r\n".b)
      disposition = lines.first
      { name: disposition[/ name="([^"]*)"/, 1], filename: disposition[/filename="([^"]*)"/, 1],
        type: lines[1]&.then { |line| line[/\AContent-Type: (.+)\z/i, 1] }, data: data }
    end
  end

  def test_a_call_carries_the_key_and_unwraps_the_list
    alpr, server = client do
      ok('{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}')
    end
    cameras = alpr.cameras.list
    request = server.requests.first
    assert_equal ["GET", "/api/v1/cameras", "Bearer #{KEY}", "application/json"], [request.method, request.path, request.headers["authorization"], request.headers["accept"]]
    assert_match(%r{\Aalpr-ruby/}, request.headers["user-agent"])
    refute request.headers.key?("idempotency-key"), "the API does not take an Idempotency-Key"
    assert_equal 2, cameras.size
    assert_equal ["cam_1", true, nil], [cameras[0].id, cameras[0].enabled, cameras[0].reading_area]
    assert_equal "Portão", cameras[0].name
    area = cameras[1].reading_area
    assert_equal [0.1, 3, 0.6], [area.box.x, area.points.size, area.points[1][0]]
  end

  def test_a_photo_goes_as_multipart
    alpr, server = client { ok(RECOGNIZED) }
    result = alpr.photos.recognize(Alpr::PhotosRecognizeParams.new(image: JPEG, lpr_confidence: 0.5))
    request = server.requests.first
    assert_equal ["POST", "/api/v1/recognize"], [request.method, request.path]
    sent = parts(request)
    image = sent.find { |part| part[:name] == "image" }
    assert_equal [JPEG.b, "photo.jpg", "image/jpeg"], [image[:data], image[:filename], image[:type]]
    assert_equal "0.5", sent.find { |part| part[:name] == "lpr_confidence" }[:data]
    assert_nil(sent.find { |part| part[:name] == "min_ocr_confidence" }, "an option left out was sent")
    assert_equal 2, sent.size
    assert_equal 41, result.credits_remaining
    assert_equal 1, result.plates.size
    plate = result.plates[0]
    assert_equal ["BRA2E19", 97.3, 120], [plate.plate, plate.conf, plate.coordinate_left]
    assert_equal "0.99,0.98,0.97,0.96,0.97,0.96,0.96", plate.char_confs
  end

  def test_a_hash_of_params_is_a_body_too
    alpr, server = client { ok(RECOGNIZED) }
    alpr.photos.recognize({ image: JPEG, min_ocr_confidence: 1.0 })
    assert_equal "1", parts(server.requests.first).find { |part| part[:name] == "min_ocr_confidence" }[:data]
  end

  def test_a_photo_is_named_by_its_bytes
    { "jpeg" => [JPEG, "photo.jpg", "image/jpeg"], "png" => [PNG, "photo.png", "image/png"],
      "other" => ["not an image", "photo", "application/octet-stream"] }.each do |name, (data, filename, type)|
      alpr, server = client { ok('{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}') }
      result = alpr.photos.detect(Alpr::PhotosDetectParams.new(image: data))
      image = parts(server.requests.first).find { |part| part[:name] == "image" }
      assert_equal [filename, type, data.b], [image[:filename], image[:type], image[:data]], name
      assert_equal [20, []], [result.image_width, result.plates], name
    end
  end

  def test_a_plate_image_is_read_by_ocr
    alpr, server = client { ok('{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}') }
    result = alpr.photos.ocr(Alpr::PhotosOCRParams.new(image: PNG))
    assert_equal "/api/v1/ocr", server.requests.first.path
    assert_equal ["ABC1234", nil, 0.91], [result.plate, result.detection_id, result.confidence]
  end

  def test_a_detection_image_is_a_link
    alpr, server = client { ok('{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}') }
    image = alpr.recognitions.image("a/b")
    assert_equal "/api/v1/detections/a%2Fb/image", server.requests.first.path
    assert_equal ["a/b", 300], [image.detection_id, image.expires_in]
    assert image.image_url.start_with?("https://alpr.sh/")
  end

  def reading(id)
    %({"cameraId":null,"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"#{id}","plate":"BRA2E19","source":"api"})
  end

  def test_iterating_walks_every_page_by_cursor
    alpr, server = client do |request|
      case request.query["before"]
      when nil then ok(%({"data":[#{reading("r3")},#{reading("r2")}],"next":"c2"}))
      when "c2" then ok(%({"data":[#{reading("r1")}],"next":null}))
      else [500, {}, "{}"]
      end
    end
    ids = alpr.recognitions.list_iter(plate: "BRA", source: "api").map(&:id)
    assert_equal %w[r3 r2 r1], ids
    assert_equal [{ "plate" => "BRA", "source" => "api" }, { "before" => "c2", "plate" => "BRA", "source" => "api" }], server.requests.map(&:query)
    assert_equal 90.0, alpr.recognitions.list_iter.first.conf
    assert_instance_of Float, alpr.recognitions.list_iter.first.conf
    page = alpr.recognitions.list(before: "c2")
    assert_equal({ "before" => "c2" }, server.requests.last.query)
    assert_equal [1, nil, nil], [page.items.size, page.next_cursor, page.items[0].camera_id]
  end

  def test_a_cursor_that_does_not_move_ends_the_walk
    alpr, server = client do
      ok('{"data":[{"cameraId":"cam_1","capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"r1","plate":"ABC1234","source":"camera"}],"next":"same"}')
    end
    assert_equal 2, alpr.recognitions.list_iter.count
    assert_equal 2, server.requests.size
  end

  def test_a_walk_ends_at_the_first_error
    seen = 0
    alpr, = client do
      seen += 1
      seen == 1 ? ok(%({"data":[#{reading("r1")}],"next":"c2"})) : [503, {}, '{"error":"storage_unavailable","message":"later"}']
    end
    ids = []
    error = assert_raises(Alpr::Error) { alpr.recognitions.list_iter { |item| ids << item.id } }
    assert_equal [%w[r1], 503], [ids, error.status]
  end

  def test_a_refusal_is_a_typed_error
    alpr, = client do |request|
      if request.path == "/api/v1/recognize"
        [402, {}, '{"error":"insufficient_credits","message":"This workspace has no credits left."}']
      else
        [429, { "Retry-After" => "7" }, '{"error":"rate_limited","message":"Too many requests."}']
      end
    end
    refused = assert_raises(Alpr::Error) { alpr.photos.recognize({ image: JPEG }) }
    assert_equal [402, "insufficient_credits", "This workspace has no credits left.", {}], [refused.status, refused.code, refused.message, refused.fields]
    limited = assert_raises(Alpr::Error) { alpr.cameras.list }
    assert_equal [429, "rate_limited", 7], [limited.status, limited.code, limited.retry_after]
  end

  def test_an_error_body_that_is_not_json_is_still_an_error
    alpr, = client { [502, {}, "<html>bad gateway</html>"] }
    error = assert_raises(Alpr::Error) { alpr.cameras.list }
    assert_equal [502, "", nil], [error.status, error.code, error.retry_after]
  end

  def test_a_call_can_use_another_key
    alpr, server = client { ok('{"data":[]}') }
    assert_equal [], alpr.cameras.list(api_key: "alpr_live_other")
    alpr.cameras.list
    assert_equal ["Bearer alpr_live_other", "Bearer #{KEY}"], server.requests.map { |request| request.headers["authorization"] }
  end

  def test_a_redirect_is_refused_and_the_key_never_follows_it
    elsewhere = FakeServer.new { ok("{}") }
    (@servers ||= []) << elsewhere
    alpr, = client { [302, { "Location" => "#{elsewhere.base_url}/steal" }, ""] }
    error = assert_raises(Alpr::Error) { alpr.cameras.list }
    assert_equal 302, error.status
    assert_empty elsewhere.requests
  end

  def test_a_base_url_must_be_https_unless_it_is_loopback
    ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"].each do |base_url|
      Alpr::Client.new("k", base_url: base_url)
    end
    ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "", "http://[::2]"].each do |base_url|
      error = assert_raises(ArgumentError, base_url) { Alpr::Client.new("k", base_url: base_url) }
      assert_match(/must be https/, error.message)
    end
  end

  # The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
  # Alpr.sh events signed under two secrets, as while one is rotated.
  NEW_SECRET = "whsec_SDK-test-secret-new-0123456789"
  OLD_SECRET = "whsec_SDK-test-secret-old-0123456789"
  OTHER_SECRET = "whsec_SDK-test-secret-other-012345678"
  SIGNED_AT = 1_792_670_400
  STAMP = SIGNED_AT.to_s
  NOW = Time.at(SIGNED_AT + 120)

  RECOGNITION_BODY = '{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}'
  RECOGNITION_NEW = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623"
  RECOGNITION_OLD = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781"
  ALERT_BODY = '{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}'
  ALERT_NEW = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a"
  TEST_BODY = '{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}'
  TEST_NEW = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245"
  UNKNOWN_BODY = '{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}'
  UNKNOWN_NEW = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6"
  PLUS_SIGNATURE = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771"

  # A request's headers; several signatures are several header lines.
  def webhook_headers(id, stamp, *signatures)
    { "x-alprsh-delivery-id" => id, "X-Alprsh-Timestamp" => stamp, "X-Alprsh-Signature" => signatures }
  end

  def refused?(secret, headers, body, now: NOW)
    Alpr.verify_webhook_signature(secret, headers, body, now: now)
    false
  rescue Alpr::WebhookVerificationError
    true
  end

  def test_the_webhook_vector_verifies
    headers = webhook_headers("del_0001", STAMP, RECOGNITION_NEW)
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, headers, RECOGNITION_BODY, now: NOW)
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, headers, RECOGNITION_BODY.b, now: NOW), "the body as raw bytes"
    assert refused?(NEW_SECRET, headers, "#{RECOGNITION_BODY} "), "a changed body verified"
    assert refused?(NEW_SECRET, webhook_headers("del_0009", STAMP, RECOGNITION_NEW), RECOGNITION_BODY), "another delivery id verified"
    assert refused?(NEW_SECRET, headers, RECOGNITION_BODY, now: Time.at(SIGNED_AT + 301)), "a stale webhook verified"
    assert refused?(NEW_SECRET, headers, RECOGNITION_BODY, now: Time.at(SIGNED_AT - 301)), "a webhook from the future verified"
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, headers, RECOGNITION_BODY, now: Time.at(SIGNED_AT + 300))
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, headers, RECOGNITION_BODY, now: Time.at(SIGNED_AT - 300))
    assert refused?(OTHER_SECRET, headers, RECOGNITION_BODY), "another secret verified"
    assert refused?(NEW_SECRET, {}, RECOGNITION_BODY), "a request with no headers verified"
    assert_equal 300, Alpr::WEBHOOK_TOLERANCE
  end

  def test_an_empty_secret_is_a_configuration_error
    headers = webhook_headers("del_0001", STAMP, RECOGNITION_NEW)
    error = assert_raises(ArgumentError) { Alpr.verify_webhook_signature("", headers, RECOGNITION_BODY, now: NOW) }
    refute_kind_of Alpr::WebhookVerificationError, error
    assert_raises(ArgumentError) { Alpr.verify_webhook("", headers, RECOGNITION_BODY, now: NOW) }
  end

  def test_headers_are_found_in_any_case_and_in_a_rack_env
    env = { "HTTP_X_ALPRSH_DELIVERY_ID" => "del_0001", "HTTP_X_ALPRSH_TIMESTAMP" => STAMP, "HTTP_X_ALPRSH_SIGNATURE" => RECOGNITION_NEW }
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, env, RECOGNITION_BODY, now: NOW)
    upper = { "X-ALPRSH-DELIVERY-ID" => "del_0001", "x-alprsh-timestamp" => STAMP, "x-Alprsh-signature" => RECOGNITION_NEW }
    assert_nil Alpr.verify_webhook_signature(NEW_SECRET, upper, RECOGNITION_BODY, now: NOW)
  end

  def test_a_timestamp_that_is_not_plain_digits_is_refused
    ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 ", "1792670400\n", "１７９２６７０４００"].each do |stamp|
      assert refused?(NEW_SECRET, webhook_headers("del_0001", stamp, PLUS_SIGNATURE), RECOGNITION_BODY), "#{stamp.inspect} verified"
    end
    assert refused?(NEW_SECRET, { "X-Alprsh-Timestamp" => STAMP, "X-Alprsh-Signature" => RECOGNITION_NEW }, RECOGNITION_BODY), "no delivery id"
    assert refused?(NEW_SECRET, { "x-alprsh-delivery-id" => "del_0001", "X-Alprsh-Signature" => RECOGNITION_NEW }, RECOGNITION_BODY), "no timestamp"
  end

  def test_more_than_one_signature_verifies_during_a_rotation
    {
      "one value" => webhook_headers("del_0001", STAMP, "#{RECOGNITION_OLD},#{RECOGNITION_NEW}"),
      "two lines" => webhook_headers("del_0001", STAMP, RECOGNITION_OLD, RECOGNITION_NEW),
      "with spaces" => webhook_headers("del_0001", STAMP, "#{RECOGNITION_OLD}, #{RECOGNITION_NEW}")
    }.each do |name, headers|
      [NEW_SECRET, OLD_SECRET].each do |secret|
        assert_nil Alpr.verify_webhook_signature(secret, headers, RECOGNITION_BODY, now: NOW), "#{name} under #{secret}"
      end
      assert refused?(OTHER_SECRET, headers, RECOGNITION_BODY), "#{name}: a secret that signed nothing verified"
    end
    {
      "a malformed one beside a good one" => "sha256=zz,#{RECOGNITION_NEW}",
      "no prefix" => RECOGNITION_NEW.delete_prefix("sha256="),
      "a short one" => "sha256=97de",
      "an empty one" => "#{RECOGNITION_NEW},",
      "too many" => "#{RECOGNITION_OLD},#{RECOGNITION_OLD},#{RECOGNITION_OLD},#{RECOGNITION_OLD},#{RECOGNITION_OLD},#{RECOGNITION_OLD},#{RECOGNITION_NEW}"
    }.each do |name, signature|
      assert refused?(NEW_SECRET, webhook_headers("del_0001", STAMP, signature), RECOGNITION_BODY), "#{name} verified"
    end
  end

  def test_a_webhook_answers_its_typed_event
    event = Alpr.verify_webhook(NEW_SECRET, webhook_headers("del_0001", STAMP, RECOGNITION_NEW), RECOGNITION_BODY, now: NOW)
    assert_instance_of Alpr::RecognitionCreatedWebhookEvent, event
    assert_equal ["recognition.created", "rec_1", "BRA2E19", 0.97, "cam_1", "camera", "ws_1", "2026-10-22T11:59:58Z"],
                 [event.event_name, event.id, event.plate, event.confidence, event.camera_id, event.source, event.tenant_id, event.captured_at]
    event = Alpr.verify_webhook(NEW_SECRET, webhook_headers("del_0002", STAMP, ALERT_NEW), ALERT_BODY.b, now: NOW)
    assert_instance_of Alpr::AlertTriggeredWebhookEvent, event
    assert_equal ["Veículo bloqueado", "rec_1", "rule_1"], [event.rule_name, event.recognition_id, event.rule_id]
    event = Alpr.verify_webhook(NEW_SECRET, webhook_headers("del_0003", STAMP, TEST_NEW), TEST_BODY, now: NOW)
    assert_instance_of Alpr::TestWebhookEvent, event
    assert_equal ["webhook.test", "2026-10-22T12:00:00Z"], [event.event_name, event.sent_at]
  end

  def test_an_unknown_event_is_not_an_error
    event = Alpr.verify_webhook(NEW_SECRET, webhook_headers("del_0004", STAMP, UNKNOWN_NEW), UNKNOWN_BODY, now: NOW)
    assert_instance_of Alpr::UnknownWebhookEvent, event
    assert_equal ["payout.sent", "po_1", JSON.parse(UNKNOWN_BODY)], [event.event_name, event.id, event.body]
    assert_raises(Alpr::WebhookVerificationError) do
      Alpr.verify_webhook(NEW_SECRET, webhook_headers("del_0005", STAMP, "sha256=#{"0" * 64}"), '{"id":"x"}', now: NOW)
    end
  end

  def sign(secret, id, body)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{STAMP}.#{id}.#{body}")}"
  end

  def test_a_signature_helper_matches_the_vectors
    assert_equal RECOGNITION_NEW, sign(NEW_SECRET, "del_0001", RECOGNITION_BODY)
    assert_equal RECOGNITION_OLD, sign(OLD_SECRET, "del_0001", RECOGNITION_BODY)
  end

  def test_a_verified_body_that_is_not_an_event_is_a_parse_error
    ["[1]", '{"id":"x"}', '{"event":3}', '{"event":""}', "not json", '"event"'].each do |body|
      headers = webhook_headers("del_0001", STAMP, sign(NEW_SECRET, "del_0001", body))
      error = assert_raises(Alpr::WebhookParseError, body) { Alpr.verify_webhook(NEW_SECRET, headers, body, now: NOW) }
      refute_kind_of Alpr::WebhookVerificationError, error
    end
    body = '{"event":"recognition.created","id":"rec_1"}'
    headers = webhook_headers("del_0001", STAMP, sign(NEW_SECRET, "del_0001", body))
    assert_raises(Alpr::WebhookParseError) { Alpr.verify_webhook(NEW_SECRET, headers, body, now: NOW) }
  end
end

# frozen_string_literal: true

# Alpr.sh's Ruby SDK tests, with nothing to install: ruby -Ilib -Itest test/alpr_test.rb

require "minitest/autorun"
require "json"
require "openssl"
require "socket"
require "uri"
require "alpr"

class AlprTest < Minitest::Test
  # Records each request and answers what the test says.
  class Recorder
    attr_reader :seen

    def initialize(&answer)
      @answer = answer
      @seen = []
    end

    def call(method, url, headers, body, _timeout)
      request = { method: method, url: URI(url), headers: headers, body: body }
      @seen << request
      status, payload, extra = @answer.call(request)
      [status, extra, payload.nil? ? "" : JSON.generate(payload)]
    end
  end

  def client(&answer)
    recorder = Recorder.new(&answer)
    [Alpr::Client.new("prk_test_key", base_url: "https://alpr.test/", transport: recorder), recorder]
  end

  def product(id)
    { "id" => id, "name" => "Curso", "description" => "", "status" => "active", "created_at" => "2026-10-17T00:00:00Z" }
  end

  def query(request)
    URI.decode_www_form(request[:url].query.to_s).to_h
  end

  def test_a_call_carries_the_key_and_unwraps_the_data
    alpr, recorder = client { [200, { "data" => product("prod_1") }, {}] }
    got = alpr.products.get("prod_1")
    assert_equal "prod_1", got.id
    assert_equal "active", got.status
    seen = recorder.seen.first
    assert_equal "GET", seen[:method]
    assert_equal "/api/v1/products/prod_1", seen[:url].path
    assert_equal "Bearer prk_test_key", seen[:headers]["Authorization"]
  end

  def test_a_write_sends_its_body_and_idempotency_key
    alpr, recorder = client { [201, { "data" => product("prod_1") }, {}] }
    alpr.products.create(Alpr::ProductsCreateParams.new(name: "Curso"), idempotency_key: "create-1")
    seen = recorder.seen.first
    assert_equal "POST", seen[:method]
    assert_equal "create-1", seen[:headers]["Idempotency-Key"]
    assert_equal({ "name" => "Curso" }, JSON.parse(seen[:body]))
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

  def test_a_discount_goes_through_create_get_list_and_delete
    discount = ->(id) { JSON.parse(%q({"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}).sub("__ID__", id)) }
    alpr, recorder = client do |request|
      case request[:method]
      when "POST" then [201, { "data" => discount.call("disc_1") }, {}]
      when "DELETE" then [204, nil, {}]
      else
        if request[:url].path == "/api/v1/discounts"
          page = query(request)["page"]
          [200, { "data" => { "items" => [discount.call("disc_#{page}")], "pagination" => { "total_count" => 2, "max_page" => 2 } } }, {}]
        else
          [200, { "data" => discount.call("disc_1") }, {}]
        end
      end
    end
    created = alpr.discounts.create({ name: "Black", type: "percentage", duration: "once", basis_points: 1000 })
    assert_equal ["disc_1", nil, ["prod_1"]], [created.id, created.code, created.product_ids]
    assert_equal "Black", alpr.discounts.get("disc_1").name
    assert_equal %w[disc_1 disc_2], alpr.discounts.list_iter(limit: 1).map(&:id)
    assert_nil alpr.discounts.delete("disc_1")
    assert_equal [["POST", "/api/v1/discounts"], ["GET", "/api/v1/discounts/disc_1"], ["GET", "/api/v1/discounts"], ["GET", "/api/v1/discounts"], ["DELETE", "/api/v1/discounts/disc_1"]],
                 recorder.seen.map { |seen| [seen[:method], seen[:url].path] }
    assert_equal({ "name" => "Black", "type" => "percentage", "duration" => "once", "basis_points" => 1000 }, JSON.parse(recorder.seen.first[:body]))
  end

  def test_a_free_form_value_decodes_nested
    state = JSON.parse('{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}')
    alpr, = client { [200, { "data" => state }, {}] }
    grant = alpr.customers.get_state("cus_1").granted_benefits.first
    assert_equal({ "flags" => { "beta" => true, "limits" => { "seats" => 5, "tiers" => ["a", 2, nil, 1.5] } } }, grant.benefit_metadata)
    assert_equal({ "links" => [{ "url" => "https://example.com", "expires" => nil }] }, grant.properties)
  end

  def test_a_post_without_a_key_is_sent_with_its_own_a_get_with_none
    alpr, recorder = client { [201, { "data" => product("prod_1") }, {}] }
    2.times { alpr.products.create(Alpr::ProductsCreateParams.new(name: "Curso")) }
    alpr.products.create(Alpr::ProductsCreateParams.new(name: "Curso"), idempotency_key: "mine")
    alpr.products.get("prod_1")
    keys = recorder.seen.map { |seen| seen[:headers]["Idempotency-Key"] }
    uuid = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert_match uuid, keys[0]
    assert_match uuid, keys[1]
    refute_equal keys[0], keys[1]
    assert_equal ["mine", nil], keys[2..]
  end

  def test_iterating_walks_every_page
    alpr, recorder = client do |request|
      page = query(request)["page"]
      [200, { "data" => { "items" => [product("prod_#{page}")], "pagination" => { "total_count" => 3, "max_page" => 3 } } }, {}]
    end
    assert_equal %w[prod_1 prod_2 prod_3], alpr.products.list_iter(limit: 1).map(&:id)
    assert_equal "1", query(recorder.seen.first)["limit"]
  end

  def test_a_refusal_is_a_typed_error
    alpr, = client do |request|
      if request[:url].path == "/api/v1/customers"
        [422, { "error" => "invalid_request", "fields" => { "email" => ["send an e-mail"] } }, {}]
      else
        [429, nil, { "retry-after" => "7" }]
      end
    end
    refused = assert_raises(Alpr::Error) { alpr.customers.create({ name: "x", email: "x" }) }
    assert_equal [422, "invalid_request"], [refused.status, refused.code]
    assert_equal ["send an e-mail"], refused.fields["email"]
    limited = assert_raises(Alpr::Error) { alpr.products.list }
    assert_equal [429, 7], [limited.status, limited.retry_after]
  end

  # The webhook vectors every SDK checks: Standard Webhooks' own example, and
  # Alpr.sh events signed under two secrets, as while one is rotated.
  REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
  NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
  ORDER_PAID = '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}'
  USAGE_RECORDED = '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}'
  PAYOUT_SENT = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}'
  SIGNED_AT = 1_792_670_400

  def webhook_headers(id, at, signature)
    { "Webhook-Id" => id, "webhook-timestamp" => at.to_s, "webhook-signature" => signature }
  end

  def test_the_standard_webhooks_vector_verifies
    body = '{"test": 2432232314}'
    headers = webhook_headers("msg_p5jXN8AQM9LWM0D4loKWxJek", 1_614_265_330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    at = Time.at(1_614_265_330)
    assert_nil Alpr.verify_webhook_signature(REFERENCE_SECRET, headers, body, now: at)
    [[REFERENCE_SECRET, "#{body} ", at], [REFERENCE_SECRET, body, at + 301], [NEW_SECRET, body, at]].each do |secret, payload, now|
      assert_raises(Alpr::WebhookVerificationError) { Alpr.verify_webhook_signature(secret, headers, payload, now: now) }
    end
  end

  def test_a_timestamp_that_is_not_plain_digits_is_refused
    body = '{"test": 2432232314}'
    [["+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="], ["²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="], ["", "x"], ["1_6", "x"]].each do |stamp, signature|
      headers = webhook_headers("msg_p5jXN8AQM9LWM0D4loKWxJek", stamp, "v1,#{signature}")
      assert_raises(Alpr::WebhookVerificationError, stamp) { Alpr.verify_webhook_signature(REFERENCE_SECRET, headers, body, now: Time.at(1_614_265_330)) }
    end
  end

  def test_a_webhook_answers_its_typed_event
    now = Time.at(SIGNED_AT + 120)
    headers = webhook_headers("msg_2", SIGNED_AT, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
    [NEW_SECRET, OLD_SECRET].each do |secret|
      event = Alpr.verify_webhook(secret, headers, ORDER_PAID, now: now)
      assert_instance_of Alpr::OrderWebhookEvent, event
      assert_equal ["order.paid", "ord_1", 3, 360], [event.type, event.data.id, event.data.installments, event.data.installment_interest_cents]
    end
    assert_raises(Alpr::WebhookVerificationError) { Alpr.verify_webhook(REFERENCE_SECRET, headers, ORDER_PAID, now: now) }
    usage = Alpr.verify_webhook(NEW_SECRET, webhook_headers("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), USAGE_RECORDED, now: now)
    assert_instance_of Alpr::IdentifiersWebhookEvent, usage
    assert_equal %w[msg_3 mer_1], [usage.id, usage.data["merchant_id"]]
    unknown = Alpr.verify_webhook(NEW_SECRET, webhook_headers("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PAYOUT_SENT, now: now)
    assert_instance_of Alpr::UnknownWebhookEvent, unknown
    assert_equal ["payout.sent", { "payout_id" => "po_1", "amount_cents" => 5000 }], [unknown.type, unknown.data]
  end

  def test_the_real_http_sends_and_reads_through_net_http
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new { loop { answer(server.accept) } }
    base_url = "http://127.0.0.1:#{server.addr[1]}"
    product = Alpr::Client.new("prk_test_key", base_url: base_url).products.create({ name: "Alpr.sh" }, idempotency_key: "create-1")
    assert_equal ["Alpr.sh", "create-1", "POST /api/v1/products application/json"], [product.name, product.description, product.created_at]
    detached = Alpr::Client.new("prk_test_key", base_url: base_url).payment_methods.detach("pm 1/2")
    assert_equal "POST /api/v1/payment_methods/pm%201%2F2/detach -", detached.id
    refused = assert_raises(Alpr::Error) { Alpr::Client.new("prk_test_other", base_url: base_url).products.get("prod_1") }
    assert_equal [401, "invalid_credential", 3], [refused.status, refused.code, refused.retry_after]
  ensure
    thread&.kill
    server&.close
  end

  private

  # Answers one connection as the API would: what it was sent, wrapped in
  # data, or a 401 to another key.
  def answer(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s.force_encoding(Encoding::UTF_8)
    status, extra, payload = respond(request_line.split[0, 2].join(" "), headers, body)
    encoded = JSON.generate(payload).b
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n#{extra}Content-Length: #{encoded.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(encoded)
  ensure
    socket.close
  end

  def respond(request, headers, body)
    return [401, "Retry-After: 3\r\n", { "error" => "invalid_credential" }] if headers["authorization"] != "Bearer prk_test_key"

    name = body.empty? ? "" : JSON.parse(body)["name"]
    if request.end_with?("/detach")
      return [200, "", { "data" => { "id" => "#{request} #{headers["content-type"] || "-"}", "detached" => true } }]
    end

    [201, "", { "data" => { "id" => "prod_1", "name" => name, "description" => headers["idempotency-key"].to_s, "status" => "active",
                            "created_at" => "#{request} #{headers["content-type"]}" } }]
  end
end

require "test_helper"

class RequestRuleTest < ActiveSupport::TestCase
  test "is valid with host only" do
    r = RequestRule.new(host: "api.example.com")
    assert r.valid?
  end

  test "is valid with cidr only" do
    r = RequestRule.new(cidr: "10.0.0.0/8")
    assert r.valid?
  end

  test "is invalid with both host and cidr" do
    r = RequestRule.new(host: "api.example.com", cidr: "10.0.0.0/8")
    assert_not r.valid?
    assert_includes r.errors[:base], "host and cidr are mutually exclusive"
  end

  test "is invalid with neither host nor cidr" do
    r = RequestRule.new
    assert_not r.valid?
    assert_includes r.errors[:base], "either host or cidr must be present"
  end

  test "rejects malformed cidr" do
    r = RequestRule.new(cidr: "not-a-cidr")
    assert_not r.valid?
    assert_includes r.errors[:cidr], "is not a valid CIDR"
  end

  test "accepts valid HTTP methods" do
    r = RequestRule.new(host: "x", http_methods: %w[GET POST])
    assert r.valid?
  end

  test "accepts wildcard method" do
    r = RequestRule.new(host: "x", http_methods: %w[*])
    assert r.valid?
  end

  test "rejects unknown HTTP method" do
    r = RequestRule.new(host: "x", http_methods: %w[BOGUS])
    assert_not r.valid?
    assert r.errors[:http_methods].any? { |m| m.include?("BOGUS") }
  end

  test "rejects lowercase HTTP method" do
    r = RequestRule.new(host: "x", http_methods: %w[get])
    assert_not r.valid?
    assert r.errors[:http_methods].any? { |m| m.include?("get") }
  end

  test "rejects TRACE (not in allowlist)" do
    r = RequestRule.new(host: "x", http_methods: %w[TRACE])
    assert_not r.valid?
  end

  test "http_methods must be an array" do
    r = RequestRule.new(host: "x", http_methods: "GET")
    assert_not r.valid?
    assert_includes r.errors[:http_methods], "must be an array"
  end

  test "accepts path with leading slash" do
    r = RequestRule.new(host: "x", paths: ["/v1/*"])
    assert r.valid?
  end

  test "rejects path without leading slash" do
    r = RequestRule.new(host: "x", paths: ["v1/*"])
    assert_not r.valid?
    assert r.errors[:paths].any? { |m| m.include?("v1/*") }
  end

  test "paths must be an array" do
    r = RequestRule.new(host: "x", paths: "/v1")
    assert_not r.valid?
    assert_includes r.errors[:paths], "must be an array"
  end

  test "position defaults to 0 when not set" do
    RequestRule.delete_all
    a = RequestRule.create!(host: "a.example.com")
    assert_equal 0, a.position
  end

  test "explicit position is respected" do
    RequestRule.delete_all
    a = RequestRule.create!(host: "a.example.com", position: 5)
    assert_equal 5, a.position
  end

  test "default_scope orders by position" do
    RequestRule.delete_all
    c = RequestRule.create!(host: "c.example.com", position: 2)
    a = RequestRule.create!(host: "a.example.com", position: 0)
    b = RequestRule.create!(host: "b.example.com", position: 1)
    assert_equal [ a, b, c ], RequestRule.all.to_a
  end

  test "declares rqr as its oid prefix" do
    assert_equal "rqr", RequestRule.oid_prefix
  end

  test "find_by_oid round-trips" do
    r = request_rules(:api_host)
    assert_equal r, RequestRule.find_by_oid(r.oid)
  end
end

require 'test_helper'
require 'minitest/mock'

class ServerConnectionTest < ActionDispatch::IntegrationTest
  HEADERS_TEXT = "X-Api-Key: abc123\nAuthorization: Bearer token\nmalformed line\n"

  test 'connect stores parsed custom headers in the session and sends them on raw requests' do
    get root_url, params: { server_url: 'http://example.test/fhir', server_headers: HEADERS_TEXT }
    assert_response :success
    assert_equal({ 'X-Api-Key' => 'abc123', 'Authorization' => 'Bearer token' }, session[:server_headers])

    captured = nil
    fake_response = Struct.new(:to_str).new('{"total": 7}')
    RestClient::Request.stub(:execute, ->(args) { captured = args; fake_response }) do
      get resource_count_url(type: 'Location')
    end
    assert_equal 7, response.parsed_body['count']
    assert_equal 'abc123', captured[:headers]['X-Api-Key']
    assert_equal 'Bearer token', captured[:headers]['Authorization']
    assert_equal 'http://example.test/fhir/Location?_summary=count', captured[:url]
  end

  test 'reconnecting with an empty headers field clears stored headers' do
    get root_url, params: { server_url: 'http://example.test/fhir', server_headers: HEADERS_TEXT }
    get root_url, params: { server_url: 'http://example.test/fhir', server_headers: '' }
    assert_equal({}, session[:server_headers])
  end
end

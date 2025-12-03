require 'json'
require 'httparty'

zipcode = 20_854
response = HTTParty.get(
  'http://open.mapquestapi.com/geocoding/v1/address',
  query: {
    key: 'A4F1XOyCcaGmSpgy2bLfQVD5MdJezF0S',
    postalCode: zipcode,
    country: 'USA',
    thumbMaps: false
  }
)
# coords = response.deep_symbolize_keys&.dig(:results)&.first&.dig(:locations).first&.dig(:latLng)
coords = response['results'].first['locations'].first['latLng']
{
  x: coords[:lng],
  y: coords[:lat]
}
puts coords

response = HTTParty.get(
  'https://ndh-server.fast.hl7.org/fhir/HealthcareService',
  query: {
    'location.near' => '42|-71|25|km'
  }
)

jresponse = JSON.parse(response.body)

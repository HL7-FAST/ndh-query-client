# frozen_string_literal: true

################################################################################
#
# Locations Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

require 'json'
require 'cgi'

class LocationsController < ApplicationController

  before_action :connect_to_server, only: [:index, :show]

  #-----------------------------------------------------------------------------

  # GET /locations

  def index
    return unless @client

    if params[:page].present?
      update_page(params[:page])
      @search = search_query_for_display
    else
      if params[:query_string].present?
        query_params = query_hash_from_string(params[:query_string])
        modifiedparams = zip_plus_radius_to_near(query_params) if query_params
        reply = @client.search(
          FHIR::Location,
          search: {
            parameters: modifiedparams.merge(
     #         _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Location'
            )
          }
        )         
      else
        reply = @client.search(
          FHIR::Location,
          search: {
            parameters: {
      #        _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Location'
            }
          }
        )
    end

      @bundle = reply.resource
      @search = search_query_for_display
    end

    update_bundle_links

    @query_params = Location.query_params
    @locations = (@bundle&.entry || []).map(&:resource).select { |r| r.is_a?(FHIR::Location) }
  end

  #-----------------------------------------------------------------------------

  # GET /locations/[id]

  def show
    return unless @client

    reply = @client.read(FHIR::Location, params[:id])
    fhir_location = reply.resource
    @location = Location.new(fhir_location) unless fhir_location.nil?
    @verification_results = fetch_verification_results("Location/#{params[:id]}")
  end

  #-----------------------------------------------------------------------------

  # This version is different than the one in the other two controllers, since it uses "address-postalcode" instead of "zip" and string keys instead of symbols
  def zip_plus_radius_to_near(params)
    #  Convert zipcode + radius to lat/long+radius in the FHIR near format (lat|long|radius|units)
    if params['radius'].present?
      radius = params.delete('radius')
      zip = params.delete('address-postalcode')
      zipcode = Zipcode.find_by_zip(zip) if zip.present?
      params['near'] = "#{zipcode.latitude}|#{zipcode.longitude}|#{radius}|[mi_us]" if zipcode
    end
    params
  end

end

# frozen_string_literal: true

################################################################################
#
# Practitioners Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

require 'json'
require 'cgi'

class PractitionersController < ApplicationController

  before_action :connect_to_server, only: [:index, :show]

  # FHIR.logger.level = Logger::WARN
  #-----------------------------------------------------------------------------

  # GET /practitioners

  def index
    return unless @client

    if params[:page].present?
      update_page(params[:page])
    else
      if params[:query_string].present?
        parameters = query_hash_from_string(params[:query_string])
        reply = @client.search(
          FHIR::Practitioner,
          search: {
            parameters: parameters.merge(
    #          _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Practitioner'
            )
          }
        )
      else
        reply = @client.search(
          FHIR::Practitioner,
          search: {
            parameters: {
     #         _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Practitioner'
            }
          }
        )
      end

      @bundle = reply.resource
      @search = search_query_for_display
    end

    update_bundle_links

    @query_params = Practitioner.query_params
    @practitioners = @bundle.present? ? @bundle.entry.map(&:resource).select { |r| r.is_a?(FHIR::Practitioner) } : []
    @params = params
  end

  #-----------------------------------------------------------------------------

  # GET /practitioners/[id]

  def show
    return unless @client

    reply = @client.read(FHIR::Practitioner, params[:id])
    fhir_practitioner = reply.resource
    @practitioner = Practitioner.new(fhir_practitioner) unless fhir_practitioner.nil?
    @verification_results = fetch_verification_results("Practitioner/#{params[:id]}")
  end

end

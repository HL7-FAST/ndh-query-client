# frozen_string_literal: true

################################################################################
#
# Organizations Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

require 'json'
require 'cgi'

class OrganizationsController < ApplicationController
  
  before_action :connect_to_server, only: [:index, :show]

  #-----------------------------------------------------------------------------

  # GET /organizations

  def index
    return unless @client

    typecodes = 'fac,bus,prvgrp,payer,atyprv'
    if params[:page].present?
      update_page(params[:page])
      @search = search_query_for_display
    else
      if params[:query_string].present?
        parameters = query_hash_from_string(params[:query_string])

        reply = @client.search(
          FHIR::Organization,
          search: {
            parameters: parameters.merge(
       #       _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Organization'
               type:      typecodes         
            )
          }
        )
      else
        reply = @client.search(
          FHIR::Organization,
          search: {
            parameters: {
        #      _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-Organization'
              type:      typecodes    
            }
          }
        )
      end
    
      @bundle = reply.resource
      #binding.pry 
      @search = search_query_for_display
    end

    update_bundle_links

    @query_params = Organization.query_params
    @organizations = []
    @organizations = (@bundle&.entry || []).map(&:resource).select { |r| r.is_a?(FHIR::Organization) } if @bundle
  end

  #-----------------------------------------------------------------------------

  # GET /organizations/[id]

  def show
    return unless @client

    reply = @client.read(FHIR::Organization, params[:id])
    fhir_organization = reply.resource
    @organization = Organization.new(fhir_organization) unless fhir_organization.nil?
    @verification_results = fetch_verification_results("Organization/#{params[:id]}")
  end

end

# frozen_string_literal: true

################################################################################
#
# Practitioner Roles Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

require 'json'
require 'cgi'

class PractitionerRolesController < ApplicationController

  before_action :connect_to_server, only: [:index, :show]

  #-----------------------------------------------------------------------------

  # GET /practitioner_roles

  def index
    return unless @client

    if params[:page].present?
      update_page(params[:page])
    else
      if params[:query_string].present?
        parameters = query_hash_from_string(params[:query_string])
        reply = @client.search(
          FHIR::PractitionerRole,
          search: {
            parameters: parameters.merge(
     #         _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-PractitionerRole'
            )
          }
        )
      else
        reply = @client.search(
          FHIR::PractitionerRole,
          search: {
            parameters: {
      #        _profile: 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-PractitionerRole'
            }
          }
        )
      end

      @bundle = reply.resource
      @search = "<Search String in Returned Bundle is empty>"
      @search = CGI.unescape(@bundle.link.select { |l| l.relation === "self"}.first.url) if @bundle.link.first 
   end

    update_bundle_links

    @query_params = PractitionerRole.query_params
    @practitioner_roles = @bundle.entry.map(&:resource)
  end

  #-----------------------------------------------------------------------------

  # GET /practitioner_roles/[id]

  def show
    return unless @client

    reply = @client.read(FHIR::PractitionerRole, params[:id])
  fhir_practitioner_role = reply.resource
  @practitioner_role = PractitionerRole.new(fhir_practitioner_role) unless fhir_practitioner_role.nil?
  end

end

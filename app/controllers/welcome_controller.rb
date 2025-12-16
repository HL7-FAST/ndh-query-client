# frozen_string_literal: true

################################################################################
#
# Welcome Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

require 'json'

class WelcomeController < ApplicationController
  # GET /

  def index
    connect_to_server
    get_resource_counts
  end

  def get_resource_counts
    @endpoints = 0
    @healthCareServices = 0
    @insurancePlans = 0
    @locations = 0
    @networks = 0
    @organizations = 0
    @organizationAffiliations = 0
    @practitioners = 0
    @practitionerRoles = 0

    response = RestClient::Request.new(method: :get, url: server_url + '/$get-resource-counts').execute
    results = JSON.parse(response.to_str)
    results['parameter'].each do |param|
      case param['name']
      when 'Endpoint'
        @endpoints = param['valueInteger']
      when 'HealthcareService'
        @healthCareServices = param['valueInteger']
      when 'InsurancePlan'
        @insurancePlans = param['valueInteger']
      when 'Location'
        @locations = param['valueInteger']
      # when "Network"
      #   @networks = param["valueInteger"]
      when 'Organization'
        @organizations = param['valueInteger']
      when 'OrganizationAffiliation'
        @organizationAffiliations = param['valueInteger']
      when 'Practitioner'
        @practitioners = param['valueInteger']
      when 'PractitionerRole'
        @practitionerRoles = param['valueInteger']
      end
    end

    # Network isn't a resource so we will query for its count separately
    response = RestClient::Request.new(method: :get,
                                       url: "#{server_url}/Organization?type=ntwk&_total=accurate").execute
    results = JSON.parse(response.to_str)
    @networks = results['total']
  rescue StandardError => e
    @endpoints = 0
    @healthCareServices = 0
    @insurancePlans = 0
    @locations = 0
    @networks = 0
    @organizations = 0
    @organizationAffiliations = 0
    @practitioners = 0
    @practitionerRoles = 0
  end
end

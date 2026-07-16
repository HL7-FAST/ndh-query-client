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
  COUNTABLE_TYPES = %w[
    Endpoint HealthcareService InsurancePlan Location Organization
    OrganizationAffiliation Practitioner PractitionerRole
  ].freeze

  # GET /

  def index
    connect_to_server
  end

  # GET /resource_counts
  #
  # Returns all counts at once via the non-standard $get-resource-counts
  # operation (fast on HAPI-based servers). Returns null counts if the server
  # does not support the operation; the front page then falls back to
  # per-type _summary=count requests.

  def counts
    return head :bad_request unless server_url.present?

    response = RestClient::Request.new(
      method: :get,
      url: "#{server_url}/$get-resource-counts",
      headers: { accept: 'application/fhir+json' },
      timeout: 15
    ).execute
    parameters = JSON.parse(response.to_str)['parameter']
    render json: { counts: parameters.to_h { |p| [p['name'], p['valueInteger']] } }
  rescue StandardError
    render json: { counts: nil }
  end

  # GET /resource_count?type=Location
  #
  # Returns the total for a single resource type using a standard
  # _summary=count search. Used as the fallback when $get-resource-counts is
  # unavailable, and always for Network (the operation does not report it).
  # A null count with an error means the request failed; a null count without
  # one means the server responded but omitted Bundle.total (it is optional).

  def count
    query = if params[:type] == 'Network'
              'Organization?type=ntwk&_summary=count'
            elsif COUNTABLE_TYPES.include?(params[:type])
              "#{params[:type]}?_summary=count"
            end
    return head :bad_request unless query && server_url.present?

    response = RestClient::Request.new(
      method: :get,
      url: "#{server_url}/#{query}",
      headers: { accept: 'application/fhir+json' },
      timeout: 15
    ).execute
    render json: { count: JSON.parse(response.to_str)['total'] }
  rescue RestClient::ExceptionWithResponse => e
    details = operation_outcome_diagnostics(e.response)
    render json: { count: nil, error: ["HTTP #{e.http_code}", details].compact_blank.join(': ') }
  rescue StandardError => e
    render json: { count: nil, error: e.message }
  end
end

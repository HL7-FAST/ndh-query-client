# frozen_string_literal: true

################################################################################
#
# Endpoint Model
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

class Endpoint < Resource
  include ActiveModel::Model

  attr_accessor :id, :meta, :implicit_rules, :language, :text, :identifier,
                :active, :connection_type, :name, :managing_organization,
                :contacts, :period, :payload_types, :payload_mime_types,
                :headers, :extensions

  #-----------------------------------------------------------------------------

  def initialize(endpoint)
    @id = endpoint.id
    @connection_type = endpoint.connectionType
    @name = endpoint.name
    @managing_organization = endpoint.managingOrganization
    @contacts = endpoint.contact
    @period = endpoint.period
    @payload_types = endpoint.payloadType
    @payload_mime_types = endpoint.payloadMimeType
    @headers = endpoint.header
    @extensions = endpoint.extension
  end

  #-----------------------------------------------------------------------------

  # FHIR search query parameters for Endpoints are:
  #
  #   _id, _language, connection-type, identifier, identifier-assigner, mime-type,
  #   name, organization, payload-type, status, usecase-standard, usecase-type,
  #   via-intermediary

  def self.search(server, query)
    parameters = {}

    query.each do |key, value|
      parameters[key] = value unless value.empty?
    end

    server.search(FHIR::Endpoint, search: { parameters: parameters })
  end

  #-----------------------------------------------------------------------------

  def self.query_params
    [
      {
        name: 'Connection Type',
        value: 'connection-type'
      },
      {
        name: 'ID',
        value: '_id'
      },
      {
        name: 'Last Updated',
        value: '_lastUpdated'
      },
      {
        name: 'Identifier',
        value: 'identifier'
      },
      #{
      #  name: 'Identifier Assigner',
      #  value: 'identifier-assigner'
      #},
     # {
     #   name: 'Intermediary',
     #   value: 'via-intermediary'
     # },
      #{
      #  name: 'MIME Type',
      #  value: 'mime-type'
      #},

      {
        name: 'Use Case Type',
        value: 'endpoint-usecase-type'
      },
      {
        name: 'Non-FHIR Use Case Type',
        value: 'endpoint-nonfhir-usecase-type'
      },
      {
        name: 'Trust Framework Type',
        value: 'endpoint-trust-framework-type'
      },
      {
        name: 'Dynamic Registration Trust Profile',
        value: 'endpoint-dynamic-registration-trust-profile'
      },
      {
        name: 'Access Control Mechanism',
        value: 'endpoint-access-control-mechanism'
      },
      {
        name: 'Connection Type Version',
        value: 'endpoint-connection-type-version'
      },
      {
        name: 'IHE Connection Type',
        value: 'endpoint-ihe-connection-type'
      },
      {
        name: 'Verification Status',
        value: 'endpoint-verification-status'
      },
      {
        name: 'Organization',
        value: 'organization'
      },
      {
        name: 'Payload Type',
        value: 'payload-type'
      },
      {
        name: 'Status',
        value: 'status'
      },
      {
        name: 'Use Case Standard',
        value: 'endpoint-usecase-standard'
      }
    ]
  end

end

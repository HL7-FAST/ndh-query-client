# frozen_string_literal: true

################################################################################
#
# Application Helper
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################
require 'httparty'

module ApplicationHelper
  # Determines the CSS class of the flash message for display from the
  # specified level.
  
  def flash_class(level)
    case level
    when 'notice'
      css_class = 'alert-info'
    when 'success'
      css_class = 'alert-success'
    when 'error'
      css_class = 'alert-danger'
    when 'alert'
      css_class = 'alert-danger'
    end

    css_class
  end

  #-----------------------------------------------------------------------------

 
  def display_human_name(name)

    if !name.try(:text).nil?
      result = name.try(:text)
    else
      
      if !name.try(:prefix).nil?
        result = name.try(:prefix).join(', ')
      end
  
      if !name.try(:given).nil?
        if result.length != 0
          result = result + ' '
        end
        result = result + name.try(:given).join(', ')
      end
      if !name.try(:family).nil?
        if result.length != 0
          result = result + ' '
        end
        result = result + name.try(:family)
      end
  
      if !name.try(:suffix).nil?
        if result.length != 0
          result = result + ' '
        end
        result = result + name.try(:suffix).join(', ')
      end
      
    end

    sanitize(result)
    
  end


  #def display_human_name(name)
  #  result = "None"
  #  puts name.inspect

    #result = [if name.prefix.nil? '' : name.prefix.join(', '), if name.given.nil? '' : name.given.join(' '), if name.family.nil? '' : name.family].join(' ')
  #  result = name.family
  #  result = [if name.prefix.nil? '' : name.prefix.join(', '), if name.given.nil? '' : name.given.join(' '), if name.family.nil? '' : name.family].join(' ')
    #result += ', ' + name.suffix.join(', ') if name.suffix.present?
  #  sanitize(result)
  #end

  #-----------------------------------------------------------------------------

  def display_telecom(telecom)
    if !telecom.try(:value).nil?
      if !telecom.try(:system).nil?
        sanitize(telecom.try(:system) + ': ' + number_to_phone(telecom.try(:value), area_code: true))
      else
        sanitize('contact: ' + number_to_phone(telecom.try(:value), area_code: true))
      end
    end
  end

  #-----------------------------------------------------------------------------

  def display_identifier(identifier)
    if !identifier.try(:assigner).nil? && !identifier.assigner.try(:display).nil? && !identifier.try(:type).nil? && !identifier.type.try(:text).nil? && !identifier.try(:value).nil?
      sanitize("#{identifier.assigner.display}: ( #{identifier.type&.text}, #{identifier.value})")
    elsif !identifier.try(:value).nil?
      sanitize("#{identifier.value}")
    end
  #    sanitize([identifier.type.text, identifier.value, identifier.assigner.display].join(', '))
  end

  #-----------------------------------------------------------------------------

  # Concatenates a list of display elements.

  def display_list(list)
    sanitize(list.empty? ? 'None' : list.map(&:display).join(', '))
  end

  #-----------------------------------------------------------------------------

  # Concatenates a list of code elements.

  def display_code_list(list)
    sanitize(list.empty? ? 'None' : list.map(&:code).join(', '))
  end

  #-----------------------------------------------------------------------------

  # Concatenates a list of coding display elements.

  def display_coding_list(list)
    if list.empty?
      result = 'None'
    else
      result = []
      #result = list.map{|coding| display_coding(coding)}
      list.map(&:coding).each do |item|
        #result << coding.map(&:display)
        item.each { |coding| result << display_coding(coding) }
        #result << coding.code
      
      end
      result = result.join(',<br />')
    end

    sanitize(result)
  end

  def display_CodeableConcept(codeableConcept)
    if codeableConcept.text.present?
      result = codeableConcept.text
    else
      result = display_coding(codeableConcept.coding[0])
    end
    sanitize(result)
  end

  def display_coding(coding)
    if coding.display.present?
      result = coding.display
    elsif coding.code.present?
      result = coding.code
    end
    sanitize(result)
  end

  #-----------------------------------------------------------------------------

  def google_maps(address)
    if address.present?
      'https://www.google.com/maps/search/' + html_escape(address.text)
    end
  end

  #-----------------------------------------------------------------------------

  def display_address(address)
    if address.present?
      result =  link_to(google_maps(address)) do 
                  [address.line.join('<br />'), 
                  [[address.city, address.state].join(', '), 
                          display_postal_code(address.postalCode)].join(' ')
                  ].join('<br />').html_safe
                end
    else
      result = 'None'
    end
    
    sanitize(result)
  end

  #-----------------------------------------------------------------------------

  def display_postal_code(postal_code)
    sanitize(postal_code.match(/^\d{9}$/) ?
        postal_code.strip.sub(/([A-Z0-9]+)([A-Z0-9]{4})/, '\1-\2') : postal_code)
  end

  #-----------------------------------------------------------------------------

  def controller_type (reference)
  end

  #-----------------------------------------------------------------------------

  def display_reference(reference, use_controller: "default")
    if reference.present?
      components = reference.reference.split('/')
      if use_controller.eql?("default")
        controller = components.first.underscore.pluralize
      else
        controller = use_controller
      end

      sanitize(link_to(reference.display,
                       ["/",controller, '/', components.last].join))
    end
  end

  #-----------------------------------------------------------------------------
  
  # use_controller allows us to display networks using the network 
  # controller/view, rather than the organization controller/view.
  # a network is-a organization, but their display needs may be distinct.

  def display_reference_list(list,use_controller: "default")
    sanitize(list.map { |element| display_reference(element,use_controller:use_controller) }.join(',<br />'))
  end

  #-----------------------------------------------------------------------------

  def display_extension_list(list)
    sanitize(list.map { |extension| display_reference(extension.valueReference) }.join(',<br />'))
  end

  def display_leaf_extension(list)
      if list.valueCodeableConcept.present?
        result = display_CodeableConcept(list.valueCodeableConcept)
      elsif list.valueCoding.present?
          result = display_coding(list.valueCodeableConcept.valueCoding)
      elsif list.valueIdentifier.present?
          result = display_identifier(list.valueIdentifier)
      elsif list.valueString.present?
          result = list.valueString
      elsif list.valueCode.present?
          result = list.valueCode
      elsif list.valueReference.present?
          result = display_reference(list.valueReference)
        elsif list.valueBoolean.present?
          result = list.valueBoolean
      end
  end

  #def get_extension(list, parent_url, child_url = 'None')
  #  if extensions.present?
  ##    extensions.each do |extension|
  #        if extension.url.include?(url)
  #          if child_url != 'None'
  #           extension.extension.each do |latlong|
  #            if latlong.url.include?('latitude')
  #                lat = latlong.valueDecimal
  #            end
  #            if latlong.url.include?('longitude')
  #              long = latlong.valueDecimal
  #            end
  #        end
  #        @geolocation << {latitude: lat, longitude: long }
  #    end
  #end


  #-----------------------------------------------------------------------------

  def display_location_type(list)
    if list.empty?
      result = 'None'
    else
      result = list.map(&:text).join(',<br />')
    end

    sanitize(result)
  end

  #-----------------------------------------------------------------------------

  def format_zip(zip)
    if zip.length > 5
      "#{zip[0..4]}-#{zip[5..-1]}"
    else
      zip
    end
  end
  
end

def format_phone(phone)
  phone.tr('^0-9', '')  
  if phone.length == 10
    "(#{phone[0..2]}) #{phone[3..5]}-#{phone[6..9]}"
  elsif phone.length == 11
    "+#{phone[1]} (#{phone[1..3]}) #{phone[4..6]}-#{phone[7..10]}"
  else
    phone
  end
end




  #-----------------------------------------------------------------------------
  # Extension Descriptions - Rather simplistic and prone to collisions with children. Ideally would separate and make smarter.
  def extension_title(url)
    titles = {
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-newpatients" => "New Patients",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-delivery-method" => "Delivery Method",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-rating" => "Rating",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-paymentAccepted" => "Payment Accepted",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-requiredDocument" => "Required Document",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-fundingSource" => "Funding Source",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-usage-restriction" => "Useage Restriction",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-verification-status" => "Verification Status",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-network-reference" => "Network",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-service-or-program-requirement" => "Service or Program Requirement",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-org-description" => "Organization Description",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-qualification" => "Qualification",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-accessibility" => "Accessibility",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-associatedServers" => "Associated Servers",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-careteam-alias" => "Care Team Alias",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-combined-payload-and-mimetype" => "Payload and MIME Type",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-communication-proficiency" => "Communication Proficiency",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-contactpoint-availabletime" => "Contact Point Available TIme",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-digitalcertificate" => "Digital Certificate",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-dynamicRegistration" => "Dynamic Registration",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpointAccessControlMechanism" => "Access Control Mechanism",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-connection-type-version" => "Connection Type Version",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-ihe-specific-connection-type" => "IHE Connection Type",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-non-fhir-usecase" => "Non-FHIR Use Case",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-ig-supported" => "IG Supported",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-healthcareservice-reference" => "Healthcare Service",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-usecase" => "Use Cases",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-reference" => "Endpoint",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-endpoint-rank" => "Endpoint Rank",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-fhir-ig" => "FHIR IG",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-identifier-status" => "Identifier Status",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-insuranceplan-reference" => "Insurance Plan",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-language-speak" => "Languages Spoken",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-location-reference" => "Location",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-logo" => "Logo",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-network-reference" => "Network",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-org-alias-period" => "Alias Period",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-org-alias-type" => "Alias Type",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-practitioner-qualification" => "Qualification",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-rating-details" => "Rating Details",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-secureExchangeArtifacts" => "Secure Exchange Artifacts",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-supported-ig-actor" => "Supported IG Actor",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-trustFramework" => "Trust Framework",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-restrictFhirPath" => "Restrict FHIR Path",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-via-intermediary" => "Intermediary",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-secureEndpoint" => "Secure Endpoint",
      "http://hl7.org/fhir/us/ndh/StructureDefinition/base-ext-igsSupported" => "IGs Supported",
      "ratingType" => "Type",
      "ratingValue" => " Value",
      "ratingSystem" => "System",
      "acceptingPatients" => "Accepting new patients",
      "fromNetwork" => "Accepting patients from network",
      "characteristics" => "Characteristics",
      "deliveryMethodtype" => "Delivery method type",
      "virtualModalities" => "Virtual modalities",
      "requiredDocumentId" => "ID",
      "document" => "Document",
      "fundingSourceId" => "ID",
      "fundingOrganization" => "Organization",
      "fundingSource" => "Source",
      "age-range" => "Age range requirement",
      "age-group" => "Age group requirement",
      "birthsex" => "Birth sex requirement",
      "gender-identity" => "Gender identity requirement",
      "employment-status" => "Employment status requirement",
      "insurance-status" => "Insurance status requirement",
      "va-status" => "VA status requirement",
      "preferred-language" => "Preferred language requirement",
      "whereValid" => "Where valid",
      "associatedServersType" => "Type",
      "serverURL" => "URL",
      "mimeType" => "MIME type",
      "daysOfWeek" => "Days of week",
      "allDay" => "All day",
      "availableStartTime" => "Start time",
      "availableEndTime" => "End time",
      "expirationDate" => "Expiration date",
      "trustProfile" => "Trust profile",
      "endpointUsecasetype" => "Use case type",
      "ig-publication" => "Publication",
      "ig-name" => "Name",
      "ig-version" => "Version",
      "endpointUsecasetype" => "Use case type",
      "secureExchangeArtifactsType" => "Type",
      "ig-actor-name" => "Actor name",
      "ig-actor" => "Actor",
      "trustFrameworkType" => "Type",
      "signedArtifact" => "Signed artifact",
      "publicCertificate" => "Public certificate"
    }
    if titles.key?(url)
      result = titles[url]
    else
      if(url.start_with?('http'))
        result = url
      else
        result = url.capitalize
      end
    end

  end 
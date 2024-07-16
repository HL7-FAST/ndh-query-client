# frozen_string_literal: true
require "erb"
require 'pry'

################################################################################
#
# Application Controller
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

class ApplicationController < ActionController::Base

  include ERB::Util
  FHIR.logger.level = Logger::DEBUG

  #-----------------------------------------------------------------------------

  # Get the FHIR server url
  def server_url
    url = (params[:server_url] || session[:server_url])
    url = url.strip if url 
  end

  #-----------------------------------------------------------------------------

  def setup_dalli
    unless Rails.env.production?
      options = { :namespace => "ndh-query-client", :compress => true }
      @dalli_client = Dalli::Client.new('localhost:11211', options)
    end
  end

  #-----------------------------------------------------------------------------

  # Connect the FHIR client with the specified server and save the connection
  # for future requests.

  def connect_to_server
    if server_url.present?
      @client = FHIR::Client.new(server_url)
      @client.use_r4
      @client.additional_headers = { 'Accept-Encoding' => 'identity' }  # 
      @client.set_basic_auth("fhiruser","change-password")
      cookies[:server_url] = server_url
      session[:server_url] = server_url      
    end

    rescue => exception
      err = "Connection failed: Ensure provided url points to a valid FHIR server"
      redirect_to root_path, flash: { error: err }
  end

  #-----------------------------------------------------------------------------

  def update_bundle_links
    session[:next_bundle] = @bundle&.next_link&.url
    session[:previous_bundle] = @bundle&.previous_link&.url
    @next_page_disabled = session[:next_bundle].blank? ? 'disabled' : ''
    @previous_page_disabled = session[:previous_bundle].blank? ? 'disabled' : ''
  end

  #-----------------------------------------------------------------------------

  # Performs pagination on the resource list.
  #
  # Params:
  #   +page+:: which page to get

  def update_page(page)
    case page
    when 'previous'
      @bundle = previous_bundle
    when 'next'
      @bundle = next_bundle
    end
  end

  #-----------------------------------------------------------------------------

  # Retrieves the previous bundle page from the FHIR server.

  def previous_bundle
    url = session[:previous_bundle]

    if url.present?
      @client.parse_reply(FHIR::Bundle, @client.default_format,
                          @client.raw_read_url(url))
    end
  end

  #-----------------------------------------------------------------------------

  # Retrieves the next bundle page from the FHIR server.

  def next_bundle
    url = session[:next_bundle]

    if url.present?
      @client.parse_reply(FHIR::Bundle, @client.default_format,
                          @client.raw_read_url(url))
    end
  end

  #-----------------------------------------------------------------------------

  # Turns a query string such as "name=abc&id=123" into a hash like
  # { 'name' => 'abc', 'id' => '123' }
  def query_hash_from_string(query_string)
    query_string.split('&').each_with_object({}) do |string, hash|
      key, value = string.split('=')
      hash[key] = value
    end
  end

  #-----------------------------------------------------------------------------

  def fetch_payers
    # binding.pry 
    @payers = @client.search(
      FHIR::Organization,
      search: { parameters: { type: 'payer' } }
    ).resource.entry.map do |entry|
      {
        value: entry.resource.id,
        name: entry.resource.name
      }
    end
    
  rescue => exception
    redirect_to root_path, flash: { error: 'Please specify a plan network server (fetch_payers)' }
  end

  #-----------------------------------------------------------------------------

  # Fetch all plans, and remember their resources, names, and networks

  def fetch_plans (id = nil)
    @plans = []
    parameters = {}
    @networks_by_plan = {}

    #parameters[:_profile] = 'http://hl7.org/fhir/us/davinci-pdex-plan-net/StructureDefinition/plannet-InsurancePlan' 
    parameters[:_count] = 100
    if (id.present?)
      parameters[:_id] = id
    end

    insurance_plans = @client.search(FHIR::InsurancePlan,
                                      search: { parameters: parameters })
    if good_response(insurance_plans.response[:code]) 
      insurance_plans.resource.entry.map do |entry|
        if entry.resource.id.present? && entry.resource.name.present?
          @plans << {
            value: entry.resource.id,
            name: entry.resource.name
          }
          @networks_by_plan[entry.resource.id] = entry.resource.network
        end
      end

      @plans.sort_by! { |hsh| hsh[:name] }
    else
      redirect_to root_path, 
          flash: { error: "Could not retrieve insurance plans from the server (fetch_plans, " + 
                        insurance_plans.response[:code].to_s + ")" }
    end
  end

  #-----------------------------------------------------------------------------

  # GET /providers/networks or /pharmacies/networks -- perhaps this should be in the networks controller?

  def networks
    id = params[:_id]
    fetch_plans(id)
    networks = @networks_by_plan[id]
    network_list = networks.map do |entry|
      {
        value: entry.reference,
        name: entry.display
      }
    end
    render json: network_list
  end

  #-----------------------------------------------------------------------------

  def zip_plus_radius_to_address(params)
    #  Convert zipcode + radius to address='zipcode list'
    if params[:zip].present?   # delete zip and radius params and replace with address
      zip = params[:zip]
      params.delete(:zip)
      radius = 5 # default
      if params[:radius].present?
        radius = params[:radius].to_i
        params.delete(:radius)
      end
      params[:zipcode] = Zipcode.zipcodes_within(radius, zip).join(',')
    end
    params
  end

  #-----------------------------------------------------------------------------

  def display_human_name(name)
    result = [name.prefix.join(', '), name.given.join(' '), name.family].join(' ')
    result += ', ' + name.suffix.join(', ') if name.suffix.present?
    result
  end

  #-----------------------------------------------------------------------------

  def display_telecom(telecom)

    if telecom.try(:system).nil?
      telecom.try(:system) + ': ' + telecom.try(:value)
    else
      'contact: ' + format_phone(telecom.try(:value))
    end
  end

  #-----------------------------------------------------------------------------

  def display_address(address)
    if address.present?
      "<a href = \"" + "https://www.google.com/maps/search/" + html_escape(address.text) +
       "\" >" +
      address.line.join('<br>') + 
      "<br>#{address.city}, #{address.state} #{format_zip(address.postalCode)}" + 
      "</a>"
    end
  end

  #-----------------------------------------------------------------------------

  def prepare_query_text(query,klass)
    a = []
    query.each do |key,value| 
      if value.class==Array 
        value.map do  |entry| 
          a << "#{key}=#{entry}"  
        end
      else
        a <<  "#{key}=#{value}"  
      end
    end
    "#{server_url}/#{klass}?" + a.join('&')
  end

  #-----------------------------------------------------------------------------

  def format_zip(zip)
    if zip.length > 5
      "#{zip[0..4]}-#{zip[5..-1]}"
    else
      zip
    end
  end

  #-----------------------------------------------------------------------------

  def good_response(response)
    response >= 200 && response < 300
  end

  #-----------------------------------------------------------------------------



  #-----------------------------------------------------------------------------
  # Terminologies
  NON_INDIVIDUAL_SPECIALTIES = [
    { value: 'http://nucc.org/provider-taxonomy|251300000X', name: 'Local Education Agency (LEA)' },
    { value: 'http://nucc.org/provider-taxonomy|251B00000X', name: 'Case Management Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251C00000X', name: 'Developmentally Disabled Services Day Training Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251E00000X', name: 'Home Health Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251F00000X', name: 'Home Infusion Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251G00000X', name: 'Community Based Hospice Care Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251J00000X', name: 'Nursing Care Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251K00000X', name: 'Public Health or Welfare Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251S00000X', name: 'Community/Behavioral Health Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251T00000X', name: 'PACE Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|251V00000X', name: 'Voluntary or Charitable Agency' },
    { value: 'http://nucc.org/provider-taxonomy|251X00000X', name: 'Supports Brokerage Agency' },
    { value: 'http://nucc.org/provider-taxonomy|252Y00000X', name: 'Early Intervention Provider Agency' },
    { value: 'http://nucc.org/provider-taxonomy|253J00000X', name: 'Foster Care Agency' },
    { value: 'http://nucc.org/provider-taxonomy|253Z00000X', name: 'In Home Supportive Care Agency' },
    { value: 'http://nucc.org/provider-taxonomy|261Q00000X', name: 'Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QA0005X', name: 'Ambulatory Family Planning Facility' },
    { value: 'http://nucc.org/provider-taxonomy|261QA0006X', name: 'Ambulatory Fertility Facility' },
    { value: 'http://nucc.org/provider-taxonomy|261QA0600X', name: 'Adult Day Care Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QA0900X', name: 'Amputee Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QA1903X', name: 'Ambulatory Surgical Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QA3000X', name: 'Augmentative Communication Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QB0400X', name: 'Birthing Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QC0050X', name: 'Critical Access Hospital Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QC1500X', name: 'Community Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QC1800X', name: 'Corporate Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QD0000X', name: 'Dental Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QD1600X', name: 'Developmental Disabilities Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QE0002X', name: 'Emergency Care Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QE0700X', name: 'End-Stage Renal Disease (ESRD) Treatment Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QE0800X', name: 'Endoscopy Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QF0050X', name: 'Non-Surgical Family Planning Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QF0400X', name: 'Federally Qualified Health Center (FQHC)' },
    { value: 'http://nucc.org/provider-taxonomy|261QG0250X', name: 'Genetics Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QH0100X', name: 'Health Service Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QH0700X', name: 'Hearing and Speech Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QI0500X', name: 'Infusion Therapy Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QL0400X', name: 'Lithotripsy Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM0801X', name: 'Mental Health Clinic/Center (Including Community Mental Health Center)' },
    { value: 'http://nucc.org/provider-taxonomy|261QM0850X', name: 'Adult Mental Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM0855X', name: 'Adolescent and Children Mental Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1000X', name: 'Migrant Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1100X', name: 'Military/U.S. Coast Guard Outpatient Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1101X', name: 'Military and U.S. Coast Guard Ambulatory Procedure Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1102X', name: 'Military Outpatient Operational (Transportable) Component Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1103X', name: 'Military Ambulatory Procedure Visits Operational (Transportable) Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1200X', name: 'Magnetic Resonance Imaging (MRI) Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM1300X', name: 'Multi-Specialty Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM2500X', name: 'Medical Specialty Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QM2800X', name: 'Methadone Clinic' },
    { value: 'http://nucc.org/provider-taxonomy|261QM3000X', name: 'Medically Fragile Infants and Children Day Care' },
    { value: 'http://nucc.org/provider-taxonomy|261QP0904X', name: 'Federal Public Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP0905X', name: 'State or Local Public Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP1100X', name: 'Podiatric Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP2000X', name: 'Physical Therapy Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP2300X', name: 'Primary Care Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP2400X', name: 'Prison Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QP3300X', name: 'Pain Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0200X', name: 'Radiology Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0206X', name: 'Mammography Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0207X', name: 'Mobile Mammography Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0208X', name: 'Mobile Radiology Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0400X', name: 'Rehabilitation Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0401X', name: 'Comprehensive Outpatient Rehabilitation Facility (CORF)' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0404X', name: 'Cardiac Rehabilitation Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0405X', name: 'Substance Use Disorder Rehabilitation Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR0800X', name: 'Recovery Care Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR1100X', name: 'Research Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QR1300X', name: 'Rural Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QS0112X', name: 'Oral and Maxillofacial Surgery Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QS0132X', name: 'Ophthalmologic Surgery Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QS1000X', name: 'Student Health Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QS1200X', name: 'Sleep Disorder Diagnostic Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QU0200X', name: 'Urgent Care Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QV0200X', name: 'VA Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QX0100X', name: 'Occupational Medicine Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QX0200X', name: 'Oncology Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|261QX0203X', name: 'Radiation Oncology Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|273100000X', name: 'Epilepsy Hospital Unit' },
    { value: 'http://nucc.org/provider-taxonomy|273R00000X', name: 'Psychiatric Hospital Unit' },
    { value: 'http://nucc.org/provider-taxonomy|273Y00000X', name: 'Rehabilitation Hospital Unit' },
    { value: 'http://nucc.org/provider-taxonomy|275N00000X', name: 'Medicare Defined Swing Bed Hospital Unit' },
    { value: 'http://nucc.org/provider-taxonomy|276400000X', name: 'Substance Use Disorder Rehabilitation Hospital Unit' },
    { value: 'http://nucc.org/provider-taxonomy|281P00000X', name: 'Chronic Disease Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|281PC2000X', name: 'Childrens Chronic Disease Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282E00000X', name: 'Long Term Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282J00000X', name: 'Religious Nonmedical Health Care Institution' },
    { value: 'http://nucc.org/provider-taxonomy|282N00000X', name: 'General Acute Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282NC0060X', name: 'Critical Access Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282NC2000X', name: 'Childrens Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282NR1301X', name: 'Rural Acute Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282NW0100X', name: 'Womens Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|283Q00000X', name: 'Psychiatric Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|283X00000X', name: 'Rehabilitation Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|283XC2000X', name: 'Childrens Rehabilitation Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|284300000X', name: 'Special Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|286500000X', name: 'Military Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|2865M2000X', name: 'Military General Acute Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|2865X1600X', name: 'Operational (Transportable) Military General Acute Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|291900000X', name: 'Military Clinical Medical Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|291U00000X', name: 'Clinical Medical Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|292200000X', name: 'Dental Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|293D00000X', name: 'Physiological Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|302F00000X', name: 'Exclusive Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|302R00000X', name: 'Health Maintenance Organization' },
    { value: 'http://nucc.org/provider-taxonomy|305R00000X', name: 'Preferred Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|305S00000X', name: 'Point of Service' },
    { value: 'http://nucc.org/provider-taxonomy|310400000X', name: 'Assisted Living Facility' },
    { value: 'http://nucc.org/provider-taxonomy|3104A0625X', name: 'Assisted Living Facility (Mental Illness)' },
    { value: 'http://nucc.org/provider-taxonomy|3104A0630X', name: 'Assisted Living Facility (Behavioral Disturbances)' },
    { value: 'http://nucc.org/provider-taxonomy|310500000X', name: 'Mental Illness Intermediate Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|311500000X', name: 'Alzheimer Center (Dementia Center)' },
    { value: 'http://nucc.org/provider-taxonomy|311Z00000X', name: 'Custodial Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|311ZA0620X', name: 'Adult Care Home Facility' },
    { value: 'http://nucc.org/provider-taxonomy|313M00000X', name: 'Nursing Facility/Intermediate Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|314000000X', name: 'Skilled Nursing Facility' },
    { value: 'http://nucc.org/provider-taxonomy|3140N1450X', name: 'Pediatric Skilled Nursing Facility' },
    { value: 'http://nucc.org/provider-taxonomy|315D00000X', name: 'Inpatient Hospice' },
    { value: 'http://nucc.org/provider-taxonomy|315P00000X', name: 'Intellectual Disabilities Intermediate Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|174200000X', name: 'Meals Provider' },
    { value: 'http://nucc.org/provider-taxonomy|177F00000X', name: 'Lodging Provider' },
    { value: 'http://nucc.org/provider-taxonomy|320600000X', name: 'Intellectual and/or Developmental Disabilities Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|320700000X', name: 'Physical Disabilities Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|320800000X', name: 'Mental Illness Community Based Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|320900000X', name: 'Intellectual and/or Developmental Disabilities Community Based Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|322D00000X', name: 'Emotionally Disturbed Childrens Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|323P00000X', name: 'Psychiatric Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|324500000X', name: 'Substance Abuse Rehabilitation Facility' },
    { value: 'http://nucc.org/provider-taxonomy|3245S0500X', name: 'Childrens Substance Abuse Rehabilitation Facility' },
    { value: 'http://nucc.org/provider-taxonomy|385H00000X', name: 'Respite Care' },
    { value: 'http://nucc.org/provider-taxonomy|385HR2050X', name: 'Respite Care Camp' },
    { value: 'http://nucc.org/provider-taxonomy|385HR2055X', name: 'Child Mental Illness Respite Care' },
    { value: 'http://nucc.org/provider-taxonomy|385HR2060X', name: 'Child Intellectual and/or Developmental Disabilities Respite Care' },
    { value: 'http://nucc.org/provider-taxonomy|385HR2065X', name: 'Child Physical Disabilities Respite Care' },
    { value: 'http://nucc.org/provider-taxonomy|331L00000X', name: 'Blood Bank' },
    { value: 'http://nucc.org/provider-taxonomy|332000000X', name: 'Military/U.S. Coast Guard Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332100000X', name: 'Department of Veterans Affairs (VA) Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332800000X', name: 'Indian Health Service/Tribal/Urban Indian Health (I/T/U) Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332900000X', name: 'Non-Pharmacy Dispensing Site' },
    { value: 'http://nucc.org/provider-taxonomy|332B00000X', name: 'Durable Medical Equipment & Medical Supplies' },
    { value: 'http://nucc.org/provider-taxonomy|332BC3200X', name: 'Customized Equipment (DME)' },
    { value: 'http://nucc.org/provider-taxonomy|332BD1200X', name: 'Dialysis Equipment & Supplies (DME)' },
    { value: 'http://nucc.org/provider-taxonomy|332BN1400X', name: 'Nursing Facility Supplies (DME)' },
    { value: 'http://nucc.org/provider-taxonomy|332BP3500X', name: 'Parenteral & Enteral Nutrition Supplies (DME)' },
    { value: 'http://nucc.org/provider-taxonomy|332BX2000X', name: 'Oxygen Equipment & Supplies (DME)' },
    { value: 'http://nucc.org/provider-taxonomy|332G00000X', name: 'Eye Bank' },
    { value: 'http://nucc.org/provider-taxonomy|332H00000X', name: 'Eyewear Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|332S00000X', name: 'Hearing Aid Equipment' },
    { value: 'http://nucc.org/provider-taxonomy|332U00000X', name: 'Home Delivered Meals' },
    { value: 'http://nucc.org/provider-taxonomy|333300000X', name: 'Emergency Response System Companies' },
    { value: 'http://nucc.org/provider-taxonomy|333600000X', name: 'Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0002X', name: 'Clinic Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0003X', name: 'Community/Retail Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0004X', name: 'Compounding Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336H0001X', name: 'Home Infusion Therapy Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336I0012X', name: 'Institutional Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336L0003X', name: 'Long Term Care Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336M0002X', name: 'Mail Order Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336M0003X', name: 'Managed Care Organization Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336N0007X', name: 'Nuclear Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336S0011X', name: 'Specialty Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|335E00000X', name: 'Prosthetic/Orthotic Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|335G00000X', name: 'Medical Foods Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|335U00000X', name: 'Organ Procurement Organization' },
    { value: 'http://nucc.org/provider-taxonomy|335V00000X', name: 'Portable X-ray and/or Other Portable Diagnostic Imaging Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|341600000X', name: 'Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|3416A0800X', name: 'Air Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|3416L0300X', name: 'Land Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|3416S0300X', name: 'Water Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|341800000X', name: 'Military/U.S. Coast Guard Transport,' },
    { value: 'http://nucc.org/provider-taxonomy|3418M1110X', name: 'Military or U.S. Coast Guard Ground Transport Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|3418M1120X', name: 'Military or U.S. Coast Guard Air Transport Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|3418M1130X', name: 'Military or U.S. Coast Guard Water Transport Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|343800000X', name: 'Secured Medical Transport (VAN)' },
    { value: 'http://nucc.org/provider-taxonomy|343900000X', name: 'Non-emergency Medical Transport (VAN)' },
    { value: 'http://nucc.org/provider-taxonomy|344600000X', name: 'Taxi' },
    { value: 'http://nucc.org/provider-taxonomy|344800000X', name: 'Air Carrier' },
    { value: 'http://nucc.org/provider-taxonomy|347B00000X', name: 'Bus' },
    { value: 'http://nucc.org/provider-taxonomy|347C00000X', name: 'Private Vehicle' },
    { value: 'http://nucc.org/provider-taxonomy|347D00000X', name: 'Train' },
    { value: 'http://nucc.org/provider-taxonomy|347E00000X', name: 'Transportation Broker' }
  ].freeze 

  INDIVIDUAL_AND_GROUP_SPECIALTIES = [
    { value: 'http://nucc.org/provider-taxonomy|101200000X', name: 'Drama Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|101Y00000X', name: 'Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|101YA0400X', name: 'Addiction (Substance Use Disorder) Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|101YM0800X', name: 'Mental Health Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|101YP1600X', name: 'Pastoral Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|101YP2500X', name: 'Professional Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|101YS0200X', name: 'School Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|102L00000X', name: 'Psychoanalyst' },
    { value: 'http://nucc.org/provider-taxonomy|102X00000X', name: 'Poetry Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|103G00000X', name: 'Clinical Neuropsychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103K00000X', name: 'Behavioral Analyst' },
    { value: 'http://nucc.org/provider-taxonomy|103T00000X', name: 'Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TA0400X', name: 'Addiction (Substance Use Disorder) Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TA0700X', name: 'Adult Development & Aging Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TB0200X', name: 'Cognitive & Behavioral Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TC0700X', name: 'Clinical Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TC1900X', name: 'Counseling Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TC2200X', name: 'Clinical Child & Adolescent Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TE1100X', name: 'Exercise & Sports Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TF0000X', name: 'Family Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TF0200X', name: 'Forensic Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TH0004X', name: 'Health Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TH0100X', name: 'Health Service Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TM1800X', name: 'Intellectual & Developmental Disabilities Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TP0016X', name: 'Prescribing (Medical) Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TP0814X', name: 'Psychoanalysis Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TP2701X', name: 'Group Psychotherapy Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TR0400X', name: 'Rehabilitation Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103TS0200X', name: 'School Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|104100000X', name: 'Social Worker' },
    { value: 'http://nucc.org/provider-taxonomy|1041C0700X', name: 'Clinical Social Worker' },
    { value: 'http://nucc.org/provider-taxonomy|1041S0200X', name: 'School Social Worker' },
    { value: 'http://nucc.org/provider-taxonomy|106E00000X', name: 'Assistant Behavior Analyst' },
    { value: 'http://nucc.org/provider-taxonomy|106H00000X', name: 'Marriage & Family Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|106S00000X', name: 'Behavior Technician' },
    { value: 'http://nucc.org/provider-taxonomy|111N00000X', name: 'Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NI0013X', name: 'Independent Medical Examiner Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NI0900X', name: 'Internist Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NN0400X', name: 'Neurology Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NN1001X', name: 'Nutrition Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NP0017X', name: 'Pediatric Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NR0200X', name: 'Radiology Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NR0400X', name: 'Rehabilitation Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NS0005X', name: 'Sports Physician Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NT0100X', name: 'Thermography Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NX0100X', name: 'Occupational Health Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|111NX0800X', name: 'Orthopedic Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|122300000X', name: 'Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223D0001X', name: 'Public Health Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223D0004X', name: 'Dentist Anesthesiologist' },
    { value: 'http://nucc.org/provider-taxonomy|1223E0200X', name: 'Endodontist' },
    { value: 'http://nucc.org/provider-taxonomy|1223G0001X', name: 'General Practice Dentistry' },
    { value: 'http://nucc.org/provider-taxonomy|1223P0106X', name: 'Oral and Maxillofacial Pathology Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223P0221X', name: 'Pediatric Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223P0300X', name: 'Periodontist' },
    { value: 'http://nucc.org/provider-taxonomy|1223P0700X', name: 'Prosthodontist' },
    { value: 'http://nucc.org/provider-taxonomy|1223S0112X', name: 'Oral and Maxillofacial Surgery (Dentist)' },
    { value: 'http://nucc.org/provider-taxonomy|1223X0008X', name: 'Oral and Maxillofacial Radiology Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223X0400X', name: 'Orthodontics and Dentofacial Orthopedic Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|1223X2210X', name: 'Orofacial Pain Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|122400000X', name: 'Denturist' },
    { value: 'http://nucc.org/provider-taxonomy|124Q00000X', name: 'Dental Hygienist' },
    { value: 'http://nucc.org/provider-taxonomy|125J00000X', name: 'Dental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|125K00000X', name: 'Advanced Practice Dental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|125Q00000X', name: 'Oral Medicinist' },
    { value: 'http://nucc.org/provider-taxonomy|126800000X', name: 'Dental Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|126900000X', name: 'Dental Laboratory Technician' },
    { value: 'http://nucc.org/provider-taxonomy|132700000X', name: 'Dietary Manager' },
    { value: 'http://nucc.org/provider-taxonomy|133N00000X', name: 'Nutritionist' },
    { value: 'http://nucc.org/provider-taxonomy|133NN1002X', name: 'Nutrition Education Nutritionist' },
    { value: 'http://nucc.org/provider-taxonomy|133V00000X', name: 'Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1004X', name: 'Pediatric Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1005X', name: 'Renal Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1006X', name: 'Metabolic Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1101X', name: 'Gerontological Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1201X', name: 'Obesity and Weight Management Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1301X', name: 'Oncology Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1401X', name: 'Pediatric Critical Care Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|133VN1501X', name: 'Sports Dietetics Nutrition Registered Dietitian' },
    { value: 'http://nucc.org/provider-taxonomy|136A00000X', name: 'Registered Dietetic Technician' },
    { value: 'http://nucc.org/provider-taxonomy|146D00000X', name: 'Personal Emergency Response Attendant' },
    { value: 'http://nucc.org/provider-taxonomy|146L00000X', name: 'Paramedic' },
    { value: 'http://nucc.org/provider-taxonomy|146M00000X', name: 'Intermediate Emergency Medical Technician' },
    { value: 'http://nucc.org/provider-taxonomy|146N00000X', name: 'Basic Emergency Medical Technician' },
    { value: 'http://nucc.org/provider-taxonomy|152W00000X', name: 'Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WC0802X', name: 'Corneal and Contact Management Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WL0500X', name: 'Low Vision Rehabilitation Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WP0200X', name: 'Pediatric Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WS0006X', name: 'Sports Vision Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WV0400X', name: 'Vision Therapy Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|152WX0102X', name: 'Occupational Vision Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|156F00000X', name: 'Technician/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|156FC0800X', name: 'Contact Lens Technician/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|156FC0801X', name: 'Contact Lens Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1100X', name: 'Ophthalmic Technician/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1101X', name: 'Ophthalmic Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1201X', name: 'Optometric Assistant Technician' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1202X', name: 'Optometric Technician' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1700X', name: 'Ocularist' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1800X', name: 'Optician' },
    { value: 'http://nucc.org/provider-taxonomy|156FX1900X', name: 'Orthoptist' },
    { value: 'http://nucc.org/provider-taxonomy|163W00000X', name: 'Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WA0400X', name: 'Addiction (Substance Use Disorder) Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WA2000X', name: 'Administrator Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC0200X', name: 'Critical Care Medicine Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC0400X', name: 'Case Management Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC1400X', name: 'College Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC1500X', name: 'Community Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC1600X', name: 'Continuing Education/Staff Development Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC2100X', name: 'Continence Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WC3500X', name: 'Cardiac Rehabilitation Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WD0400X', name: 'Diabetes Educator Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WD1100X', name: 'Peritoneal Dialysis Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WE0003X', name: 'Emergency Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WE0900X', name: 'Enterostomal Therapy Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WF0300X', name: 'Flight Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WG0000X', name: 'General Practice Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WG0100X', name: 'Gastroenterology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WG0600X', name: 'Gerontology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WH0200X', name: 'Home Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WH0500X', name: 'Hemodialysis Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WH1000X', name: 'Hospice Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WI0500X', name: 'Infusion Therapy Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WI0600X', name: 'Infection Control Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WL0100X', name: 'Lactation Consultant (Registered Nurse)' },
    { value: 'http://nucc.org/provider-taxonomy|163WM0102X', name: 'Maternal Newborn Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WM0705X', name: 'Medical-Surgical Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WM1400X', name: 'Nurse Massage Therapist (NMT)' },
    { value: 'http://nucc.org/provider-taxonomy|163WN0002X', name: 'Neonatal Intensive Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WN0003X', name: 'Low-Risk Neonatal Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WN0300X', name: 'Nephrology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WN0800X', name: 'Neuroscience Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WN1003X', name: 'Nutrition Support Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0000X', name: 'Pain Management Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0200X', name: 'Pediatric Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0218X', name: 'Pediatric Oncology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0807X', name: 'Child & Adolescent Psychiatric/Mental Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0808X', name: 'Psychiatric/Mental Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP0809X', name: 'Adult Psychiatric/Mental Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP1700X', name: 'Perinatal Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WP2201X', name: 'Ambulatory Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WR0006X', name: 'Registered Nurse First Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|163WR0400X', name: 'Rehabilitation Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WR1000X', name: 'Reproductive Endocrinology/Infertility Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WS0121X', name: 'Plastic Surgery Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WS0200X', name: 'School Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WU0100X', name: 'Urology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WW0000X', name: 'Wound Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WW0101X', name: 'Ambulatory Womens Health Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0002X', name: 'High-Risk Obstetric Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0003X', name: 'Inpatient Obstetric Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0106X', name: 'Occupational Health Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0200X', name: 'Oncology Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0601X', name: 'Otorhinolaryngology & Head-Neck Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX0800X', name: 'Orthopedic Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX1100X', name: 'Ophthalmic Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|163WX1500X', name: 'Ostomy Care Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|164W00000X', name: 'Licensed Practical Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|164X00000X', name: 'Licensed Vocational Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|167G00000X', name: 'Licensed Psychiatric Technician' },
    { value: 'http://nucc.org/provider-taxonomy|170100000X', name: 'Ph.D. Medical Genetics' },
    { value: 'http://nucc.org/provider-taxonomy|170300000X', name: 'Genetic Counselor (M.S.)' },
    { value: 'http://nucc.org/provider-taxonomy|171000000X', name: 'Military Health Care Provider' },
    { value: 'http://nucc.org/provider-taxonomy|1710I1002X', name: 'Independent Duty Corpsman' },
    { value: 'http://nucc.org/provider-taxonomy|1710I1003X', name: 'Independent Duty Medical Technicians' },
    { value: 'http://nucc.org/provider-taxonomy|171400000X', name: 'Health & Wellness Coach' },
    { value: 'http://nucc.org/provider-taxonomy|171100000X', name: 'Acupuncturist' },
    { value: 'http://nucc.org/provider-taxonomy|171M00000X', name: 'Case Manager/Care Coordinator' },
    { value: 'http://nucc.org/provider-taxonomy|171R00000X', name: 'Interpreter' },
    { value: 'http://nucc.org/provider-taxonomy|171W00000X', name: 'Contractor' },
    { value: 'http://nucc.org/provider-taxonomy|171WH0202X', name: 'Home Modifications Contractor' },
    { value: 'http://nucc.org/provider-taxonomy|171WV0202X', name: 'Vehicle Modifications Contractor' },
    { value: 'http://nucc.org/provider-taxonomy|172A00000X', name: 'Driver' },
    { value: 'http://nucc.org/provider-taxonomy|172M00000X', name: 'Mechanotherapist' },
    { value: 'http://nucc.org/provider-taxonomy|172P00000X', name: 'Naprapath' },
    { value: 'http://nucc.org/provider-taxonomy|172V00000X', name: 'Community Health Worker' },
    { value: 'http://nucc.org/provider-taxonomy|173000000X', name: 'Legal Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|173C00000X', name: 'Reflexologist' },
    { value: 'http://nucc.org/provider-taxonomy|173F00000X', name: 'Sleep Specialist (PhD)' },
    { value: 'http://nucc.org/provider-taxonomy|174400000X', name: 'Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|1744G0900X', name: 'Graphics Designer' },
    { value: 'http://nucc.org/provider-taxonomy|1744P3200X', name: 'Prosthetics Case Management' },
    { value: 'http://nucc.org/provider-taxonomy|1744R1102X', name: 'Research Study Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|1744R1103X', name: 'Research Study Abstracter/Coder' },
    { value: 'http://nucc.org/provider-taxonomy|174H00000X', name: 'Health Educator' },
    { value: 'http://nucc.org/provider-taxonomy|174M00000X', name: 'Veterinarian' },
    { value: 'http://nucc.org/provider-taxonomy|174MM1900X', name: 'Medical Research Veterinarian' },
    { value: 'http://nucc.org/provider-taxonomy|174N00000X', name: 'Lactation Consultant (Non-RN)' },
    { value: 'http://nucc.org/provider-taxonomy|174V00000X', name: 'Clinical Ethicist' },
    { value: 'http://nucc.org/provider-taxonomy|175F00000X', name: 'Naturopath' },
    { value: 'http://nucc.org/provider-taxonomy|175L00000X', name: 'Homeopath' },
    { value: 'http://nucc.org/provider-taxonomy|175M00000X', name: 'Lay Midwife' },
    { value: 'http://nucc.org/provider-taxonomy|175T00000X', name: 'Peer Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|176B00000X', name: 'Midwife' },
    { value: 'http://nucc.org/provider-taxonomy|176P00000X', name: 'Funeral Director' },
    { value: 'http://nucc.org/provider-taxonomy|183500000X', name: 'Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835C0205X', name: 'Critical Care Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835G0303X', name: 'Geriatric Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835N0905X', name: 'Nuclear Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835N1003X', name: 'Nutrition Support Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835P0018X', name: 'Pharmacist Clinician (PhC)/ Clinical Pharmacy Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|1835P0200X', name: 'Pediatric Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835P1200X', name: 'Pharmacotherapy Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835P1300X', name: 'Psychiatric Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835P2201X', name: 'Ambulatory Care Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|1835X0200X', name: 'Oncology Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|183700000X', name: 'Pharmacy Technician' },
    { value: 'http://nucc.org/provider-taxonomy|193200000X', name: 'Multi-Specialty Group' },
    { value: 'http://nucc.org/provider-taxonomy|202C00000X', name: 'Independent Medical Examiner Physician' },
    { value: 'http://nucc.org/provider-taxonomy|202K00000X', name: 'Phlebology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|204C00000X', name: 'Sports Medicine (Neuromusculoskeletal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|204D00000X', name: 'Neuromusculoskeletal Medicine & OMM Physician' },
    { value: 'http://nucc.org/provider-taxonomy|204E00000X', name: 'Oral & Maxillofacial Surgery (D.M.D.) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|204F00000X', name: 'Transplant Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|204R00000X', name: 'Electrodiagnostic Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207K00000X', name: 'Allergy & Immunology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207KA0200X', name: 'Allergy Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207KI0005X', name: 'Clinical & Laboratory Immunology (Allergy & Immunology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207L00000X', name: 'Anesthesiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207LA0401X', name: 'Addiction Medicine (Anesthesiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207LC0200X', name: 'Critical Care Medicine (Anesthesiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207LH0002X', name: 'Hospice and Palliative Medicine (Anesthesiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207LP2900X', name: 'Pain Medicine (Anesthesiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207LP3000X', name: 'Pediatric Anesthesiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207N00000X', name: 'Dermatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ND0101X', name: 'MOHS-Micrographic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ND0900X', name: 'Dermatopathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207NI0002X', name: 'Clinical & Laboratory Dermatological Immunology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207NP0225X', name: 'Pediatric Dermatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207NS0135X', name: 'Procedural Dermatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207P00000X', name: 'Emergency Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PE0004X', name: 'Emergency Medical Services (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PE0005X', name: 'Undersea and Hyperbaric Medicine (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PH0002X', name: 'Hospice and Palliative Medicine (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PP0204X', name: 'Pediatric Emergency Medicine (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PS0010X', name: 'Sports Medicine (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207PT0002X', name: 'Medical Toxicology (Emergency Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207Q00000X', name: 'Family Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QA0000X', name: 'Adolescent Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QA0401X', name: 'Addiction Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QA0505X', name: 'Adult Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QB0002X', name: 'Obesity Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QG0300X', name: 'Geriatric Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QH0002X', name: 'Hospice and Palliative Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QS0010X', name: 'Sports Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207QS1201X', name: 'Sleep Medicine (Family Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207R00000X', name: 'Internal Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RA0000X', name: 'Adolescent Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RA0001X', name: 'Advanced Heart Failure and Transplant Cardiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RA0002X', name: 'Adult Congenital Heart Disease Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RA0201X', name: 'Allergy & Immunology (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RA0401X', name: 'Addiction Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RB0002X', name: 'Obesity Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RC0000X', name: 'Cardiovascular Disease Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RC0001X', name: 'Clinical Cardiac Electrophysiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RC0200X', name: 'Critical Care Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RE0101X', name: 'Endocrinology, Diabetes & Metabolism Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RG0100X', name: 'Gastroenterology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RG0300X', name: 'Geriatric Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RH0000X', name: 'Hematology (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RH0002X', name: 'Hospice and Palliative Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RH0003X', name: 'Hematology & Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RH0005X', name: 'Hypertension Specialist Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RI0001X', name: 'Clinical & Laboratory Immunology (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RI0008X', name: 'Hepatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RI0011X', name: 'Interventional Cardiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RI0200X', name: 'Infectious Disease Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RM1200X', name: 'Magnetic Resonance Imaging (MRI) Internal Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RN0300X', name: 'Nephrology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RP1001X', name: 'Pulmonary Disease Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RR0500X', name: 'Rheumatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RS0010X', name: 'Sports Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RS0012X', name: 'Sleep Medicine (Internal Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RT0003X', name: 'Transplant Hepatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207RX0202X', name: 'Medical Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SC0300X', name: 'Clinical Cytogenetics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SG0201X', name: 'Clinical Genetics (M.D.) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SG0202X', name: 'Clinical Biochemical Genetics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SG0203X', name: 'Clinical Molecular Genetics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SG0205X', name: 'Ph.D. Medical Genetics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207SM0001X', name: 'Molecular Genetic Pathology (Medical Genetics) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207T00000X', name: 'Neurological Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207U00000X', name: 'Nuclear Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207UN0901X', name: 'Nuclear Cardiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207UN0902X', name: 'Nuclear Imaging & Therapy Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207UN0903X', name: 'In Vivo & In Vitro Nuclear Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207V00000X', name: 'Obstetrics & Gynecology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VB0002X', name: 'Obesity Medicine (Obstetrics & Gynecology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VC0200X', name: 'Critical Care Medicine (Obstetrics & Gynecology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VE0102X', name: 'Reproductive Endocrinology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VF0040X', name: 'Female Pelvic Medicine and Reconstructive Surgery (Obstetrics & Gynecology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VG0400X', name: 'Gynecology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VH0002X', name: 'Hospice and Palliative Medicine (Obstetrics & Gynecology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VM0101X', name: 'Maternal & Fetal Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VX0000X', name: 'Obstetrics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207VX0201X', name: 'Gynecologic Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207W00000X', name: 'Ophthalmology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0009X', name: 'Glaucoma Specialist (Ophthalmology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0107X', name: 'Retina Specialist (Ophthalmology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0108X', name: 'Uveitis and Ocular Inflammatory Disease (Ophthalmology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0109X', name: 'Neuro-ophthalmology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0110X', name: 'Pediatric Ophthalmology and Strabismus Specialist Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0120X', name: 'Cornea and External Diseases Specialist Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207WX0200X', name: 'Ophthalmic Plastic and Reconstructive Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207X00000X', name: 'Orthopaedic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XP3100X', name: 'Pediatric Orthopaedic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XS0106X', name: 'Orthopaedic Hand Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XS0114X', name: 'Adult Reconstructive Orthopaedic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XS0117X', name: 'Orthopaedic Surgery of the Spine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XX0004X', name: 'Orthopaedic Foot and Ankle Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XX0005X', name: 'Sports Medicine (Orthopaedic Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207XX0801X', name: 'Orthopaedic Trauma Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207Y00000X', name: 'Otolaryngology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YP0228X', name: 'Pediatric Otolaryngology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YS0012X', name: 'Sleep Medicine (Otolaryngology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YS0123X', name: 'Facial Plastic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YX0007X', name: 'Plastic Surgery within the Head & Neck (Otolaryngology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YX0602X', name: 'Otolaryngic Allergy Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YX0901X', name: 'Otology & Neurotology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207YX0905X', name: 'Otolaryngology/Facial Plastic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZB0001X', name: 'Blood Banking & Transfusion Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZC0006X', name: 'Clinical Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZC0008X', name: 'Clinical Informatics (Pathology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZC0500X', name: 'Cytopathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZD0900X', name: 'Dermatopathology (Pathology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZF0201X', name: 'Forensic Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZH0000X', name: 'Hematology (Pathology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZI0100X', name: 'Immunopathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZM0300X', name: 'Medical Microbiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZN0500X', name: 'Neuropathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0007X', name: 'Molecular Genetic Pathology (Pathology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0101X', name: 'Anatomic Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0102X', name: 'Anatomic Pathology & Clinical Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0104X', name: 'Chemical Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0105X', name: 'Clinical Pathology/Laboratory Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|207ZP0213X', name: 'Pediatric Pathology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208000000X', name: 'Pediatrics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080A0000X', name: 'Pediatric Adolescent Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080B0002X', name: 'Pediatric Obesity Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080C0008X', name: 'Child Abuse Pediatrics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080H0002X', name: 'Pediatric Hospice and Palliative Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080I0007X', name: 'Pediatric Clinical & Laboratory Immunology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080N0001X', name: 'Neonatal-Perinatal Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0006X', name: 'Developmental – Behavioral Pediatrics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0008X', name: 'Pediatric Neurodevelopmental Disabilities Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0201X', name: 'Pediatric Allergy/Immunology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0202X', name: 'Pediatric Cardiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0203X', name: 'Pediatric Critical Care Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0204X', name: 'Pediatric Emergency Medicine (Pediatrics) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0205X', name: 'Pediatric Endocrinology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0206X', name: 'Pediatric Gastroenterology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0207X', name: 'Pediatric Hematology & Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0208X', name: 'Pediatric Infectious Diseases Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0210X', name: 'Pediatric Nephrology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0214X', name: 'Pediatric Pulmonology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080P0216X', name: 'Pediatric Rheumatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080S0010X', name: 'Pediatric Sports Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080S0012X', name: 'Pediatric Sleep Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080T0002X', name: 'Pediatric Medical Toxicology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2080T0004X', name: 'Pediatric Transplant Hepatology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208100000X', name: 'Physical Medicine & Rehabilitation Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081H0002X', name: 'Hospice and Palliative Medicine (Physical Medicine & Rehabilitation) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081N0008X', name: 'Neuromuscular Medicine (Physical Medicine & Rehabilitation) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081P0004X', name: 'Spinal Cord Injury Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081P0010X', name: 'Pediatric Rehabilitation Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081P0301X', name: 'Brain Injury Medicine (Physical Medicine & Rehabilitation) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081P2900X', name: 'Pain Medicine (Physical Medicine & Rehabilitation) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2081S0010X', name: 'Sports Medicine (Physical Medicine & Rehabilitation) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208200000X', name: 'Plastic Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2082S0099X', name: 'Plastic Surgery Within the Head and Neck (Plastic Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2082S0105X', name: 'Surgery of the Hand (Plastic Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083A0100X', name: 'Aerospace Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083A0300X', name: 'Addiction Medicine (Preventive Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083B0002X', name: 'Obesity Medicine (Preventive Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083C0008X', name: 'Clinical Informatics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083P0011X', name: 'Undersea and Hyperbaric Medicine (Preventive Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083P0500X', name: 'Preventive Medicine/Occupational Environmental Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083P0901X', name: 'Public Health & General Preventive Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083S0010X', name: 'Sports Medicine (Preventive Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083T0002X', name: 'Medical Toxicology (Preventive Medicine) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2083X0100X', name: 'Occupational Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084A0401X', name: 'Addiction Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084A2900X', name: 'Neurocritical Care Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084B0002X', name: 'Obesity Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084B0040X', name: 'Behavioral Neurology & Neuropsychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084D0003X', name: 'Diagnostic Neuroimaging (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084F0202X', name: 'Forensic Psychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084H0002X', name: 'Hospice and Palliative Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084N0008X', name: 'Neuromuscular Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084N0400X', name: 'Neurology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084N0402X', name: 'Neurology with Special Qualifications in Child Neurology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084N0600X', name: 'Clinical Neurophysiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0005X', name: 'Neurodevelopmental Disabilities Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0015X', name: 'Psychosomatic Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0301X', name: 'Brain Injury Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0800X', name: 'Psychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0802X', name: 'Addiction Psychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0804X', name: 'Child & Adolescent Psychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P0805X', name: 'Geriatric Psychiatry Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084P2900X', name: 'Pain Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084S0010X', name: 'Sports Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084S0012X', name: 'Sleep Medicine (Psychiatry & Neurology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2084V0102X', name: 'Vascular Neurology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085B0100X', name: 'Body Imaging Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085D0003X', name: 'Diagnostic Neuroimaging (Radiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085H0002X', name: 'Hospice and Palliative Medicine (Radiology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085N0700X', name: 'Neuroradiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085N0904X', name: 'Nuclear Radiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085P0229X', name: 'Pediatric Radiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085R0001X', name: 'Radiation Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085R0202X', name: 'Diagnostic Radiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085R0203X', name: 'Therapeutic Radiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085R0204X', name: 'Vascular & Interventional Radiology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085R0205X', name: 'Radiological Physics Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2085U0001X', name: 'Diagnostic Ultrasound Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208600000X', name: 'Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086H0002X', name: 'Hospice and Palliative Medicine (Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0102X', name: 'Surgical Critical Care Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0105X', name: 'Surgery of the Hand (Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0120X', name: 'Pediatric Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0122X', name: 'Plastic and Reconstructive Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0127X', name: 'Trauma Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086S0129X', name: 'Vascular Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2086X0206X', name: 'Surgical Oncology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208800000X', name: 'Urology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2088F0040X', name: 'Female Pelvic Medicine and Reconstructive Surgery (Urology) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|2088P0231X', name: 'Pediatric Urology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208C00000X', name: 'Colon & Rectal Surgery Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208D00000X', name: 'General Practice Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208G00000X', name: 'Thoracic Surgery (Cardiothoracic Vascular Surgery) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208M00000X', name: 'Hospitalist Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208U00000X', name: 'Clinical Pharmacology Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208VP0000X', name: 'Pain Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|208VP0014X', name: 'Interventional Pain Medicine Physician' },
    { value: 'http://nucc.org/provider-taxonomy|209800000X', name: 'Legal Medicine (M.D./D.O.) Physician' },
    { value: 'http://nucc.org/provider-taxonomy|211D00000X', name: 'Podiatric Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|213E00000X', name: 'Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213EP0504X', name: 'Public Medicine Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213EP1101X', name: 'Primary Podiatric Medicine Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213ER0200X', name: 'Radiology Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213ES0000X', name: 'Sports Medicine Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213ES0103X', name: 'Foot & Ankle Surgery Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|213ES0131X', name: 'Foot Surgery Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|221700000X', name: 'Art Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|222Q00000X', name: 'Developmental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|222Z00000X', name: 'Orthotist' },
    { value: 'http://nucc.org/provider-taxonomy|224900000X', name: 'Mastectomy Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|224L00000X', name: 'Pedorthist' },
    { value: 'http://nucc.org/provider-taxonomy|224P00000X', name: 'Prosthetist' },
    { value: 'http://nucc.org/provider-taxonomy|224Y00000X', name: 'Clinical Exercise Physiologist' },
    { value: 'http://nucc.org/provider-taxonomy|224Z00000X', name: 'Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|224ZE0001X', name: 'Environmental Modification Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|224ZF0002X', name: 'Feeding, Eating & Swallowing Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|224ZL0004X', name: 'Low Vision Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|224ZR0403X', name: 'Driving and Community Mobility Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|225000000X', name: 'Orthotic Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|225100000X', name: 'Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251C2600X', name: 'Cardiopulmonary Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251E1200X', name: 'Ergonomics Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251E1300X', name: 'Clinical Electrophysiology Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251G0304X', name: 'Geriatric Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251H1200X', name: 'Hand Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251H1300X', name: 'Human Factors Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251N0400X', name: 'Neurology Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251P0200X', name: 'Pediatric Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251S0007X', name: 'Sports Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2251X0800X', name: 'Orthopedic Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225200000X', name: 'Physical Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|225400000X', name: 'Rehabilitation Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|225500000X', name: 'Respiratory/Developmental/Rehabilitative Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2255A2300X', name: 'Athletic Trainer' },
    { value: 'http://nucc.org/provider-taxonomy|2255R0406X', name: 'Blind Rehabilitation Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|225600000X', name: 'Dance Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225700000X', name: 'Massage Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225800000X', name: 'Recreation Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225A00000X', name: 'Music Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225B00000X', name: 'Pulmonary Function Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|225C00000X', name: 'Rehabilitation Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|225CA2400X', name: 'Assistive Technology Practitioner Rehabilitation Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|225CA2500X', name: 'Assistive Technology Supplier Rehabilitation Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|225CX0006X', name: 'Orientation and Mobility Training Rehabilitation Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|225X00000X', name: 'Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XE0001X', name: 'Environmental Modification Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XE1200X', name: 'Ergonomics Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XF0002X', name: 'Feeding, Eating & Swallowing Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XG0600X', name: 'Gerontology Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XH1200X', name: 'Hand Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XH1300X', name: 'Human Factors Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XL0004X', name: 'Low Vision Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XM0800X', name: 'Mental Health Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XN1300X', name: 'Neurorehabilitation Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XP0019X', name: 'Physical Rehabilitation Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XP0200X', name: 'Pediatric Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225XR0403X', name: 'Driving and Community Mobility Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|226000000X', name: 'Recreational Therapist Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|226300000X', name: 'Kinesiotherapist' },
    { value: 'http://nucc.org/provider-taxonomy|227800000X', name: 'Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278C0205X', name: 'Critical Care Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278E0002X', name: 'Emergency Care Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278E1000X', name: 'Educational Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278G0305X', name: 'Geriatric Care Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278G1100X', name: 'General Care Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278H0200X', name: 'Home Health Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P1004X', name: 'Pulmonary Diagnostics Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P1005X', name: 'Pulmonary Rehabilitation Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P1006X', name: 'Pulmonary Function Technologist Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P3800X', name: 'Palliative/Hospice Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P3900X', name: 'Neonatal/Pediatric Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278P4000X', name: 'Patient Transport Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2278S1500X', name: 'SNF/Subacute Care Certified Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|227900000X', name: 'Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279C0205X', name: 'Critical Care Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279E0002X', name: 'Emergency Care Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279E1000X', name: 'Educational Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279G0305X', name: 'Geriatric Care Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279G1100X', name: 'General Care Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279H0200X', name: 'Home Health Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P1004X', name: 'Pulmonary Diagnostics Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P1005X', name: 'Pulmonary Rehabilitation Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P1006X', name: 'Pulmonary Function Technologist Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P3800X', name: 'Palliative/Hospice Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P3900X', name: 'Neonatal/Pediatric Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279P4000X', name: 'Patient Transport Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|2279S1500X', name: 'SNF/Subacute Care Registered Respiratory Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|229N00000X', name: 'Anaplastologist' },
    { value: 'http://nucc.org/provider-taxonomy|231H00000X', name: 'Audiologist' },
    { value: 'http://nucc.org/provider-taxonomy|231HA2400X', name: 'Assistive Technology Practitioner Audiologist' },
    { value: 'http://nucc.org/provider-taxonomy|231HA2500X', name: 'Assistive Technology Supplier Audiologist' },
    { value: 'http://nucc.org/provider-taxonomy|235500000X', name: 'Speech/Language/Hearing Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2355A2700X', name: 'Audiology Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|2355S0801X', name: 'Speech-Language Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|235Z00000X', name: 'Speech-Language Pathologist' },
    { value: 'http://nucc.org/provider-taxonomy|237600000X', name: 'Audiologist-Hearing Aid Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|237700000X', name: 'Hearing Instrument Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|242T00000X', name: 'Perfusionist' },
    { value: 'http://nucc.org/provider-taxonomy|243U00000X', name: 'Radiology Practitioner Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|246Q00000X', name: 'Pathology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QB0000X', name: 'Blood Banking Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QC1000X', name: 'Chemistry Pathology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QC2700X', name: 'Cytotechnology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QH0000X', name: 'Hematology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QH0401X', name: 'Hemapheresis Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|246QH0600X', name: 'Histology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QI0000X', name: 'Immunology Pathology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QL0900X', name: 'Laboratory Management Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QL0901X', name: 'Diplomate Laboratory Management Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QM0706X', name: 'Medical Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246QM0900X', name: 'Microbiology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246R00000X', name: 'Pathology Technician' },
    { value: 'http://nucc.org/provider-taxonomy|246RH0600X', name: 'Histology Technician' },
    { value: 'http://nucc.org/provider-taxonomy|246RM2200X', name: 'Medical Laboratory Technician' },
    { value: 'http://nucc.org/provider-taxonomy|246RP1900X', name: 'Phlebotomy Technician' },
    { value: 'http://nucc.org/provider-taxonomy|246W00000X', name: 'Cardiology Technician' },
    { value: 'http://nucc.org/provider-taxonomy|246X00000X', name: 'Cardiovascular Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246XC2901X', name: 'Cardiovascular Invasive Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246XC2903X', name: 'Vascular Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246XS1301X', name: 'Sonography Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246Y00000X', name: 'Health Information Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246YC3301X', name: 'Hospital Based Coding Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|246YC3302X', name: 'Physician Office Based Coding Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|246YR1600X', name: 'Registered Record Administrator' },
    { value: 'http://nucc.org/provider-taxonomy|246Z00000X', name: 'Other Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZA2600X', name: 'Medical Art Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZB0301X', name: 'Biomedical Engineer' },
    { value: 'http://nucc.org/provider-taxonomy|246ZB0302X', name: 'Biomedical Photographer' },
    { value: 'http://nucc.org/provider-taxonomy|246ZB0500X', name: 'Biochemist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZB0600X', name: 'Biostatiscian' },
    { value: 'http://nucc.org/provider-taxonomy|246ZC0007X', name: 'Surgical Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|246ZE0500X', name: 'EEG Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZE0600X', name: 'Electroneurodiagnostic Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZG0701X', name: 'Graphics Methods Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZG1000X', name: 'Medical Geneticist (PhD) Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZI1000X', name: 'Medical Illustrator' },
    { value: 'http://nucc.org/provider-taxonomy|246ZN0300X', name: 'Nephrology Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZS0410X', name: 'Surgical Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|246ZX2200X', name: 'Orthopedic Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|247000000X', name: 'Health Information Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2470A2800X', name: 'Assistant Health Information Record Technician' },
    { value: 'http://nucc.org/provider-taxonomy|247100000X', name: 'Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471B0102X', name: 'Bone Densitometry Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471C1101X', name: 'Cardiovascular-Interventional Technology Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471C1106X', name: 'Cardiac-Interventional Technology Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471C3401X', name: 'Computed Tomography Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471C3402X', name: 'Radiography Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471M1202X', name: 'Magnetic Resonance Imaging Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471M2300X', name: 'Mammography Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471N0900X', name: 'Nuclear Medicine Technology Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471Q0001X', name: 'Quality Management Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471R0002X', name: 'Radiation Therapy Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471S1302X', name: 'Sonography Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471V0105X', name: 'Vascular Sonography Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|2471V0106X', name: 'Vascular-Interventional Technology Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|247200000X', name: 'Other Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2472B0301X', name: 'Biomedical Engineering Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2472D0500X', name: 'Darkroom Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2472E0500X', name: 'EEG Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2472R0900X', name: 'Renal Dialysis Technician' },
    { value: 'http://nucc.org/provider-taxonomy|2472V0600X', name: 'Veterinary Technician' },
    { value: 'http://nucc.org/provider-taxonomy|247ZC0005X', name: 'Clinical Laboratory Director (Non-physician)' },
    { value: 'http://nucc.org/provider-taxonomy|342000000X', name: 'Transportation Network Company' },
    { value: 'http://nucc.org/provider-taxonomy|363A00000X', name: 'Physician Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|363AM0700X', name: 'Medical Physician Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|363AS0400X', name: 'Surgical Physician Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|363L00000X', name: 'Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LA2100X', name: 'Acute Care Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LA2200X', name: 'Adult Health Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LC0200X', name: 'Critical Care Medicine Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LC1500X', name: 'Community Health Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LF0000X', name: 'Family Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LG0600X', name: 'Gerontology Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LN0000X', name: 'Neonatal Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LN0005X', name: 'Critical Care Neonatal Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LP0200X', name: 'Pediatric Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LP0222X', name: 'Critical Care Pediatric Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LP0808X', name: 'Psychiatric/Mental Health Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LP1700X', name: 'Perinatal Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LP2300X', name: 'Primary Care Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LS0200X', name: 'School Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LW0102X', name: 'Womens Health Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LX0001X', name: 'Obstetrics & Gynecology Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|363LX0106X', name: 'Occupational Health Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|364S00000X', name: 'Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SA2100X', name: 'Acute Care Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SA2200X', name: 'Adult Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SC0200X', name: 'Critical Care Medicine Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SC1501X', name: 'Community Health/Public Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SC2300X', name: 'Chronic Care Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SE0003X', name: 'Emergency Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SE1400X', name: 'Ethics Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SF0001X', name: 'Family Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SG0600X', name: 'Gerontology Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SH0200X', name: 'Home Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SH1100X', name: 'Holistic Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SI0800X', name: 'Informatics Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SL0600X', name: 'Long-Term Care Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SM0705X', name: 'Medical-Surgical Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SN0000X', name: 'Neonatal Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SN0800X', name: 'Neuroscience Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0200X', name: 'Pediatric Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0807X', name: 'Child & Adolescent Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0808X', name: 'Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0809X', name: 'Adult Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0810X', name: 'Child & Family Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0811X', name: 'Chronically Ill Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0812X', name: 'Community Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP0813X', name: 'Geropsychiatric Psychiatric/Mental Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP1700X', name: 'Perinatal Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SP2800X', name: 'Perioperative Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SR0400X', name: 'Rehabilitation Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SS0200X', name: 'School Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364ST0500X', name: 'Transplantation Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SW0102X', name: 'Womens Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SX0106X', name: 'Occupational Health Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SX0200X', name: 'Oncology Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|364SX0204X', name: 'Pediatric Oncology Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|367500000X', name: 'Certified Registered Nurse Anesthetist' },
    { value: 'http://nucc.org/provider-taxonomy|367A00000X', name: 'Advanced Practice Midwife' },
    { value: 'http://nucc.org/provider-taxonomy|367H00000X', name: 'Anesthesiologist Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|372500000X', name: 'Chore Provider' },
    { value: 'http://nucc.org/provider-taxonomy|372600000X', name: 'Adult Companion' },
    { value: 'http://nucc.org/provider-taxonomy|373H00000X', name: 'Day Training/Habilitation Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|374700000X', name: 'Technician' },
    { value: 'http://nucc.org/provider-taxonomy|3747A0650X', name: 'Attendant Care Provider' },
    { value: 'http://nucc.org/provider-taxonomy|3747P1801X', name: 'Personal Care Attendant' },
    { value: 'http://nucc.org/provider-taxonomy|374J00000X', name: 'Doula' },
    { value: 'http://nucc.org/provider-taxonomy|374K00000X', name: 'Religious Nonmedical Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|374T00000X', name: 'Religious Nonmedical Nursing Personnel' },
    { value: 'http://nucc.org/provider-taxonomy|374U00000X', name: 'Home Health Aide' },
    { value: 'http://nucc.org/provider-taxonomy|376G00000X', name: 'Nursing Home Administrator' },
    { value: 'http://nucc.org/provider-taxonomy|376J00000X', name: 'Homemaker' },
    { value: 'http://nucc.org/provider-taxonomy|376K00000X', name: 'Nurses Aide' },
    { value: 'http://nucc.org/provider-taxonomy|405300000X', name: 'Prevention Professional' }
  ].freeze
    
  SPECIALTIES = (NON_INDIVIDUAL_SPECIALTIES + INDIVIDUAL_AND_GROUP_SPECIALTIES).freeze 
    

  NEW_PATIENT_OPTIONS = [
    { value: 'nopt', name: 'Not accepting patients' },
    { value: 'newpt', name: 'Accepting patients' },
    { value: 'existptonly', name: 'Accepting existing patients' },
    { value: 'existptfam', name: 'Accepting existing patients and members of their families' }
  ].freeze 

  INSURANCE_STATUS_OPTIONS = [
    { value: 'http://hl7.org/fhir/us/ndh/CodeSystem/InsuranceStatusCS|insured', name: 'Insured' },
    { value: 'http://hl7.org/fhir/us/ndh/CodeSystem/InsuranceStatusCS|uninsured', name: 'Uninsured' },
    { value: 'http://hl7.org/fhir/us/ndh/CodeSystem/InsuranceStatusCS|underinsured', name: 'Underinsured' }
  ].freeze 

  BIRTH_SEX_OPTIONS = [
    { value: 'F', name: 'Female' },
    { value: 'M', name: 'Male' },
    { value: 'OTH', name: 'Other' }
  ].freeze 

  VETERAN_STATUS_OPTIONS = [
    { value: 'true', name: 'Veteran' }
  ].freeze 

  EMPLOYMENT_STATUS_OPTIONS = [
    { value: 'http://terminology.hl7.org/CodeSystem/v2-0066|1', name: 'Full time employed' },
    { value: 'http://terminology.hl7.org/CodeSystem/v2-0066|2', name: 'Part time employed' },
    { value: 'http://terminology.hl7.org/CodeSystem/v2-0066|3', name: 'Unemployed' },
    { value: 'http://terminology.hl7.org/CodeSystem/v2-0066|4', name: 'Self-employed' },
    { value: 'http://terminology.hl7.org/CodeSystem/v2-0066|5', name: 'Retired' }
  ].freeze 

  

  PROGRAMS = [
    { value: 'http://terminology.hl7.org/CodeSystem/program|1', name: 'Acquired Brain Injury (ABI) Program ' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|2', name: 'ABI Slow To Recover (ABI STR) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|3', name: 'Access Programs' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|4', name: 'Adult and Further Education (ACFE) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|5', name: 'Adult Day Activity and Support Services (ADASS) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|6', name: 'Adult Day Care Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|7', name: 'ATSS (Adult Training Support Service)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|8', name: 'Community Aged Care Packages (CACP)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|9', name: 'Care Coordination & Supplementary Services (CCSS)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|10', name: 'Cognitive Dementia Memory Service (CDAMS)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|11', name: 'ChildFIRST' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|12', name: 'Children\'s Contact Services' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|13', name: 'Community Visitors Scheme' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|14', name: 'CPP (Community Partners Program)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|15', name: 'Closing the Gap (CTG)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|16', name: 'Coordinated Veterans\' Care (CVC) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|17', name: 'Day Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|18', name: 'Drop In Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|19', name: 'Early Years Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|20', name: 'Employee Assistance Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|21', name: 'Home And Community Care (HACC)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|22', name: 'Hospital Admission Risk Program (HARP)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|23', name: 'Hospital in the Home (HITH) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|24', name: 'ICTP (Intensive Community Treatment Program)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|25', name: 'IFSS (Intensive Family Support Program)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|26', name: 'JPET (Job Placement, Education and Training)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|27', name: 'Koori Juvenile Justice Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|28', name: 'Language Literacy and Numeracy Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|29', name: 'Life Skills Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|30', name: 'LMP (Lifestyle Modification Program)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|31', name: 'MedsCheck Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|32', name: 'Methadone/Buprenorphine Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|33', name: 'National Disabilities Insurance Scheme (NDIS)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|34', name: 'National Diabetes Services Scheme (NDSS)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|35', name: 'Needle/Syringe Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|36', name: 'nPEP Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|37', name: 'Personal Support Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|38', name: 'Partners in Recovery (PIR) Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|39', name: 'Pre-employment Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|40', name: 'Reconnect Program' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|41', name: 'Sexual Abuse Counselling and Prevention Program (SACPP)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|42', name: 'Social Support Programs' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|43', name: 'Supported Residential Service (SRS)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|44', name: 'Tasmanian Aboriginal Centre (TAC)' },
    { value: 'http://terminology.hl7.org/CodeSystem/program|45', name: 'Victim\'s Assistance Program' }
  ]

  PHARMACY_SPECIALTIES = [
    { value: 'http://nucc.org/provider-taxonomy|333600000X', name: 'Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0002X', name: 'Clinic Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0003X', name: 'Community/Retail Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336C0004X', name: 'Compounding Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336H0001X', name: 'Home Infusion Therapy Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336I0012X', name: 'Institutional Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336L0003X', name: 'Long Term Care Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336M0002X', name: 'Mail Order Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336M0003X', name: 'Managed Care Organization Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336N0007X', name: 'Nuclear Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|3336S0011X', name: 'Specialty Pharmacy' }
  ].freeze 

  NUCC_CODES = [
    { value: 'http://nucc.org/provider-taxonomy|101Y00000X', name: 'Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|102L00000X', name: 'Psychoanalyst' },
    { value: 'http://nucc.org/provider-taxonomy|102X00000X', name: 'Poetry Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|103G00000X', name: 'Clinical Neuropsychologist' },
    { value: 'http://nucc.org/provider-taxonomy|103K00000X', name: 'Behavior Analyst' },
    { value: 'http://nucc.org/provider-taxonomy|103T00000X', name: 'Psychologist' },
    { value: 'http://nucc.org/provider-taxonomy|104100000X', name: 'Social Worker' },
    { value: 'http://nucc.org/provider-taxonomy|106E00000X', name: 'Assistant Behavior Analyst' },
    { value: 'http://nucc.org/provider-taxonomy|106H00000X', name: 'Marriage & Family Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|106S00000X', name: 'Behavior Technician' },
    { value: 'http://nucc.org/provider-taxonomy|111N00000X', name: 'Chiropractor' },
    { value: 'http://nucc.org/provider-taxonomy|122300000X', name: 'Dentist' },
    { value: 'http://nucc.org/provider-taxonomy|122400000X', name: 'Denturist' },
    { value: 'http://nucc.org/provider-taxonomy|124Q00000X', name: 'Dental Hygienist' },
    { value: 'http://nucc.org/provider-taxonomy|125J00000X', name: 'Dental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|125K00000X', name: 'Advanced Practice Dental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|125Q00000X', name: 'Oral Medicinist' },
    { value: 'http://nucc.org/provider-taxonomy|126800000X', name: 'Dental Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|126900000X', name: 'Dental Laboratory Technician' },
    { value: 'http://nucc.org/provider-taxonomy|132700000X', name: 'Dietary Manager' },
    { value: 'http://nucc.org/provider-taxonomy|133N00000X', name: 'Nutritionist' },
    { value: 'http://nucc.org/provider-taxonomy|133V00000X', name: 'Dietitian, Registered' },
    { value: 'http://nucc.org/provider-taxonomy|136A00000X', name: 'Dietetic Technician, Registered' },
    { value: 'http://nucc.org/provider-taxonomy|146D00000X', name: 'Personal Emergency Response Attendant' },
    { value: 'http://nucc.org/provider-taxonomy|146L00000X', name: 'Emergency Medical Technician, Paramedic' },
    { value: 'http://nucc.org/provider-taxonomy|146M00000X', name: 'Emergency Medical Technician, Intermediate' },
    { value: 'http://nucc.org/provider-taxonomy|146N00000X', name: 'Emergency Medical Technician, Basic' },
    { value: 'http://nucc.org/provider-taxonomy|152W00000X', name: 'Optometrist' },
    { value: 'http://nucc.org/provider-taxonomy|156F00000X', name: 'Technician/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|163W00000X', name: 'Registered Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|164W00000X', name: 'Licensed Practical Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|164X00000X', name: 'Licensed Vocational Nurse' },
    { value: 'http://nucc.org/provider-taxonomy|167G00000X', name: 'Licensed Psychiatric Technician' },
    { value: 'http://nucc.org/provider-taxonomy|170100000X', name: 'Medical Genetics, Ph.D. Medical Genetics' },
    { value: 'http://nucc.org/provider-taxonomy|170300000X', name: 'Genetic Counselor, MS' },
    { value: 'http://nucc.org/provider-taxonomy|171000000X', name: 'Military Health Care Provider' },
    { value: 'http://nucc.org/provider-taxonomy|171100000X', name: 'Acupuncturist' },
    { value: 'http://nucc.org/provider-taxonomy|171M00000X', name: 'Case Manager/Care Coordinator' },
    { value: 'http://nucc.org/provider-taxonomy|171R00000X', name: 'Interpreter' },
    { value: 'http://nucc.org/provider-taxonomy|171W00000X', name: 'Contractor' },
    { value: 'http://nucc.org/provider-taxonomy|172A00000X', name: 'Driver' },
    { value: 'http://nucc.org/provider-taxonomy|172M00000X', name: 'Mechanotherapist' },
    { value: 'http://nucc.org/provider-taxonomy|172P00000X', name: 'Naprapath' },
    { value: 'http://nucc.org/provider-taxonomy|172V00000X', name: 'Community Health Worker' },
    { value: 'http://nucc.org/provider-taxonomy|173000000X', name: 'Legal Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|173C00000X', name: 'Reflexologist' },
    { value: 'http://nucc.org/provider-taxonomy|173F00000X', name: 'Sleep Specialist, PhD' },
    { value: 'http://nucc.org/provider-taxonomy|174200000X', name: 'Meals' },
    { value: 'http://nucc.org/provider-taxonomy|174400000X', name: 'Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|174H00000X', name: 'Health Educator' },
    { value: 'http://nucc.org/provider-taxonomy|174M00000X', name: 'Veterinarian' },
    { value: 'http://nucc.org/provider-taxonomy|174N00000X', name: 'Lactation Consultant, Non-RN' },
    { value: 'http://nucc.org/provider-taxonomy|174V00000X', name: 'Clinical Ethicist' },
    { value: 'http://nucc.org/provider-taxonomy|175F00000X', name: 'Naturopath' },
    { value: 'http://nucc.org/provider-taxonomy|175L00000X', name: 'Homeopath' },
    { value: 'http://nucc.org/provider-taxonomy|175M00000X', name: 'Midwife, Lay' },
    { value: 'http://nucc.org/provider-taxonomy|175T00000X', name: 'Peer Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|176B00000X', name: 'Midwife' },
    { value: 'http://nucc.org/provider-taxonomy|176P00000X', name: 'Funeral Director' },
    { value: 'http://nucc.org/provider-taxonomy|177F00000X', name: 'Lodging' },
    { value: 'http://nucc.org/provider-taxonomy|183500000X', name: 'Pharmacist' },
    { value: 'http://nucc.org/provider-taxonomy|183700000X', name: 'Pharmacy Technician' },
    { value: 'http://nucc.org/provider-taxonomy|193200000X', name: 'Multi-Specialty' },
    { value: 'http://nucc.org/provider-taxonomy|193400000X', name: 'Single Specialty' },
    { value: 'http://nucc.org/provider-taxonomy|202C00000X', name: 'Independent Medical Examiner' },
    { value: 'http://nucc.org/provider-taxonomy|202K00000X', name: 'Phlebology' },
    { value: 'http://nucc.org/provider-taxonomy|204C00000X', name: 'Neuromusculoskeletal Medicine, Sports Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|204D00000X', name: 'Neuromusculoskeletal Medicine & OMM' },
    { value: 'http://nucc.org/provider-taxonomy|204E00000X', name: 'Oral & Maxillofacial Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|204F00000X', name: 'Transplant Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|204R00000X', name: 'Electrodiagnostic Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|207K00000X', name: 'Allergy & Immunology' },
    { value: 'http://nucc.org/provider-taxonomy|207L00000X', name: 'Anesthesiology' },
    { value: 'http://nucc.org/provider-taxonomy|207N00000X', name: 'Dermatology' },
    { value: 'http://nucc.org/provider-taxonomy|207P00000X', name: 'Emergency Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|207Q00000X', name: 'Family Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|207R00000X', name: 'Internal Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|207T00000X', name: 'Neurological Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|207U00000X', name: 'Nuclear Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|207V00000X', name: 'Obstetrics & Gynecology' },
    { value: 'http://nucc.org/provider-taxonomy|207W00000X', name: 'Ophthalmology' },
    { value: 'http://nucc.org/provider-taxonomy|207X00000X', name: 'Orthopaedic Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|207Y00000X', name: 'Otolaryngology' },
    { value: 'http://nucc.org/provider-taxonomy|208000000X', name: 'Pediatrics' },
    { value: 'http://nucc.org/provider-taxonomy|208100000X', name: 'Physical Medicine & Rehabilitation' },
    { value: 'http://nucc.org/provider-taxonomy|208200000X', name: 'Plastic Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|208600000X', name: 'Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|208800000X', name: 'Urology' },
    { value: 'http://nucc.org/provider-taxonomy|208C00000X', name: 'Colon & Rectal Surgery' },
    { value: 'http://nucc.org/provider-taxonomy|208D00000X', name: 'General Practice' },
    { value: 'http://nucc.org/provider-taxonomy|208G00000X', name: 'Thoracic Surgery (Cardiothoracic Vascular Surgery)' },
    { value: 'http://nucc.org/provider-taxonomy|208M00000X', name: 'Hospitalist' },
    { value: 'http://nucc.org/provider-taxonomy|208U00000X', name: 'Clinical Pharmacology' },
    { value: 'http://nucc.org/provider-taxonomy|209800000X', name: 'Legal Medicine' },
    { value: 'http://nucc.org/provider-taxonomy|211D00000X', name: 'Assistant, Podiatric' },
    { value: 'http://nucc.org/provider-taxonomy|213E00000X', name: 'Podiatrist' },
    { value: 'http://nucc.org/provider-taxonomy|221700000X', name: 'Art Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|222Q00000X', name: 'Developmental Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|222Z00000X', name: 'Orthotist' },
    { value: 'http://nucc.org/provider-taxonomy|224900000X', name: 'Mastectomy Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|224L00000X', name: 'Pedorthist' },
    { value: 'http://nucc.org/provider-taxonomy|224P00000X', name: 'Prosthetist' },
    { value: 'http://nucc.org/provider-taxonomy|224Y00000X', name: 'Clinical Exercise Physiologist' },
    { value: 'http://nucc.org/provider-taxonomy|224Z00000X', name: 'Occupational Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|225000000X', name: 'Orthotic Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|225100000X', name: 'Physical Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225200000X', name: 'Physical Therapy Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|225400000X', name: 'Rehabilitation Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|225500000X', name: 'Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|225600000X', name: 'Dance Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225700000X', name: 'Massage Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225800000X', name: 'Recreation Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225A00000X', name: 'Music Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|225B00000X', name: 'Pulmonary Function Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|225C00000X', name: 'Rehabilitation Counselor' },
    { value: 'http://nucc.org/provider-taxonomy|225X00000X', name: 'Occupational Therapist' },
    { value: 'http://nucc.org/provider-taxonomy|226000000X', name: 'Recreational Therapist Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|226300000X', name: 'Kinesiotherapist' },
    { value: 'http://nucc.org/provider-taxonomy|227800000X', name: 'Respiratory Therapist, Certified' },
    { value: 'http://nucc.org/provider-taxonomy|227900000X', name: 'Respiratory Therapist, Registered' },
    { value: 'http://nucc.org/provider-taxonomy|229N00000X', name: 'Anaplastologist' },
    { value: 'http://nucc.org/provider-taxonomy|231H00000X', name: 'Audiologist' },
    { value: 'http://nucc.org/provider-taxonomy|235500000X', name: 'Specialist/Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|235Z00000X', name: 'Speech-Language Pathologist' },
    { value: 'http://nucc.org/provider-taxonomy|237600000X', name: 'Audiologist-Hearing Aid Fitter' },
    { value: 'http://nucc.org/provider-taxonomy|237700000X', name: 'Hearing Instrument Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|242T00000X', name: 'Perfusionist' },
    { value: 'http://nucc.org/provider-taxonomy|243U00000X', name: 'Radiology Practitioner Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|246Q00000X', name: 'Specialist/Technologist, Pathology' },
    { value: 'http://nucc.org/provider-taxonomy|246R00000X', name: 'Technician, Pathology' },
    { value: 'http://nucc.org/provider-taxonomy|246W00000X', name: 'Technician, Cardiology' },
    { value: 'http://nucc.org/provider-taxonomy|246X00000X', name: 'Specialist/Technologist Cardiovascular' },
    { value: 'http://nucc.org/provider-taxonomy|246Y00000X', name: 'Specialist/Technologist, Health Information' },
    { value: 'http://nucc.org/provider-taxonomy|246Z00000X', name: 'Specialist/Technologist, Other' },
    { value: 'http://nucc.org/provider-taxonomy|247000000X', name: 'Technician, Health Information' },
    { value: 'http://nucc.org/provider-taxonomy|247100000X', name: 'Radiologic Technologist' },
    { value: 'http://nucc.org/provider-taxonomy|247200000X', name: 'Technician, Other' },
    { value: 'http://nucc.org/provider-taxonomy|251300000X', name: 'Local Education Agency (LEA)' },
    { value: 'http://nucc.org/provider-taxonomy|251B00000X', name: 'Case Management' },
    { value: 'http://nucc.org/provider-taxonomy|251C00000X', name: 'Day Training, Developmentally Disabled Services' },
    { value: 'http://nucc.org/provider-taxonomy|251E00000X', name: 'Home Health' },
    { value: 'http://nucc.org/provider-taxonomy|251F00000X', name: 'Home Infusion' },
    { value: 'http://nucc.org/provider-taxonomy|251G00000X', name: 'Hospice Care, Community Based' },
    { value: 'http://nucc.org/provider-taxonomy|251J00000X', name: 'Nursing Care' },
    { value: 'http://nucc.org/provider-taxonomy|251K00000X', name: 'Public Health or Welfare' },
    { value: 'http://nucc.org/provider-taxonomy|251S00000X', name: 'Community/Behavioral Health' },
    { value: 'http://nucc.org/provider-taxonomy|251T00000X', name: 'Program of All-Inclusive Care for the Elderly (PACE) Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|251V00000X', name: 'Voluntary or Charitable' },
    { value: 'http://nucc.org/provider-taxonomy|251X00000X', name: 'Supports Brokerage' },
    { value: 'http://nucc.org/provider-taxonomy|252Y00000X', name: 'Early Intervention Provider Agency' },
    { value: 'http://nucc.org/provider-taxonomy|253J00000X', name: 'Foster Care Agency' },
    { value: 'http://nucc.org/provider-taxonomy|253Z00000X', name: 'In Home Supportive Care' },
    { value: 'http://nucc.org/provider-taxonomy|261Q00000X', name: 'Clinic/Center' },
    { value: 'http://nucc.org/provider-taxonomy|273100000X', name: 'Epilepsy Unit' },
    { value: 'http://nucc.org/provider-taxonomy|273R00000X', name: 'Psychiatric Unit' },
    { value: 'http://nucc.org/provider-taxonomy|273Y00000X', name: 'Rehabilitation Unit' },
    { value: 'http://nucc.org/provider-taxonomy|275N00000X', name: 'Medicare Defined Swing Bed Unit' },
    { value: 'http://nucc.org/provider-taxonomy|276400000X', name: 'Rehabilitation, Substance Use Disorder Unit' },
    { value: 'http://nucc.org/provider-taxonomy|281P00000X', name: 'Chronic Disease Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282E00000X', name: 'Long Term Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|282J00000X', name: 'Religious Nonmedical Health Care Institution' },
    { value: 'http://nucc.org/provider-taxonomy|282N00000X', name: 'General Acute Care Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|283Q00000X', name: 'Psychiatric Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|283X00000X', name: 'Rehabilitation Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|284300000X', name: 'Special Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|286500000X', name: 'Military Hospital' },
    { value: 'http://nucc.org/provider-taxonomy|287300000X', name: 'Christian Science Sanitorium' },
    { value: 'http://nucc.org/provider-taxonomy|291900000X', name: 'Military Clinical Medical Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|291U00000X', name: 'Clinical Medical Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|292200000X', name: 'Dental Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|293D00000X', name: 'Physiological Laboratory' },
    { value: 'http://nucc.org/provider-taxonomy|302F00000X', name: 'Exclusive Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|302R00000X', name: 'Health Maintenance Organization' },
    { value: 'http://nucc.org/provider-taxonomy|305R00000X', name: 'Preferred Provider Organization' },
    { value: 'http://nucc.org/provider-taxonomy|305S00000X', name: 'Point of Service' },
    { value: 'http://nucc.org/provider-taxonomy|310400000X', name: 'Assisted Living Facility' },
    { value: 'http://nucc.org/provider-taxonomy|310500000X', name: 'Intermediate Care Facility, Mental Illness' },
    { value: 'http://nucc.org/provider-taxonomy|311500000X', name: 'Alzheimer Center (Dementia Center)' },
    { value: 'http://nucc.org/provider-taxonomy|311Z00000X', name: 'Custodial Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|313M00000X', name: 'Nursing Facility/Intermediate Care Facility' },
    { value: 'http://nucc.org/provider-taxonomy|314000000X', name: 'Skilled Nursing Facility' },
    { value: 'http://nucc.org/provider-taxonomy|315D00000X', name: 'Hospice, Inpatient' },
    { value: 'http://nucc.org/provider-taxonomy|315P00000X', name: 'Intermediate Care Facility, Mentally Retarded' },
    { value: 'http://nucc.org/provider-taxonomy|317400000X', name: 'Christian Science Facility' },
    { value: 'http://nucc.org/provider-taxonomy|320600000X', name: 'Residential Treatment Facility, Mental Retardation and/or Developmental Disabilities' },
    { value: 'http://nucc.org/provider-taxonomy|320700000X', name: 'Residential Treatment Facility, Physical Disabilities' },
    { value: 'http://nucc.org/provider-taxonomy|320800000X', name: 'Community Based Residential Treatment Facility, Mental Illness' },
    { value: 'http://nucc.org/provider-taxonomy|320900000X', name: 'Intellectual and/or Developmental Disabilities Community Based Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|322D00000X', name: 'Residential Treatment Facility, Emotionally Disturbed Children' },
    { value: 'http://nucc.org/provider-taxonomy|323P00000X', name: 'Psychiatric Residential Treatment Facility' },
    { value: 'http://nucc.org/provider-taxonomy|324500000X', name: 'Substance Abuse Rehabilitation Facility' },
    { value: 'http://nucc.org/provider-taxonomy|331L00000X', name: 'Blood Bank' },
    { value: 'http://nucc.org/provider-taxonomy|332000000X', name: 'Military/U.S. Coast Guard Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332100000X', name: 'Department of Veterans Affairs (VA) Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332800000X', name: 'Indian Health Service/Tribal/Urban Indian Health (I/T/U) Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|332900000X', name: 'Non-Pharmacy Dispensing Site' },
    { value: 'http://nucc.org/provider-taxonomy|332B00000X', name: 'Durable Medical Equipment & Medical Supplies' },
    { value: 'http://nucc.org/provider-taxonomy|332G00000X', name: 'Eye Bank' },
    { value: 'http://nucc.org/provider-taxonomy|332H00000X', name: 'Eyewear Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|332S00000X', name: 'Hearing Aid Equipment' },
    { value: 'http://nucc.org/provider-taxonomy|332U00000X', name: 'Home Delivered Meals' },
    { value: 'http://nucc.org/provider-taxonomy|333300000X', name: 'Emergency Response System Companies' },
    { value: 'http://nucc.org/provider-taxonomy|333600000X', name: 'Pharmacy' },
    { value: 'http://nucc.org/provider-taxonomy|335E00000X', name: 'Prosthetic/Orthotic Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|335G00000X', name: 'Medical Foods Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|335U00000X', name: 'Organ Procurement Organization' },
    { value: 'http://nucc.org/provider-taxonomy|335V00000X', name: 'Portable X-ray and/or Other Portable Diagnostic Imaging Supplier' },
    { value: 'http://nucc.org/provider-taxonomy|341600000X', name: 'Ambulance' },
    { value: 'http://nucc.org/provider-taxonomy|341800000X', name: 'Military/U.S. Coast Guard Transport' },
    { value: 'http://nucc.org/provider-taxonomy|343800000X', name: 'Secured Medical Transport (VAN)' },
    { value: 'http://nucc.org/provider-taxonomy|343900000X', name: 'Non-emergency Medical Transport (VAN)' },
    { value: 'http://nucc.org/provider-taxonomy|344600000X', name: 'Taxi' },
    { value: 'http://nucc.org/provider-taxonomy|344800000X', name: 'Air Carrier' },
    { value: 'http://nucc.org/provider-taxonomy|347B00000X', name: 'Bus' },
    { value: 'http://nucc.org/provider-taxonomy|347C00000X', name: 'Private Vehicle' },
    { value: 'http://nucc.org/provider-taxonomy|347D00000X', name: 'Train' },
    { value: 'http://nucc.org/provider-taxonomy|347E00000X', name: 'Transportation Broker' },
    { value: 'http://nucc.org/provider-taxonomy|363A00000X', name: 'Physician Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|363L00000X', name: 'Nurse Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|364S00000X', name: 'Clinical Nurse Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|367500000X', name: 'Nurse Anesthetist, Certified Registered' },
    { value: 'http://nucc.org/provider-taxonomy|367A00000X', name: 'Advanced Practice Midwife' },
    { value: 'http://nucc.org/provider-taxonomy|367H00000X', name: 'Anesthesiologist Assistant' },
    { value: 'http://nucc.org/provider-taxonomy|372500000X', name: 'Chore Provider' },
    { value: 'http://nucc.org/provider-taxonomy|372600000X', name: 'Adult Companion' },
    { value: 'http://nucc.org/provider-taxonomy|373H00000X', name: 'Day Training/Habilitation Specialist' },
    { value: 'http://nucc.org/provider-taxonomy|374700000X', name: 'Technician' },
    { value: 'http://nucc.org/provider-taxonomy|374J00000X', name: 'Doula' },
    { value: 'http://nucc.org/provider-taxonomy|374K00000X', name: 'Religious Nonmedical Practitioner' },
    { value: 'http://nucc.org/provider-taxonomy|374T00000X', name: 'Religious Nonmedical Nursing Personnel' },
    { value: 'http://nucc.org/provider-taxonomy|374U00000X', name: 'Home Health Aide' },
    { value: 'http://nucc.org/provider-taxonomy|376G00000X', name: 'Nursing Home Administrator' },
    { value: 'http://nucc.org/provider-taxonomy|376J00000X', name: 'Homemaker' },
    { value: 'http://nucc.org/provider-taxonomy|376K00000X', name: "Nurse's Aide" },
    { value: 'http://nucc.org/provider-taxonomy|385H00000X', name: 'Respite Care' },
    { value: 'http://nucc.org/provider-taxonomy|390200000X', name: 'Student in an Organized Health Care Education/Training Program' },
    { value: 'http://nucc.org/provider-taxonomy|405300000X', name: 'Prevention Professional' }
  ].freeze

end

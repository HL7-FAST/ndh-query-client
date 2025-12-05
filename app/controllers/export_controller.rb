require 'json'
require 'uri'

class ExportController < ApplicationController
  before_action :connect_to_server

  # GET /export/index
  # Main page for initiating and monitoring bulk FHIR exports
  def index
    clear_export_state
  end

  # POST /export/start
  # Initiates a new bulk FHIR export operation
  def start
    begin
      export_url = build_export_url
      response = initiate_export(export_url)

      if response.code == 202
        handle_export_initiated(response, export_url)
      else
        handle_export_error(response, 'Unexpected response code when initiating export')
      end
    rescue RestClient::Exception => e
      handle_rest_client_error(e, 'Failed to initiate export')
    rescue StandardError => e
      handle_generic_error(e)
    end

    render json: @export_state
  end

  # GET /export/status
  # Polls the status of an ongoing export operation
  def status
    poll_url = session[:export_poll_url]

    if poll_url.blank?
      render json: { status: 'error', message: 'No active export operation' }, status: :not_found
      return
    end

    begin
      response = poll_export_status(poll_url)

      case response.code
      when 200
        handle_export_complete(response)
      when 202
        handle_export_in_progress(response)
      else
        handle_export_error(response, 'Unexpected status code')
      end
    rescue RestClient::Exception => e
      handle_rest_client_error(e, 'Failed to check export status')
    rescue StandardError => e
      handle_generic_error(e)
    end

    render json: @export_state
  end

  # DELETE /export/cancel
  # Cancels an ongoing export operation
  def cancel
    poll_url = session[:export_poll_url]

    if poll_url.present?
      begin
        RestClient::Request.execute(method: :delete, url: poll_url, headers: headers_for_request)
      rescue StandardError => e
        Rails.logger.error "Error canceling export: #{e.message}"
      end
    end

    clear_export_state
    render json: { status: 'canceled', message: 'Export operation canceled' }
  end

  private

  # Build the export URL with all supported parameters
  def build_export_url
    base_url = "#{server_url}/$export"
    query_params = []

    # Standard FHIR bulk export parameters - default to application/fhir+ndjson
    query_params << "_outputFormat=#{CGI.escape('application/fhir+ndjson')}"
    query_params << "_since=#{CGI.escape(params[:since])}" if params[:since].present?
    query_params << "_until=#{CGI.escape(params[:until])}" if params[:until].present?

    if params[:resource_types].present?
      types = params[:resource_types].is_a?(Array) ? params[:resource_types].join(',') : params[:resource_types]
      query_params << "_type=#{CGI.escape(types)}"
    end

    if params[:type_filter].present?
      filters = params[:type_filter].is_a?(Array) ? params[:type_filter] : [params[:type_filter]]
      filters.each { |filter| query_params << "_typeFilter=#{CGI.escape(filter)}" }
    end

    query_params << "_elements=#{CGI.escape(params[:elements])}" if params[:elements].present?

    query_string = query_params.any? ? "?#{query_params.join('&')}" : ''
    "#{base_url}#{query_string}"
  end

  # Initiate the export request
  def initiate_export(export_url)
    RestClient::Request.execute(
      method: :get,
      url: export_url,
      headers: headers_for_export
    )
  end

  # Poll the export status
  def poll_export_status(poll_url)
    RestClient::Request.execute(
      method: :get,
      url: poll_url,
      headers: headers_for_request
    )
  end

  # Headers for initiating export
  def headers_for_export
    {
      'Accept' => 'application/fhir+json',
      'Prefer' => 'respond-async'
    }
  end

  # Headers for status polling
  def headers_for_request
    { 'Accept' => 'application/fhir+json' }
  end

  # Handle successful export initiation
  def handle_export_initiated(response, export_url)
    poll_url = response.headers[:content_location]
    session[:export_poll_url] = poll_url
    session[:export_request_url] = export_url

    @export_state = {
      status: 'initiated',
      message: 'Export successfully initiated',
      poll_url: poll_url,
      request_url: export_url,
      retry_after: response.headers[:retry_after]&.to_i || 5
    }
  end

  # Handle export still in progress
  def handle_export_in_progress(response)
    progress = response.headers[:x_progress]
    retry_after = response.headers[:retry_after]&.to_i || 5

    @export_state = {
      status: 'in_progress',
      message: progress || 'Export in progress',
      progress: progress,
      retry_after: retry_after,
      poll_url: session[:export_poll_url],
      request_url: session[:export_request_url]
    }
  end

  # Handle completed export
  def handle_export_complete(response)
    manifest = parse_json_response(response)

    if manifest
      poll_url = session[:export_poll_url]
      session[:export_poll_url] = nil
      @export_state = {
        status: 'complete',
        message: manifest['message'] || 'Export completed',
        manifest: manifest,
        transaction_time: manifest['transactionTime'],
        request_url: manifest['request'],
        poll_url: poll_url,
        requires_access_token: manifest['requiresAccessToken'],
        output_files: manifest['output'] || [],
        deleted_files: manifest['deleted'] || [],
        error_files: manifest['error'] || []
      }
    else
      handle_parse_error
    end
  end

  # Handle export errors
  def handle_export_error(response, message)
    operation_outcome = parse_json_response(response)
    session[:export_poll_url] = nil

    @export_state = {
      status: 'error',
      message: message,
      http_status: response.code,
      operation_outcome: operation_outcome
    }
  end

  # Handle RestClient errors
  def handle_rest_client_error(error, message)
    operation_outcome = nil

    operation_outcome = parse_json_response(error.response) if error.response

    session[:export_poll_url] = nil

    @export_state = {
      status: 'error',
      message: "#{message}: #{error.message}",
      http_status: error.response&.code,
      operation_outcome: operation_outcome
    }
  end

  # Handle generic errors
  def handle_generic_error(error)
    Rails.logger.error "Export error: #{error.message}\n#{error.backtrace.join("\n")}"
    session[:export_poll_url] = nil

    @export_state = {
      status: 'error',
      message: "An unexpected error occurred: #{error.message}"
    }
  end

  # Handle JSON parsing errors
  def handle_parse_error
    @export_state = {
      status: 'error',
      message: 'Failed to parse export response'
    }
  end

  # Parse JSON response
  def parse_json_response(response)
    body = response.respond_to?(:to_str) ? response.to_str : response.body
    return nil if body.blank?

    content_type = response.headers[:content_type] || ''
    return nil unless content_type.match?(%r{application/(fhir\+)?json|text/json})

    JSON.parse(body)
  rescue JSON::ParserError => e
    Rails.logger.error "JSON parse error: #{e.message}"
    nil
  end

  # Clear export state
  def clear_export_state
    session[:export_poll_url] = nil
    session[:export_request_url] = nil
  end
end

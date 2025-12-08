# frozen_string_literal: true

################################################################################
#
# Practitioner Helper
#
# Copyright (c) 2019 The MITRE Corporation.  All rights reserved.
#
################################################################################

module PractitionerHelper

  def display_qualification(qualification)
    sanitize(qualification.identifier)
  end

  #-----------------------------------------------------------------------------

  def display_code(code)
    sanitize(code.coding.display)
  end

  #-----------------------------------------------------------------------------

  def display_period(period, include_label: true)
    return '' unless period.present?

    start_date = format_period_date(period.start)
    end_date = format_period_date(period.end)

    result = if start_date.present? && end_date.present?
               "#{start_date} to #{end_date}"
             elsif start_date.present?
               "#{start_date} onwards"
             elsif end_date.present?
               "until #{end_date}"
             else
               ''
             end

    return '' if result.blank?

    result = "Effective #{result}" if include_label
    sanitize(result)
  end

  def format_period_date(date_string)
    return nil if date_string.blank?

    # Parse ISO 8601 date and format as YYYY-MM-DD
    Date.parse(date_string).strftime('%Y-%m-%d')
  rescue ArgumentError
    date_string
  end

  #-----------------------------------------------------------------------------

  def display_issuer(issuer)
    sanitize(issuer.display)
  end

  #-----------------------------------------------------------------------------

  def display_photo(photo, gender, options)
      options [:class] = "img-fluid"
      image_tag(photo, options)
  end
  
end

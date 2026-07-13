# frozen_string_literal: true

# Ask the FHIR server for an accurate match count on every GET search so
# result pages can display totals. Servers that ignore _total are unaffected.
module FHIRSearchWithTotal
  def search(klass, options = {}, format = @default_format)
    if options.dig(:search, :body).nil?
      options[:search] ||= {}
      parameters = (options[:search][:parameters] ||= {})
      parameters[:_total] = 'accurate' unless parameters.key?(:_total) || parameters.key?('_total')
    end
    super
  end
end

FHIR::Client.prepend(FHIRSearchWithTotal)

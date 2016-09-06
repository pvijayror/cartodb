# encoding: utf-8

require_relative './odbc'

module CartoDB
  module Importer2
    class Connector

      # Generic ODBC provider passing through any ODBC connection attributes in the 'connection' parameter.
      # Either a 'driver' or a 'dns' parameter must be present in 'connection'.
      #
      # This is not meant for public use.
      #
      class GenericOdbcProvider < OdbcProvider

        def initialize(params)
          super
          if @connection
            @dsn        = @connection[:dsn]
            @driver     = @connection[:driver]
          end
        end

        def errors
          errors = super
          if @connection.blank?
            errors << "Missing 'connection' parameters"
          else
            errors << "Must define either 'dsn' or 'driver' in 'connection'" if @dns.blank? && @driver.blank?
          end
          errors
        end

        private

        def connection_attributes
          @connection
        end
      end

    end
  end
end

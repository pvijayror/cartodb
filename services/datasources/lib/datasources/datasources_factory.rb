# encoding: utf-8

module CartoDB
  module Datasources
      class DatasourcesFactory

        NAME = 'DatasourcesFactory'

        # Retrieve a datasource instance
        # @param datasource_name string
        # @param user User
        # @return mixed
        # @throws MissingConfigurationError
        def self.get_datasource(datasource_name, user)
          case datasource_name
            when Url::Dropbox::DATASOURCE_NAME
              Url::Dropbox.get_new(DatasourcesFactory.config_for(datasource_name), user)
            when Url::GDrive::DATASOURCE_NAME
              Url::GDrive.get_new(DatasourcesFactory.config_for(datasource_name), user)
            when Url::PublicUrl::DATASOURCE_NAME
              Url::PublicUrl.get_new()
            when nil
              nil
            else
              raise MissingConfigurationError.new("unrecognized datasource #{datasource_name}", NAME)
          end
        end

        # Gets the config of a certain datasource
        # @param datasource_name string
        # @return string
        # @throws MissingConfigurationError
        def self.config_for(datasource_name)
          config_source = @forced_config ? @forced_config : Cartodb.config

          case datasource_name
            when Url::Dropbox::DATASOURCE_NAME, Url::GDrive::DATASOURCE_NAME
              config = (config_source[:oauth] rescue nil)
              config = (config_source[:oauth.to_s] rescue nil)
            when Search::Twitter
              config = (config_source[:datasources_search] rescue nil)
              config = (config_source[:datasources_search.to_s] rescue nil)
            else
              config = nil
          end

          if config.nil? || config.empty?
            raise MissingConfigurationError.new("missing configuration for datasource #{datasource_name}", NAME)
          end
          config.fetch(datasource_name)
        end

        # Allows to set a custom config (useful for testing)
        # @param custom_config string
        def self.set_config(custom_config)
          @forced_config = custom_config
        end

      end
  end
end


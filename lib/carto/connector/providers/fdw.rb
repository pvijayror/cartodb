# encoding: utf-8

require_relative './base'

# Base class for Connector Providers
# that use FDW to import data through a foreign table.
#
# This is an abstract class; concrete classes derived from this one
# must implement these methods to handle FDW operations:
#
# * `fdw_create_server(server_name)`
# * `fdw_create_usermap(server_name, user_name)`
# * `fdw_create_foreign_table(server_name, schema_name, foreign_prefix, username)`
# * `fdw_list_tables(limits:)`
#
module Carto
  class Connector
    class FdwProvider < Provider
      def copy_table(schema_name:, table_name:, limits: {})
        log "Connector Copy table  #{schema_name}.#{table_name}"
        validate!
        # TODO: logging with CartoDB::Logger
        with_server do
          begin
            qualified_table_name = fdw_qualified_table_name(schema_name, table_name)
            log "Creating Foreign Table"
            foreign_table_name = fdw_create_foreign_table(
              server_name,
              foreign_table_schema,
              foreign_prefix,
              @connector_context.user.database_username
            )
            log "Copying Foreign Table"
            max_rows = limits[:max_rows]
            fdw_copy_foreign_table(
              qualified_table_name, qualified_foreign_table_name(foreign_table_name), max_rows
            )
            check_copied_table_size(qualified_table_name, max_rows)
          ensure
            fdw_drop_foreign_table(foreign_table_schema, foreign_table_name) if foreign_table_name
          end
        end
      end

      def list_tables(limits: {})
        limit = limits[:max_listed_tables]
        validate! only: [:connection]
        with_server do
          fdw_list_tables server_name, foreign_table_schema, foreign_prefix, limit
        end
      end

      def remote_data_updated?
        # TODO: can we detect if query results have changed?
        true
      end

      private

      include FdwSupport

      # Execute code that requires a FDW server/user mapping
      # The server name is given by the method `#server_name`
      def with_server
        # Currently we create temporary server and user mapings when we need them,
        # and drop them after use.
        log "Creating Server"
        fdw_create_server server_name
        log "Creating Usermaps"
        fdw_create_usermap server_name, @connector_context.user.database_username
        fdw_create_usermap server_name, 'postgres'
        yield
      rescue => error
        log "Connector Error #{error}"
        raise error
      ensure
        log "Connector cleanup"
        fdw_drop_usermap server_name, 'postgres'
        fdw_drop_usermap server_name, @connector_context.user.database_username
        fdw_drop_server server_name
        log "Connector cleaned-up"
      end

      # maximum unique identifier length in PostgreSQL
      MAX_PG_IDENTIFIER_LEN = 63
      # minimum length left available for the table part in foreign table names
      MIN_TAB_ID_LEN        = 10

      # Named used for the foreign server (unique poer Connector instance)
      def server_name
        max_len = MAX_PG_IDENTIFIER_LEN - unique_suffix.size - MIN_TAB_ID_LEN - 1
        connector_name = Carto::DB::Sanitize.sanitize_identifier self.class.to_s.split('::').last
        "#{connector_name[0...max_len].downcase}_#{unique_suffix}"
      end

      # Prefix to be used by foreign table names (so they're unique per Connector instance)
      # This leaves at least MIN_TAB_ID_LEN available identifier characters given PostgreSQL's
      # limit of MAX_PG_IDENTIFIER_LEN
      def foreign_prefix
        "#{server_name}_"
      end

      def foreign_table_schema
        # since connectors' foreign table names are unique (because
        # server names are unique and not reused)
        # we could in principle use any schema (@schema, 'public', 'cdb_importer')
        CartoDB::Connector::Importer::ORIGIN_SCHEMA
      end

      def qualified_foreign_table_name(foreign_table_name)
        fdw_qualified_table_name(foreign_table_schema, foreign_table_name)
      end

      # Create FDW server with given name
      def fdw_create_server(_server_name)
        must_be_defined_in_derived_class
      end

      # Create usermap for the given user
      def fdw_create_usermap(_server_name, _username)
        must_be_defined_in_derived_class
      end

      # Create the foreign table used for importing
      # Must return the name of the created foreign table
      def fdw_create_foreign_table(_server_name, _schema_name, _foreign_prefix, _username)
        must_be_defined_in_derived_class
      end

      # SQL code to drop the FDW server
      def fdw_drop_server(server_name)
        execute_as_superuser fdw_drop_server_sql(server_name, cascade: true)
      end

      # Dop the user mapping
      def fdw_drop_usermap(server_name, user)
        execute_as_superuser fdw_drop_usermap_sql(server_name, user)
      end

      # Drop the foreign table
      def fdw_drop_foreign_table(schema_name, table_name)
        execute_as_superuser fdw_drop_foreign_table_sql(schema_name, table_name)
      end

      # Copy foreign table to local table
      def fdw_copy_foreign_table(local_table_name, foreign_table_name, max_rows)
        limit = max_rows && max_rows > 0 ? " LIMIT #{max_rows}" : ''
        execute %{
          CREATE TABLE #{local_table_name}
            AS SELECT * FROM #{foreign_table_name}
              #{limit};
        }
      end

      # Retrieve list of external tables;
      # should return array of hashes with keys :schema and :name
      def fdw_list_tables(_limits: {})
        must_be_defined_in_derived_class
      end

      def check_copied_table_size(table_name, max_rows)
        warnings = {}
        if max_rows && max_rows > 0
          num_rows = execute(%{
            SELECT count(*) as num_rows FROM #{table_name};
          }).first['num_rows']
          if num_rows == max_rows
            # The maximum number of rows per connection was reached
            warnings[:max_rows_per_connection] = max_rows
          end
        end
        warnings
      end

      def unique_suffix
        @unique_suffix ||= UUIDTools::UUID.timestamp_create.to_s.delete('-') # .to_i.to_s(16) # or hash from user, etc.
      end
    end
  end
end

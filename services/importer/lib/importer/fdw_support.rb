# encoding: utf-8

# Support methods to generate FDW-related SQL commands

module CartoDB
  module FdwSupport
    def fdw_create_server(fdw, server_name, options)
      %{
        CREATE SERVER #{server_name}
          FOREIGN DATA WRAPPER #{fdw}
          #{options_clause(options)};
      }
    end

    def fdw_create_usermap(server_name, user_name, options)
      %{
        CREATE USER MAPPING FOR "#{user_name}"
          SERVER #{server_name}
          #{options_clause(options)};
      }
    end

    def fdw_import_foreign_schema(server_name, remote_schema_name, schema_name, options)
      %{
        IMPORT FOREIGN SCHEMA "#{remote_schema_name}"
          FROM SERVER #{server_name}
          INTO "#{schema_name}"
          #{options_clause(options)};
       }
    end

    def fdw_import_foreign_schema_limited(server_name, remote_schema_name, schema_name, limited_to, options)
      %{
        IMPORT FOREIGN SCHEMA "#{remote_schema_name}"
          LIMIT TO #{limited_to}
          FROM SERVER #{server_name}
          INTO "#{schema_name}"
          #{options_clause(options)};
       }
    end

    def fdw_grant_select(schema_name, table_name, user_name)
      %{
        GRANT SELECT ON #{qualified_table_name(schema_name, table_name)} TO "#{user_name}";
       }
    end

    def fdw_create_foreign_table(server_name, schema_name, table_name, columns, options)
      %{
        CREATE FOREIGN TABLE #{qualified_table_name(schema_name, table_name)} (#{columns * ','})
          SERVER #{server_name}
          #{options_clause(options)};
       }
    end

    def fdw_drop_server(server_name)
      "DROP SERVER IF EXISTS #{server_name} CASCADE;"
    end

    def fdw_drop_foreign_table(schema_name, table_name)
      %{DROP FOREIGN TABLE IF EXISTS #{qualified_table_name(schema_name, table_name)} CASCADE;}
    end

    def fdw_rename_foreign_table(schema, foreign_table_name, new_name)
      %{
        ALTER FOREIGN TABLE #{qualified_table_name(schema, foreign_table_name)}
        RENAME TO #{qualified_table_name(nil, new_name)};
      }
    end

    private

    def qualified_table_name(schema_name, table_name)
      name = []
      name << %{"#{schema_name}"} if schema_name.present?
      name << %{"#{table_name}"}
      name.join('.')
    end

    def quote_option_name(option)
      option = option.to_s
      if option && option.to_s.downcase != option.to_s
        %{"#{option}"}
      else
        option
      end
    end

    def options_clause(options)
      if options.present?
        options_list = options.map { |k, v| "#{quote_option_name k} '#{escape_single_quotes v}'" } * ",\n"
        "OPTIONS (#{options_list})"
      else
        ''
      end
    end

    def escape_single_quotes(text)
      text.to_s.gsub("'", "''")
    end
  end
end

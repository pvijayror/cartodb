# Overview creation
#
# Pending issues: metrics, quotas/limits, timing, logging, ...
#
class Overviews

  MIN_ROWS = 1000000

  def initialize(user, database = nil)
    @user = user
    @database = database || user.in_database
  end

  def required?(table, options = {})
    schema = schema_from_options(options)
    # TODO: check quotas, etc...
    table_row_count(schema, table) >= MIN_ROWS
  end

  def create!(table, options = {})
    schema = schema_from_options(options)
    table_name = table_name_with_schema(schema, table)

    # TODO: timing, loggin, ...
    @database.run %{
      SELECT cartodb.CDB_CreateOverviews('#{table_name}'::REGCLASS);
    }
  end

  private

  def table_row_count(schema, table)
    table_row_count = CartoDB::PlatformLimits::Importer::TableRowCount.new(
      user: @user,
      db: @database
    )
    table_row_count.get(table_name: table, tables_schema: schema)
  end

  def schema_from_options(options = {})
    options[:schema] || @user.database_schema
  end

  def table_name_with_schema(schema, table)
    # TODO: quote if necessary
    "#{schema}.#{table}"
  end

end

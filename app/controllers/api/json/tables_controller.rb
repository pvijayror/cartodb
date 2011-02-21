# coding: UTF-8

class Api::Json::TablesController < ApplicationController

  REJECT_PARAMS = %W{ format controller action id row_id }

  skip_before_filter :verify_authenticity_token

  before_filter :api_authorization_required
  before_filter :load_table, :except => [:index, :create, :query]

  # Get the list of tables of a user
  # * Request Method: +GET+
  # * URI: +/api/json/tables+
  # * Format: +JSON+
  # * Response:
  #     [
  #       {
  #         "id" => 1,
  #         "name" => "My table",
  #         "privacy" => "PUBLIC"
  #       },
  #       {
  #         "id" => 2,
  #         "name" => "My private data",
  #         "privacy" => "PRIVATE"
  #       }
  #     ]
  def index
    @tables = Table.select(:id,:user_id,:name,:privacy).all
    respond_to do |format|
      format.json do
        render :json => @tables.map{ |table| {:id => table.id, :name => table.name, :privacy => table_privacy_text(table)} }.to_json,
               :callback => params[:callback]
      end
    end
  end

  # Gets the rows from a table
  # * Request Method: +GET+
  # * URI: +/api/json/tables/1+
  # * Params:
  #   * +rows_per_page+: number of rows in the response. By default +10+
  #   * +page+: number of the current page. By default +0+
  # * Format: +JSON+
  # * Response:
  #     {
  #       "total_rows" => 100,
  #       "columns" => [[:id, "integer"], [:name, "text"], [:location, "geometry"], [:description, "text"]],
  #       "rows" => [{:id=>1, :name=>"name 1", :location=>"...", :description=>"description 1"}]
  #     }
  def show
    respond_to do |format|
      format.json do
        render :json => @table.to_json(:rows_per_page => params[:rows_per_page], :page => params[:page], :cartodb_types => true),
               :callback => params[:callback]
      end
    end
  end

  # Create a new table
  # * Request Method: +POST+
  # * URI: +/api/json/tables
  # * Format: +JSON+
  # * Response if _success_:
  #   * status code: 302
  #   * location: the url of the new table
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error message"] }
  def create
    @table = Table.new
    @table.user_id = current_user.id
    @table.name = params[:name] if params[:name]
    if params[:file]
      @table.import_from_file = params[:file]
      if $progress[params["X-Progress-ID".to_sym]].nil?
        $progress[params["X-Progress-ID".to_sym]] = 0
      end
    end
    @table.force_schema = params[:schema] if params[:schema]
    if @table.valid? && @table.save
      render :json => { :id => @table.id }.to_json, :status => 200, :location => table_path(@table),
             :callback => params[:callback]
    else
      render :json => { :errors => @table.errors.full_messages }.to_json, :status => 400, :callback => params[:callback]
    end
  rescue => e
    render :json => { :errors => [translate_error(e.message.split("\n").first)] }.to_json,
           :status => 400, :callback => params[:callback] and return
  end

  # Run a query against your database
  # * Request Method: +GET+
  # * URI: +/api/json/tables/query+
  # * Params:
  #   * +query+: the query to be executed
  # * Format: +JSON+
  # * Response:
  #     {
  #       "total_rows" => 100,
  #       "columns" => [:id, :name, ...],
  #       "rows" => [{:id=>1, :name=>"name 1", :location=>"...", :description=>"description 1"}]
  #     }
  def query
    respond_to do |format|
      format.json do
        render :json => current_user.run_query(params[:query]).to_json, :callback => params[:callback]
      end
    end
  end

  # Gets the scehma from a table
  #
  # * Request Method: +GET+
  # * URI: +/api/json/tables/1/schema+
  # * Format: +JSON+
  # * Response:
  #     [[:id, "integer"], [:name, "text"], [:location, "geometry"], [:description, "text"]]
  def schema
    respond_to do |format|
      format.json do
        render :json => @table.schema(:cartodb_types => true).to_json, :callback => params[:callback]
      end
    end
  end

  # Toggle the privacy of a table. Returns the new privacy status
  # * Request Method: +PUT+
  # * URI: +/api/json/tables/1/toggle_privacy+
  # * Format: +JSON+
  # * Response:
  #     { "privacy" => "PUBLIC" }
  def toggle_privacy
    @table.toggle_privacy!
    respond_to do |format|
      format.json do
        render :json => { :privacy => table_privacy_text(@table) }.to_json, :callback => params[:callback]
      end
    end
  end

  # Update a table
  # * Request Method: +PUT+
  # * URI: +/api/json/tables/1/update+
  # * Format: +JSON+
  # * Parameters: a hash with keys representing the attributes and values with the new values for that attributes
  #     {
  #       "tags" => "new tag #1, new tag #2",
  #       "name" => "new name"
  #     }
  # * Response if _success_:
  #   * status code: 200
  #   * body:
  #       {
  #         "tags" => "new tag #1, new tag #2"
  #         "name" => "new name"
  #       }
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error #1", "error #2"] }
  def update
    respond_to do |format|
      format.json do
        begin
          @table.set_all(params)
          if @table.save
            render :json => params.merge(@table.reload.values).to_json, :status => 200, :callback => params[:callback]
          else
            render :json => { :errors => @table.errors.full_messages}.to_json, :status => 400, :callback => params[:callback]
          end
        rescue => e
          render :json => { :errors => [translate_error(e.message.split("\n").first)] }.to_json,
                 :status => 400, :callback => params[:callback] and return
        end
      end
    end
  end

  # Update the schema of a table
  # * Request Method: +PUT+
  # * URI: +/api/json/tables/:id/update_schema+
  # * Format: +JSON+
  # * Parameters for adding or removing a column:
  #     {
  #       "what" => ("add"|"drop")
  #       "column" => {
  #          "name" => "new column name",
  #          "type" => "type"
  #       }
  #     }
  # * Parameters for modifying a column:
  #     {
  #       "what" => "modify"
  #       "column" => {
  #          "old_name" => "old column name"
  #          "new_name" => "new column name",
  #          "type" => "the new type"
  #       }
  #     }
  # * Response if _success_:
  #   * status code: 200
  #   * body: _nothing_
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error message"] }
  def update_schema
    respond_to do |format|
      format.json do
        if params[:what] && %W{ add drop modify }.include?(params[:what])
          unless params[:column].blank? || params[:column].empty?
            begin
              if params[:what] == 'add'
                resp = @table.add_column!(params[:column])
                render :json => resp.to_json, :status => 200, :callback => params[:callback] and return
              elsif params[:what] == 'drop'
                @table.drop_column!(params[:column])
                render :json => ''.to_json, :status => 200, :callback => params[:callback] and return
              else
                resp = @table.modify_column!(params[:column])
                render :json => resp.to_json, :status => 200, :callback => params[:callback] and return
              end
            rescue => e
              errors = if e.is_a?(CartoDB::InvalidType)
                [e.db_message]
              else
                [translate_error(e.message.split("\n").first)]
              end
              render :json => { :errors => errors }.to_json, :status => 400,
                     :callback => params[:callback] and return
            end
          else
            render :json => { :errors => ["column parameter can't be blank"] }.to_json, :status => 400,
                   :callback => params[:callback] and return
          end
        else
          render :json => { :errors => ["what parameter has an invalid value"] }.to_json, :status => 400,
                 :callback => params[:callback] and return
        end
      end
    end
  end

  # Insert a new row in a table
  # * Request Method: +POST+
  # * URI: +/api/json/tables/:id/rows+
  # * Format: +JSON+
  # * Parameters:
  #     {
  #       "column_name1" => "value1",
  #       "column_name2" => "value2"
  #     }
  # * Response if _success_:
  #   * status code: 200
  #   * body: _nothing_
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error message"] }
  def create_row
    primary_key = @table.insert_row!(params.reject{|k,v| REJECT_PARAMS.include?(k)})
    respond_to do |format|
      format.json do
        render :json => {:id => primary_key}.to_json, :status => 200, :callback => params[:callback]
      end
    end
  rescue => e
    render :json => { :errors => [e.error_message] }.to_json, :status => 400,
           :callback => params[:callback] and return
  end

  # Insert a new row in a table
  # * Request Method: +PUT+
  # * URI: +/api/json/tables/:id/rows/:row_id+
  # * Format: +JSON+
  # * Parameters:
  #     {
  #       "column_name" => "new value"
  #     }
  # * Response if _success_:
  #   * status code: 200
  #   * body: _nothing_
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error message"] }
  def update_row
    respond_to do |format|
      format.json do
        unless params[:row_id].blank?
          begin
            if resp = @table.update_row!(params[:row_id], params.reject{|k,v| REJECT_PARAMS.include?(k)})
              render :json => ''.to_json, :status => 200
            else
              case resp
                when 404
                  render :json => { :errors => ["row identified with #{params[:row_id]} not found"] }.to_json,
                         :status => 400, :callback => params[:callback] and return
              end
            end
          rescue => e
            render :json => { :errors => [translate_error(e.message.split("\n").first)] }.to_json, :status => 400,
                   :callback => params[:callback] and return
          end
        else
          render :json => { :errors => ["row_id can't be blank"] }.to_json,
                 :status => 400, :callback => params[:callback] and return
        end
      end
    end
  end

  # Drop the table
  # * Request Method: +DELETE+
  # * URI: +/api/json/tables/:id
  # * Format: +JSON+
  # * Response if _success_:
  #   * status code: 200
  #   * body: _nothing_
  def delete
    @table.destroy
    render :json => ''.to_json, :status => 200, :location => dashboard_path, :callback => params[:callback]
  end

  # Set the columns of the geometry of the table
  # * Request Method: +PUT+
  # * URI: +/api/json/table/:id/set_geometry_columns
  # * Format: +JSON+
  # * Parameters for setting lat and lon columns:
  #     {
  #       "lat_column" => "<lat_column_name>",
  #       "lon_column" => "<lon_column_name>"
  #     }
  # * Parameters for setting an address column:
  #     {
  #       "address_column" => "<address_column_name>"
  #     }
  # * Response if _success_:
  #   * status code: 200
  # * Response if _error_:
  #   * status code +400+
  #   * body:
  #       { "errors" => ["error message"] }
  def set_geometry_columns
    if params.keys.include?("lat_column") && params.keys.include?("lon_column")
      @table.set_lan_lon_columns!(params[:lat_column].try(:to_sym), params[:lon_column].try(:to_sym))
      render :json => ''.to_json, :status => 200, :callback => params[:callback]
    elsif params.keys.include?("address_column")
      @table.set_address_column!(params[:address_column].try(:to_sym))
      render :json => ''.to_json, :status => 200, :callback => params[:callback]
    else
      render :json => { :errors => ["Invalid parameters"] }.to_json,
             :status => 400, :callback => params[:callback] and return
    end
  rescue => e
    render :json => { :errors => [translate_error(e.message.split("\n").first)] }.to_json,
           :status => 400, :callback => params[:callback] and return
  end

  protected

  def load_table
    @table = Table.select(:id,:user_id,:name,:privacy,:geometry_columns).filter(:id => params[:id]).first
    raise RecordNotFound if @table.user_id != current_user.id
  end

end
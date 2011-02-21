# coding: UTF-8

require File.expand_path(File.dirname(__FILE__) + '/../acceptance_helper')

feature "Tables JSON API" do

  background do
    Capybara.current_driver = :rack_test
  end

  scenario "Retrieve different pages of rows from a table" do
    user = create_user
    table = create_table :user_id => user.id

    10.times do
      user.run_query("INSERT INTO \"#{table.name}\" (Name,Latitude,Longitude,Description) VALUES ('#{String.random(10)}',#{rand(100000).to_f / 100.0}, #{rand(100000).to_f / 100.0},'#{String.random(100)}')")
    end

    content = user.run_query("select * from \"#{table.name}\"")[:rows]

    authenticate_api user

    get_json "/api/json/tables/#{table.id}?rows_per_page=2"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 10
    json_response['columns'].should == [
      ["cartodb_id", "number"], ["name", "string"], ["latitude", "number", "latitude"],
      ["longitude", "number", "longitude"], ["description", "string"], ["created_at", "date"], ["updated_at", "date"]
    ]
    json_response['rows'][0].symbolize_keys.slice(:cartodb_id, :name, :location, :description).
      should == content[0].slice(:cartodb_id, :name, :location, :description)
    json_response['rows'][1].symbolize_keys.slice(:cartodb_id, :name, :location, :description).
      should == content[1].slice(:cartodb_id, :name, :location, :description)

    get_json "/api/json/tables/#{table.id}?rows_per_page=2&page=1"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['rows'][0].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[2].slice(:cartodb_id, :name, :location, :description)
    json_response['rows'][1].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[3].slice(:cartodb_id, :name, :location, :description)
  end

  scenario "Update the privacy status of a table" do
    user = create_user
    table = create_table :user_id => user.id, :privacy => Table::PRIVATE

    table.should be_private

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/toggle_privacy"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['privacy'].should == 'PUBLIC'
    table.reload.should_not be_private

    put_json "/api/json/tables/#{table.id}/toggle_privacy"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['privacy'].should == 'PRIVATE'
    table.reload.should be_private
  end

  scenario "Update the name of a table" do
    user = create_user
    old_table = create_table :user_id => user.id, :privacy => Table::PRIVATE, :name => 'Old table'
    table = create_table :user_id => user.id, :privacy => Table::PRIVATE

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/update", {:name => "My brand new name"}
    response.status.should == 200
    table.reload
    table.name.should == "my_brand_new_name"
    json_response = JSON(response.body)
    json_response['name'].should == 'my_brand_new_name'

    put_json "/api/json/tables/#{table.id}/update", {:name => ""}
    response.status.should == 200
    table.reload
    table.name.should == "untitle_table"
    json_response = JSON(response.body)
    json_response['name'].should == 'untitle_table'

    put_json "/api/json/tables/#{old_table.id}/update", {:name => "Untitle table"}
    response.status.should == 400
    json_response = JSON(response.body)
    json_response['errors'].should == ["A table with name \"untitle_table\" already exists"]
    old_table.reload
    old_table.name.should == "old_table"
  end

  scenario "Update the tags of a table" do
    user = create_user
    table = create_table :user_id => user.id

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/update", {:tags => "tag1, tag2, tag3"}
    response.status.should == 200
    Tag.count.should == 3
    tags = Tag.filter(:user_id => user.id, :table_id => table.id).all
    tags.size.should == 3
    tags.map(&:name).sort.should == %W{ tag1 tag2 tag3 }

    put_json "/api/json/tables/#{table.id}/update", {:tags => ""}
    response.status.should == 200
    Tag.count.should == 0
  end

  scenario "Get the schema of a table" do
    user = create_user
    table = create_table :user_id => user.id

    authenticate_api user

    get_json "/api/json/tables/#{table.id}/schema"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == [
      ["cartodb_id", "number"], ["name", "string"], ["latitude", "number", "latitude"],
      ["longitude", "number", "longitude"], ["description", "string"], ["created_at", "date"], ["updated_at", "date"]
    ]
  end

  scenario "Get a list of tables" do
    user = create_user

    authenticate_api user

    get_json "/api/json/tables"
    response.status.should == 200
    JSON(response.body).should == []

    table1 = create_table :user_id => user.id, :name => 'My table #1', :privacy => Table::PUBLIC
    table2 = create_table :user_id => user.id, :name => 'My table #2', :privacy => Table::PRIVATE
    get_json "/api/json/tables"
    response.status.should == 200
    response.body.should == [
      {
        "id" => table1.id,
        "name" => "my_table_1",
        "privacy" => "PUBLIC"
      },
      {
        "id" => table2.id,
        "name" => "my_table_2",
        "privacy" => "PRIVATE"
      }
    ].to_json
  end

  scenario "Modify the schema of a table" do
    user = create_user
    table = create_table :user_id => user.id

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "add", :column => {
                                                                  :type => "number", :name => "postal code"
                                                              }
                                                           }
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == {"name" => "postal_code", "type" => "integer", "cartodb_type" => "number"}
    table.reload

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "modify", :column => {
                                                                  :type => "string", :name => "postal_code"
                                                              }
                                                           }
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == {"name" => "postal_code", "type" => "varchar", "cartodb_type" => "string"}


    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "modify", :column => {
                                                                  :type => "number", :name => "postal_code"
                                                              }
                                                           }
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == {"name" => "postal_code", "type" => "integer", "cartodb_type" => "number"}

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "add", :column => {
                                                                  :type => "integerrrr", :name => "no matter what"
                                                              }
                                                           }
    response.status.should == 400
    json_response = JSON(response.body)
    json_response['errors'].should == ["PGError: ERROR:  type \"integerrrr\" does not exist"]

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "drop", :column => {
                                                                :name => "postal_code"
                                                              }
                                                           }
    response.status.should == 200

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "drop", :column => {
                                                                :name => "postal_code"
                                                              }
                                                           }
    response.status.should == 400
    table.reload
    json_response = JSON(response.body)
    json_response['errors'].should == ["PGError: ERROR:  column \"postal_code\" of relation \"#{table.name}\" does not exist"]

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "wadus", :column => {
                                                                :name => "postal_code"
                                                              }
                                                           }
    response.status.should == 400
    table.reload
    json_response = JSON(response.body)
    json_response['errors'].should == ["what parameter has an invalid value"]

    put_json "/api/json/tables/#{table.id}/update_schema", {
                                                              :what => "add", :column => {}
                                                           }
    response.status.should == 400
    table.reload
    json_response = JSON(response.body)
    json_response['errors'].should == ["column parameter can't be blank"]
  end

  scenario "Insert a new row in a table" do
    user = create_user
    table = create_table :user_id => user.id

    authenticate_api user

    post_json "/api/json/tables/#{table.id}/rows", {
        :name => "Name 123",
        :description => "The description"
    }
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['id'].should == 1
    table.reload
    table.rows_counted.should == 1
    table.to_json[:total_rows].should == 1
  end

  scenario "Update the value from a ceil" do
    user = create_user
    table = create_table :user_id => user.id

    authenticate_api user

    table.insert_row!({:name => String.random(12)})

    row = table.to_json(:rows_per_page => 1, :page => 0)[:rows].first
    row[:description].should be_blank

    put_json "/api/json/tables/#{table.id}/rows/#{row[:cartodb_id]}", {:description => "Description 123"}
    response.status.should == 200
    table.reload
    row = table.to_json(:rows_per_page => 1, :page => 0)[:rows].first
    row[:description].should == "Description 123"

    put_json "/api/json/tables/#{table.id}/rows/#{row[:cartodb_id]}", {:cartodb_id => "666"}
    response.status.should == 200
    table.reload
    row = table.to_json(:rows_per_page => 1, :page => 0)[:rows].first
    row[:cartodb_id].should == 1
  end

  scenario "Update the value from a ceil with an invalid value" do
    user = create_user
    table = new_table
    table.force_schema = "age integer"
    table.user_id = user.id
    table.save

    authenticate_api user

    table.insert_row!({:age => rand(100)})

    put_json "/api/json/tables/#{table.id}/rows/1", {:age => "abc10"}
    response.status.should == 400
    json_response = JSON(response.body)
    json_response['errors'].should == ["PGError: ERROR:  invalid input syntax for integer: \"abc10\""]
  end

  scenario "Drop a table" do
    user = create_user
    table = create_table :user_id => user.id
    other = create_user
    table_other = create_table :user_id => other.id

    authenticate_api user

    delete_json "/api/json/tables/#{table.id}"
    response.status.should == 200
    Table[table.id].should be_nil
    response.location.should =~ /^\/dashboard$/

    delete_json "/api/json/tables/#{table_other.id}"
    response.status.should == 404

    Table[table_other.id].should_not be_nil
  end

  scenario "Create a new table without schema" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables"
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    post_json "/api/json/tables"
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i
  end

  scenario "Create a new table specifing a name and a schema" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {:name => "My new imported table", :schema => "bla bla blat"}
    response.status.should == 400

    post_json "/api/json/tables", {
      :name => "My new imported table",
      :schema => "code varchar, title varchar, did integer, date_prod timestamp, kind varchar"
    }

    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{response.location.match(/\/(\d+)$/)[1].to_i}/schema"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == [
      ["cartodb_id", "number"], ["code", "string"], ["title", "string"], ["did", "number"],
      ["date_prod", "date"], ["kind", "string"], ["created_at", "date"], ["updated_at", "date"]
    ]
  end

  scenario "Import a file when the schema is wrong" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :schema => "url varchar(255) not null, login varchar(255), country varchar(255), \"followers count\" integer",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/twitters.csv", "text/csv")
               }
    response.status.should == 400
  end

  scenario "Create a new table specifing an schema and a file from which import data" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :schema => "url varchar(255) not null, login varchar(255), country varchar(255), \"followers count\" integer, foo varchar(255)",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/twitters.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 7
    row0 = json_response['rows'][0].symbolize_keys
    row0[:url].should == "http://twitter.com/vzlaturistica/statuses/23424668752936961"
    row0[:login].should == "vzlaturistica "
    row0[:country].should == " Venezuela "
    row0[:followers_count].should == 211
  end

  scenario "Create a new table from importing file twitters.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/twitters.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 7
    row0 = json_response['rows'][0].symbolize_keys
    row0[:url].should == "http://twitter.com/vzlaturistica/statuses/23424668752936961"
    row0[:login].should == "vzlaturistica "
    row0[:country].should == " Venezuela "
    row0[:followers_count].should == 211
  end

  scenario "Create a new table from importing file import_csv_1.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_1.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 100
    row = json_response['rows'][6].symbolize_keys
    row[:id].should == 6
    row[:name_of_species].should == "Laetmonice producta 6"
    row[:kingdom].should == "Animalia"
    row[:family].should == "Aphroditidae"
    row[:lat].should == 0.2
    row[:lon].should == 2.8
    row[:views].should == 540
  end

  scenario "Create a new table from importing file import_csv_1.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_1.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 100
    row = json_response['rows'][6].symbolize_keys
    row[:id].should == 6
    row[:name_of_species].should == "Laetmonice producta 6"
    row[:kingdom].should == "Animalia"
    row[:family].should == "Aphroditidae"
    row[:lat].should == 0.2
    row[:lon].should == 2.8
    row[:views].should == 540
  end

  scenario "Create a new table from importing file import_csv_2.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_2.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 100
    row = json_response['rows'][6].symbolize_keys
    row[:id].should == 6
    row[:name_of_specie].should == "Laetmonice producta 6"
    row[:kingdom].should == "Animalia"
    row[:family].should == "Aphroditidae"
    row[:lat].should == 0.2
    row[:lon].should == 2.8
    row[:views].should == 540
  end

  scenario "Create a new table from importing file import_csv_3.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_3.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 100
    row = json_response['rows'][6].symbolize_keys
    row[:id].should == 6
    row[:name_of_specie].should == "Laetmonice producta 6"
    row[:kingdom].should == "Animalia"
    row[:family].should == "Aphroditidae"
    row[:lat].should == 0.2
    row[:lon].should == 2.8
    row[:views].should == 540
  end

  scenario "Create a new table from importing file import_csv_4.csv" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "Twitts",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_4.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    json_response['id'].should == response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/#{json_response['id']}?rows_per_page=10"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 100
    row = json_response['rows'][6].symbolize_keys
    row[:id].should == 6
    row[:name_of_specie].should == "Laetmonice producta 6"
    row[:kingdom].should == "Animalia"
    row[:family].should == "Aphroditidae"
    row[:lat].should == 0.2
    row[:lon].should == 2.8
    row[:views].should == 540
  end

  scenario "Run a query against a table" do
    user = create_user

    authenticate_api user

    post_json "/api/json/tables", {
                    :name => "antantaric species",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_1.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    table_id = response.location.match(/\/(\d+)$/)[1].to_i

    get_json "/api/json/tables/query", {
      :query => "select * from antantaric_species where family='Polynoidae' limit 10"
    }
    response.status.should == 200
    json_response = JSON(response.body)
    json_response['total_rows'].should == 2
    json_response['rows'][0].symbolize_keys[:name_of_species].should == "Barrukia cristata"
    json_response['rows'][1].symbolize_keys[:name_of_species].should == "Eulagisca gigantea"
  end

  scenario "Run a query against a table using JSONP and key authorization" do
    Capybara.current_driver = :selenium

    user = create_user
    api_key = user.create_key "example.org"
    api_key2 = user.create_key "127.0.0.1"

    post_json "/api/json/tables", {
                    :api_key => api_key,
                    :name => "antantaric species",
                    :file => Rack::Test::UploadedFile.new("#{Rails.root}/db/fake_data/import_csv_1.csv", "text/csv")
               }
    response.status.should == 200
    response.location.should =~ /tables\/(\d+)$/
    json_response = JSON(response.body)
    table_id = response.location.match(/\/(\d+)$/)[1].to_i

    FileUtils.cp("#{Rails.root}/spec/support/test_jsonp.html", "#{Rails.root}/public/")

    visit "/test_jsonp.html?api_key=#{api_key2}"

    page.find("div#results").text.should == "Barrukia cristata"

    FileUtils.rm("#{Rails.root}/public/test_jsonp.html")
  end

  scenario "Get the available types for columns" do
    user = create_user

    authenticate_api user

    get_json "/api/json/column_types"
    response.status.should == 200
    json_response = JSON(response.body)
    json_response.should == %W{ Number String Date Boolean }
  end

  scenario "Set the geometry from a table to latitude and longitude" do
    user = create_user
    table = new_table
    table.user_id = user.id
    table.save

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/set_geometry_columns", {:lat_column => :latitude, :lon_column => :longitude}
    response.status.should == 200

    table.reload
    table.lat_column.should == :latitude
    table.lon_column.should == :longitude

    put_json "/api/json/tables/#{table.id}/set_geometry_columns", {:lat_column => nil, :lon_column => nil}
    response.status.should == 200

    table.reload
    table.lat_column.should be_nil
    table.lon_column.should be_nil
  end

  scenario "Set the geometry from a table to an address column" do
    user = create_user
    table = new_table
    table.user_id = user.id
    table.save

    authenticate_api user

    put_json "/api/json/tables/#{table.id}/set_geometry_columns", {:address_column => :address}
    response.status.should == 200

    table.reload
    table.address_column.should == :address
  end

end
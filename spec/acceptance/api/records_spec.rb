# coding: UTF-8

require File.expand_path(File.dirname(__FILE__) + '/../acceptance_helper')

feature "API 1.0 records management" do

  background do
    Capybara.current_driver = :rack_test
    @user = create_user
    login_as @user
  end

  scenario "Get the records from a table" do
    table = create_table :user_id => @user.id

    @user.in_database do |user_database|
      10.times do
        user_database.run("INSERT INTO \"#{table.name}\" (Name,Latitude,Longitude,Description) VALUES ('#{String.random(10)}',#{Float.random_latitude}, #{Float.random_longitude},'#{String.random(100)}')")
      end
    end

    content = @user.run_query("select * from \"#{table.name}\"")[:rows]

    get_json "#{api_table_records_url(table.name)}?rows_per_page=2"
    parse_json(response) do |r|
      r.status.should be_success
      r.body[:id].should == table.id
      r.body[:name].should == table.name
      r.body[:total_rows].should == 10
      r.body[:rows][0].symbolize_keys.slice(:cartodb_id, :name, :location, :description).
        should == content[0].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][1].symbolize_keys.slice(:cartodb_id, :name, :location, :description).
        should == content[1].slice(:cartodb_id, :name, :location, :description)
    end

    get_json "#{api_table_records_url(table.name)}?rows_per_page=2&page=1"
    parse_json(response) do |r|
      r.status.should be_success
      r.body[:rows][0].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[2].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][1].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[3].slice(:cartodb_id, :name, :location, :description)
    end

    get_json "#{api_table_records_url(table.name)}?rows_per_page=2&page=1..3"
    parse_json(response) do |r|
      r.status.should be_success
      r.body[:rows][0].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[2].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][1].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[3].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][2].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[4].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][3].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[5].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][4].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[6].slice(:cartodb_id, :name, :location, :description)
      r.body[:rows][5].symbolize_keys.slice(:cartodb_id, :name, :location, :description).should == content[7].slice(:cartodb_id, :name, :location, :description)
    end
  end

end

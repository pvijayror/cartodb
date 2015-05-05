# encoding: utf-8

shared_examples_for "tables controllers" do

  # TODO: Keep migrating spec/requests/api/tables_spec.rb

  describe '#show legacy tests' do

    before(:all) do
      CartoDB::Varnish.any_instance.stubs(:send_command).returns(true)
      @user = create_user(:username => 'test', :email => "client@example.com", :password => "clientex", :private_tables_enabled => true)
      host! 'test.localhost.lan'
    end

    before(:each) do
      delete_user_data @user
    end


    let(:params) { { :api_key => @user.api_key } }



    it 'returns table attributes' do
      table = create_table(
        user_id:      @user.id,
        name:         'My table #1',
        privacy:      UserTable::PRIVACY_PRIVATE,
        tags:         "tag 1, tag 2,tag 3, tag 3",
        description:  'Testing is awesome'
      )

      get_json api_v1_tables_show_url(params.merge(id: table.id)) do |response|
        response.status.should == 200
        response.body.fetch(:name).should == 'my_table_1'
        response.body.fetch(:description).should == 'Testing is awesome'
      end
    end

    it "check imported table metadata" do
      data_import = DataImport.create(
                                      user_id: @user.id,
                                      data_source: '/../spec/support/data/TM_WORLD_BORDERS_SIMPL-0.3.zip'
                                      ).run_import!

      get_json api_v1_tables_show_url(params.merge(id: data_import.table_id)) do |response|
        response.status.should be_success
        response.body.should include(
                                     name: "tm_world_borders_simpl_0_3",
                                     privacy: "PRIVATE",
                                     schema: [["cartodb_id", "number"], ["the_geom", "geometry", "geometry", "multipolygon"], ["area", "number"], ["fips", "string"], ["iso2", "string"], ["iso3", "string"], ["lat", "number"], ["lon", "number"], ["name", "string"], ["pop2005", "number"], ["region", "number"], ["subregion", "number"], ["un", "number"], ["created_at", "date"], ["updated_at", "date"]],
                                     rows_counted: 246,
                                     description: nil,
                                     geometry_types: ["ST_MultiPolygon"]
                                     )
      end
    end

    it "creates a new table without schema" do
      post_json api_v1_tables_create_url(params) do |response|
        response.status.should be_success
        response.body[:id].should == response.headers['Location'].match(/\/([a-f\-\d]+)$/)[1]
        response.body[:name].should match(/^untitled/)
        response.body[:schema].should =~ default_schema
      end
    end

    it "creates a new table without schema when a table of the same name exists on the database" do
      create_table(name: 'untitled_table', user_id: @user.id)
      post_json api_v1_tables_create_url(params) do |response|
        response.status.should be_success
        response.body[:name].should match(/^untitled_table/)
        response.body[:name].should_not == 'untitled_table'
        response.body[:schema].should =~ default_schema
      end
      @user.tables.count.should == 2
    end

    it "creates a new table specifing a name, description and a schema" do
      post_json api_v1_tables_create_url(params.merge(
        name: "My new blank table", 
        schema: "code varchar, title varchar, did integer, date_prod timestamp, kind varchar", 
        description: "Testing is awesome")) do |response|
        response.status.should be_success
        response.body[:name].should == "my_new_blank_table"
        response.body[:description].should == "Testing is awesome"
        response.body[:schema].should =~ [
           ["cartodb_id", "number"], ["code", "string"], ["title", "string"], ["did", "number"],
           ["the_geom", "geometry", "geometry", "geometry"],
           ["date_prod", "date"], ["kind", "string"], ["created_at", "date"], ["updated_at", "date"]
         ]
      end
    end

    it "updates the metadata of an existing table" do
      table = create_table :user_id => @user.id, :name => 'My table #1',  :tags => "tag 1, tag 2,tag 3, tag 3", :description => ""

       put_json api_v1_tables_update_url(params.merge(
          id: table.id,
          name: table.name,
          tags: "bars,disco", 
          privacy: UserTable::PRIVACY_PRIVATE,
          description: "Testing is awesome")) do |response|
        response.status.should be_success
        response.body[:id].should == table.id
        response.body[:name].should == table.name
        response.body[:privacy] == "PRIVATE"
        response.body[:description].should == "Testing is awesome"
        (response.body[:schema] - default_schema).should be_empty
      end
    end

    it "updates with bad values the metadata of an existing table" do
      table1 = create_table :user_id => @user.id, :name => 'My table #1', :tags => "tag 1, tag 2,tag 3, tag 3"
      put_json api_v1_tables_update_url(params.merge(id: table1.id, privacy: "bad privacy value")) do |response|
        response.status.should == 400
        table1.reload.privacy.should == ::UserTable::PRIVACY_PRIVATE
      end

      put_json api_v1_tables_update_url(params.merge(id: table1.id, name: "")) do |response|
        response.status.should == 400
      end

    end

    it "updates a table and sets the lat and long columns" do
      table = Table.new :privacy => UserTable::PRIVACY_PRIVATE, :name => 'Madrid Bars',
                        :tags => 'movies, personal'
      table.user_id = @user.id
      table.force_schema = "name varchar, address varchar, latitude float, longitude float"
      table.save
      pk = table.insert_row!({:name => "Hawai", :address => "Calle de Pérez Galdós 9, Madrid, Spain", :latitude => 40.423012, :longitude => -3.699732})
      table.insert_row!({:name => "El Estocolmo", :address => "Calle de la Palma 72, Madrid, Spain", :latitude => 40.426949, :longitude => -3.708969})
      table.insert_row!({:name => "El Rey del Tallarín", :address => "Plaza Conde de Toreno 2, Madrid, Spain", :latitude => 40.424654, :longitude => -3.709570})
      table.insert_row!({:name => "El Lacón", :address => "Manuel Fernández y González 8, Madrid, Spain", :latitude => 40.415113, :longitude => -3.699871})
      table.insert_row!({:name => "El Pico", :address => "Calle Divino Pastor 12, Madrid, Spain", :latitude => 40.428198, :longitude => -3.703991})

      put_json api_v1_tables_update_url(params.merge(
        :id => table.id,
        :latitude_column => "latitude",
        :longitude_column => "longitude"
      )) do |response|
        response.status.should be_success
        response.body[:schema].should include(["the_geom", "geometry", "geometry", "point"])
      end
    end

  end

end

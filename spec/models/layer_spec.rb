require 'spec_helper'
require 'models/layer_shared_examples'

describe Layer do
  it_behaves_like 'Layer model' do
    let(:layer_class) { Layer }
    def create_map(options = {})
      Map.create(options)
    end

    def add_layer_to_entity(entity, layer)
      entity.add_layer(layer)
    end

    before(:all) do
      @quota_in_bytes = 500.megabytes
      @table_quota = 500

      @user = FactoryGirl.create(:valid_user, private_tables_enabled: true)

      @table = Table.new
      @table.user_id = @user.id
      @table.save
    end

    before(:each) do
      bypass_named_maps
    end

    after(:all) do
      @user.destroy
    end

    describe '#copy' do
      it 'returns a copy of the layer' do
        layer       = layer_class.create(kind: 'carto', options: { style: 'bogus' })
        layer_copy  = layer.copy

        layer_copy.kind.should    == layer.kind
        layer_copy.options.should == layer.options
        layer_copy.id.should be_nil
      end
    end
  end

  describe '#affected_table_names' do
    include UniqueNamesHelper

    before(:all) do
      helper = TestUserFactory.new
      @organization = FactoryGirl.create(:organization, quota_in_bytes: 1000000000000)
      @owner = helper.create_owner(@organization)
      @hyphen_user = helper.create_test_user(unique_name('user-'), @organization)
      @owner_table = FactoryGirl.create(:user_table, user: @owner, name: unique_name('table'))
      @subuser_table = FactoryGirl.create(:user_table, user: @hyphen_user, name: unique_name('table'))
      @hyphen_table = FactoryGirl.create(:user_table, user: @hyphen_user, name: unique_name('table-'))
    end

    before(:each) do
      @hyphen_user_layer = layer_class.new
      @hyphen_user_layer.stubs(:user).returns(@hyphen_user)

      @owner_layer = layer_class.new
      @owner_layer.stubs(:user).returns(@owner)
    end

    it 'returns normal tables' do
      @owner_layer.send(:affected_table_names, "SELECT * FROM #{@owner_table.name}")
                  .should eq ["#{@owner.username}.#{@owner_table.name}"]
    end

    it 'returns tables from users with hyphens' do
      @hyphen_user_layer.send(:affected_table_names, "SELECT * FROM #{@subuser_table.name}")
                        .should eq ["\"#{@hyphen_user.username}\".#{@subuser_table.name}"]
    end

    it 'returns table with hyphens in the name' do
      @hyphen_user_layer.send(:affected_table_names, "SELECT * FROM \"#{@hyphen_table.name}\"")
                        .should eq ["\"#{@hyphen_user.username}\".\"#{@hyphen_table.name}\""]
    end

    it 'returns multiple tables' do
      @hyphen_user_layer.send(:affected_table_names, "SELECT * FROM \"#{@hyphen_table.name}\", #{@subuser_table.name}")
                        .should =~ ["\"#{@hyphen_user.username}\".\"#{@hyphen_table.name}\"",
                                    "\"#{@hyphen_user.username}\".#{@subuser_table.name}"]
    end
  end
end

# encoding: utf-8

require 'spec_helper_min'
require 'factories/carto_visualizations'

describe Carto::Snapshot do
  include Carto::Factories::Visualizations

  before(:all) do
    @user = FactoryGirl.create(:carto_user)
    @_m, @_t, @_tv, @visualization = create_full_visualization(@user)
  end

  after(:all) do
    destroy_full_visualization(@_m, @_t, @_tv, @visualization)
    @user.destroy
  end

  describe('#validation') do
    it 'rejects nil visualization' do
      snapshot = Carto::Snapshot.new(user_id: @user.id)
      snapshot.save.should be_false
      snapshot.errors[:visualization].should_not be_empty
    end

    it 'rejects nil user' do
      snapshot = Carto::Snapshot.new(visualization_id: @visualization.id)
      snapshot.save.should be_false
      snapshot.errors[:user].should_not be_empty
    end
  end
end

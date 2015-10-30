require_relative '../../../spec_helper'

describe CartoDB::Stats::Platform do

  describe '#pay_users' do

    it 'returns only paid users' do
      pay_users = CartoDB::Stats::Platform.new.pay_users

      free = FactoryGirl.create(:user, account_type: Carto::AccountType::FREE)
      paid = FactoryGirl.create(:user, account_type: Carto::AccountType::MAGELLAN)

      CartoDB::Stats::Platform.new.pay_users.should == (pay_users + 1)
    end

  end

end

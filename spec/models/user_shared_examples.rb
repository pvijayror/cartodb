# encoding: UTF-8

require 'mock_redis'
require 'active_support/time'
require_relative '../spec_helper'
require_relative '../../services/table-geocoder/lib/geocoder_usage_metrics'

# Tests should define the following method:
# - `get_twitter_imports_count_by_user_id`
# - `get_user_by_id`
shared_examples_for "user models" do
  describe '#get_twitter_imports_count' do
    include_context 'users helper'

    it "should count tweet imports" do
      FactoryGirl.create(:search_tweet, user: @user1, retrieved_items: 5)

      FactoryGirl.create(:search_tweet, user: @user2, retrieved_items: 6)

      get_twitter_imports_count_by_user_id(@user1.id).should == 5
    end
  end

  describe 'twitter_datasource_enabled for org users' do
    include_context 'organization with users helper'

    it 'is enabled if organization has it enabled, no matter whether user has it or not,
        and enabled if he has it enabled, no matter whether org has it or not' do
      @organization.twitter_datasource_enabled = false
      @organization.save.reload

      @org_user_1.twitter_datasource_enabled = false
      @org_user_1.save.reload
      get_user_by_id(@org_user_1.id).twitter_datasource_enabled.should == false

      @organization.twitter_datasource_enabled = true
      @organization.save.reload

      @org_user_1.save.reload
      get_user_by_id(@org_user_1.id).twitter_datasource_enabled.should == true

      @org_user_1.twitter_datasource_enabled = true
      @org_user_1.save.reload
      get_user_by_id(@org_user_1.id).twitter_datasource_enabled.should == true

      @organization.twitter_datasource_enabled = false
      @organization.save.reload

      @org_user_1.twitter_datasource_enabled = true
      @org_user_1.save.reload
      get_user_by_id(@org_user_1.id).twitter_datasource_enabled.should == true
    end
  end

  describe 'User#remaining_geocoding_quota' do
    include_context 'users helper'
    include_context 'organization with users helper'

    it 'calculates the remaining quota for a non-org user correctly' do
      @user1.geocoding_quota = 500
      @user1.save
      Geocoding.new(kind: 'high-resolution',
                    user: @user1,
                    formatter: '{dummy}',
                    processed_rows: 100).save

      get_user_by_id(@user1.id).remaining_geocoding_quota.should == 400
    end

    it 'takes into account geocodings performed by the org users #4033' do
      @organization.geocoding_quota = 500
      @organization.save.reload

      Geocoding.new(kind: 'high-resolution',
                    user: @org_user_1,
                    formatter: '{dummy}',
                    processed_rows: 100).save

      Geocoding.new(kind: 'high-resolution',
                    user: @org_user_2,
                    formatter: '{dummy}',
                    processed_rows: 100).save

      get_user_by_id(@org_user_1.id).remaining_geocoding_quota.should == 300
      get_user_by_id(@org_user_2.id).remaining_geocoding_quota.should == 300
    end
  end

  describe 'User#used_geocoding_quota' do
    include_context 'users helper'
    include_context 'organization with users helper'

    before(:each) do
      @mock_redis = MockRedis.new
      @user1.geocoding_quota = 500
      @user1.period_end_date = (DateTime.current + 1) << 1
      @user1.save.reload
      @organization.geocoding_quota = 500
      @organization.save.reload
      @organization.owner.period_end_date = (DateTime.current + 1) << 1
      @organization.owner.save.reload
    end

    it 'calculates the used geocoder quota in the current billing cycle' do
      usage_metrics = CartoDB::GeocoderUsageMetrics.new(@mock_redis, @user1.username, nil)
      Carto::TableGeocoderFactory.stubs(:get_geocoder_metrics_instance).returns(usage_metrics)
      Geocoding.new(kind: 'high-resolution',
                    user: @user1,
                    formatter: '{dummy}',
                    processed_rows: 0,
                    cache_hits: 100,
                    created_at: (DateTime.current - 1)).save
      Geocoding.new(kind: 'high-resolution',
                    user: @user1,
                    formatter: '{dummy}',
                    processed_rows: 100,
                    cache_hits: 0,
                    created_at: (DateTime.current - 2)).save
      Geocoding.new(kind: 'high-resolution',
                    user: @user1,
                    formatter: '{dummy}',
                    processed_rows: 10,
                    cache_hits: 0,
                    created_at: DateTime.current).save
      usage_metrics.incr(:geocoder_here, :success_responses, 10, DateTime.current)
      usage_metrics.incr(:geocoder_here, :success_responses, 100, (DateTime.current - 2))
      usage_metrics.incr(:geocoder_cache, :success_responses, 100, (DateTime.current - 1))

      get_user_by_id(@user1.id).get_new_system_geocoding_calls.should == 210
      get_user_by_id(@user1.id).get_geocoding_calls.should == 210
    end

    it 'calculates the used geocoding quota for an organization' do
      usage_metrics_1 = CartoDB::GeocoderUsageMetrics.new(@mock_redis, @org_user_1.username, @organization.name)
      usage_metrics_2 = CartoDB::GeocoderUsageMetrics.new(@mock_redis, @org_user_2.username, @organization.name)
      # We are going to get the organization data show we could use both usage_metrics objects
      Carto::TableGeocoderFactory.stubs(:get_geocoder_metrics_instance).returns(usage_metrics_1)
      Geocoding.new(kind: 'high-resolution',
                    user: @org_user_1,
                    formatter: '{dummy}',
                    processed_rows: 100,
                    created_at: DateTime.current).save

      Geocoding.new(kind: 'high-resolution',
                    user: @org_user_2,
                    formatter: '{dummy}',
                    processed_rows: 120,
                    cache_hits: 10,
                    created_at: DateTime.current - 1).save

      usage_metrics_1.incr(:geocoder_here, :success_responses, 100, DateTime.current)
      usage_metrics_2.incr(:geocoder_here, :success_responses, 120, DateTime.current - 1)
      usage_metrics_2.incr(:geocoder_cache, :success_responses, 10, DateTime.current - 1)

      @organization.get_new_system_geocoding_calls.should == 230
    end

    it 'calculates the used geocoder quota in the current billing cycle including empty requests' do
      usage_metrics = CartoDB::GeocoderUsageMetrics.new(@mock_redis, @user1.username, nil)
      Carto::TableGeocoderFactory.stubs(:get_geocoder_metrics_instance).returns(usage_metrics)
      usage_metrics.incr(:geocoder_here, :success_responses, 10, DateTime.current)
      usage_metrics.incr(:geocoder_here, :success_responses, 100, (DateTime.current - 2))
      usage_metrics.incr(:geocoder_here, :empty_responses, 10, (DateTime.current - 2))
      usage_metrics.incr(:geocoder_cache, :success_responses, 100, (DateTime.current - 1))

      get_user_by_id(@user1.id).get_new_system_geocoding_calls.should == 220
    end
  end
end

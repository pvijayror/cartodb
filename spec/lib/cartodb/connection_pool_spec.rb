require_relative '../../spec_helper'

describe CartoDB::ConnectionPool do
  before(:all) do
    @max_pool_size = ConnectionPool::MAX_POOL_SIZE
    ConnectionPool::MAX_POOL_SIZE = 2
  end

  after(:all) do
    ConnectionPool::MAX_POOL_SIZE = @max_pool_size
  end

  before(:each) do
    # Need to close the connections because there might be more than the new maximum already in the pool
    $pool.close_connections!
  end

  after(:each) do
    @new_user.destroy unless @new_user.nil?
  end

  def database_object_count
    GC.start
    ObjectSpace.each_object(Sequel::Postgres::Database).count
  end

  def user_object_count
    GC.start
    ObjectSpace.each_object(User).count
  end

  def pool_contains?(connection)
    $pool.all.values.map { |a| a[:connection] }.include?(connection)
  end

  describe '#eviction_policy' do
    it 'evicts older connection (LRU)' do
      @new_user = create_user
      conn_1 = $user_1.in_database
      conn_2 = $user_2.in_database
      conn_3 = @new_user.in_database
      pool_contains?(conn_1).should be_false
      pool_contains?(conn_2).should be_true
      pool_contains?(conn_3).should be_true

      conn_1 = $user_1.in_database
      pool_contains?(conn_1).should be_true
      pool_contains?(conn_2).should be_false
      pool_contains?(conn_3).should be_true
    end
  end

  describe '#user_databases' do
    it 'does not leak user databases' do
      # The maximum number of connections allowed in memory before the test is considered to be leaking (failure).
      # Although the pool will only keep 2 connections open (MAX_POOL_SIZE set at the beginning of the test),
      # there are some other connections that are not tracked by the pool (tracked by Rails instead).
      # Typical # of connections is 0 for correct tests and 45 for leaky tests but vary depending on execution order.
      MAX_ALLOWABLE_CONNECTIONS = 10

      initial_user_count = user_object_count
      initial_db_count = database_object_count
      @new_user = create_user

      # Create some connections to user database and check that they are not leaked
      (0..4).each do |_|
        [$user_1, $user_2, @new_user].each do |user|
          user.in_database.test_connection.should be_true
        end
      end
      database_object_count.should < (initial_db_count + MAX_ALLOWABLE_CONNECTIONS)

      # Destroy new user and ensure it does not leaks (as soon as his db connection is evicted)
      @new_user.destroy
      @new_user = nil

      (0..4).each do |_|
        [$user_1, $user_2].each do |user|
          user.in_database.test_connection.should be_true
        end
      end
      database_object_count.should < (initial_db_count + MAX_ALLOWABLE_CONNECTIONS)

      pending 'Inconsistent, depending on ruby version'
      user_object_count.should eq initial_user_count
    end
  end
end

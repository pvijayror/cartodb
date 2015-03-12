# encoding: utf-8
require_relative '../../../app/models/visualization/table_blender'
require 'mocha'

include CartoDB::Visualization

RSpec.configure do |config|
  config.mock_with :mocha
end

# TODO this file cannot be executed in isolation
describe TableBlender do
  describe '#blend' do
    it 'returns a map with layers from the passed tables' do
      pending
    end
  end #blend

  # TODO test too coupled with implementation outside blender
  # refactor once Privacy is extracted
  describe '#blended_privacy' do
    it 'returns private if any of all tables is private' do
      user   = Object.new
      tables = [fake_public_table, fake_private_table]
      TableBlender.new(user, tables).blended_privacy.should == 'private'

      tables = [fake_private_table, fake_public_table]
      TableBlender.new(user, tables).blended_privacy.should == 'private'
    end

    it 'returns public if all tables are public' do
      user   = Object.new
      tables = [fake_public_table, fake_public_table]

      TableBlender.new(user, tables).blended_privacy.should == 'public'
    end
  end #blended_privacy


  def fake_public_table
    storage = mock
    storage.stubs(:private?).returns(false)
    storage.stubs(:public_with_link_only?).returns(false)
    table = mock
    table.stubs(:storage).returns(storage)
    table
  end #fake_public_table

  def fake_private_table
    storage = mock
    storage.stubs(:private?).returns(true)
    storage.stubs(:public_with_link_only?).returns(false)
    table = mock
    table.stubs(:storage).returns(storage)
    table
  end #fake_private_table
end # TableBlender


# coding: UTF-8

require_relative '../spec_helper'

include CartoDB

describe CartoDB::SharedEntity do

  before(:all) do
    CartoDB::Varnish.any_instance.stubs(:send_command).returns(true)
    @user = create_user(:quota_in_bytes => 524288000, :table_quota => 500)
  end

  describe '#create' do
    it 'tests basic creation and validation' do
      user_id   = UUIDTools::UUID.timestamp_create.to_s
      entity_id = UUIDTools::UUID.timestamp_create.to_s

      SharedEntity.all.count.should eq 0

      shared_entity = SharedEntity.new(
          user_id:    user_id,
          entity_id:  entity_id,
          type:       SharedEntity::TYPE_VISUALIZATION
      )
      shared_entity.valid?.should eq true
      shared_entity.errors.should eq Hash.new
      shared_entity.save

      SharedEntity.all.count.should eq 1

      shared_entity2 = SharedEntity.new(
          user_id:    user_id,
          entity_id:  entity_id,
          type:       SharedEntity::TYPE_VISUALIZATION
      )
      shared_entity2.valid?.should eq false
      shared_entity2.errors.should eq({[:user_id, :entity_id]=>['is already taken']})

      shared_entity.destroy

      SharedEntity.all.count.should eq 0

      shared_entity = SharedEntity.new(
          entity_id:  entity_id,
          type:       SharedEntity::TYPE_VISUALIZATION
      )
      shared_entity.valid?.should eq false

      shared_entity = SharedEntity.new(
          user_id:    user_id,
          type:       SharedEntity::TYPE_VISUALIZATION
      )
      shared_entity.valid?.should eq false

      shared_entity = SharedEntity.new(
          user_id:    user_id,
          entity_id:  entity_id,
      )
      shared_entity.valid?.should eq false

      shared_entity = SharedEntity.new(
      )
      shared_entity.valid?.should eq false

      shared_entity = SharedEntity.new(
          user_id:    user_id,
          entity_id:  entity_id,
          type:       'whatever'
      )
      shared_entity.valid?.should eq false
    end

  end

end

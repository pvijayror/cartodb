require 'active_record'

module Carto
  class Organization < ActiveRecord::Base

    has_many :users, inverse_of: :organization, order: :username
    belongs_to :owner, class_name: Carto::User

    def get_geocoding_calls(options = {})
      users.map{ |u| 
          u.get_geocoding_calls(options) 
        }.sum
    end

    def twitter_imports_count(options = {})
      users.map{ |u|
        u.twitter_imports_count(options) 
      }.sum
    end

    def is_owner_user?(user)
      self.owner_id == user.id
    end

  end

end

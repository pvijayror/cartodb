# encoding: utf-8

require_relative './carto_json_serializer'

module Carto
  class UserNotification < ActiveRecord::Base
    belongs_to :user
    serialize :notifications, ::Carto::CartoJsonSerializer

    VALID_CATEGORIES = [:builder].freeze

    def notifications_for(category)
      raise "Invalid notification category #{category}" unless VALID_CATEGORIES.include?(category)

      notifications[category] = {} unless notifications.include?(category)
      notifications[category]
    end
  end
end

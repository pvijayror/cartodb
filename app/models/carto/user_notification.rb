# encoding: utf-8

require_relative './carto_json_serializer'

module Carto
  class UserNotification < ActiveRecord::Base
    belongs_to :user
    serialize :notifications, ::Carto::CartoJsonSerializer

    validates :user, presence: true
    validate  :only_valid_categories

    VALID_CATEGORIES = %w(builder).freeze

    private

    def only_valid_categories
      !notifications.keys.any? do |category|
        errors.add(:notifications, "Invalid category: #{category}") unless VALID_CATEGORIES.include?(category)
      end
    end
  end
end

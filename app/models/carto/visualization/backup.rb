# encoding: UTF-8

require 'active_record'

module Carto
  module Visualization
    class Backup < ActiveRecord::Base

      # @param String username
      # @param Uuid visualization
      # @param String export_vizjson
      # @param DateTime created_at (Self-generated)

      validates :username, :visualization, :export_vizjson, presence: true

    end
  end
end

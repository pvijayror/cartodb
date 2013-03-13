# encoding: utf-8 require 'set'
require_relative '../visualization'
require_relative './member'
require_relative '../../../services/data-repository/structures/collection'

module CartoDB
  module Visualization
    class Collection
      def initialize(attributes={}, member_class=Member, repository=nil)
        repository ||= Visualization.default_repository
        @collection = DataRepository::Collection
                       .new(attributes, member_class, repository)
      end #initialize

      DataRepository::Collection::INTERFACE.each do |method_name|
        define_method(method_name) do |*arguments, &block|
          result = collection.send(method_name, *arguments, &block)
          return self if result.is_a?(DataRepository::Collection)
          result
        end
      end

      private

      attr_reader :collection
    end # Collection
  end # Visualization
end # CartoDB


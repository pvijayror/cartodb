# encoding: UTF-8

# NOTE: Implement further methods from ActiveRecord::Relation here as needed
module Carto
  class OffdatabaseQueryAdapter

    # @param query ActiveRecord::Relation
    # @param order_by_asc_or_desc_by_attribute Hash { key: value, key: value } where
    #   key = { String  => { submodel: String|nil, attribute: String }, ... }
    #   value = :asc | :desc
    def initialize(query, order_by_asc_or_desc_by_attribute)
      @query = query
      @order_by_asc_or_desc_by_attribute = order_by_asc_or_desc_by_attribute
      @offset = 0
      @limit = nil
    end

    def offset(offset)
      @offset = offset
      self
    end

    def limit(limit)
      @limit = limit
      self
    end

    def all
      results
    end

    def map
      results.map { |a|
        yield(a)
      }
    end

    def count
      results.count 
    end

    private

    def results
      @results ||= get_results
    end

    def get_results
      all = @query.all
      @order_by_asc_or_desc_by_attribute.each { |attribute, asc_or_desc|
        # Cache attribute type
        unless all.count == 0
          @is_array = all.first.send(attribute).is_a?(Array)
        end
        all = all.sort { |x, y|
          x_attribute = x.send(attribute)
          x_attribute = x_attribute.count if @is_array
          y_attribute = y.send(attribute)
          y_attribute = y_attribute.count if @is_array
          asc_or_desc == :asc ? x_attribute <=> y_attribute : y_attribute <=> x_attribute
        }
      }
      all[@offset, last_index(all)]
    end

    def last_index(array)
      @limit.nil? ? array.count : (@offset + @limit)
    end

  end
end
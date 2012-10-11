class Map < Sequel::Model
  many_to_many :layers, :order => :order, :after_add => proc { |map, layer| 
    layer.set_default_order(map)
  }

  many_to_many :data_layers, :clone => :layers, :right_key => :layer_id, :conditions => { :kind => "carto" }
  many_to_many :base_layers, :clone => :layers, :right_key => :layer_id

  one_to_many :tables
  many_to_one :user

  plugin :association_dependencies, :layers => :nullify
  self.raise_on_save_failure = false

  PUBLIC_ATTRIBUTES = %W{ id user_id provider bounding_box_sw bounding_box_ne center zoom view_bounds_sw view_bounds_ne }

  DEFAULT_OPTIONS = {
    zoom:            3,
    bounding_box_sw: [0, 0],
    bounding_box_ne: [0, 0],
    provider:        'leaflet',
    center:          [0, 0]
  }

  # TODO remove this
  # We'll need to join maps and tables for this version
  # but they are meant to be totally independent entities
  # in the future
  attr_accessor :table_id
  def after_save
    Table.filter(user_id: self.user_id, id: self.table_id).
      update(map_id: self.id) unless self.table_id.blank?

    self.invalidate_varnish_cache
    self.affected_tables.map &:invalidate_varnish_cache
  end

  def public_values
    Hash[PUBLIC_ATTRIBUTES.map{ |a| [a, self.send(a)] }]
  end

  def validate
    super

    errors.add(:user_id, "can't be blank") if user_id.blank?
    #errors.add(:table_id, "can't be blank") if table_id.blank?
    #errors.add(:user_id, "does not exist") if user_id.present? && User[user_id].nil?
    #errors.add(:table_id, "table #{table_id} doesn't belong to user #{user_id}") if user_id.present? && !User[user_id].tables.select(:id).map(&:id).include?(table_id)
  end

  def invalidate_varnish_cache
    t = self.tables_dataset.select(:id, :user_id, :name).first
    CartoDB::Varnish.new.purge("obj.http.X-Cache-Channel ~ #{t.varnish_key}:vizjson")
  end

  ##
  # Returns an array of tables used on the map
  #
  def affected_tables
    queries = layers.map { |l| l.options['query'].blank? ? nil : l.options['query'] }.compact
    queries.map { |q|
      begin
        xml = user.in_database.fetch("EXPLAIN (FORMAT XML) #{q}").first[:"QUERY PLAN"]
        Nokogiri::XML(xml).search("Relation-Name").map(&:text).map { |table_name| Table.find_by_identifier(user.id, table_name) }
      rescue Sequel::DatabaseError
      end
    }.flatten.compact.uniq
  end
end

Sequel.migration do
  up do
    create_table :mapcaps do
      foreign_key :visualization_id, :visualization, type: 'uuid', null: false

      Uuid :id, primary_key: true, default: 'uuid_generate_v4()'.lit

      String :export_json, null: false, type: 'json'
      String :ids_json, null: false, type: 'json'

      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table :mapcaps
  end
end

# encoding: utf-8

require_relative '../../lib/datasources'

include CartoDB::Datasources

describe Url::GDrive do

  def get_config
    {
      'application_name' => '',
      'client_id' => '',
      'client_secret' => ''
    }
  end #get_config

  describe '#filters' do
    it 'test that filter options work correctly' do
      gdrive_provider = Url::GDrive.get_new(get_config)

      # No filter = all formats allowed
      filter = []
      Url::GDrive::FORMATS_TO_MIME_TYPES.each do |id, mime_types|
        mime_types.each do |mime_type|
          filter = filter.push(mime_type)
        end
      end
      gdrive_provider.filter.should eq filter

      # Filter to 'documents'
      filter = []
      format_ids = [ Url::GDrive::FORMAT_CSV, Url::GDrive::FORMAT_EXCEL ]
      Url::GDrive::FORMATS_TO_MIME_TYPES.each do |id, mime_types|
        if format_ids.include?(id)
          mime_types.each do |mime_type|
            filter = filter.push(mime_type)
          end
        end

      end
      gdrive_provider.filter = format_ids
      gdrive_provider.filter.should eq filter
    end
  end #run

end


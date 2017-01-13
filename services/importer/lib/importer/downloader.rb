# encoding: utf-8
require 'fileutils'
require 'open3'
require 'uri'
require_relative './exceptions'
require_relative './source_file'
require_relative './url_translator/osm'
require_relative './url_translator/osm2'
require_relative './url_translator/fusion_tables'
require_relative './url_translator/github'
require_relative './url_translator/google_maps'
require_relative './url_translator/google_docs'
require_relative './url_translator/kimono_labs'
require_relative './unp'
require_relative '../../../../lib/carto/http/client'
require_relative '../../../../lib/carto/url_validator'
require_relative '../helpers/quota_check_helpers.rb'

module CartoDB
  module Importer2
    class Downloader
      include CartoDB::Importer2::QuotaCheckHelpers
      extend Carto::UrlValidator

      # in seconds
      HTTP_CONNECT_TIMEOUT = 60
      DEFAULT_HTTP_REQUEST_TIMEOUT = 600
      URL_ESCAPED_CHARACTERS = 'áéíóúÁÉÍÓÚñÑçÇàèìòùÀÈÌÒÙ'.freeze

      CONTENT_DISPOSITION_RE  = %r{;\s*filename=(.*;|.*)}
      URL_RE                  = %r{://}

      CONTENT_TYPES_MAPPING = [
        {
          content_types: ['text/plain'],
          extensions: ['txt', 'kml', 'geojson']
        },
        {
          content_types: ['text/csv'],
          extensions: ['csv']
        },
        {
          content_types: ['application/vnd.ms-excel'],
          extensions: ['xls']
        },
        {
          content_types: ['application/vnd.ms-excel.sheet.binary.macroEnabled.12'],
          extensions: ['xlsb']
        },
        {
          content_types: ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
          extensions: ['xlsx']
        },
        {
          content_types: ['application/vnd.geo+json'],
          extensions: ['geojson']
        },
        {
          content_types: ['application/vnd.google-earth.kml+xml'],
          extensions: ['kml']
        },
        {
          content_types: ['application/vnd.google-earth.kmz'],
          extensions: ['kmz']
        },
        {
          content_types: ['application/gpx+xml'],
          extensions: ['gpx']
        },
        {
          content_types: ['application/zip'],
          extensions: ['zip', 'carto']
        },
        {
          content_types: ['application/x-gzip'],
          extensions: ['tgz', 'gz']
        },
        {
          content_types: ['application/json', 'text/javascript', 'application/javascript'],
          extensions: ['json']
        },
        {
          content_types: ['application/osm3s+xml'],
          extensions: ['osm']
        }
      ].freeze

      def self.supported_extensions
        @supported_extensions ||= CartoDB::Importer2::Unp::SUPPORTED_FORMATS
                                  .concat(CartoDB::Importer2::Unp::COMPRESSED_EXTENSIONS)
                                  .sort_by(&:length).reverse
      end

      def self.supported_extensions_match
        @supported_extensions_match ||= supported_extensions.map { |ext|
          ext = ext.gsub('.', '\\.')
          [/#{ext}$/i, /#{ext}(?=\.)/i, /#{ext}(?=\?)/i, /#{ext}(?=&)/i]
        }.flatten
      end

      def self.url_filename_regex
        @url_filename_regex ||= Regexp.new("[[:word:]-]+#{Regexp.union(supported_extensions_match)}+", Regexp::IGNORECASE)
      end

      def initialize(url, http_options = {}, options = {})
        @url = url
        raise UploadError if url.nil?

        @http_options = http_options
        @options = options
        @importer_config = options[:importer_config]
        @ogr2ogr_config = options[:ogr2ogr]
        @downloaded_bytes = 0
        @parsed_url = parse_url(url)
      end

      def provides_stream?
        false
      end

      def http_download?
        true
      end

      def run(available_quota_in_bytes=nil)
        set_local_source_file || set_downloaded_source_file(available_quota_in_bytes)
        self
      end

      def modified?
        previous_etag           = http_options.fetch(:etag, false)
        previous_last_modified  = http_options.fetch(:last_modified, false)
        etag                    = etag_from(headers)
        last_modified           = last_modified_from(headers)

        return true unless (previous_etag || previous_last_modified)
        return true if previous_etag && etag && previous_etag != etag
        return true if previous_last_modified && last_modified && previous_last_modified.to_i < last_modified.to_i
        false
      rescue
        false
      end

      def checksum
        etag_from(headers)
      end

      def multi_resource_import_supported?
        false
      end

      attr_reader :source_file, :datasource, :etag, :last_modified, :http_response_code
      attr_accessor :url

      private

      def parse_url(url)
        supported_translator = supported_translator(url)

        raw_url = if supported_translator
                    @custom_filename = supported_translator.try(:rename_destination, url)
                    supported_translator.translate(url)
                  else
                    url
                  end

        raw_url.try(:is_a?, String) ? URI.escape(raw_url.strip, URL_ESCAPED_CHARACTERS) : raw_url
      end

      attr_reader :http_options
      attr_writer :source_file

      def set_local_source_file
        unless valid_url?
          self.source_file = SourceFile.new(url)
          self
        end
      end

      def set_downloaded_source_file(available_quota_in_bytes = nil)
        if available_quota_in_bytes
          raise_if_over_storage_quota(requested_quota: content_length_from_headers(headers),
                                      available_quota: available_quota_in_bytes.to_i,
                                      user_id: @options[:user_id])
        end

        @etag           = etag_from(headers)
        @last_modified  = last_modified_from(headers)
        return self unless modified?

        download_and_store

        self.source_file  = nil unless modified?
        self
      end

      def headers
        @headers ||= http_client.head(@parsed_url, typhoeus_options).headers
      end

      MAX_REDIRECTS = 5

      def typhoeus_options
        verify_ssl = http_options.fetch(:verify_ssl_cert, false)
        cookiejar = Tempfile.new('cookiejar_').path

        {
          cookiefile:       cookiejar,
          cookiejar:        cookiejar,
          followlocation:   true,
          ssl_verifypeer:   verify_ssl,
          ssl_verifyhost:   (verify_ssl ? 2 : 0),
          forbid_reuse:     true,
          connecttimeout:   HTTP_CONNECT_TIMEOUT,
          timeout:          http_options.fetch(:http_timeout, DEFAULT_HTTP_REQUEST_TIMEOUT),
          maxredirs:        MAX_REDIRECTS
        }
      end

      FILENAME_PREFIX = 'importer_'.freeze

      def download_and_store
        file = Tempfile.new(FILENAME_PREFIX, encoding: 'ascii-8bit')
        binded_request(@parsed_url, file).run

        file_path = if @filename
                      new_file_path = File.join(Pathname.new(file.path).dirname, @filename)
                      File.rename(file.path, new_file_path)

                      new_file_path
                    else
                      file.path
                    end

        self.source_file = SourceFile.new(file_path, @filename)
      ensure
        file.close
        file.unlink
      end

      MAX_DOWNLOAD_SIZE = 5_242_880

      def binded_request(url, file)
        request = Typhoeus::Request.new(url, typhoeus_options)

        request.on_headers do |response|
          raise_error_for_response(response) unless response.success?

          @http_response_code = response.code

          CartoDB::Importer2::Downloader.validate_url!(response.effective_url)
        end

        request.on_body do |chunk|
          if (@downloaded_bytes += chunk.bytesize) > MAX_DOWNLOAD_SIZE
            raise PartialDownloadError.new("download file too big (> #{MAX_DOWNLOAD_SIZE} bytes)")
          else
            file.write(chunk)
          end
        end

        request.on_complete do |response|
          raise_error_for_response(response) unless response.success?

          headers = response.headers

          basename = @custom_filename ||
                     filename_from_headers(headers) ||
                     filename_from_url(url) ||
                     random_name

          @filename = name_with_extension(basename)
          @etag = etag_from(headers)
          @last_modified = last_modified_from(headers)
        end

        request
      end

      def raise_error_for_response(response)
        CartoDB::Logger.error(message: 'CartoDB::Importer2::Downloader: Error', response: response)

        if response.timed_out?
          raise DownloadTimeoutError.new("TIMEOUT ERROR: Body:#{response.body}")
        elsif response.headers['Error'] && response.headers['Error'] =~ /too many nodes/
          raise TooManyNodesError.new(response.headers['Error'])
        elsif response.return_code == :couldnt_resolve_host
          raise CouldntResolveDownloadError.new("Couldn't resolve #{@parsed_url}")
        elsif response.code == 401
          raise UnauthorizedDownloadError.new(response.body)
        elsif response.code == 404
          raise NotFoundDownloadError.new(response.body)
        elsif response.return_code == :partial_file
          raise PartialDownloadError.new("DOWNLOAD ERROR: A file transfer was shorter or larger than expected")
        else
          raise DownloadError.new("DOWNLOAD ERROR: Code:#{response.code} Body:#{response.body}")
        end
      end

      def extension_from_headers(content_type)
        downcased_content_type = content_type.downcase
        CONTENT_TYPES_MAPPING.each do |item|
          if item[:content_types].include?(downcased_content_type)
            return item[:extensions]
          end
        end
        return []
      end

      def name_with_extension(name)
        # No content-type
        return name unless content_type.present?

        content_type_extensions = extension_from_headers(content_type)
        # We don't have extension registered for that content-type
        return name if content_type_extensions.empty?

        file_extension = File.extname(name).split('.').last
        name_without_extension = File.basename(name, ".*")

        #If there is no extension or file extension match in the content type extensions, add content type
        #extension to the file name deleting the previous extension (if exist)
        if (file_extension.nil? || file_extension.empty?) || !content_type_extensions.include?(file_extension)
          return "#{name_without_extension}.#{content_type_extensions.first}"
        else
          return name
        end
      end

      def content_length_from_headers(headers)
        content_length = headers['Content-Length'] || -1
        content_length.to_i
      end

      def etag_from(headers)
        etag = headers['ETag']
        etag = etag.delete('"').delete("'") if etag
        etag
      end

      def last_modified_from(headers)
        last_modified = headers['Last-Modified']
        last_modified = last_modified.delete('"').delete("'") if last_modified
        if last_modified
          begin
            last_modified = DateTime.httpdate(last_modified)
          rescue
            last_modified = nil
          end
        end
        last_modified
      end

      def valid_url?
        url =~ URL_RE
      end

      URL_TRANSLATORS = [
        UrlTranslator::OSM2,
        UrlTranslator::OSM,
        UrlTranslator::FusionTables,
        UrlTranslator::GitHub,
        UrlTranslator::GoogleMaps,
        UrlTranslator::GoogleDocs,
        UrlTranslator::KimonoLabs
      ].freeze

      def supported_translator(url)
        URL_TRANSLATORS.map(&:new).find { |translator| translator.supported?(url) }
      end

      def content_type(headers)
        media_type = headers['Content-Type']
        return nil unless media_type
        media_type.split(';').first
      end

      def filename_from_headers(headers)
        disposition = headers['Content-Disposition']
        return false unless disposition
        filename = disposition.match(CONTENT_DISPOSITION_RE).to_a[1]
        return false unless filename

        parsed_filename = filename.delete("'").delete('"').split(';').first

        parsed_filename if parsed_filename.present?
      end

      def filename_from_url(url)
        url_name = self.class.url_filename_regex.match(url).to_s

        url_name unless url_name.empty?
      end

      def random_name
        random_generator = Random.new
        name = ''
        10.times {
          name << (random_generator.rand*10).to_i.to_s
        }
        name
      end

      def temporary_directory
        return @temporary_directory if @temporary_directory
        @temporary_directory = Unp.new(@importer_config).generate_temporary_directory.temporary_directory
      end

      def gdrive_deny_in?(headers)
        headers['X-Frame-Options'] == 'DENY'
      end

      def md5_command_for(name)
        %Q(md5sum #{name} | cut -d' ' -f1)
      end

      def http_client
        @http_client ||= Carto::Http::Client.get('downloader', log_requests: true)
      end
    end
  end
end

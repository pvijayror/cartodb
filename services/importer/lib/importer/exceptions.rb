# encoding: utf-8

module CartoDB
  module Importer2
    class NoPrjAvailableError       < StandardError; end
    class ShpNormalizationError     < StandardError; end
    class InvalidSridError          < StandardError; end
    class InvalidShpError           < StandardError; end
    class ShpToSqlConversionError   < StandardError; end
  end # Importer2
end # CartoDB


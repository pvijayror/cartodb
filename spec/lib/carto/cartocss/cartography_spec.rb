# encoding utf-8

require 'spec_helper_min'

module Carto
  module CartoCSS
    describe 'Default cartography' do
      describe '#default' do
        let(:production_default_cartography) do
          {
            "simple" => {
              "point" => {
                "fill" => {
                  "size" => {
                    "fixed" => 7
                  },
                  "color" => {
                    "fixed" => "#FFB927",
                    "opacity" => 0.9
                  }
                },
                "stroke" => {
                  "size" => {
                    "fixed" => 1
                  },
                  "color" => {
                    "fixed" => "#FFF",
                    "opacity" => 1
                  }
                }
              },

              "line" => {
                "fill" => {},
                "stroke" => {
                  "size" => {
                    "fixed" => 1.5
                  },
                  "color" => {
                    "fixed" => "#3EBCAE",
                    "opacity" => 1
                  }
                }
              },

              "polygon" => {
                "fill" => {
                  "color" => {
                    "fixed" => "#374C70",
                    "opacity" => 0.9
                  }
                },
                "stroke" => {
                  "size" => {
                    "fixed" => 1
                  },
                  "color" => {
                    "fixed" => "#FFF",
                    "opacity" => 0.5
                  }
                }
              }
            }
          }
        end

        it 'has stayed the same' do
          cartography = Carto::Definition.instance.load_from_file

          cartography.should eq production_default_cartography
        end
      end

      it 'handles inexesitent file paths' do
        cartography = Carto::CartoCSS::Cartography.instance

        expect { cartography.load_from_file(file_path: '/fake/path.json') }.to raise_error do
          'Carto::CartoCSS::Cartography: Couldn\'t read from file'
        end
      end
    end
  end
end

# coding: UTF-8

require 'spec_helper'

describe CartoDB::SqlParser do
  it "should parse distance() function" do
    CartoDB::SqlParser.parse("SELECT *, distance(r.the_geom, 40.33, 22.10) as distance from restaurants r where type_of_food = 'indian' limit 10").should == 
      "SELECT *, st_distance_sphere(r.the_geom,ST_SetSRID(ST_Point(40.33,22.10),4326)) as distance from restaurants r where type_of_food = 'indian' limit 10"
    CartoDB::SqlParser.parse("SELECT *,distance(the_geom, -3, 21.10) from restaurants").should == 
      "SELECT *,st_distance_sphere(the_geom,ST_SetSRID(ST_Point(-3,21.10),4326)) from restaurants"
  end
  
  it "should parse latitude() and longitude() functions" do
    CartoDB::SqlParser.parse("SELECT latitude(r.the_geom) as latitude, longitude(r.the_geom) as longitude from restaurants where type_of_food = 'indian' limit 10").should == 
      "SELECT ST_Y(r.the_geom) as latitude, ST_X(r.the_geom) as longitude from restaurants where type_of_food = 'indian' limit 10"
    CartoDB::SqlParser.parse("SELECT latitude(the_geom) as latitude, longitude(the_geom) as longitude from restaurants where type_of_food = 'indian' limit 10").should == 
      "SELECT ST_Y(the_geom) as latitude, ST_X(the_geom) as longitude from restaurants where type_of_food = 'indian' limit 10"
  end
  
  it "should parse intersect() functions" do
    CartoDB::SqlParser.parse("select * from restaurants where intersects(40.33,22.10,the_geom) = true").should == 
      "select * from restaurants where ST_Intersects(ST_SetSRID(ST_Point(40.33,22.10),4326),the_geom) = true"
  end
  
  it "should parse queries that combine different functions" do
    CartoDB::SqlParser.parse("SELECT latitude(the_geom), longitude(r.the_geom) from restaurantes r order by distance(the_geom, 40.5, 30.3)").should ==
      "SELECT ST_Y(the_geom), ST_X(r.the_geom) from restaurantes r order by st_distance_sphere(the_geom,ST_SetSRID(ST_Point(40.5,30.3),4326))"
  end
  
  it "should parse queries containing geojson()" do
    CartoDB::SqlParser.parse("SELECT 1 as foo, geojson(the_geom) from restaurants r").should ==
      "SELECT 1 as foo, ST_AsGeoJSON(the_geom,6) from restaurants r"
  end
  
  it "should parse queries containing kml()" do
    CartoDB::SqlParser.parse("SELECT 1 as foo, kml(the_geom) from restaurants r").should ==
      "SELECT 1 as foo, ST_AsKML(the_geom,6) from restaurants r"
  end  
  
  it "should parse queries containing svg()" do
    CartoDB::SqlParser.parse("SELECT 1 as foo, svg(the_geom) from restaurants r").should ==
      "SELECT 1 as foo, ST_AsSVG(the_geom,0,6) from restaurants r"
  end  
  
  it "should parse queries containing wkt()" do
    CartoDB::SqlParser.parse("SELECT 1 as foo, wkt(the_geom) from restaurants r").should ==
      "SELECT 1 as foo, ST_AsText(the_geom) from restaurants r"
  end  
  
  it "should parse queries containing geohash()" do
    CartoDB::SqlParser.parse("SELECT 1 as foo, geohash(the_geom) from restaurants r").should ==
      "SELECT 1 as foo, ST_GeoHash(the_geom,6) from restaurants r"
  end
  
  it "should convert any the_geom reference, including a * into a ST_AsGeoJSON(the_geom)" do
    CartoDB::SqlParser.parse("select the_geom from table").should == "select ST_AsGeoJSON(the_geom) as the_geom from table"
    CartoDB::SqlParser.parse("select cartodb_id, the_geom from wadus").should == "select cartodb_id,ST_AsGeoJSON(the_geom) as the_geom from wadus"
    CartoDB::SqlParser.parse("select a,b,the_geom from table").should == "select a,b,ST_AsGeoJSON(the_geom) as the_geom from table"
    CartoDB::SqlParser.parse("select ST_X(the_geom) from table").should == "select ST_X(the_geom) from table"
    CartoDB::SqlParser.parse("select ST_X(   the_geom  ) from table").should == "select ST_X(   the_geom  ) from table"
    CartoDB::SqlParser.parse("select the_geom, other_column from table").should == "select ST_AsGeoJSON(the_geom) as the_geom, other_column from table"
    CartoDB::SqlParser.parse("select other_column, the_geom from table").should == "select other_column,ST_AsGeoJSON(the_geom) as the_geom from table"
  end
  
  it "should expand * to a list of columns" do
    user = create_user
    table = new_table
    table.user_id = user.id
    table.name = 'table1'
    table.save
    
    CartoDB::SqlParser.parse("select * from table1", user.database_name).should == "select cartodb_id,name,description,ST_AsGeoJSON(the_geom) as the_geom,created_at,updated_at from table1"
    CartoDB::SqlParser.parse("select * from table1 where intersects(40.33,22.10,the_geom) = true", user.database_name).should == 
      "select cartodb_id,name,description,ST_AsGeoJSON(the_geom) as the_geom,created_at,updated_at from table1 where ST_Intersects(ST_SetSRID(ST_Point(40.33,22.10),4326),the_geom) = true"
  end
  
  it "should expand table_name.* to a list of columns" do
    user = create_user
    table1 = new_table
    table1.user_id = user.id
    table1.name = 'table1'
    table1.save
    
    table2 = new_table
    table2.user_id = user.id
    table2.name = 'table2'
    table2.save
    
    CartoDB::SqlParser.parse("select table2.*,table1.cartodb_id from table1,table2", user.database_name).should == 
      "select table2.cartodb_id,table2.name,table2.description,ST_AsGeoJSON(table2.the_geom) as the_geom,table2.created_at,table2.updated_at,table1.cartodb_id from table1,table2"
  end

  it "should expand table1.*,table2.* to a list of columns" do
    user = create_user
    table1 = new_table
    table1.user_id = user.id
    table1.name = 'table1'
    table1.save
    
    table2 = new_table
    table2.user_id = user.id
    table2.name = 'table2'
    table2.save
    
    CartoDB::SqlParser.parse("select table1.*,table2.* from table1,table2", user.database_name).should == 
      "select table1.cartodb_id,table1.name,table1.description,ST_AsGeoJSON(table1.the_geom) as the_geom,table1.created_at,table1.updated_at,table2.cartodb_id,table2.name,table2.description,ST_AsGeoJSON(table2.the_geom) as the_geom,table2.created_at,table2.updated_at from table1,table2"
  end
  
  it "should parse the_geom when included in a function" do
    CartoDB::SqlParser.parse("select geojson(ST_Union(the_geom)) as the_geom from cp_vizzuality WHERE cod_postal in ('01001','01002')").should == 
      "select ST_AsGeoJSON(ST_Union(the_geom),6) as the_geom from cp_vizzuality WHERE cod_postal in ('01001','01002')"
  end
  
end

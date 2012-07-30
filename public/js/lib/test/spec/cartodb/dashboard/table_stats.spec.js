
describe("table-stats", function() {
  var tablestats
    , tables
    , user;

  beforeEach(function() {

    tables = new cdb.admin.Tables();
    user = new cdb.admin.User({ id : "1" });

    tables.reset([{name: 'test'}]);

    tablestats = new cdb.admin.dashboard.TableStats({
      username: "admin",
      model: user,
      tables: tables
    });

  });

  it("should update user stats when tables model is fetched", function() {
    spyOn(tablestats.model, 'fetch');
    tables.reset([{name: 'test'}]);
    expect(tablestats.model.fetch).toHaveBeenCalled();
  });

  it("should update user stats when new table is added", function() {
    spyOn(tablestats.model, 'fetch');
    tables.add({name: 'test'});
    expect(tablestats.model.fetch).toHaveBeenCalled();
  });

  it("should update user stats when a table is removed", function() {
    tables.add({name: 'test'});
    spyOn(tablestats.model, 'fetch');
    tables.remove(tables.at(0));
    expect(tablestats.model.fetch).toHaveBeenCalled();
  });
});

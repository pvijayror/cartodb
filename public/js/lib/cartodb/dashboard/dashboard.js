/**
 *  entry point for dashboard
 */


$(function() {

    var Dashboard = cdb.core.View.extend({
        el: document.body,

        initialize: function() {
          this._initModels();
          this._initViews();

          this.tables.fetch();
        },

        _initModels: function() {
          this.tables = new cbd.admin.Tables();
        },

        _initViews: function() {

          this.settings = new Settings({
            template_base: $('#settings_template').html(),
            speed: 300
          });
          this.$el.append(settings.render().el);

          setTimeout(function(){
            settings.open();  
          },3);
        }
    });

    var DashboardRouter = Backbone.Router.extend({

        routes: {
            '/': 'index'
        },

        index: function() {
        }

    });

    var dashboard = new Dashboard();
    var router = new DashboardRouter();

    // expose to debug
    window.dashboard = dashboard;



});

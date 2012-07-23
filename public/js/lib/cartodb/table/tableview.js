
(function() {

    var HeaderDropdown = cdb.admin.UserMenu.extend({ 

      events: {
        'click .order_column': 'orderColumns',
        'click .rename_column': 'renameColumn',
        'click .change_data_type': 'changeType',
        'click .georeference': 'georeference',
        'click .filter_by_this_column': 'filterColumn',
        'click .delete_column': 'deleteColumn'
      },

      setTable: function(table, column) {
        this.table = table;
        this.column = column;
      },

      orderColumns: function(e) { },

      renameColumn: function(e) {
        e.preventDefault();
        this.hide();
        this.trigger('renameColumn');
        return false;
      },

      changeType: function(e) { },

      georeference: function(e) { },

      filterColumn: function(e) { },

      deleteColumn: function(e) {
        e.preventDefault();
        cdb.log.debug("removing column: " + this.column);
        this.hide();
        this.table.deleteColumn(this.column);
        return false;
      }
    });

    /**
     * view used to render each row
     */
    cdb.admin.RowView = cdb.ui.common.RowView.extend({

      initialize: function() {
         this.constructor.__super__.initialize.apply(this);
         this.options.row_header = true;
      },
      /**
       * return each cell view
       */
      valueView: function(colName, value) {
        return $('<div>').append(value);
      }
    });


    /**
     * header cell view, manages operations on table columns
     */

    var HeaderView = cdb.admin.HeaderView = cdb.core.View.extend({

      events: {
        'click    .coloptions':      'showColumnOptions',
        'keydown  .col_name_edit':   '_checkEditColnameInput'
      },

      initialize: function() {
        this.column = this.options.column;
        this.table = this.options.table;
        this.template = this.getTemplate('table/views/table_header_view');
        this.editing_name = false;

        HeaderView.colOptions= new HeaderDropdown({
          position: 'position',
          template_base: "table/views/table_header_options"
        });
        HeaderView.colOptions.render();
      },

      render: function() {
        this.$el.html('');

        this.$el.append(this.template({
          col_name: this.column[0],
          col_type: this.column[1],
          editing_name: this.editing_name
        }));
        return this;
      },

      _openColOptions: function(e) {
        var colOptions = HeaderView.colOptions;
        colOptions.off();
        this.$el.append(colOptions.el);

        // set data for column and table currently editing
        colOptions.setTable(this.table, this.column[0]);

        colOptions.bind('renameColumn', this._renameColumn, this);

        // bind the stuff
        colOptions.open(e, e.target);
      },

      _checkEditColnameInput: function(e) {
        if(e.keyCode === 13) {
          this.table.renameColumn(this.column[0], $('.col_name_edit').val());
        }
      },

      _finishEdit: function() {
        this.editing_name = false;
        this.render();
      },

      _renameColumn: function() {
        this.editing_name = true;
        this.render();
      },

      showColumnOptions: function(e) {
        var self = this;
        e.preventDefault();
        var colOptions = HeaderView.colOptions;
        colOptions.hide(function() {
          self._openColOptions(e);
        });
        return false;
      }

    });

    /**
     * table view shown in admin
     */
    cdb.admin.TableView = cdb.ui.common.Table.extend({

      rowView: cdb.admin.RowView,

      initialize: function() {
         var self = this;
         this.constructor.__super__.initialize.apply(this);
         this.options.row_header = true;
         this.model.data().bind('newPage', this.newPage, this);
         setInterval(function() {
           if(!self.$el.is(":visible")) {
             return;
           }
           var pos = $(this).scrollTop();
           var d = self.model.data();
           if( pos + $(window).height() >= $(document).height() ) {
             d.setPage(d.getPage() + 1);
           } else if (pos <= 0) {
             d.setPage(d.getPage() - 1);
           }

         }, 300);

        // Moving header when scrolls
        $(window).scroll(function(ev){
          self.$el.find("thead th div div").css({top: $(window).scrollTop() + "px"});
        });
      },

      /**
       * called when a new page is loaded
       */
      newPage: function(currentPage, direction) {
         var d = this.model.data();
         var rowspp = d.options.get('rows_per_page');
         var max_items = rowspp*4;
         if(d.size() > max_items) {
           var idx = currentPage*rowspp;
           if(direction == 'up') {
             d.remove(d.models.slice(max_items, d.size()));
           } else {
             d.remove(d.models.slice(0, idx));
           }
           cdb.log.debug("removing rows");
         }
      },

      headerView: function(column) {
        if(column[1] !== 'header') {
          var v = new cdb.admin.HeaderView({ column: column, table: this.model});
          this.addView(v);
          return v.render().el;
        } else {
          return '<div><div></div></div>';
        }
      }
    });

    cdb.admin.TableTab = cdb.core.View.extend({

      className: 'table',

      initialize: function() {
        this.tableView = new cdb.admin.TableView({
          dataModel: this.model.data(),
          model: this.model
        });
      },

      render: function() {
        this.$el.append(this.tableView.el);
        return this;
      }

    });

})();

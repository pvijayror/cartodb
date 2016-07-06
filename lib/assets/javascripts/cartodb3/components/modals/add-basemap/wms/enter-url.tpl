<div class="ImportPanel">
  <div class="ImportPanel-header">
    <h3 class="ImportPanel-headerTitle">Insert your WMS/WMTS URL</h3>
    <p class="ImportPanel-headerDescription">A list of available layers will be shown below.</p>
  </div>
  <div class="Form-row">
    <div class="Form-rowLabel">
      <label class="Form-label">Enter a URL</label>
    </div>
    <div class="Form-rowData Form-rowData--longer">
      <input type="text" class="Form-input Form-input--longer has-icon js-url" value="" placeholder="E.g. http://openlayers.org/en/v3.5.0/examples/data/ogcsample.xml">
      <i class="CDB-IconFont CDB-IconFont-dribbble Form-inputIcon js-idle"></i>
      <div class="Form-inputError js-error <%- (layersFetched && layers.length === 0) ? 'is-visible' : '' %>">
        <% if (layersFetched && layers.length === 0) { %>
          The URL is either invalid or contains unsupported projections <a target="_blank" href="http://docs.cartodb.com/cartodb-editor.html#including-an-external-basemap">(see docs)</a>
        <% } %>
      </div>
    </div>
  </div>
</div>
<div class="Dialog-footer Dialog-footer--withoutBorder u-inner">
  <button class="Button Button--main Button--inline js-fetch-layers is-disabled">
    <span>Get layers</span>
  </button>
</div>

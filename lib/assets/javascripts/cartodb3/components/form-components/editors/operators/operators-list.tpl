<ul class="CDB-Dropdown-calculations CDB-Text is-semibold">
  <li class="CDB-Dropdown-calculationsElement">
    <input class="CDB-Radio" type="radio" name="operator" value="count" <% if (operator === 'count') { %>checked<% } %>>
    <span class="u-iBlock CDB-Radio-face"></span>
    <label class="u-iBlock u-lSpace">COUNT</label>
  </li>
  <li class="CDB-Dropdown-calculationsElement">
    <input class="CDB-Radio" type="radio" name="operator" value="sum" <% if (operator === 'sum') { %>checked<% } %>>
    <span class="u-iBlock CDB-Radio-face"></span>
    <label class="u-iBlock u-lSpace">SUM</label>
  </li>
  <li class="CDB-Dropdown-calculationsElement">
    <input class="CDB-Radio" type="radio" name="operator" value="avg" <% if (operator === 'avg') { %>checked<% } %>>
    <span class="u-iBlock CDB-Radio-face"></span>
    <label class="u-iBlock u-lSpace">AVG</label>
  </li>
  <li class="CDB-Dropdown-calculationsElement">
    <input class="CDB-Radio" type="radio" name="operator" value="max" <% if (operator === 'max') { %>checked<% } %>>
    <span class="u-iBlock CDB-Radio-face"></span>
    <label class="u-iBlock u-lSpace">MAX</label>
  </li>
  <li class="CDB-Dropdown-calculationsElement">
    <input class="CDB-Radio" type="radio" name="operator" value="min" <% if (operator === 'min') { %>checked<% } %>>
    <span class="u-iBlock CDB-Radio-face"></span>
    <label class="u-iBlock u-lSpace">MIN</label>
  </li>
</ul>
<div class="js-list"></div>

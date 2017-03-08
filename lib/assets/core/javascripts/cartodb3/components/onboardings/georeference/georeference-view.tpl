<div class="LayerOnboarding-pads LayerOnboarding-pads--left">
  <div class="LayerOnboarding-padTop"></div>
  <div class="LayerOnboarding-padMiddle LayerOnboarding-padMiddle--highlight js-highlight"></div>
</div>

<div class="Onboarding-contentWrapper is-step0 js-step">
  <div class="Onboarding-contentBody is-step0 js-step">
    <div class="Onboarding-body is-step0">
      <p class="CDB-Text Onboarding-headerText Onboarding-headerText--georeference"><%= _t('style-onboarding.georeference.title', { name: name })%></p>

      <p class="CDB-Text LayerOnboarding-description"><%- _t('style-onboarding.georeference.description')%></p>
    </div>

    <div class="Onboarding-footer is-step0">
      <div class="Onboarding-footerButtons">
        <button class="CDB-Button CDB-Button--secondary CDB-Button--white CDB-Button--big Onboarding-footer--marginRight js-close">
          <span class="CDB-Button-Text CDB-Text u-upperCase is-semibold CDB-Size-medium"><%- _t('style-onboarding.georeference.skip')%></span>
        </button>

        <button class="CDB-Button CDB-Button--primary CDB-Button--big js-georeference">
          <span class="CDB-Button-Text CDB-Text u-upperCase is-semibold CDB-Size-medium"><%- _t('style-onboarding.georeference.data')%></span>
        </button>
      </div>

      <div class="u-iBlock">
        <input class="CDB-Checkbox js-forget" type="checkbox" id="forget-me" name="forget-me" value="true">
        <span class="u-iBlock CDB-Checkbox-face"></span>
        <label for="forget-me" class="Onboarding-forgetLabel Checkbox-label CDB-Text CDB-Size-small u-whiteTextColor is-light u-lSpace"><%- _t('style-onboarding.never-show-message') %></label>
      </div>
    </div>
  </div>
</div>

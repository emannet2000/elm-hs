(function () {
  'use strict';

  var leadStages = ['Lead', 'Qualified', 'Consultation', 'Application/Deal', 'Student/Client', 'Completed', 'Lost'];
  var legacyLeadStages = ['New Lead', 'Contacted', 'Initial Assessment', 'Qualified', 'Consultation Booked', 'Proposal Sent', 'Converted', 'Closed/Lost'];
  var stageMap = {
    'New Lead': 'Lead',
    'Contacted': 'Lead',
    'Initial Assessment': 'Qualified',
    'Qualified': 'Qualified',
    'Consultation Booked': 'Consultation',
    'Proposal Sent': 'Application/Deal',
    'Converted': 'Student/Client',
    'Closed/Lost': 'Lost'
  };

  function text(el) {
    return (el && el.textContent ? el.textContent : '').replace(/\s+/g, ' ').trim();
  }

  function dispatchChange(el) {
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function canonicalizeLeadSelect(select) {
    var values = Array.prototype.map.call(select.options, function (o) { return o.value; });
    var isLeadStageSelect = legacyLeadStages.some(function (s) { return values.indexOf(s) !== -1; });
    if (!isLeadStageSelect || select.dataset.eccLifecycle === '1') return;

    var current = stageMap[select.value] || select.value;
    select.innerHTML = '';
    leadStages.forEach(function (stage) {
      var option = document.createElement('option');
      option.value = stage;
      option.textContent = stage;
      select.appendChild(option);
    });
    select.value = leadStages.indexOf(current) !== -1 ? current : 'Lead';
    select.dataset.eccLifecycle = '1';
    dispatchChange(select);
  }

  function currentLeadStage() {
    var candidates = document.querySelectorAll('.badge, .stage-badge, [class*="stage"], dd, td, span');
    for (var i = 0; i < candidates.length; i += 1) {
      var value = text(candidates[i]);
      var canonical = stageMap[value] || value;
      if (leadStages.indexOf(canonical) !== -1) return canonical;
    }
    return null;
  }

  function applyLifecycleUi() {
    document.querySelectorAll('select').forEach(canonicalizeLeadSelect);

    var stage = currentLeadStage();
    document.querySelectorAll('button, a').forEach(function (el) {
      var label = text(el);

      if (label === '+ Add Client' || label === 'Add Client') {
        el.style.display = 'none';
        el.setAttribute('aria-hidden', 'true');
      }

      if (label === 'Convert to Client' || label === 'Convert') {
        el.textContent = 'Convert to Student/Client';
        var allowed = stage === 'Application/Deal';
        el.style.display = allowed ? '' : 'none';
        el.setAttribute('aria-hidden', allowed ? 'false' : 'true');
      }

      if (label === 'Advance' && stage) {
        var next = {
          'Lead': 'Qualified',
          'Qualified': 'Consultation',
          'Consultation': 'Application/Deal',
          'Student/Client': 'Completed'
        }[stage];
        if (next) {
          el.textContent = 'Advance to ' + next;
          el.style.display = '';
        } else {
          el.style.display = 'none';
        }
      }
    });

    document.querySelectorAll('a, button, span').forEach(function (el) {
      if (text(el) === 'Clients' && !el.dataset.eccLifecycleLabel) {
        el.textContent = 'Students / Clients';
        el.dataset.eccLifecycleLabel = '1';
      }
    });
  }

  var scheduled = false;
  function scheduleApply() {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(function () {
      scheduled = false;
      applyLifecycleUi();
    });
  }

  document.addEventListener('DOMContentLoaded', scheduleApply);
  window.addEventListener('popstate', scheduleApply);
  new MutationObserver(scheduleApply).observe(document.documentElement, { childList: true, subtree: true });
  scheduleApply();
})();

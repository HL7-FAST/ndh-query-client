// Generic loading feedback for form submissions (remote and full-page).
$(document).on('submit', 'form', function () {
  const $submit = $(this).find('[type="submit"]').first();
  const spinner = $('<span class="spinner-border spinner-border-sm me-1" role="status" aria-hidden="true"></span>');
  $submit.prop('disabled', true);
  $submit.is('button') ? $submit.prepend(spinner) : spinner.insertBefore($submit);
});

$(document).on('ajax:complete', 'form[data-remote]', function () {
  $(this).find('[type="submit"]').prop('disabled', false);
  $(this).find('.spinner-border').remove();
});

// Restore controls when the page is served from the back-forward cache.
$(window).on('pageshow', function () {
  $('[type="submit"]').prop('disabled', false);
  $('.spinner-border').remove();
});

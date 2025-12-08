// FHIR Bulk Export Management
// Handles export initiation, auto-polling with exponential backoff, and result display

class BulkExportManager {
  constructor() {
    this.pollTimer = null;
    this.pollAttempts = 0;
    this.maxPollAttempts = 60;
    this.baseRetryInterval = 2000; // 2 seconds base
    this.maxRetryInterval = 60000; // 60 seconds max
    this.exportActive = false;

    this.bindEvents();
  }

  bindEvents() {
    // Form submission
    const exportForm = document.getElementById('export-form');
    if (exportForm) {
      exportForm.addEventListener('submit', (e) => {
        e.preventDefault();
        this.startExport();
      });
    }

    // Cancel button
    const cancelBtn = document.getElementById('cancel-export-btn');
    if (cancelBtn) {
      cancelBtn.addEventListener('click', () => this.cancelExport());
    }

    // Resource type toggles
    const resourceCheckboxes = document.querySelectorAll('input[name="resource_types[]"]');
    resourceCheckboxes.forEach(checkbox => {
      checkbox.addEventListener('change', () => this.updateSelectedResourcesCount());
    });
  }

  async startExport() {
    const form = document.getElementById('export-form');
    const formData = new FormData(form);

    // Clear previous results
    const resultsContainer = document.getElementById('export-results');
    if (resultsContainer) {
      resultsContainer.innerHTML = '';
    }

    this.showStatus('initiated', 'Initiating export...');
    this.setExportActive(true);

    try {
      const response = await fetch('/export/start', {
        method: 'POST',
        headers: {
          'X-CSRF-Token': this.getCsrfToken(),
          'Accept': 'application/json'
        },
        body: formData
      });

      const data = await response.json();

      if (data.status === 'initiated') {
        this.showStatus('in_progress', data.message, { poll_url: data.poll_url, request_url: data.request_url });
        this.pollAttempts = 0;
        this.startPolling(data.retry_after || 5);
      } else if (data.status === 'error') {
        this.showError(data.message, data.operation_outcome);
        this.setExportActive(false);
      }
    } catch (error) {
      this.showError('Failed to start export: ' + error.message);
      this.setExportActive(false);
    }
  }

  startPolling(initialDelay = 5) {
    this.stopPolling();

    const delay = Math.min(
      this.baseRetryInterval * Math.pow(1.5, this.pollAttempts),
      this.maxRetryInterval
    );

    const actualDelay = this.pollAttempts === 0 ? initialDelay * 1000 : delay;

    this.pollTimer = setTimeout(() => this.pollStatus(), actualDelay);
  }

  async pollStatus() {
    if (!this.exportActive) {
      return;
    }

    this.pollAttempts++;

    if (this.pollAttempts > this.maxPollAttempts) {
      this.showError('Export polling timed out. Please check the server status.');
      this.setExportActive(false);
      return;
    }

    try {
      const response = await fetch('/export/status', {
        method: 'GET',
        headers: {
          'X-CSRF-Token': this.getCsrfToken(),
          'Accept': 'application/json'
        }
      });

      const data = await response.json();

      if (data.status === 'in_progress') {
        this.showStatus('in_progress', data.message || 'Export in progress...', {
          progress: data.progress,
          attempts: this.pollAttempts,
          poll_url: data.poll_url,
          request_url: data.request_url
        });
        this.startPolling(data.retry_after || 5);
      } else if (data.status === 'complete') {
        this.showComplete(data);
        this.setExportActive(false);
      } else if (data.status === 'error') {
        this.showError(data.message, data.operation_outcome);
        this.setExportActive(false);
      }
    } catch (error) {
      this.showError('Failed to check export status: ' + error.message);
      this.setExportActive(false);
    }
  }

  async cancelExport() {
    if (!confirm('Are you sure you want to cancel this export?')) {
      return;
    }

    try {
      const response = await fetch('/export/cancel', {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': this.getCsrfToken(),
          'Accept': 'application/json'
        }
      });

      const data = await response.json();
      this.showStatus('canceled', data.message);
      this.setExportActive(false);
    } catch (error) {
      this.showError('Failed to cancel export: ' + error.message);
    }
  }

  stopPolling() {
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
  }

  setExportActive(active) {
    this.exportActive = active;

    const startBtn = document.getElementById('start-export-btn');
    const cancelBtn = document.getElementById('cancel-export-btn');
    const formInputs = document.querySelectorAll('#export-form input, #export-form select');

    if (startBtn) startBtn.disabled = active;
    if (cancelBtn) cancelBtn.disabled = !active;

    formInputs.forEach(input => {
      input.disabled = active;
    });

    if (!active) {
      this.stopPolling();
    }
  }

  showStatus(status, message, extra = {}) {
    const statusContainer = document.getElementById('export-status');
    if (!statusContainer) return;

    let bgStyle = '';
    let textClass = 'text-white';

    switch(status) {
      case 'initiated':
        bgStyle = 'background-color: #0d6efd;'; // Bootstrap primary blue
        textClass = 'text-white';
        break;
      case 'in_progress':
        bgStyle = 'background-color: #0dcaf0;'; // Bootstrap info cyan
        textClass = 'text-dark';
        break;
      case 'complete':
        bgStyle = 'background-color: #198754;'; // Bootstrap success green
        textClass = 'text-white';
        break;
      case 'error':
        bgStyle = 'background-color: #dc3545;'; // Bootstrap danger red
        textClass = 'text-white';
        break;
      case 'canceled':
        bgStyle = 'background-color: #ffc107;'; // Bootstrap warning yellow
        textClass = 'text-dark';
        break;
    }

    let html = `<div class="row mt-4">`;
    html += `<div class="col-12">`;
    html += `<div class="${textClass} p-4 rounded" style="${bgStyle}">`;
    html += `<h4 class="mb-3">${this.escapeHtml(message)}</h4>`;

    if (extra.progress) {
      html += `<p class="mb-2"><strong>Progress:</strong> ${this.escapeHtml(extra.progress)}</p>`;
    }

    if (extra.attempts) {
      html += `<p class="mb-2"><strong>Poll attempt:</strong> ${extra.attempts}</p>`;
    }

    if (extra.request_url) {
      html += `<div class="mt-3"><strong>Request URL:</strong><br><code class="d-block mt-2 p-2 bg-dark text-light rounded small">${this.escapeHtml(extra.request_url)}</code></div>`;
    }

    if (extra.poll_url) {
      html += `<div class="mt-3"><strong>Polling URL:</strong><br><code class="d-block mt-2 p-2 bg-dark text-light rounded small">${this.escapeHtml(extra.poll_url)}</code></div>`;
    }

    html += `</div></div></div>`;

    statusContainer.innerHTML = html;
  }

  showError(message, operationOutcome = null) {
    const statusContainer = document.getElementById('export-status');
    if (!statusContainer) return;

    let html = `<div class="row mt-4">`;
    html += `<div class="col-12">`;
    html += `<div class="bg-danger text-white p-3 rounded">`;
    html += `<h5 class="mb-2">Error</h5>`;
    html += `<p class="mb-2">${this.escapeHtml(message)}</p>`;

    if (operationOutcome && operationOutcome.issue) {
      html += '<div class="mt-3"><strong>Details:</strong><ul class="mb-0 mt-2">';
      operationOutcome.issue.forEach(issue => {
        html += `<li>${issue.severity}: ${this.escapeHtml(issue.diagnostics || issue.details?.text || 'No details')}</li>`;
      });
      html += '</ul></div>';
    }

    html += `</div></div></div>`;

    statusContainer.innerHTML = html;
  }

  showComplete(data) {
    const statusContainer = document.getElementById('export-status');
    const resultsContainer = document.getElementById('export-results');

    if (statusContainer) {
      this.showStatus('complete', data.message);
    }

    if (resultsContainer && data.manifest) {
      this.displayResults(data);
    }
  }

  displayResults(data) {
    const container = document.getElementById('export-results');
    if (!container) return;

    let html = '<section class="row mt-4">';
    html += '<div class="col-12"><h3>Export Results</h3></div>';

    // Metadata table
    html += '<div class="col-12 mt-3">';
    html += '<table class="table table-dark">';

    if (data.transaction_time) {
      html += '<tr><td>Transaction Time</td><td>' + this.escapeHtml(data.transaction_time) + '</td></tr>';
    }

    if (data.request_url) {
      html += '<tr><td>Request URL</td><td><code style="word-break: break-all;">' + this.escapeHtml(data.request_url) + '</code></td></tr>';
    }

    if (data.poll_url) {
      html += '<tr><td>Polling URL</td><td><code style="word-break: break-all;">' + this.escapeHtml(data.poll_url) + '</code></td></tr>';
    }

    if (data.requires_access_token !== undefined) {
      html += '<tr><td>Requires Access Token</td><td>' + (data.requires_access_token ? 'Yes' : 'No') + '</td></tr>';
    }

    html += '</table></div>';

    // Output files
    if (data.output_files && data.output_files.length > 0) {
      html += '<div class="col-12 mt-4"><h4>Output Files</h4></div>';
      html += '<div class="col-12"><table class="table table-dark">';
      html += '<tr><th scope="col">Type</th><th scope="col">URL</th></tr>';

      data.output_files.forEach(file => {
        html += '<tr>';
        html += '<td>' + this.escapeHtml(file.type || 'N/A') + '</td>';
        html += '<td><a href="' + this.escapeHtml(file.url) + '" target="_blank">' + this.escapeHtml(file.url) + '</a></td>';
        html += '</tr>';
      });

      html += '</table></div>';
    }

    // Deleted resources
    if (data.deleted_files && data.deleted_files.length > 0) {
      html += '<div class="col-12 mt-4"><h4>Deleted Resources</h4></div>';
      html += '<div class="col-12"><table class="table table-dark">';
      html += '<tr><th scope="col">Type</th><th scope="col">URL</th><th scope="col">Count</th></tr>';

      data.deleted_files.forEach(file => {
        html += '<tr>';
        html += '<td>' + this.escapeHtml(file.type || 'N/A') + '</td>';
        html += '<td><a href="' + this.escapeHtml(file.url) + '" target="_blank">' + this.escapeHtml(file.url) + '</a></td>';
        html += '</tr>';
      });

      html += '</table></div>';
    }

    // Error files
    if (data.error_files && data.error_files.length > 0) {
      html += '<div class="col-12 mt-4"><h4>Error Files</h4></div>';
      html += '<div class="col-12"><table class="table table-dark">';
      html += '<tr><th scope="col">Type</th><th scope="col">URL</th></tr>';

      data.error_files.forEach(file => {
        html += '<tr>';
        html += '<td>' + this.escapeHtml(file.type || 'OperationOutcome') + '</td>';
        html += '<td><a href="' + this.escapeHtml(file.url) + '" target="_blank">' + this.escapeHtml(file.url) + '</a></td>';
        html += '</tr>';
      });

      html += '</table></div>';
    }

    // No files in any category
    if (
      (!data.output_files || data.output_files.length === 0) &&
      (!data.deleted_files || data.deleted_files.length === 0) &&
      (!data.error_files || data.error_files.length === 0)
    ) {
      html += '<div class="col-12 mt-3"><p>No files were generated during this export.</p></div>';
    }

    html += '</section>';
    container.innerHTML = html;
  }

  updateSelectedResourcesCount() {
    const checkboxes = document.querySelectorAll('input[name="resource_types[]"]:checked');
    const counter = document.getElementById('selected-resources-count');
    if (counter) {
      counter.textContent = checkboxes.length;
    }
  }

  getCsrfToken() {
    const token = document.querySelector('meta[name="csrf-token"]');
    return token ? token.getAttribute('content') : '';
  }

  escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  if (document.getElementById('export-form')) {
    window.bulkExportManager = new BulkExportManager();
  }
});

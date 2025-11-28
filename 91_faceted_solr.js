// solr_facetview.js
// Modernized behaviour for SolrFacetedBrowse with ES6+ features
class SolrFacetView {
  constructor() {
    this.autocompleteTimeout = null;
    this.init();
  }

  init() {
    document.addEventListener('DOMContentLoaded', () => this.initializeComponents());
  }

  initializeComponents() {
    const container = document.querySelector('#ep_solr_facetview');
    if (!container) return;

    this.setupAutocomplete();
    this.setupFacetSearchInputs(container);
    this.setupEventListeners(container);
    this.initializeFacetBoxes(container);
  }

  // Modern URLSearchParams-based form serialization
  formToQueryString(form) {
    const params = new URLSearchParams();
    const formData = new FormData(form);
    
    // Handle all form elements including checkboxes, radios, and multi-selects
    for (const [name, value] of formData.entries()) {
      params.append(name, value);
    }
    
    return params.toString();
  }

  // Enhanced facet preview with async/await
  async loadFacetPreview(toggleEl) {
    const container = toggleEl.closest('li');
    if (!container) return;

    const previewContainer = container.querySelector('.facet_preview_container');
    if (!previewContainer) return;

    // Toggle visibility
    if (previewContainer.style.display === 'block') {
      this.hidePreview(previewContainer);
      return;
    }

    const field = toggleEl.dataset.field;
    const value = toggleEl.dataset.value;
    const fqStr = toggleEl.dataset.fq;
    const form = document.getElementById('facetview_search');
    
    if (!form) return;

    try {
      this.showPreviewLoading(previewContainer);
      const html = await this.fetchFacetPreview(form, field, value, fqStr);
      this.showPreviewContent(previewContainer, html);
    } catch (error) {
      this.handlePreviewError(previewContainer, error);
    }
  }

  hidePreview(previewContainer) {
    previewContainer.style.display = 'none';
    previewContainer.innerHTML = '';
  }

  showPreviewLoading(previewContainer) {
    previewContainer.style.display = 'block';
    previewContainer.innerHTML = '<div class="facet_preview_loading">Loading preview…</div>';
  }

  showPreviewContent(previewContainer, html) {
    previewContainer.innerHTML = html;
  }

  handlePreviewError(previewContainer, error) {
    console.error('Facet preview error:', error);
    previewContainer.innerHTML = '<div class="facet_preview_error">Error loading preview.</div>';
  }

  async fetchFacetPreview(form, field, value, fqStr) {
    const baseUrl = form.getAttribute('action') || window.location.pathname;
    const params = new URLSearchParams(this.formToQueryString(form));
    
    params.set('_action', 'facet_preview');
    params.set('field', field || '');
    params.set('value', value || '');
    params.set('preview_fq', fqStr || '');

    const url = `${baseUrl}?${params.toString()}`;
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'text/html'
      }
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    return await response.text();
  }

  // Improved facet show more/less with animation support
  toggleFacetShowMore(button) {
    const field = button.dataset.field;
    if (!field) return;

    const box = button.closest('.ep_solr_facet_box');
    if (!box) return;

    const isExpanded = box.dataset.expanded === 'true';
    const facetValues = box.querySelectorAll('ul.facetview_values > li');
    const visibleCount = 10;

    facetValues.forEach((li, index) => {
      if (!isExpanded && index >= visibleCount) {
        li.style.display = 'none';
      } else {
        li.style.display = '';
      }
    });

    // Update state and button text
    box.dataset.expanded = (!isExpanded).toString();
    button.textContent = isExpanded ? 'Show More' : 'Show Less';
    
    // Optional: Add animation class for smooth transitions
    box.classList.toggle('facet-expanded', !isExpanded);
  }

  // Facet selection with better user feedback
  applyFacetSelect(select) {
    const fq = select.value;
    if (!fq) return;

    const form = document.getElementById('facetview_search');
    if (!form) return;

    // Add loading state
    select.disabled = true;
    select.classList.add('loading');

    const baseUrl = form.getAttribute('action') || window.location.pathname;
    const params = new URLSearchParams(this.formToQueryString(form));
    params.append('fq', fq);

    window.location.href = `${baseUrl}?${params.toString()}`;
  }

  // Enhanced facet search with debouncing
  setupFacetSearchInputs(container) {
    const inputs = container.querySelectorAll('.facet_search_input');
    
    inputs.forEach(input => {
      // Add debounced search
      const debouncedSearch = this.debounce((term) => {
        this.filterFacetValues(input, term);
      }, 300);

      input.addEventListener('input', (e) => {
        const term = e.target.value.trim().toLowerCase();
        debouncedSearch(term);
      });

      // Clear search on escape
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
          e.target.value = '';
          this.filterFacetValues(input, '');
        }
      });
    });
  }

  filterFacetValues(input, term) {
    const box = input.closest('.ep_solr_facet_box');
    if (!box) return;

    const items = box.querySelectorAll('ul.facetview_values > li');
    let visibleCount = 0;

    items.forEach(li => {
      const textEl = li.querySelector('.facetview_filterchoice, .facetview_filterselected');
      const text = textEl ? textEl.textContent.toLowerCase() : li.textContent.toLowerCase();

      const isVisible = !term || text.includes(term);
      li.style.display = isVisible ? '' : 'none';
      
      if (isVisible) visibleCount++;
    });

    // Update show more button visibility if needed
    this.updateShowMoreButton(box, visibleCount);
  }

  updateShowMoreButton(box, visibleCount) {
    const button = box.querySelector('.facet_show_more');
    if (!button) return;

    const totalItems = box.querySelectorAll('ul.facetview_values > li').length;
    button.style.display = visibleCount >= totalItems ? 'none' : '';
  }

  // Modern autocomplete with better UX
  setupAutocomplete() {
    const searchInput = document.getElementById('facetview_freetext');
    if (!searchInput || searchInput.dataset.autocomplete !== 'true') return;

    const list = this.createAutocompleteContainer(searchInput);

    // Debounced input handler
    const debouncedInput = this.debounce(async (term) => {
      if (term.length < 2) {
        this.clearAutocomplete(list);
        return;
      }

      try {
        const suggestions = await this.fetchAutocompleteSuggestions(term);
        this.populateAutocomplete(list, suggestions, searchInput);
      } catch (error) {
        console.error('Autocomplete error:', error);
        this.clearAutocomplete(list);
      }
    }, 250);

    searchInput.addEventListener('input', (e) => {
      const term = e.target.value.trim();
      debouncedInput(term);
    });

    // Enhanced keyboard navigation
    searchInput.addEventListener('keydown', (e) => {
      this.handleAutocompleteKeyboard(e, list, searchInput);
    });

    // Hide on blur (with delay to allow clicking on suggestions)
    searchInput.addEventListener('blur', () => {
      setTimeout(() => this.clearAutocomplete(list), 150);
    });
  }

  createAutocompleteContainer(input) {
    const wrapper = document.createElement('div');
    wrapper.className = 'facetview_autocomplete_wrapper';

    input.parentNode.insertBefore(wrapper, input);
    wrapper.appendChild(input);

    const list = document.createElement('ul');
    list.className = 'facetview_autocomplete_list';
    list.setAttribute('role', 'listbox');
    list.setAttribute('aria-label', 'Search suggestions');
    wrapper.appendChild(list);

    return list;
  }

  clearAutocomplete(list) {
    list.innerHTML = '';
    list.style.display = 'none';
    list.removeAttribute('aria-activedescendant');
  }

  populateAutocomplete(list, suggestions, input) {
    this.clearAutocomplete(list);
    
    if (!suggestions?.length) return;

    const fragment = document.createDocumentFragment();
    
    suggestions.slice(0, 10).forEach((term, index) => {
      const li = document.createElement('li');
      li.className = 'facetview_autocomplete_item';
      li.id = `autocomplete-item-${index}`;
      li.setAttribute('role', 'option');
      li.textContent = term;
      
      li.addEventListener('mousedown', (e) => {
        e.preventDefault();
        input.value = term;
        this.clearAutocomplete(list);
        input.focus();
      });
      
      fragment.appendChild(li);
    });

    list.appendChild(fragment);
    list.style.display = 'block';
    list.setAttribute('aria-expanded', 'true');
  }

  handleAutocompleteKeyboard(event, list, input) {
    const items = list.querySelectorAll('.facetview_autocomplete_item');
    if (!items.length) return;

    const currentActive = list.querySelector('.facetview_autocomplete_item.active');
    let currentIndex = currentActive ? 
      Array.from(items).indexOf(currentActive) : -1;

    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        currentIndex = (currentIndex + 1) % items.length;
        break;
      case 'ArrowUp':
        event.preventDefault();
        currentIndex = currentIndex <= 0 ? items.length - 1 : currentIndex - 1;
        break;
      case 'Enter':
        event.preventDefault();
        if (currentActive) {
          input.value = currentActive.textContent;
          this.clearAutocomplete(list);
        }
        return;
      case 'Escape':
        this.clearAutocomplete(list);
        return;
      default:
        return;
    }

    // Update active item
    items.forEach(item => item.classList.remove('active'));
    if (items[currentIndex]) {
      items[currentIndex].classList.add('active');
      list.setAttribute('aria-activedescendant', items[currentIndex].id);
    }
  }

  async fetchAutocompleteSuggestions(term) {
    const form = document.getElementById('facetview_search');
    if (!form) return [];

    const baseUrl = form.getAttribute('action') || window.location.pathname;
    const params = new URLSearchParams(this.formToQueryString(form));
    
    params.set('_action', 'autocomplete');
    params.set('term', term);

    const url = `${baseUrl}?${params.toString()}`;
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json'
      }
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    return await response.json();
  }

  // Event listener setup with event delegation
  setupEventListeners(container) {
    container.addEventListener('click', (e) => {
      const previewToggle = e.target.closest('.facet_preview_toggle');
      if (previewToggle) {
        e.preventDefault();
        this.loadFacetPreview(previewToggle);
        return;
      }

      const showMoreBtn = e.target.closest('.facet_show_more');
      if (showMoreBtn) {
        e.preventDefault();
        this.toggleFacetShowMore(showMoreBtn);
        return;
      }
    });

    container.addEventListener('change', (e) => {
      const select = e.target.closest('.facet_select');
      if (select) {
        this.applyFacetSelect(select);
      }
    });

    // Improved accessibility: keyboard support for preview toggles
    container.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        const previewToggle = e.target.closest('.facet_preview_toggle');
        if (previewToggle) {
          e.preventDefault();
          this.loadFacetPreview(previewToggle);
        }
      }
    });
  }

  initializeFacetBoxes(container) {
    container.querySelectorAll('.ep_solr_facet_box').forEach(box => {
      const button = box.querySelector('.facet_show_more');
      if (!button) return;

      box.dataset.expanded = 'false';
      this.toggleFacetShowMore(button);
    });
  }

  // Utility function: debounce
  debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
      const later = () => {
        clearTimeout(timeout);
        func(...args);
      };
      clearTimeout(timeout);
      timeout = setTimeout(later, wait);
    };
  }

  // Utility function: throttle (for potential future use)
  throttle(func, limit) {
    let inThrottle;
    return function(...args) {
      if (!inThrottle) {
        func.apply(this, args);
        inThrottle = true;
        setTimeout(() => inThrottle = false, limit);
      }
    };
  }
}

// Initialize the module
new SolrFacetView();

// Optional: Make it available globally for debugging
window.SolrFacetView = SolrFacetView;

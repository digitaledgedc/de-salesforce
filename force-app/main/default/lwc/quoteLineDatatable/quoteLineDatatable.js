import { LightningElement, api } from 'lwc';

const _fmtCache = new Map();
function formatCurrency(val, cc) {
    if (val == null || val === '') return '';
    const code = cc || 'USD';
    let fmt = _fmtCache.get(code);
    if (!fmt) {
        try {
            fmt = new Intl.NumberFormat('en-US', {
                style: 'currency', currency: code,
                minimumFractionDigits: 2, maximumFractionDigits: 2
            });
        } catch (_e) {
            fmt = new Intl.NumberFormat('en-US', {
                style: 'currency', currency: 'USD',
                minimumFractionDigits: 2, maximumFractionDigits: 2
            });
        }
        _fmtCache.set(code, fmt);
    }
    return fmt.format(val);
}

function formatDate(val) {
    if (!val) return '';
    const d = new Date(val + 'T00:00:00');
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

function formatNumber(val, col) {
    if (val == null || val === '') return '';
    const minFrac = col?.typeAttributes?.minimumFractionDigits ?? 0;
    const maxFrac = col?.typeAttributes?.maximumFractionDigits ?? 4;
    return new Intl.NumberFormat('en-US', {
        minimumFractionDigits: minFrac, maximumFractionDigits: maxFrac
    }).format(val);
}

export default class QuoteLineDatatable extends LightningElement {
    @api keyField = 'Id';
    @api hideDraftBar = false;
    @api readOnly = false;

    _data = [];
    _columns = [];
    _selectedIds = new Set();
    _draftMap = new Map(); // rowId -> { field: value }
    _editingCell = null;   // { rowId, fieldName }
    _draftSeq = 0;         // bumped on clearDrafts to force <select> DOM recreation
    _sortField = null;
    _sortDir = 'asc';
    _colWidths = {};
    _resizing = null;

    // ─── Public API ──────────────────────────────────────────────────────

    @api
    get data() { return this._data; }
    set data(val) { this._data = val || []; }

    @api
    get columns() { return this._columns; }
    set columns(val) { this._columns = val || []; }

    @api
    get selectedRows() { return [...this._selectedIds]; }
    set selectedRows(val) {
        this._selectedIds = new Set(val || []);
    }

    @api
    get draftValues() { return this._draftMapToArray(); }
    set draftValues(val) {
        if (!val || !val.length) {
            this._draftMap = new Map();
            this._editingCell = null;
            this._draftSeq++;
        }
    }

    // ─── Computed ────────────────────────────────────────────────────────

    get visibleColumns() {
        return this._columns.filter(c => c.type !== 'button-icon');
    }

    get viewBtnCol() {
        return this._columns.find(c => c.type === 'button-icon') || null;
    }

    get headerCols() {
        return this.visibleColumns.map(col => {
            const isRight = col.type === 'currency' || col.type === 'number';
            let sortCls = 'qld-sort-icon';
            if (col.fieldName === this._sortField) {
                sortCls += this._sortDir === 'asc' ? ' qld-sort-asc' : ' qld-sort-desc';
            }
            const w = this._colWidths[col.fieldName] || col.initialWidth || 150;
            return {
                ...col,
                headerClass: `qld-th${isRight ? ' qld-th-right' : ''}`,
                sortClass: sortCls,
                colStyle: `width:${w}px`
            };
        });
    }

    get allSelected() {
        return this._data.length > 0 && this._data.every(r => this._selectedIds.has(r[this.keyField]));
    }

    get hasDrafts() {
        return this._draftMap.size > 0;
    }

    get showDraftBar() {
        return this.hasDrafts && !this.hideDraftBar;
    }

    @api
    getDraftValues() {
        return this._draftMapToArray();
    }

    @api
    clearDrafts() {
        this._draftMap = new Map();
        this._editingCell = null;
        this._draftSeq++;
    }

    get rows() {
        const sorted = this._getSortedData();
        return sorted.map(row => {
            const rowId = row[this.keyField];
            const isSelected = this._selectedIds.has(rowId);
            const rowDrafts = this._draftMap.get(rowId) || {};

            // View button info
            const vb = this.viewBtnCol;
            let viewIcon = 'eye';
            let viewTitle = 'View details';
            if (vb?.typeAttributes) {
                const iconFn = vb.typeAttributes.iconName?.fieldName;
                const titleFn = vb.typeAttributes.title?.fieldName;
                if (iconFn && row[iconFn]) {
                    viewIcon = row[iconFn] === 'utility:warning' ? 'warning' : 'eye';
                }
                if (titleFn && row[titleFn]) viewTitle = row[titleFn];
            }

            // Build cells
            const cells = this.visibleColumns.map(col => {
                const fn = col.fieldName;
                const rawVal = rowDrafts[fn] !== undefined ? rowDrafts[fn] : row[fn];
                const isEditing = this._editingCell?.rowId === rowId && this._editingCell?.fieldName === fn;
                const hasDraft = rowDrafts[fn] !== undefined;

                // Append draft sequence to key for select-based columns so the
                // browser <select> element is destroyed/recreated on clearDrafts,
                // ensuring the displayed value reverts to the original.
                const selectKey = col.editOptions || col.type === 'attributePicklist'
                    ? `${rowId}-${fn || col.type}-${this._draftSeq}`
                    : `${rowId}-${fn || col.type}`;
                return {
                    key: selectKey,
                    fieldName: fn,
                    value: rawVal,
                    editValue: isEditing ? (rawVal ?? '') : null,
                    displayValue: (col.type === 'attributePicklist' && !!row._showCustomValue && !rawVal)
                        ? (row.Custom_Attribute_Value__c || this._formatValue(rawVal, col, row))
                        : this._formatValue(rawVal, col, row),
                    isEditing,
                    isEditable: !!col.editable,
                    hasDraft,
                    // Type flags
                    isUrl: col.type === 'url',
                    isCurrency: col.type === 'currency',
                    isNumber: col.type === 'number',
                    isDateLocal: col.type === 'date-local',
                    isAttributePicklist: col.type === 'attributePicklist',
                    isText: !['url', 'currency', 'number', 'date-local', 'attributePicklist', 'button-icon'].includes(col.type),
                    // URL specifics
                    urlLabel: col.typeAttributes?.label?.fieldName ? (row[col.typeAttributes.label.fieldName] || '') : '',
                    urlHref: col.type === 'url' ? (rawVal || '#') : '',
                    urlTarget: col.typeAttributes?.target || '_self',
                    // Attribute picklist
                    picklistOptions: col.typeAttributes?.options?.fieldName
                        ? (row[col.typeAttributes.options.fieldName] || []).map(o => ({ ...o, selected: o.value === rawVal }))
                        : [],
                    picklistRowId: col.typeAttributes?.rowId?.fieldName ? (row[col.typeAttributes.rowId.fieldName] || '') : '',
                    hasAttribute: col.typeAttributes?.hasAttribute?.fieldName ? !!row[col.typeAttributes.hasAttribute.fieldName] : false,
                    showPicklist: col.type === 'attributePicklist' &&
                        col.typeAttributes?.hasAttribute?.fieldName &&
                        !!row[col.typeAttributes.hasAttribute.fieldName] &&
                        col.typeAttributes?.options?.fieldName &&
                        Array.isArray(row[col.typeAttributes.options.fieldName]) &&
                        row[col.typeAttributes.options.fieldName].length > 0,
                    attrDisabled: col.typeAttributes?.disabled?.fieldName ? !!row[col.typeAttributes.disabled.fieldName] : false,
                    // Custom attribute value (inline text input when showCustomValue but no picklist)
                    showCustomInput: col.type === 'attributePicklist' && !!row._showCustomValue &&
                        !(col.typeAttributes?.hasAttribute?.fieldName && !!row[col.typeAttributes.hasAttribute.fieldName] &&
                          col.typeAttributes?.options?.fieldName && Array.isArray(row[col.typeAttributes.options.fieldName]) &&
                          row[col.typeAttributes.options.fieldName].length > 0),
                    customAttrValue: rowDrafts.Custom_Attribute_Value__c !== undefined
                        ? rowDrafts.Custom_Attribute_Value__c
                        : (row.Custom_Attribute_Value__c || ''),
                    // Config-driven input type for the custom-value fallback (parent column
                    // config decides; defaults to text so other reuses of this datatable
                    // aren't affected).
                    customInputType: col.typeAttributes?.customValueInputType || 'text',
                    // Alignment
                    cellClass: this._cellClass(col, hasDraft, isEditing),
                    // Editable input type — date picker for dates, text for rest
                    inputType: col.type === 'date-local' ? 'date' : 'text',
                    inputStep: undefined,
                    // Picklist edit options
                    hasEditOptions: !!col.editOptions,
                    editOptions: col.editOptions
                        ? col.editOptions.map(o => ({ ...o, selected: o.value === rawVal }))
                        : [],
                };
            });

            return {
                key: rowId,
                rowId,
                isSelected,
                isReadOnly: !!row._readOnly,
                rowClass: `qld-row${isSelected ? ' qld-row-selected' : ''}`,
                viewIcon,
                viewTitle,
                isWarning: viewIcon === 'warning',
                isEye: viewIcon === 'eye',
                _raw: row,
                cells
            };
        });
    }

    // ─── Formatting ──────────────────────────────────────────────────────

    _formatValue(val, col, row) {
        if (val == null || val === '') return '-';
        switch (col.type) {
            case 'currency':
                return formatCurrency(val, col.typeAttributes?.currencyCode);
            case 'number':
                return formatNumber(val, col);
            case 'date-local':
                return formatDate(val);
            case 'url':
                return col.typeAttributes?.label?.fieldName ? (row[col.typeAttributes.label.fieldName] || val) : val;
            default:
                return String(val);
        }
    }

    _cellClass(col, hasDraft, isEditing) {
        let cls = 'qld-cell';
        if (col.type === 'currency' || col.type === 'number') cls += ' qld-cell-right';
        if (hasDraft) cls += ' qld-cell-edited';
        if (isEditing) cls += ' qld-cell-editing';
        if (col.editable) cls += ' qld-cell-editable';
        return cls;
    }

    // ─── Sorting ─────────────────────────────────────────────────────────

    _getSortedData() {
        if (!this._sortField) return [...this._data];
        const dir = this._sortDir === 'asc' ? 1 : -1;
        const field = this._sortField;
        return [...this._data].sort((a, b) => {
            const va = a[field] ?? '';
            const vb = b[field] ?? '';
            if (va < vb) return -1 * dir;
            if (va > vb) return 1 * dir;
            return 0;
        });
    }

    handleSort(event) {
        const field = event.currentTarget.dataset.field;
        if (!field) return;
        if (this._sortField === field) {
            this._sortDir = this._sortDir === 'asc' ? 'desc' : 'asc';
        } else {
            this._sortField = field;
            this._sortDir = 'asc';
        }
    }

    getSortClass(col) {
        if (col.fieldName === this._sortField) {
            return this._sortDir === 'asc' ? 'qld-sort qld-sort-asc' : 'qld-sort qld-sort-desc';
        }
        return 'qld-sort';
    }

    // ─── Selection ───────────────────────────────────────────────────────

    handleSelectAll() {
        if (this.allSelected) {
            this._selectedIds = new Set();
        } else {
            this._selectedIds = new Set(this._data.map(r => r[this.keyField]));
        }
        this._fireSelection();
    }

    handleRowCheck(event) {
        const rowId = event.currentTarget.dataset.id;
        if (this._selectedIds.has(rowId)) {
            this._selectedIds.delete(rowId);
        } else {
            this._selectedIds.add(rowId);
        }
        this._selectedIds = new Set(this._selectedIds);
        this._fireSelection();
    }

    _fireSelection() {
        const selectedRows = this._data.filter(r => this._selectedIds.has(r[this.keyField]));
        this.dispatchEvent(new CustomEvent('rowselection', {
            detail: { selectedRows }
        }));
    }

    // ─── Row action (eye icon) ───────────────────────────────────────────

    handleViewClick(event) {
        const rowId = event.currentTarget.dataset.id;
        const row = this._data.find(r => r[this.keyField] === rowId);
        if (!row) return;
        const actionName = this.viewBtnCol?.typeAttributes?.name || 'view';
        this.dispatchEvent(new CustomEvent('rowaction', {
            detail: { action: { name: actionName }, row }
        }));
    }

    // ─── Inline editing ──────────────────────────────────────────────────

    handleCellClick(event) {
        if (this.readOnly) return;
        const { id: rowId, field } = event.currentTarget.dataset;
        if (!rowId || !field) return;
        const col = this.visibleColumns.find(c => c.fieldName === field);
        if (!col?.editable) return;
        // Row-level read-only override (e.g., ramped lines).
        // FB-815: Line Remarks stays editable on read-only ramp rows in Draft so
        // reps can correct/clear per-line remarks (incl. phase-note text that leaked in).
        const row = this._data?.find(r => r.Id === rowId);
        if (row?._readOnly && col.fieldName !== 'Line_Remarks__c') return;
        if (col.editOptions) return; // Inline select already visible
        this._editingCell = { rowId, fieldName: field };
        // Focus the input after render
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const input = this.template.querySelector(`[data-edit-id="${rowId}"][data-edit-field="${field}"]`);
            if (input) input.focus();
        }, 0);
    }

    handleEditBlur(event) {
        const { editId: rowId, editField: field } = event.currentTarget.dataset;
        const newVal = event.currentTarget.value;
        this._commitEdit(rowId, field, newVal);
    }

    handleEditKeydown(event) {
        if (event.key === 'Enter') {
            event.currentTarget.blur();
        } else if (event.key === 'Escape') {
            this._editingCell = null;
        }
    }

    _commitEdit(rowId, field, newVal) {
        const row = this._data.find(r => r[this.keyField] === rowId);
        if (!row) return;
        this._editingCell = null;

        // Compare with original
        const origVal = row[field];
        const col = this.visibleColumns.find(c => c.fieldName === field);
        let parsedVal = newVal;
        if (col && (col.type === 'currency' || col.type === 'number')) {
            parsedVal = newVal === '' ? null : Number(newVal);
        }

        if (String(parsedVal ?? '') === String(origVal ?? '')) {
            // No change — remove from drafts if present
            if (this._draftMap.has(rowId)) {
                const drafts = this._draftMap.get(rowId);
                delete drafts[field];
                if (!Object.keys(drafts).length) this._draftMap.delete(rowId);
                this._draftMap = new Map(this._draftMap);
                this._fireDraftChange();
            }
            return;
        }

        const existing = this._draftMap.get(rowId) || {};
        existing[field] = parsedVal;
        this._draftMap.set(rowId, existing);
        this._draftMap = new Map(this._draftMap);
        this._fireDraftChange();
    }

    _fireDraftChange() {
        this.dispatchEvent(new CustomEvent('draftchange', {
            detail: { hasDrafts: this.hasDrafts },
            bubbles: true, composed: true
        }));
    }

    handleSaveDrafts() {
        this.dispatchEvent(new CustomEvent('save', {
            detail: { draftValues: this._draftMapToArray() }
        }));
    }

    handleCancelDrafts() {
        this._draftMap = new Map();
        this._editingCell = null;
        this._draftSeq++;
        this._fireDraftChange();
    }

    _draftMapToArray() {
        const arr = [];
        this._draftMap.forEach((fields, rowId) => {
            arr.push({ Id: rowId, ...fields });
        });
        return arr;
    }

    // ─── Attribute picklist ──────────────────────────────────────────────

    handlePicklistChange(event) {
        event.stopPropagation();
        if (this.readOnly) return;
        const rowId = event.currentTarget.dataset.rowid;
        const value = event.currentTarget.value;
        this._commitEdit(rowId, 'Product_Attribute_Value__c', value);
    }

    handleCustomAttrChange(event) {
        event.stopPropagation();
        if (this.readOnly) return;
        const rowId = event.currentTarget.dataset.rowid;
        const value = event.target.value;
        this._commitEdit(rowId, 'Custom_Attribute_Value__c', value);
    }

    handleEditOptionChange(event) {
        event.stopPropagation();
        const rowId = event.currentTarget.dataset.id;
        const row = this._enrichedRows?.find(r => r.rowId === rowId);
        if (row?.isReadOnly) return;
        const field = event.currentTarget.dataset.field;
        const newVal = event.currentTarget.value;
        this._commitEdit(rowId, field, newVal);
    }

    // ─── Column resizing ────────────────────────────────────────────────

    handleResizeStart(event) {
        event.stopPropagation();
        event.preventDefault();
        const field = event.currentTarget.dataset.field;
        const th = this.template.querySelector(`th[data-field="${field}"]`);
        if (!th) return;
        this._resizing = { fieldName: field, startX: event.clientX, startWidth: th.offsetWidth };
        this._onMouseMove = (e) => this._doResize(e);
        this._onMouseUp = () => this._endResize();
        document.addEventListener('mousemove', this._onMouseMove);
        document.addEventListener('mouseup', this._onMouseUp);
    }

    _doResize(event) {
        if (!this._resizing) return;
        const diff = event.clientX - this._resizing.startX;
        const newW = Math.max(50, this._resizing.startWidth + diff);
        const th = this.template.querySelector(`th[data-field="${this._resizing.fieldName}"]`);
        if (th) th.style.width = `${newW}px`;
        this._resizing.currentWidth = newW;
    }

    _endResize() {
        if (this._resizing?.currentWidth) {
            this._colWidths = { ...this._colWidths, [this._resizing.fieldName]: this._resizing.currentWidth };
        }
        this._resizing = null;
        document.removeEventListener('mousemove', this._onMouseMove);
        document.removeEventListener('mouseup', this._onMouseUp);
    }

    disconnectedCallback() {
        if (this._onMouseMove) {
            document.removeEventListener('mousemove', this._onMouseMove);
            document.removeEventListener('mouseup', this._onMouseUp);
        }
    }

    stopPropagation(event) {
        event.stopPropagation();
    }
}
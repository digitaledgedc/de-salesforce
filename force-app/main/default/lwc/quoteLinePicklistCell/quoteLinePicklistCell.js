import { LightningElement, api } from 'lwc';

export default class QuoteLinePicklistCell extends LightningElement {
    @api value;
    @api rowId;
    @api hasAttribute;

    _options;

    @api
    get options() {
        return this._options;
    }
    set options(val) {
        this._options = (val || []).map(o => ({
            ...o,
            selected: o.value === this.value
        }));
    }

    get showPicklist() {
        return this.hasAttribute && Array.isArray(this._options) && this._options.length > 0;
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    handleChange(event) {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent('attributechange', {
            detail: { rowId: this.rowId, value: event.target.value },
            bubbles: true,
            composed: true
        }));
    }
}
import { LightningElement, api } from 'lwc';

export default class RecordFieldSection extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api fields;

    get fieldList() {
        if (!this.fields) return [];
        return this.fields.split(',').map(f => f.trim());
    }
}
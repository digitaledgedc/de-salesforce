import { LightningElement, api } from 'lwc';

export default class FlowNavigateToRecord extends LightningElement {
    @api recordId;
    _hasNavigated = false;

    renderedCallback() {
        if (this.recordId && !this._hasNavigated) {
            this._hasNavigated = true;
            window.open(`/lightning/r/${this.recordId}/view`, '_self');
        }
    }
}
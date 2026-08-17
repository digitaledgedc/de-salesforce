import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';

export default class ManageStakeholderAction extends LightningElement {
    @api recordId;

    get inputVariables() {
        return [{ name: 'recordId', type: 'String', value: this.recordId }];
    }

    handleStatusChange(evt) {
        if (evt.detail.status === 'FINISHED') {
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }
}
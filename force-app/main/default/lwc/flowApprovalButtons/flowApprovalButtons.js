import { LightningElement, api } from 'lwc';
import { FlowNavigationNextEvent, FlowNavigationFinishEvent } from 'lightning/flowSupport';

export default class FlowApprovalButtons extends LightningElement {
    @api approveLabel = 'Approve';
    @api rejectLabel  = 'Reject';
    @api saveLabel    = 'Save Draft';

    // Output property — flow reads this after navigation
    @api decision = '';

    handleCancel() {
        this.dispatchEvent(new FlowNavigationFinishEvent());
    }

    handleSave() {
        this.decision = 'Save';
        this.dispatchEvent(new FlowNavigationNextEvent());
    }

    handleReject() {
        this.decision = 'Reject';
        this.dispatchEvent(new FlowNavigationNextEvent());
    }

    handleApprove() {
        this.decision = 'Approve';
        this.dispatchEvent(new FlowNavigationNextEvent());
    }
}
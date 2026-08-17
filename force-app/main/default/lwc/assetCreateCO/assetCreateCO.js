import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import SOURCE_ORDER_FIELD from '@salesforce/schema/Asset.Source_Order__c';

export default class AssetCreateCO extends NavigationMixin(LightningElement) {
    @api recordId;
    isLoading = true;
    error;

    @wire(getRecord, { recordId: '$recordId', fields: [SOURCE_ORDER_FIELD] })
    wiredAsset({ data, error }) {
        if (data) {
            const orderId = getFieldValue(data, SOURCE_ORDER_FIELD);
            if (orderId) {
                // Close this action screen and navigate to the Order with the CO action open
                this.dispatchEvent(new CloseActionScreenEvent());
                this[NavigationMixin.Navigate]({
                    type: 'standard__webPage',
                    attributes: {
                        url: `/lightning/action/quick/Order.Create_Change_Order?backgroundContext=%2Flightning%2Fr%2FOrder%2F${orderId}%2Fview&objectApiName=Order&recordId=${orderId}`
                    }
                });
            } else {
                this.isLoading = false;
                this.error = 'This Asset has no Source Order. Cannot create a Change Order.';
            }
        } else if (error) {
            this.isLoading = false;
            this.error = 'Failed to load Asset: ' + (error.body ? error.body.message : JSON.stringify(error));
        }
    }
}
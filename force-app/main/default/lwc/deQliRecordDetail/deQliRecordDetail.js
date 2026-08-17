import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CUSTOM_ATTR_FIELD from '@salesforce/schema/QuoteLineItem.Custom_Attribute_Value__c';
import ID_FIELD from '@salesforce/schema/QuoteLineItem.Id';

export default class DeQliRecordDetail extends LightningElement {
    @api recordId;

    // FB-455/FB-960: Custom_Attribute_Value__c is Text on the object but must only ever
    // hold a number. lightning-record-form has no way to restrict input type per-field
    // (it renders strictly by schema type), so this field is pulled out of capacityFields
    // below and rendered here as a dedicated numeric input instead.
    @track customAttrValue;
    isSavingCustomAttr = false;

    @wire(getRecord, { recordId: '$recordId', fields: [CUSTOM_ATTR_FIELD] })
    wiredQli({ data }) {
        if (data) {
            this.customAttrValue = getFieldValue(data, CUSTOM_ATTR_FIELD);
        }
    }

    handleCustomAttrChange(event) {
        const value = event.target.value;
        this.isSavingCustomAttr = true;
        updateRecord({
            fields: {
                [ID_FIELD.fieldApiName]: this.recordId,
                [CUSTOM_ATTR_FIELD.fieldApiName]: value === '' ? null : value
            }
        })
            .then(() => {
                this.customAttrValue = value;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Saved', message: 'Custom attribute value updated.', variant: 'success'
                }));
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Save Failed',
                    message: err?.body?.message || 'Could not update Custom Attribute Value.',
                    variant: 'error'
                }));
            })
            .finally(() => { this.isSavingCustomAttr = false; });
    }

    /* ── Tab 1: Details ─────────────────────────────────────────────────
     * Core line identification, product, pricing, and charge fields.
     * Fields interleaved for 2-column rendering (col1, col2, col1, col2…)
     */
    detailFields = [
        'QuoteId',                      'Charge_Type__c',
        'Product2Id',                   'Charge_Frequency__c',
        'Product_Attribute_Value__c',   'Billing_Mode__c',
        'Quantity',                     'ListPrice',
        'UnitPrice',                    'MRC_Amount__c',
        'TotalPrice',                   'Line_Category__c'
    ];

    /* ── Tab 2: Schedule & Ramp ─────────────────────────────────────── */
    scheduleFields = [
        'StartDate',                    'EndDate',
        'Ramp_Phase__c',               'Ramp_Invoice_Display__c',
        'Ramp_Start_Date__c',          'Free_Months_Override__c',
        'SortOrder',                    'Is_Auto_NRC__c',
        'Description',                  'Line_Remarks__c'
    ];

    /* ── Tab 3: Capacity & Connectivity ─────────────────────────────── */
    capacityFields = [
        'CabE__c',                      'Power_kVA__c',
        'Inventory__c',                 'Space__c',
        'Reserved__c',                  'A_Side_Service_ID__c',
        'Z_Side_Service_ID__c',         'A_Side_Asset__c',
        'Z_Side_Asset__c'
    ];

    /* ── Tab 4: Billing & Pairing ───────────────────────────────────── */
    billingFields = [
        'Target_BAN__c',                'Line_Booking_Bucket__c',
        'Customer_PO_Line__c',          'Paired_MRC_Line__c',
        'Change_Type__c',               'Original_OrderItem__c'
    ];

    /* ── Tab 5: Integration ─────────────────────────────────────────── */
    integrationFields = [
        'Odoo_Product_ID__c',           'Odoo_Attribute_Value_ID__c'
    ];

    /* ── Tab 6: System ──────────────────────────────────────────────── */
    systemFields = [
        'CreatedById',                  'LastModifiedById'
    ];
}
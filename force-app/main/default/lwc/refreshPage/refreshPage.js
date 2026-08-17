import { LightningElement, api } from 'lwc';

export default class RefreshPage extends LightningElement {
    @api recordId;
    connectedCallback(){
        window.location.href = '/' +this.recordId;
       

    }
}
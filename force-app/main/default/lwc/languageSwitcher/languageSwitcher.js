import { LightningElement, track } from 'lwc';
import getCurrentLanguage from '@salesforce/apex/UserLanguageController.getCurrentLanguage';
import setLanguage from '@salesforce/apex/UserLanguageController.setLanguage';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const LANGUAGE_OPTIONS = [
    { label: 'English', value: 'en_US' },
    { label: '日本語 (Japanese)', value: 'ja' },
    { label: '中文简体 (Simplified Chinese)', value: 'zh_CN' },
    { label: '中文繁體 (Traditional Chinese)', value: 'zh_TW' },
    { label: '한국어 (Korean)', value: 'ko' },
    { label: 'Bahasa Indonesia', value: 'in' },
];

export default class LanguageSwitcher extends LightningElement {
    @track currentLanguage = 'en_US';
    @track isSaving = false;

    languageOptions = LANGUAGE_OPTIONS;

    connectedCallback() {
        getCurrentLanguage()
            .then(lang => {
                this.currentLanguage = lang;
            })
            .catch(() => {
                this.currentLanguage = 'en_US';
            });
    }

    get currentLanguageLabel() {
        const match = LANGUAGE_OPTIONS.find(o => o.value === this.currentLanguage);
        return match ? match.label : this.currentLanguage;
    }

    handleLanguageChange(event) {
        const selected = event.detail.value;
        if (selected === this.currentLanguage) return;
        this.isSaving = true;
        setLanguage({ languageKey: selected })
            .then(() => {
                // Language change requires a full page reload to take effect
                window.location.reload();
            })
            .catch(error => {
                this.isSaving = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error',
                    message: error.body ? error.body.message : 'Could not switch language.',
                    variant: 'error'
                }));
            });
    }
}
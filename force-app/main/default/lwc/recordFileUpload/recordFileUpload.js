// recordFileUpload.js
// Generic record file attachment component — replaces siteFileUpload.
// @api objectApiName: passed by the parent page/flexipage so the Apex controller
//   can filter Doc_Type_Visibility__mdt by both object and the running user's profile.
// Apex controller: SiteFileUploadController (rename to RecordFileUploadController
//   when the Apex class is updated to use generic `recordId` param names).

import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSiteDocumentTypes       from '@salesforce/apex/SiteFileUploadController.getSiteDocumentTypes';
import getSiteDocuments           from '@salesforce/apex/SiteFileUploadController.getSiteDocuments';
import setDocumentTypes           from '@salesforce/apex/SiteFileUploadController.setDocumentTypes';
import deleteDocument             from '@salesforce/apex/SiteFileUploadController.deleteDocument';
import deleteDocuments            from '@salesforce/apex/SiteFileUploadController.deleteDocuments';
import createDocumentTypeMetadata from '@salesforce/apex/SiteFileUploadController.createDocumentTypeMetadata';
import canManageDocuments         from '@salesforce/apex/SiteFileUploadController.canManageDocuments';
import enforceSizeLimit          from '@salesforce/apex/SiteFileUploadController.enforceSizeLimit';
import getMaxFileBytes           from '@salesforce/apex/SiteFileUploadController.getMaxFileBytes';

let _uid = 0;
const uid = () => `f-${++_uid}`;

// Colour key for file extension badges
const EXT_CLASS = {
    pdf  : 'su-ext-icon su-ext-icon--pdf',
    doc  : 'su-ext-icon su-ext-icon--doc',
    docx : 'su-ext-icon su-ext-icon--doc',
};

export default class RecordFileUpload extends LightningElement {

    // ── Public ────────────────────────────────────────────────
    @api recordId;

    // cardTitle / cardSubtitle can be set from the App Builder property panel
    // or by a parent component. Defaults are sensible for any object.
    @api cardTitle    = 'Documents';
    @api cardSubtitle = 'Manage attachments for this record';

    // objectApiName is passed so the Apex controller can filter
    // Doc_Type_Visibility__mdt by object and running user profile.
    @api objectApiName;

    // ── Upload modal state ────────────────────────────────────
    @track allDocTypes       = [];
    @track stagedFiles       = [];
    activeTabIdx             = 0;
    showUploadModal          = false;
    showInlineAddForm        = false;
    isSaving                 = false;
    isSavingDocType          = false;
    newDocTypeName           = '';
    _metaLoaded              = false;
    _pendingFiles            = [];
    // Ids of docs already on the platform but not yet typed. Cancelling the
    // modal deletes these, otherwise they linger with a blank Document_Type__c.
    _untypedDocIds           = [];

    // Size ceiling comes from Apex so there is exactly one place to change it.
    // Until the wire lands, uploads are still allowed — the server prunes
    // anything oversized regardless, so the caption is cosmetic.
    maxFileBytes             = null;

    // ── Documents list state ──────────────────────────────────
    @track existingDocuments = [];
    isLoadingDocs            = false;

    // ── Delete modal state ────────────────────────────────────
    showDeleteModal          = false;
    deleteTargetId           = null;
    deleteTargetName         = '';
    isDeleting               = false;

    // ── Permission ────────────────────────────────────────────
    userCanManage            = false;

    // ══════════════════════════════════════════════════════════
    // LIFECYCLE
    // ══════════════════════════════════════════════════════════
    connectedCallback() {
        this.loadDocuments();
    }

    // ══════════════════════════════════════════════════════════
    // WIRE: DOCUMENT TYPES
    // Apex filters Doc_Type_Visibility__mdt by the running user's profile
    // and by Object_API_Name__c matching objectApiName (when set).
    // ══════════════════════════════════════════════════════════
    @wire(getMaxFileBytes)
    wiredMaxFileBytes({ data }) {
        if (data) this.maxFileBytes = data;
    }

    @wire(canManageDocuments)
    wiredPermission({ data }) {
        if (data !== undefined) this.userCanManage = data === true;
    }

    @wire(getSiteDocumentTypes)
    wiredMeta({ data, error }) {
        if (data) {
            this.allDocTypes = data.map(r => r.documentType).filter(Boolean);
        } else if (error) {
            this._toast('Error', 'Failed to load document types.', 'error');
        }
        this._metaLoaded = true;
        if (this._pendingFiles.length) {
            const pending = [...this._pendingFiles];
            this._pendingFiles = [];
            this._stageFiles(pending);
        }
    }

    // ══════════════════════════════════════════════════════════
    // LOAD EXISTING DOCUMENTS
    // ══════════════════════════════════════════════════════════
    async loadDocuments() {
        if (!this.recordId) return;
        this.isLoadingDocs = true;
        try {
            const docs = await getSiteDocuments({ siteId: this.recordId });
            this.existingDocuments = (docs || []).map(d => ({
                ...d,
                fileSizeFormatted : this._formatSize(d.fileSizeBytes),
                extIconClass      : EXT_CLASS[d.fileExtension] || 'su-ext-icon su-ext-icon--default',
            }));
        } catch (err) {
            this._toast('Error', 'Failed to load documents.', 'error');
        } finally {
            this.isLoadingDocs = false;
        }
    }

    refreshDocuments() {
        this.loadDocuments();
    }

    // ══════════════════════════════════════════════════════════
    // COMPUTED GETTERS
    // ══════════════════════════════════════════════════════════
    get activeFile()       { return this.stagedFiles[this.activeTabIdx] || null; }
    get noDocTypes()       { return this.docTypeListItems.length === 0; }
    // _formatSize always prints one decimal, which reads oddly for a round cap
    // ("25.0 MB"), so the ceiling gets its own label.
    get maxSizeLabel() {
        if (!this.maxFileBytes) return '';
        const mb = this.maxFileBytes / 1048576;
        return (Number.isInteger(mb) ? mb : mb.toFixed(1)) + ' MB';
    }

    get maxSizeCaption() {
        return this.maxFileBytes
            ? `Any file type accepted - up to ${this.maxSizeLabel} per file`
            : 'Any file type accepted';
    }

    get hasDocuments()     { return this.existingDocuments.length > 0; }
    get hasMultipleFiles() { return this.stagedFiles.length > 1; }

    get docTypeListItems() {
        const selected = this.activeFile?.docType || '';
        return this.allDocTypes.map(dt => ({
            value      : dt,
            label      : dt,
            isSelected : dt === selected,
            itemClass  : ['su-dt-item', dt === selected ? 'su-dt-item--sel' : ''].filter(Boolean).join(' ')
        }));
    }

    get stagedFiles() {
        return this._stagedFiles || [];
    }
    set stagedFiles(val) {
        this._stagedFiles = (val || []).map((f, i) => ({
            ...f,
            rowClass : 'su-staged-row' + (i === this.activeTabIdx ? ' su-staged-row--active' : '')
        }));
    }

    // ══════════════════════════════════════════════════════════
    // UPLOAD (handled by lightning-file-upload, then type the files)
    // ══════════════════════════════════════════════════════════
    // lightning-file-upload owns both the click target and the drop target inside
    // its own shadow root. This org runs base components in native shadow, so
    // shadowRoot is null and neither can be driven from here — the component has
    // to be the visible control. Nothing below reaches across the boundary.
    // The size cap is applied here, not before the upload: lightning-file-upload
    // has no max-size attribute and has already committed the bytes by the time
    // this fires. Apex measures what landed, deletes anything oversized, and
    // returns it so those files never reach the staging modal. The upload cost is
    // unavoidable with this component — the file travels, then gets removed.
    async handleUploadFinished(event) {
        const files = event?.detail?.files || [];
        if (!files.length) return;

        let accepted = files;
        try {
            const rejected = await enforceSizeLimit({
                contentDocumentIds: files.map(f => f.documentId)
            });
            if (rejected?.length) {
                const bounced = new Set(rejected.map(r => r.contentDocumentId));
                accepted = files.filter(f => !bounced.has(f.documentId));
                const limit = this.maxSizeLabel || 'the configured maximum';
                rejected.forEach(r => this._toast(
                    'File too large',
                    `${r.fileName} is ${this._formatSize(r.fileSizeBytes)} - the limit is ${limit}. It was not attached.`,
                    'warning'
                ));
            }
        } catch (err) {
            // Could not verify size. The files are already stored, so let them
            // through to typing rather than stranding them untyped and invisible.
            this._toast(
                'Size check failed',
                err?.body?.message || 'Could not verify file size.',
                'warning'
            );
        }
        if (!accepted.length) {
            await this.loadDocuments();
            return;
        }

        this._untypedDocIds = [
            ...this._untypedDocIds,
            ...accepted.map(f => f.documentId)
        ];

        const staged = accepted.map(f => ({
            documentId : f.documentId,
            clientId   : uid(),
            fileName   : f.name,
            docType    : ''
        }));

        // Document types are wired async. If they have not landed yet, hold the
        // files until wiredMeta fires so the picker is never shown empty.
        if (!this._metaLoaded) {
            this._pendingFiles = [...this._pendingFiles, ...staged];
            return;
        }
        this._stageFiles(staged);
    }

    _stageFiles(staged) {
        this.stagedFiles     = [...(this._stagedFiles || []), ...staged];
        this.activeTabIdx    = Math.max(0, this.stagedFiles.length - staged.length);
        this.showUploadModal = true;
    }

    // ══════════════════════════════════════════════════════════
    // UPLOAD MODAL
    // ══════════════════════════════════════════════════════════
    // Cancel discards files that are ALREADY stored (lightning-file-upload wrote
    // them before this modal opened), so the untyped ContentDocuments are removed
    // rather than left behind with a blank Document_Type__c.
    async closeUploadModal() {
        const toRemove = [...this._untypedDocIds];
        this.showUploadModal   = false;
        this.stagedFiles       = [];
        this.showInlineAddForm = false;
        this._untypedDocIds    = [];
        if (!toRemove.length) return;
        try {
            await deleteDocuments({ contentDocumentIds: toRemove });
        } catch (err) {
            this._toast(
                'Cleanup Failed',
                'Upload was cancelled but the file(s) could not be removed. Delete them from the list below.',
                'warning'
            );
        }
        await this.loadDocuments();
    }
    // Deliberately does NOT close: a stray backdrop click would now delete files
    // that are already stored. Cancel and the X are the only exits.
    handleUploadBackdrop() { /* no-op while untyped files are pending */ }
    stopProp(e)            { e.stopPropagation(); }

    handleDocTypeSelect(e) {
        const val = e.currentTarget.dataset.value;
        this.stagedFiles = this.stagedFiles.map((f, i) =>
            i === this.activeTabIdx ? { ...f, docType: val } : f
        );
    }

    switchActiveFile(e) {
        const idx = parseInt(e.currentTarget.dataset.idx, 10);
        if (!isNaN(idx)) {
            this.activeTabIdx = idx;
            this.stagedFiles  = [...this.stagedFiles]; // trigger re-render for rowClass
        }
    }

    // ══════════════════════════════════════════════════════════
    // INLINE ADD TYPE
    // ══════════════════════════════════════════════════════════
    toggleInlineAddForm() {
        this.showInlineAddForm = !this.showInlineAddForm;
        if (!this.showInlineAddForm) this.newDocTypeName = '';
    }
    handleNewTypeName(e)  { this.newDocTypeName = e.target.value; }
    handleNewTypeKeyup(e) {
        if (e.key === 'Enter')  this.saveNewDocType();
        if (e.key === 'Escape') this.toggleInlineAddForm();
    }

    async saveNewDocType() {
        const name = this.newDocTypeName?.trim();
        if (!name) {
            this._toast('Required', 'Document Type Name is required.', 'warning');
            return;
        }
        const devName = name.replace(/[^a-zA-Z0-9\s]/g, '').trim().replace(/\s+/g, '_');
        if (!devName) {
            this._toast('Invalid', 'Name must contain at least one letter or number.', 'warning');
            return;
        }
        this.isSavingDocType = true;
        try {
            await createDocumentTypeMetadata({ masterLabel: name, developerName: devName });

            // Add to local list and auto-select it for the active file
            this.allDocTypes = [...this.allDocTypes, name];
            this.stagedFiles = this.stagedFiles.map((f, i) =>
                i === this.activeTabIdx ? { ...f, docType: name } : f
            );

            this._toast('Created', `"${name}" added and selected.`, 'success');
            this.showInlineAddForm = false;
            this.newDocTypeName    = '';
        } catch (err) {
            this._toast('Save Failed', err?.body?.message || 'Could not save.', 'error');
        } finally {
            this.isSavingDocType = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // SAVE & UPLOAD
    // ══════════════════════════════════════════════════════════
    async saveAndUpload() {
        const missing = this.stagedFiles.find(f => !f.docType);
        if (missing) {
            this._toast('Validation', `Select a Document Type for "${missing.fileName}"`, 'warning');
            return;
        }
        if (!this.recordId) {
            this._toast('Error', 'No record ID on this component.', 'error');
            return;
        }
        this.isSaving = true;
        try {
            // Files are already stored and linked to the record by
            // lightning-file-upload. This only stamps Document_Type__c.
            await setDocumentTypes({
                assignments: this.stagedFiles.map(f => ({
                    contentDocumentId : f.documentId,
                    docType           : f.docType
                }))
            });
            this.stagedFiles       = [];
            this.showUploadModal   = false;
            this.showInlineAddForm = false;
            this._untypedDocIds    = [];
            this._toast('Uploaded', 'File(s) attached successfully.', 'success');
            this.dispatchEvent(new CustomEvent('savedfiles'));
            await this.loadDocuments();
        } catch (err) {
            this._toast('Upload Failed', err?.body?.message || 'Upload failed.', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // DELETE
    // ══════════════════════════════════════════════════════════
    openDeleteConfirm(e) {
        this.deleteTargetId   = e.currentTarget.dataset.id;
        this.deleteTargetName = e.currentTarget.dataset.name;
        this.showDeleteModal  = true;
    }
    closeDeleteConfirm() {
        this.showDeleteModal  = false;
        this.deleteTargetId   = null;
        this.deleteTargetName = '';
    }

    async confirmDelete() {
        if (!this.deleteTargetId) return;
        this.isDeleting = true;
        try {
            await deleteDocument({ contentDocumentId: this.deleteTargetId });
            this._toast('Deleted', 'Document removed successfully.', 'success');
            this.closeDeleteConfirm();
            await this.loadDocuments();
        } catch (err) {
            this._toast('Delete Failed', err?.body?.message || 'Delete failed.', 'error');
        } finally {
            this.isDeleting = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════
    _formatSize(bytes) {
        if (!bytes) return '-';
        if (bytes < 1024)       return bytes + ' B';
        if (bytes < 1048576)    return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / 1048576).toFixed(1) + ' MB';
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
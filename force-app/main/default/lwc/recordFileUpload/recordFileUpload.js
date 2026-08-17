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
import uploadFilesToSite          from '@salesforce/apex/SiteFileUploadController.uploadFilesToSite';
import deleteDocument             from '@salesforce/apex/SiteFileUploadController.deleteDocument';
import createDocumentTypeMetadata from '@salesforce/apex/SiteFileUploadController.createDocumentTypeMetadata';
import canManageDocuments         from '@salesforce/apex/SiteFileUploadController.canManageDocuments';

const MAX_SIZE = 5 * 1024 * 1024;
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
    isDragging               = false;
    newDocTypeName           = '';
    _metaLoaded              = false;
    _pendingFiles            = [];

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
    get hasDocuments()     { return this.existingDocuments.length > 0; }
    get hasMultipleFiles() { return this.stagedFiles.length > 1; }
    get dropZoneClass()    { return 'su-dropzone' + (this.isDragging ? ' su-dropzone--active' : ''); }

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
    // FILE PICKER / DRAG-DROP
    // ══════════════════════════════════════════════════════════
    triggerFilePicker() {
        this.template.querySelector('[data-id="fileInput"]').click();
    }
    handleDragOver(e)  { e.preventDefault(); this.isDragging = true; }
    handleDragLeave()  { this.isDragging = false; }
    handleDrop(e) {
        e.preventDefault();
        this.isDragging = false;
        this.processFiles([...e.dataTransfer.files]);
    }
    handleFileInputChange(e) {
        this.processFiles([...e.target.files]);
        e.target.value = '';
    }

    processFiles(files) {
        const valid = [];
        for (const f of files) {
            if (f.size > MAX_SIZE) {
                this._toast('File too large', `${f.name} exceeds 5 MB.`, 'warning');
                continue;
            }
            valid.push(f);
        }
        if (!valid.length) return;
        if (!this._metaLoaded) {
            this._pendingFiles = [...this._pendingFiles, ...valid];
            return;
        }
        this._stageFiles(valid);
    }

    _stageFiles(files) {
        const staged = files.map(f => ({
            raw      : f,
            clientId : uid(),
            fileName : f.name,
            docType  : ''
        }));
        this.stagedFiles     = [...(this._stagedFiles || []), ...staged];
        this.activeTabIdx    = Math.max(0, this.stagedFiles.length - staged.length);
        this.showUploadModal = true;
    }

    // ══════════════════════════════════════════════════════════
    // UPLOAD MODAL
    // ══════════════════════════════════════════════════════════
    closeUploadModal() {
        this.showUploadModal   = false;
        this.stagedFiles       = [];
        this.showInlineAddForm = false;
    }
    handleUploadBackdrop() { this.closeUploadModal(); }
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
            const fileItems = await Promise.all(
                this.stagedFiles.map(async f => ({
                    fileName    : f.fileName,
                    base64Data  : await this._toBase64(f.raw),
                    contentType : f.raw.type || 'application/octet-stream',
                    docType     : f.docType
                }))
            );
            await uploadFilesToSite({ siteId: this.recordId, files: fileItems });
            this.stagedFiles       = [];
            this.showUploadModal   = false;
            this.showInlineAddForm = false;
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
    _toBase64(file) {
        return new Promise((res, rej) => {
            const r = new FileReader();
            r.onload  = () => res(r.result.split(',')[1]);
            r.onerror = () => rej(new Error('File read failed'));
            r.readAsDataURL(file);
        });
    }

    _formatSize(bytes) {
        if (!bytes) return '—';
        if (bytes < 1024)       return bytes + ' B';
        if (bytes < 1048576)    return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / 1048576).toFixed(1) + ' MB';
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
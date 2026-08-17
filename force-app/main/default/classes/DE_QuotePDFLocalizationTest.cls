@IsTest
private class DE_QuotePDFLocalizationTest {
    @IsTest
    static void normalizesAndMapsLanguages() {
        System.assertEquals('ja', DE_QuotePDFLocalization.normalizeLanguage('ja'));
        System.assertEquals('en_US', DE_QuotePDFLocalization.normalizeLanguage('invalid'));
        System.assertEquals('zh_CN', DE_QuotePDFLocalization.languageFromAccountPreference('Chinese'));
        System.assertEquals('en_US', DE_QuotePDFLocalization.languageFromAccountPreference(null));
        System.assert(DE_QuotePDFLocalization.preferenceMatches('Traditional Chinese', 'zh_TW'));
        System.assert(!DE_QuotePDFLocalization.preferenceMatches('Japanese', 'ko'));
    }

    @IsTest
    static void resolvesLabelsAndBuildsNonBindingTerms() {
        System.assertEquals('Quotation', DE_QuotePDFLocalization.label('PDF_Title_New_NonBinding', 'en_US'));
        System.assertEquals('Quote Number', DE_QuotePDFLocalization.label('Header_Quote_Number', 'en_US'));
        System.assertEquals(
            'Quote Number',
            DE_QuotePDFLocalization.labels('en_US').get('Header_Quote_Number'),
            'Quote Number label must be exposed in the pdfLabels map (FB-785)'
        );
        System.assertEquals(
            'Change Order',
            DE_QuotePDFLocalization.label('PDF_Title_Change_Binding', 'ko'),
            'Missing Korean translation must fall back to English'
        );
        String terms = DE_QuotePDFLocalization.buildNonBindingTermsHtml('ja');
        System.assert(terms.startsWith('<ol'));
        System.assertEquals(5, terms.split('<li>').size(), 'Four list items expected');
        System.assert(!terms.contains('Terms and Conditions'), 'VF owns the terms heading');

        System.assertEquals('Quotation', DE_QuotePDFLocalization.quoteTitle(false, false, 'en_US'));
        System.assertEquals('Service Order', DE_QuotePDFLocalization.quoteTitle(false, true, 'en_US'));
        System.assertEquals('Change Quotation', DE_QuotePDFLocalization.quoteTitle(true, false, 'en_US'));
        System.assertEquals(
            'Change Order',
            DE_QuotePDFLocalization.quoteTitle(true, true, 'ko'),
            'Unevidenced Korean title falls back to English'
        );
    }

    @IsTest
    static void formatsDatesWithoutUserLocaleDependency() {
        Date sample = Date.newInstance(2026, 7, 2);
        System.assertEquals('02-Jul-2026', DE_QuotePDFLocalization.formatDate(sample, 'en_US'));
        System.assertEquals('2026年7月2日', DE_QuotePDFLocalization.formatDate(sample, 'ja'));
        System.assertEquals('2026年7月2日', DE_QuotePDFLocalization.formatDate(sample, 'zh_CN'));
        System.assertEquals('2026년 7월 2일', DE_QuotePDFLocalization.formatDate(sample, 'ko'));
    }
}
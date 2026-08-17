global class CreditRollupSchedulable implements Schedulable {

    public static final String JOB_NAME = 'DE Credit Rollup Nightly';

    public static final String DEFAULT_CRON = '0 0 2 * * ?';

    @TestVisible
    private static Integer batchSize = 200;

    @TestVisible
    private static String jobNameOverride;

    private static String jobName() {
        return jobNameOverride != null ? jobNameOverride : JOB_NAME;
    }

    global void execute(SchedulableContext sc) {
        Database.executeBatch(new CreditRollupBatch(), batchSize);
    }

    public static Id schedule() {
        return schedule(DEFAULT_CRON);
    }

    public static Id schedule(String cron) {
        abort();
        return System.schedule(jobName(), cron, new CreditRollupSchedulable());
    }

    public static Integer abort() {
        Integer removed = 0;
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :jobName()
        ]) {
            System.abortJob(ct.Id);
            removed++;
        }
        return removed;
    }

    public static CronTrigger currentSchedule() {
        List<CronTrigger> found = [
            SELECT Id, CronExpression, State, NextFireTime, TimesTriggered,
                   CreatedBy.Name, CreatedBy.TimeZoneSidKey
            FROM CronTrigger
            WHERE CronJobDetail.Name = :jobName()
            LIMIT 1
        ];
        return found.isEmpty() ? null : found[0];
    }
}
public with sharing class EventTimelineController {

    private static final Integer MAX_ROWS_PER_SOURCE = 300;
    private static final Integer USER_SEARCH_LIMIT   = 25;

    // ── Outbound DTOs ──────────────────────────────────────────────────────────

    public class UserOption {
        @AuraEnabled public String id;       // 18-char Id
        @AuraEnabled public String label;    // Name
        @AuraEnabled public String sublabel; // Username
    }

    public class DetailItem {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public DetailItem(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class TimelineEvent {
        @AuraEnabled public String id;
        @AuraEnabled public Long   sortMs;     // epoch ms for client-side ordering
        @AuraEnabled public String timeIso;    // ISO 8601 (GMT)
        @AuraEnabled public String category;   // Login, REST API, Report, ...
        @AuraEnabled public String source;     // ELO API name
        @AuraEnabled public String title;
        @AuraEnabled public String subtitle;
        @AuraEnabled public String iconName;
        @AuraEnabled public String color;      // hex
        @AuraEnabled public String loginKey;
        @AuraEnabled public String sessionKey;
        @AuraEnabled public String requestId;
        @AuraEnabled public List<DetailItem> details = new List<DetailItem>();
    }

    public class SessionGroup {
        @AuraEnabled public String key;          // loginKey (or fallback)
        @AuraEnabled public String label;        // friendly session label
        @AuraEnabled public Boolean hasLogin;
        @AuraEnabled public String loginTimeIso;
        @AuraEnabled public String sourceIp;
        @AuraEnabled public String loginType;
        @AuraEnabled public String status;
        @AuraEnabled public String application;
        @AuraEnabled public String platform;
        @AuraEnabled public String browser;
        @AuraEnabled public Integer eventCount;
        @AuraEnabled public List<TimelineEvent> events = new List<TimelineEvent>();
        public Long earliestMs = null;
    }

    public class TimelineResponse {
        @AuraEnabled public String userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String userIdentifier15;
        @AuraEnabled public Integer totalEvents = 0;
        @AuraEnabled public List<SessionGroup> sessions = new List<SessionGroup>();
        @AuraEnabled public List<String> sourcesQueried = new List<String>();
        @AuraEnabled public List<String> warnings = new List<String>();
    }

    // ── Internal source configuration ──────────────────────────────────────────

    private class SourceConfig {
        String objApi;
        String category;
        String iconName;
        String color;
        List<String> primaryFields;  // used to build the subtitle (first non-blank wins / joined)
        List<String> detailFields;   // shown in the expandable details
        SourceConfig(String objApi, String category, String iconName, String color,
                     List<String> primaryFields, List<String> detailFields) {
            this.objApi        = objApi;
            this.category      = category;
            this.iconName      = iconName;
            this.color         = color;
            this.primaryFields = primaryFields;
            this.detailFields  = detailFields;
        }
    }

    private static List<SourceConfig> sourceConfigs() {
        return new List<SourceConfig>{
            new SourceConfig('LoginEventLog', 'Login', 'utility:login', '#10b981',
                new List<String>{ 'Status', 'LoginType' },
                new List<String>{ 'SourceIp', 'LoginType', 'Status', 'Application', 'Platform', 'Browser', 'Uri' }),
            new SourceConfig('LogoutEventLog', 'Logout', 'utility:logout', '#14b8a6',
                new List<String>{ 'SessionType' },
                new List<String>{ 'SessionType', 'SourceIp', 'Application', 'Platform' }),
            new SourceConfig('LightningPageViewEventLog', 'Page View', 'utility:preview', '#3b82f6',
                new List<String>{ 'PageEntityType', 'PageEntityId' },
                new List<String>{ 'PageEntityType', 'PageEntityId', 'Duration', 'ClientIp', 'UserAgent', 'AppName' }),
            new SourceConfig('ReportEventLog', 'Report', 'utility:report', '#d946ef',
                new List<String>{ 'Origin', 'ObjectName' },
                new List<String>{ 'Origin', 'ReportIdentifier', 'ObjectName', 'RowCount', 'AverageRowSize', 'Uri', 'ClientIp' }),
            new SourceConfig('ReportExportEventLog', 'Report Export', 'utility:download', '#ec4899',
                new List<String>{ 'ReportDescription' },
                new List<String>{ 'ReportDescription', 'SourceIp', 'Uri' }),
            new SourceConfig('RestApiEventLog', 'REST API', 'utility:integration', '#f59e0b',
                new List<String>{ 'Method', 'EntityName' },
                new List<String>{ 'Method', 'EntityName', 'StatusCode', 'RowsProcessed', 'ClientIp', 'Uri' }),
            new SourceConfig('BulkApiEventLog', 'Bulk API', 'utility:upload', '#f97316',
                new List<String>{ 'EntityName' },
                new List<String>{ 'EntityName', 'RowsProcessed', 'ClientIp' }),
            new SourceConfig('ApexExecutionEventLog', 'Apex', 'utility:apex', '#6366f1',
                new List<String>{ 'EntryPoint', 'Quiddity' },
                new List<String>{ 'EntryPoint', 'Quiddity', 'RunTime', 'CalloutTotalTime', 'NumSoqlQueries' }),
            new SourceConfig('SearchEventLog', 'Search', 'utility:search', '#8b5cf6',
                new List<String>{ 'QueryString' },
                new List<String>{ 'QueryString', 'NumResults', 'ClientIp' })
        };
    }

    // ── User search ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<UserOption> searchUsers(String term) {
        List<UserOption> out = new List<UserOption>();
        if (String.isBlank(term) || term.length() < 2) {
            return out;
        }
        String likeTerm = '%' + String.escapeSingleQuotes(term.trim()) + '%';
        for (User u : [
            SELECT Id, Name, Username
            FROM   User
            WHERE  IsActive = true
            AND    (Name LIKE :likeTerm OR Username LIKE :likeTerm)
            ORDER  BY Name
            LIMIT  :USER_SEARCH_LIMIT
        ]) {
            UserOption o = new UserOption();
            o.id       = u.Id;
            o.label    = u.Name;
            o.sublabel = u.Username;
            out.add(o);
        }
        return out;
    }

    // ── Timeline builder ───────────────────────────────────────────────────────

    @AuraEnabled
    public static TimelineResponse buildTimeline(String userId, Long startMs, Long endMs) {
        TimelineResponse resp = new TimelineResponse();

        if (String.isBlank(userId)) {
            throw new AuraHandledException('Select a user first.');
        }

        // Default to the last 24 hours when no range supplied.
        if (endMs == null)   { endMs   = System.now().getTime(); }
        if (startMs == null) { startMs = endMs - (24L * 60L * 60L * 1000L); }
        if (startMs > endMs) { Long tmp = startMs; startMs = endMs; endMs = tmp; }

        Datetime startDt = Datetime.newInstance(startMs);
        Datetime endDt   = Datetime.newInstance(endMs);

        // ELO UserIdentifier is the 15-char Id; match both casings just in case.
        String id18 = userId;
        String id15 = userId.length() >= 15 ? userId.substring(0, 15) : userId;
        Set<String> uidSet = new Set<String>{ id15, id18 };
        resp.userIdentifier15 = id15;

        try {
            User u = [SELECT Id, Name FROM User WHERE Id = :userId LIMIT 1];
            resp.userId   = u.Id;
            resp.userName = u.Name;
        } catch (Exception e) {
            resp.userId = userId;
        }

        if ((endMs - startMs) > (15L * 24L * 60L * 60L * 1000L)) {
            resp.warnings.add('Range exceeds 15 days. Event Log Objects allow at most 15 days per query, so some sources may return nothing.');
        }

        Integer maxRows = MAX_ROWS_PER_SOURCE;
        Map<String, SessionGroup> groups = new Map<String, SessionGroup>();

        for (SourceConfig cfg : sourceConfigs()) {
            // Build the field set: core correlation fields + display fields.
            Set<String> fieldSet = new Set<String>{
                'Timestamp', 'UserIdentifier', 'LoginKey', 'SessionKey', 'RequestIdentifier'
            };
            fieldSet.addAll(cfg.primaryFields);
            fieldSet.addAll(cfg.detailFields);

            List<SObject> rows = null;
            try {
                String soql = 'SELECT ' + String.join(new List<String>(fieldSet), ', ')
                    + ' FROM ' + cfg.objApi
                    + ' WHERE UserIdentifier IN :uidSet'
                    + ' AND Timestamp >= :startDt AND Timestamp <= :endDt'
                    + ' ORDER BY Timestamp ASC LIMIT :maxRows';
                rows = Database.query(soql);
            } catch (Exception exRich) {
                // A display field may not exist in this org/API version; retry with
                // just the core correlation fields so the events still appear.
                try {
                    String soqlCore = 'SELECT Timestamp, UserIdentifier, LoginKey, SessionKey, RequestIdentifier'
                        + ' FROM ' + cfg.objApi
                        + ' WHERE UserIdentifier IN :uidSet'
                        + ' AND Timestamp >= :startDt AND Timestamp <= :endDt'
                        + ' ORDER BY Timestamp ASC LIMIT :maxRows';
                    rows = Database.query(soqlCore);
                } catch (Exception exCore) {
                    // Object not available / not licensed / no access — skip gracefully.
                    resp.warnings.add(cfg.objApi + ': not available (' + exCore.getMessage() + ')');
                    continue;
                }
            }

            resp.sourcesQueried.add(cfg.objApi + ' (' + rows.size() + ')');

            for (SObject so : rows) {
                TimelineEvent te = mapEvent(so, cfg);
                if (te == null) { continue; }
                resp.totalEvents++;

                String groupKey = String.isNotBlank(te.loginKey) ? te.loginKey
                    : (String.isNotBlank(te.sessionKey) ? 'sess:' + te.sessionKey : '__unattributed__');

                SessionGroup g = groups.get(groupKey);
                if (g == null) {
                    g = new SessionGroup();
                    g.key = groupKey;
                    groups.put(groupKey, g);
                }
                g.events.add(te);
                if (g.earliestMs == null || (te.sortMs != null && te.sortMs < g.earliestMs)) {
                    g.earliestMs = te.sortMs;
                }

                // Enrich the session header from the login event itself.
                if (cfg.category == 'Login') {
                    g.hasLogin     = true;
                    g.loginTimeIso = te.timeIso;
                    g.sourceIp     = detailValue(te, 'Source Ip');
                    g.loginType    = detailValue(te, 'Login Type');
                    g.status       = detailValue(te, 'Status');
                    g.application  = detailValue(te, 'Application');
                    g.platform     = detailValue(te, 'Platform');
                    g.browser      = detailValue(te, 'Browser');
                }
            }
        }

        // Finalize groups: sort events chronologically, build labels, sort sessions.
        for (SessionGroup g : groups.values()) {
            g.events.sort(new EventAscComparator());
            g.eventCount = g.events.size();
            if (g.key == '__unattributed__') {
                g.label = 'Unattributed activity (no LoginKey)';
            } else if (g.key.startsWith('sess:')) {
                g.label = 'Session ' + g.key.substring(5);
            } else {
                g.label = 'Session ' + g.key;
            }
            resp.sessions.add(g);
        }
        resp.sessions.sort(new SessionDescComparator());

        return resp;
    }

    // ── Mapping helpers ──────────────────────────────────────────────────────

    private static TimelineEvent mapEvent(SObject so, SourceConfig cfg) {
        Datetime ts = (Datetime) safeGetObj(so, 'Timestamp');
        TimelineEvent te = new TimelineEvent();
        te.category   = cfg.category;
        te.source     = cfg.objApi;
        te.iconName   = cfg.iconName;
        te.color      = cfg.color;
        te.loginKey   = safeGet(so, 'LoginKey');
        te.sessionKey = safeGet(so, 'SessionKey');
        te.requestId  = safeGet(so, 'RequestIdentifier');
        te.timeIso    = ts != null ? ts.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
        te.sortMs     = ts != null ? ts.getTime() : 0;
        te.id         = cfg.objApi + ':' + String.valueOf(te.sortMs) + ':'
                      + (String.isNotBlank(te.requestId) ? te.requestId : String.valueOf(Math.abs(Crypto.getRandomLong())));

        // Build detail items from configured display fields (only those present + non-blank).
        Set<String> seen = new Set<String>();
        List<String> displayFields = new List<String>();
        displayFields.addAll(cfg.primaryFields);
        displayFields.addAll(cfg.detailFields);
        for (String f : displayFields) {
            if (seen.contains(f)) { continue; }
            seen.add(f);
            String v = safeGet(so, f);
            if (String.isNotBlank(v)) {
                te.details.add(new DetailItem(humanize(f), v));
            }
        }

        // Subtitle = joined non-blank primary field values.
        List<String> subParts = new List<String>();
        for (String f : cfg.primaryFields) {
            String v = safeGet(so, f);
            if (String.isNotBlank(v)) { subParts.add(v); }
        }
        te.title    = cfg.category;
        te.subtitle = String.join(subParts, '  ·  ');
        return te;
    }

    private static String detailValue(TimelineEvent te, String label) {
        for (DetailItem d : te.details) {
            if (d.label == label) { return d.value; }
        }
        return null;
    }

    private static Object safeGetObj(SObject so, String field) {
        try { return so.get(field); }
        catch (Exception e) { return null; }
    }

    private static String safeGet(SObject so, String field) {
        try {
            Object v = so.get(field);
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }

    private static String humanize(String field) {
        if (String.isBlank(field)) { return field; }
        String out = field.replaceAll('([a-z0-9])([A-Z])', '$1 $2');
        out = out.replaceAll('_', ' ');
        return out.substring(0, 1).toUpperCase() + out.substring(1);
    }

    // ── Comparators ──────────────────────────────────────────────────────────

    private class EventAscComparator implements Comparator<TimelineEvent> {
        public Integer compare(TimelineEvent a, TimelineEvent b) {
            Long am = a.sortMs == null ? 0 : a.sortMs;
            Long bm = b.sortMs == null ? 0 : b.sortMs;
            if (am == bm) { return 0; }
            return am < bm ? -1 : 1;
        }
    }

    private class SessionDescComparator implements Comparator<SessionGroup> {
        public Integer compare(SessionGroup a, SessionGroup b) {
            Long am = a.earliestMs == null ? 0 : a.earliestMs;
            Long bm = b.earliestMs == null ? 0 : b.earliestMs;
            if (am == bm) { return 0; }
            return am > bm ? -1 : 1; // most recent session first
        }
    }
}

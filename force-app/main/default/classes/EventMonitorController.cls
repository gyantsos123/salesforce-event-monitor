public with sharing class EventMonitorController {

    // On the first load (sinceEpochMs = 0) go back HISTORY_HOURS to populate history.
    // On subsequent polls we only look back POLL_LOOKBACK_SECONDS to catch new events.
    private static final Integer HISTORY_HOURS          = 8;
    // Salesforce documents RTEM BigObject ingestion delay as up to 60 minutes.
    // Use 90 min so any event that recently became queryable is included.
    private static final Integer POLL_LOOKBACK_MINUTES  = 90;
    private static final Integer MAX_ROWS_PER_TYPE      = 50;

    public class EventRecord {
        @AuraEnabled public String  id;
        @AuraEnabled public String  eventType;
        @AuraEnabled public String  channel;
        @AuraEnabled public String  username;
        @AuraEnabled public String  sourceIp;
        @AuraEnabled public String  eventDate;   // ISO8601
        @AuraEnabled public String  payloadJson; // full record as JSON for the detail modal
        // key display fields
        @AuraEnabled public String  method;
        @AuraEnabled public String  uri;
        @AuraEnabled public String  status;
        @AuraEnabled public String  loginType;
        @AuraEnabled public String  browser;
        @AuraEnabled public String  appName;
        @AuraEnabled public String  entityType;
        @AuraEnabled public String  reportId;
        @AuraEnabled public Integer rowsProcessed;
        // origin / icon helpers
        @AuraEnabled public String  client;  // ApiEvent.Client — identifies CLI, Workbench, etc.
        @AuraEnabled public String  botId;   // ApiEvent.BotId  — set when Agentforce triggered the call
        // session correlation fields (high-value for observability)
        @AuraEnabled public String  loginHistoryId;
        @AuraEnabled public String  loginKey;
        @AuraEnabled public String  sessionKey;
        @AuraEnabled public String  operationStatus;
        @AuraEnabled public String  records;  // JSON with queried record IDs
    }

    /**
     * Called by the LWC every ~20 seconds.
     * @param sinceEpochMs – JS Date.now() value of last seen event (0 = first load)
     */
    @AuraEnabled(cacheable=false)
    public static List<EventRecord> getRecentEvents(Long sinceEpochMs, Long callTs) {
        DateTime cutoff;
        if (sinceEpochMs != null && sinceEpochMs > 0) {
            // Ongoing poll — always look back POLL_LOOKBACK_MINUTES to account for
            // RTEM BigObject ingestion delay (up to ~30 min). Deduplication in the
            // LWC via _seenIds prevents already-displayed events from re-appearing.
            cutoff = DateTime.now().addMinutes(-POLL_LOOKBACK_MINUTES);
        } else {
            // First load — return full history window
            cutoff = DateTime.now().addHours(-HISTORY_HOURS);
        }

        List<EventRecord> results = new List<EventRecord>();

        results.addAll(queryLoginEvents(cutoff));
        results.addAll(queryApiEvents(cutoff));
        results.addAll(queryLightningUriEvents(cutoff));
        results.addAll(queryUriEvents(cutoff));
        results.addAll(queryListViewEvents(cutoff));
        results.addAll(queryReportEvents(cutoff));

        // Sort newest first
        results.sort(new EventDateComparator());
        return results;
    }

    // ── Per-type queries ──────────────────────────────────────────────────────

    private static List<EventRecord> queryLoginEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (LoginEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, LoginType, Status, Browser, LoginUrl,
                       SessionLevel, Application, ApiType, LoginHistoryId, LoginKey, SessionKey, LoginSubType,
                       UserId, Platform, TlsProtocol, PolicyOutcome
                FROM   LoginEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                r.id           = e.EventIdentifier;
                r.eventType    = 'Login';
                r.channel      = '/event/LoginEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.loginType    = e.LoginType;
                r.status       = e.Status;
                r.browser      = e.Browser;
                r.appName      = e.Application;
                r.client       = e.ApiType;
                // Session correlation fields
                r.loginHistoryId = e.LoginHistoryId;
                r.loginKey       = e.LoginKey;
                r.sessionKey     = e.SessionKey;
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username'       => e.Username,       'SourceIp'       => e.SourceIp,
                    'LoginType'      => e.LoginType,      'Status'         => e.Status,
                    'Browser'        => e.Browser,        'LoginUrl'       => e.LoginUrl,
                    'SessionLevel'   => e.SessionLevel,   'Application'    => e.Application,
                    'ApiType'        => e.ApiType,        'LoginHistoryId' => e.LoginHistoryId,
                    'LoginKey'       => e.LoginKey,       'SessionKey'     => e.SessionKey,
                    'LoginSubType'   => e.LoginSubType,   'UserId'         => e.UserId,
                    'Platform'       => e.Platform,       'TlsProtocol'    => e.TlsProtocol,
                    'PolicyOutcome'  => e.PolicyOutcome
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    private static List<EventRecord> queryApiEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (ApiEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, Operation, Query, RowsProcessed,
                       ApiType, Application, Client, ElapsedTime, QueriedEntities, ConnectedAppId, BotId,
                       LoginHistoryId, LoginKey, SessionKey, OperationStatus, Records
                FROM   ApiEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                // ApiEvent.Id is a non-unique placeholder (000000000000000AAA) for every row;
                // EventIdentifier is the unique key used for card keys and modal lookup.
                r.id           = e.EventIdentifier;
                r.eventType    = 'API';
                r.channel      = '/event/ApiEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.method       = e.Operation;
                r.uri          = e.Query;
                r.rowsProcessed = e.RowsProcessed != null ? Integer.valueOf(e.RowsProcessed) : null;
                r.client       = e.Client;
                // High-value session correlation fields
                r.loginHistoryId  = e.LoginHistoryId;
                r.loginKey        = e.LoginKey;
                r.sessionKey      = e.SessionKey;
                r.operationStatus = e.OperationStatus;
                r.records         = e.Records;
                // Use BotId directly when Salesforce populates it (Agentforce sessions).
                // Fall back to Client-based detection for SfdcInternalAPI calls where
                // BotId may not yet be populated by the platform.
                if (String.isNotBlank(e.BotId)) {
                    r.botId = e.BotId;
                } else if (String.isNotBlank(e.Client) && (
                    e.Client.startsWithIgnoreCase('SfdcInternalAPI') ||
                    e.Client.containsIgnoreCase('agentforce') ||
                    e.Client.containsIgnoreCase('einstein') ||
                    e.Client.containsIgnoreCase('bot')
                )) {
                    r.botId = e.Client;
                }
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username'        => e.Username,       'SourceIp'        => e.SourceIp,
                    'Operation'       => e.Operation,      'Query'           => e.Query,
                    'RowsProcessed'   => r.rowsProcessed,  'ApiType'         => e.ApiType,
                    'Application'     => e.Application,    'Client'          => e.Client,
                    'ElapsedTime'     => e.ElapsedTime,    'QueriedEntities' => e.QueriedEntities,
                    'ConnectedAppId'  => e.ConnectedAppId, 'BotId'           => e.BotId,
                    'LoginHistoryId'  => e.LoginHistoryId, 'LoginKey'        => e.LoginKey,
                    'SessionKey'      => e.SessionKey,     'OperationStatus' => e.OperationStatus,
                    'Records'         => e.Records
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    private static List<EventRecord> queryLightningUriEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (LightningUriEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, PageUrl, AppName, Duration, Operation, UserAgent
                FROM   LightningUriEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                r.id           = e.EventIdentifier;
                r.eventType    = 'Lightning UI';
                r.channel      = '/event/LightningUriEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.uri          = e.PageUrl;
                r.appName      = e.AppName;
                r.browser      = e.UserAgent;
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username'  => e.Username,  'SourceIp'  => e.SourceIp,
                    'PageUrl'   => e.PageUrl,   'AppName'   => e.AppName,
                    'Duration'  => e.Duration,  'Operation' => e.Operation,
                    'UserAgent' => e.UserAgent
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    private static List<EventRecord> queryUriEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (UriEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, Operation, Name, Message
                FROM   UriEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                r.id           = e.EventIdentifier;
                r.eventType    = 'Classic UI';
                r.channel      = '/event/UriEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.uri          = e.Name;
                r.method       = e.Operation;
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username'  => e.Username,  'SourceIp' => e.SourceIp,
                    'Name'      => e.Name,      'Operation' => e.Operation,
                    'Message'   => e.Message
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    private static List<EventRecord> queryListViewEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (ListViewEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, QueriedEntities, RowsProcessed, Name, AppName
                FROM   ListViewEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                r.id           = e.EventIdentifier;
                r.eventType    = 'List View';
                r.channel      = '/event/ListViewEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.entityType   = e.QueriedEntities;
                r.appName      = e.AppName;
                r.rowsProcessed = e.RowsProcessed != null ? Integer.valueOf(e.RowsProcessed) : null;
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username' => e.Username, 'SourceIp' => e.SourceIp,
                    'QueriedEntities' => e.QueriedEntities, 'RowsProcessed' => r.rowsProcessed,
                    'Name' => e.Name, 'AppName' => e.AppName
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    private static List<EventRecord> queryReportEvents(DateTime cutoff) {
        List<EventRecord> out = new List<EventRecord>();
        try {
            for (ReportEvent e : [
                SELECT EventIdentifier, EventDate, Username, SourceIp, Name, RowsProcessed, Format
                FROM   ReportEvent
                WHERE  EventDate > :cutoff
                ORDER  BY EventDate DESC
                LIMIT  :MAX_ROWS_PER_TYPE
            ]) {
                EventRecord r  = new EventRecord();
                r.id           = e.EventIdentifier;
                r.eventType    = 'Report';
                r.channel      = '/event/ReportEvent';
                r.username     = e.Username;
                r.sourceIp     = e.SourceIp;
                r.eventDate    = e.EventDate != null ? e.EventDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'') : null;
                r.reportId     = e.Name;
                r.rowsProcessed = e.RowsProcessed != null ? Integer.valueOf(e.RowsProcessed) : null;
                r.payloadJson  = JSON.serialize(new Map<String,Object>{
                    'Username' => e.Username, 'SourceIp' => e.SourceIp,
                    'Name'     => e.Name,     'RowsProcessed' => r.rowsProcessed,
                    'Format'   => e.Format
                });
                out.add(r);
            }
        } catch (Exception ex) { /* event type may not be licensed */ }
        return out;
    }

    // ── Comparator ───────────────────────────────────────────────────────────

    private class EventDateComparator implements Comparator<EventRecord> {
        public Integer compare(EventRecord a, EventRecord b) {
            if (a.eventDate == null && b.eventDate == null) return 0;
            if (a.eventDate == null) return 1;
            if (b.eventDate == null) return -1;
            return b.eventDate.compareTo(a.eventDate); // newest first
        }
    }
}

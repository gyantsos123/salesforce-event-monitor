import { LightningElement, track } from 'lwc';
import getRecentEvents from '@salesforce/apex/EventMonitorController.getRecentEvents';

// ── Constants ─────────────────────────────────────────────────────────────────

const MAX_EVENTS    = 100; // retained in the scrollable feed (Apex returns up to ~50/type)
const POLL_INTERVAL = 5000; // ms

const CHANNEL_CONFIG = {
    '/event/LoginEvent':       { label: 'Login',       defaultColor: 'green',
        getColor: () => 'green' },
    '/event/ApiEvent':         { label: 'API',         defaultColor: 'yellow',
        getColor: (r) => ['POST','PUT','PATCH','DELETE'].includes((r.method||'').toUpperCase()) ? 'red' : 'yellow' },
    '/event/LightningUriEvent':{ label: 'Lightning UI', defaultColor: 'blue',
        getColor: () => 'blue' },
    '/event/UriEvent':         { label: 'Classic UI',  defaultColor: 'indigo',
        getColor: () => 'indigo' },
    '/event/ListViewEvent':    { label: 'List View',   defaultColor: 'purple',
        getColor: () => 'purple' },
    '/event/ReportEvent':      { label: 'Report',      defaultColor: 'fuchsia',
        getColor: () => 'fuchsia' },
};

const ALL_CHANNELS = Object.keys(CHANNEL_CONFIG);

const COLOR_META = {
    green:   { label: 'Login',       hex: '#10b981' },
    teal:    { label: 'Logout',      hex: '#14b8a6' },
    yellow:  { label: 'API Read',    hex: '#f59e0b' },
    red:     { label: 'API Write',   hex: '#ef4444' },
    blue:    { label: 'Lightning',   hex: '#3b82f6' },
    indigo:  { label: 'Classic UI',  hex: '#6366f1' },
    purple:  { label: 'List View',   hex: '#8b5cf6' },
    fuchsia: { label: 'Report',      hex: '#d946ef' },
    orange:  { label: 'Identity',    hex: '#f97316' },
};

// ── Helper Functions ──────────────────────────────────────────────────────────

function detectOrigin(rec) {
    if (rec.botId) return 'Agentforce';
    const client    = rec.client || rec.browser || '';
    const loginType = rec.loginType || '';
    const uri       = rec.uri || rec.requestUri || '';
    const appName   = rec.appName || '';
    // Agentforce Today ECA login: Application field = 'Agentforce Today'
    if (/agentforce.?today/i.test(appName))          return 'Agentforce Today';
    // SF Dashboard ECA login: Application field = 'SF Dashboard'
    if (/sf.?dashboard/i.test(appName))              return 'SF Dashboard';
    // MCP gateway re-auth: SourceIp = 3.234.75.13 (Salesforce platform MCP gateway)
    if (rec.sourceIp === '3.234.75.13' && loginType === 'Remote Access 2.0') return 'MCP Gateway';
    // MCP: generic detection from client string or URI
    if (/mcp|model.context.protocol/i.test(client)) return 'MCP';
    if (/api\.salesforce\.com.*mcp/i.test(uri))      return 'MCP';
    if (rec.connectedAppName && /mcp|dashboard/i.test(rec.connectedAppName)) return 'MCP';
    if (/sfdx|sf-cli|force-cli|sfdx-toolbelt|salesforce-cli/i.test(client)) return 'SF CLI';
    if (/workbench/i.test(client))    return 'Workbench';
    if (/postman/i.test(client))      return 'Postman';
    if (/data.*loader/i.test(client)) return 'Data Loader';
    if (/apex/i.test(client))         return 'Apex Code';
    if (/flow/i.test(client))         return 'Flow';
    if (rec.channel === '/event/LightningUriEvent') return 'SF Lightning UI';
    if (rec.channel === '/event/UriEvent')          return 'SF Classic UI';
    if (/aura|lightning/i.test(client))             return 'SF Lightning UI';
    if (loginType === 'Remote Access 2.0')          return 'OAuth App';
    if (loginType === 'Application')                return 'Connected App';
    if (/mozilla|chrome|safari|firefox/i.test(client)) return 'SF Browser';
    return null;
}

// Returns one of: 'agentforce' | 'cli' | 'salesforce' | 'api' | 'mcp'
function detectIcon(rec) {
    if (rec.botId) return 'agentforce';
    const appName = rec.appName || '';
    // MCP: SF Dashboard ECA login, MCP gateway re-auth, or gateway IP
    if (/sf[\s_-]?dashboard/i.test(appName))   return 'mcp';
    if (/storm_auth/i.test(appName))            return 'mcp';
    if (rec.sourceIp === '3.234.75.13')         return 'mcp';
    const client = rec.client || '';
    if (/sfdx|sf-cli|force-cli|sfdx-toolbelt|salesforce-cli/i.test(client)) return 'cli';
    if (rec.channel === '/event/LightningUriEvent' ||
        rec.channel === '/event/UriEvent'          ||
        rec.channel === '/event/ListViewEvent'     ||
        rec.channel === '/event/LoginEvent')        return 'salesforce';
    // REST SOQL queries via OAuth app (sf-dashboard direct queries)
    // loginType 'Remote Access 2.0' = OAuth Connected App; CLI sessions use different types
    if (rec.channel === '/event/ApiEvent' && rec.method === 'Query' &&
        /remote access 2/i.test(rec.loginType || '')) return 'dashboard';
    return 'api';
}

// Maps the RTEM Operation field value to a human label
const OPERATION_LABELS = {
    'Query':           'SOQL Query',
    'Search':          'SOSL Search',
    'Insert':          '✏ Insert',
    'Update':          '✏ Update',
    'Upsert':          '✏ Upsert',
    'Delete':          '✏ Delete',
    'Undelete':        '✏ Undelete',
    'Merge':           '✏ Merge',
    'Execute':         'Execute',
    'ExecuteAnonymous':'Run Apex',
    'RunFlow':         'Run Flow',
    'RunReport':       'Run Report',
    'RunDashboard':    'Run Dashboard',
    'Login':           'Login',
    'Logout':          'Logout',
};

const WRITE_OPS = new Set(['Insert','Update','Upsert','Delete','Undelete','Merge']);

function isWriteOperation(rec) {
    const op = rec.method || ''; // method field holds Operation value
    return WRITE_OPS.has(op) ||
           /insert|update|upsert|delete|undelete|merge|patch|put/i.test(op);
}

function detectOperation(rec) {
    // Use the Operation field from RTEM (stored in rec.method)
    const op = rec.method || '';

    if (rec.channel === '/event/LoginEvent') {
        const st = rec.status || '';
        if (/success/i.test(st)) return 'Login ✓';
        if (st)                  return 'Login ✗';
        return 'Login';
    }
    if (rec.channel === '/event/ReportEvent')   return 'Run Report';
    if (rec.channel === '/event/ListViewEvent') return 'List View';

    if (op) {
        return OPERATION_LABELS[op] || op;
    }

    if (rec.channel === '/event/LightningUriEvent') return 'Page View';
    if (rec.channel === '/event/UriEvent')          return 'Classic Page';
    if (rec.channel === '/event/ApiEvent')          return 'API Call';
    return null;
}

function formatTime(isoString) {
    try { return new Date(isoString).toLocaleTimeString('en-US', { hour12: false }); }
    catch (e) { return ''; }
}

function originVariant(o) {
    if (!o) return '';
    if (/Agentforce Today/i.test(o))      return 'agentforce-today';
    if (/Agentforce/i.test(o))            return 'agentforce';
    if (/SF Dashboard/i.test(o))          return 'mcp';
    if (/MCP/i.test(o))                   return 'mcp';
    if (/CLI/i.test(o))                   return 'cli';
    if (/Lightning|Classic|Browser/i.test(o)) return 'ui';
    if (/Apex/i.test(o))                  return 'apex';
    if (/Flow/i.test(o))                  return 'flow';
    if (/Postman|Workbench/i.test(o))     return 'tool';
    if (/OAuth|Connected/i.test(o))       return 'oauth';
    return 'default';
}

function operationVariant(op) {
    if (!op) return '';
    if (/✏|Insert|Update|Upsert|Merge|Undelete|Patch|Put/i.test(op)) return 'write';
    if (/Delete/i.test(op))                                            return 'delete';
    if (/Query|Read|View|Page|List|Search/i.test(op))                  return 'read';
    if (/Login.*✓/.test(op))                                           return 'success';
    if (/Login.*✗/.test(op))                                           return 'failure';
    return 'default';
}

// ── Component ─────────────────────────────────────────────────────────────────

export default class StreamingMonitor extends LightningElement {
    @track events           = [];
    @track stats            = {};
    @track isPaused         = false;
    @track isConnected      = false;
    @track isLoading        = true;
    @track activeFilters    = [];
    @track selectedEvent    = null;
    @track lastError        = null;
    @track lastPollTime     = 'Never';
    @track pollCount        = 0;
    @track newEventFlash    = false;
    @track hideMonitorNoise = true;  // hides streaming monitor's own EventLogFile polls
    @track clearedAtTimestamp = null; // when set, only show events after this time

    _pollInterval  = null;
    _polling       = false;
    _prevFirstId   = null; // track first event ID to detect changes for flash

    // ── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this._visibilityHandler = () => {
            if (document.visibilityState === 'visible') this.poll();
        };
        document.addEventListener('visibilitychange', this._visibilityHandler);
        this.poll(); // immediate first run
        this._pollInterval = setInterval(() => this.poll(), POLL_INTERVAL);
    }

    disconnectedCallback() {
        if (this._pollInterval) { clearInterval(this._pollInterval); this._pollInterval = null; }
        if (this._visibilityHandler) {
            document.removeEventListener('visibilitychange', this._visibilityHandler);
            this._visibilityHandler = null;
        }
    }

    // ── Polling ──────────────────────────────────────────────────────────────

    async poll() {
        if (this._polling) return;
        this._polling = true;
        try {
            const rows = await getRecentEvents({ sinceEpochMs: 0, callTs: Date.now() });
            this.isConnected  = true;
            this.lastError    = null;
            this.lastPollTime = new Date().toLocaleTimeString('en-US', { hour12: false });
            this.pollCount    = (this.pollCount || 0) + 1;
            this.isLoading    = false;

            // Rows are newest-first from Apex; take top MAX_EVENTS
            const topRows = (rows || []).slice(0, MAX_EVENTS);

            // Flash when the leading event changes (new activity at the top)
            const firstId = topRows.length > 0 ? topRows[0].id : null;
            if (this._prevFirstId !== null && firstId !== this._prevFirstId) {
                this.newEventFlash = true;
                setTimeout(() => { this.newEventFlash = false; }, 1500);
            }
            this._prevFirstId = firstId;

            if (!this.isPaused) {
                const built       = [];
                const statsUpdate = {};

                for (const row of topRows) {
                    const cfg       = CHANNEL_CONFIG[row.channel] || { label: row.eventType, defaultColor: 'teal', getColor: () => 'teal' };
                    const color     = cfg.getColor(row);
                    const origin    = detectOrigin(row);
                    const operation = detectOperation(row);
                    const isWrite   = isWriteOperation(row);
                    const iconType  = detectIcon(row);

                    statsUpdate[color] = (statsUpdate[color] || 0) + 1;

                    built.push({
                        id:      row.id, // use stable Apex ID as key
                        channel: row.channel,
                        label:   cfg.label || row.eventType,
                        color,
                        user:    row.username || 'Unknown',
                        timeDisplay:  formatTime(row.eventDate),
                        payload:      row,
                        keyFields:    this._buildKeyFields(row),
                        origin,
                        operation,
                        isWrite,
                        iconType,
                        isIconAgentforce: iconType === 'agentforce',
                        isIconCli:        iconType === 'cli',
                        isIconSalesforce: iconType === 'salesforce',
                        isIconApi:        iconType === 'api',
                        isIconMcp:        iconType === 'mcp',
                        isIconDashboard:  iconType === 'dashboard',
                        replayId:     null,
                        cardClass:         `event-card event-card--${color}${isWrite ? ' event-card--write' : ''}`,
                        labelBadgeClass:   `label-badge label-badge--${color}`,
                        originTagClass:    origin    ? `tag tag--origin tag--${originVariant(origin)}`            : '',
                        operationTagClass: operation ? `tag tag--operation tag--op-${operationVariant(operation)}` : '',
                        modalHeaderClass:  `modal-header modal-header--${color}`,
                        prettyPayload:     row.payloadJson || JSON.stringify(row, null, 2),
                    });
                }

                this.stats  = statsUpdate;
                this.events = built; // replace the whole list every tick
            }
        } catch (err) {
            this.isConnected = false;
            this.isLoading   = false;
            this.lastError   = err?.body?.message || err?.message || JSON.stringify(err);
        } finally {
            this._polling = false;
        }
    }

    _buildKeyFields(row) {
        const candidates = [
            { key: 'Username',    value: row.username },
            { key: 'Source IP',   value: row.sourceIp },
            { key: 'Method',      value: row.method },
            { key: 'URI',         value: row.uri },
            { key: 'Status',      value: row.status },
            { key: 'Login Type',  value: row.loginType },
            { key: 'Browser',     value: row.browser },
            { key: 'App',         value: row.appName },
            { key: 'Entity',      value: row.entityType },
            { key: 'Report',      value: row.reportId },
            { key: 'Rows',        value: row.rowsProcessed != null ? Number(row.rowsProcessed).toLocaleString() : null },
        ];
        return candidates.filter(f => f.value != null && String(f.value).trim() !== '');
    }

    // ── Computed Properties ──────────────────────────────────────────────────

    get statusDotClass() {
        if (this.isLoading)   return 'status-dot status-dot--connecting';
        if (this.newEventFlash) return 'status-dot status-dot--flash';
        return this.isConnected ? 'status-dot status-dot--on' : 'status-dot status-dot--off';
    }

    get statusText() {
        if (this.isLoading)    return 'Loading history…';
        if (!this.isConnected) return 'Disconnected';
        return `Live · ${this.lastPollTime} · poll #${this.pollCount}`;
    }

    get pauseButtonClass()  { return this.isPaused ? 'ctrl-btn ctrl-btn--resume' : 'ctrl-btn ctrl-btn--pause'; }
    get pauseButtonLabel()  { return this.isPaused ? '▶  Resume' : '⏸  Pause'; }
    get hasEvents()         { return this.visibleEvents.length > 0; }
    get hasError()          { return !this.isConnected && !!this.lastError; }

    get visibleEvents() {
        let evts = this.events;
        
        // Filter by cleared timestamp - only show events after clear was pressed
        if (this.clearedAtTimestamp) {
            evts = evts.filter(e => {
                const eventTime = new Date(e.payload?.eventDate || 0).getTime();
                return eventTime > this.clearedAtTimestamp;
            });
        }
        
        if (this.hideMonitorNoise) {
            evts = evts.filter(e => !(e.channel === '/event/ApiEvent' &&
                                      (e.payload?.uri || '').toUpperCase().includes('EVENTLOGFILE')));
        }
        if (this.activeFilters.length === 0) return evts;
        return evts.filter(e => this.activeFilters.includes(e.channel));
    }
    
    get isFiltered() {
        return this.clearedAtTimestamp !== null;
    }
    
    get clearedAtDisplay() {
        if (!this.clearedAtTimestamp) return '';
        return new Date(this.clearedAtTimestamp).toLocaleTimeString('en-US', { hour12: true });
    }

    get noiseButtonLabel() { return this.hideMonitorNoise ? 'Show Monitor Noise' : 'Hide Monitor Noise'; }
    get noiseButtonClass() { return this.hideMonitorNoise ? 'ctrl-btn ctrl-btn--pause' : 'ctrl-btn ctrl-btn--resume'; }

    toggleMonitorNoise() { this.hideMonitorNoise = !this.hideMonitorNoise; }

    get eventCount()  { return this.visibleEvents.length; }
    get totalCount()  { return this.events.length; }

    get statsList() {
        return Object.entries(this.stats)
            .filter(([, n]) => n > 0)
            .map(([color, count]) => ({
                color, count,
                label: COLOR_META[color]?.label || color,
                hex:   COLOR_META[color]?.hex   || '#888',
                badgeClass: `stat-badge stat-badge--${color}`,
            }));
    }

    get channelFilters() {
        return ALL_CHANNELS.map(ch => {
            const cfg      = CHANNEL_CONFIG[ch];
            const isActive = this.activeFilters.length === 0 || this.activeFilters.includes(ch);
            return {
                channel:   ch,
                label:     cfg.label,
                chipClass: `filter-chip filter-chip--${cfg.defaultColor}${isActive ? '' : ' filter-chip--off'}`,
            };
        });
    }

    // ── Controls ────────────────────────────────────────────────────────────

    togglePause()  { this.isPaused = !this.isPaused; }
    clearEvents()  { 
        // Set timestamp filter to only show events after now
        this.clearedAtTimestamp = Date.now();
    }
    showHistory()  {
        // Remove the timestamp filter to show all events
        this.clearedAtTimestamp = null;
    }
    reconnect()    { if (this._pollTimer) { clearTimeout(this._pollTimer); this._pollTimer = null; } this.poll(); }

    toggleFilter(evt) {
        const ch = evt.currentTarget.dataset.channel;
        this.activeFilters = this.activeFilters.includes(ch)
            ? this.activeFilters.filter(f => f !== ch)
            : [...this.activeFilters, ch];
    }

    clearFilters() { this.activeFilters = []; }

    openModal(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selectedEvent = this.events.find(e => e.id === id) || null;
    }

    closeModal()        { this.selectedEvent = null; }
    stopPropagation(evt){ evt.stopPropagation(); }
}

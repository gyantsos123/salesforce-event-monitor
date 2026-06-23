import { LightningElement, track } from 'lwc';
import searchUsers from '@salesforce/apex/EventTimelineController.searchUsers';
import buildTimeline from '@salesforce/apex/EventTimelineController.buildTimeline';

const SEARCH_DEBOUNCE = 300; // ms

export default class EventTimeline extends LightningElement {
    // ── User search state ──
    @track userResults = [];
    selectedUserId = null;
    selectedUserLabel = '';
    userSearchTerm = '';
    showResults = false;
    _searchTimer;

    // ── Date range state ──
    startDate;
    endDate;
    activePreset = 'today';

    // ── Result state ──
    @track sessions = [];
    @track warnings = [];
    sourcesQueried = [];
    totalEvents = 0;
    resultUserName = '';
    loading = false;
    errorMsg = '';
    hasRun = false;

    connectedCallback() {
        this.applyPreset('today');
    }

    // ── User search ──────────────────────────────────────────────────────────

    handleUserInput(event) {
        this.userSearchTerm = event.target.value;
        this.selectedUserId = null;
        window.clearTimeout(this._searchTimer);
        const term = this.userSearchTerm;
        if (!term || term.length < 2) {
            this.userResults = [];
            this.showResults = false;
            return;
        }
        this._searchTimer = setTimeout(() => {
            searchUsers({ term })
                .then((res) => {
                    this.userResults = res || [];
                    this.showResults = true;
                })
                .catch((err) => {
                    this.errorMsg = this.reduceError(err);
                });
        }, SEARCH_DEBOUNCE);
    }

    handleUserFocus() {
        if (this.userResults.length > 0) {
            this.showResults = true;
        }
    }

    handleSelectUser(event) {
        const id = event.currentTarget.dataset.id;
        const label = event.currentTarget.dataset.label;
        this.selectedUserId = id;
        this.selectedUserLabel = label;
        this.userSearchTerm = label;
        this.showResults = false;
    }

    handleBlur() {
        // Delay so a click on a result registers before the list closes.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.showResults = false;
        }, 200);
    }

    // ── Date presets ──────────────────────────────────────────────────────────

    handlePreset(event) {
        this.applyPreset(event.currentTarget.dataset.preset);
    }

    applyPreset(preset) {
        this.activePreset = preset;
        const now = new Date();
        const end = new Date(now);
        let start = new Date(now);
        if (preset === 'today') {
            start = now;
            this.startDate = this.toDateInput(start);
            this.endDate = this.toDateInput(end);
        } else if (preset === 'yesterday') {
            start.setDate(start.getDate() - 1);
            end.setDate(end.getDate() - 1);
            this.startDate = this.toDateInput(start);
            this.endDate = this.toDateInput(end);
        } else if (preset === '7days') {
            start.setDate(start.getDate() - 6);
            this.startDate = this.toDateInput(start);
            this.endDate = this.toDateInput(end);
        } else if (preset === '14days') {
            start.setDate(start.getDate() - 13);
            this.startDate = this.toDateInput(start);
            this.endDate = this.toDateInput(end);
        }
    }

    handleStartDate(event) {
        this.startDate = event.target.value;
        this.activePreset = 'custom';
    }

    handleEndDate(event) {
        this.endDate = event.target.value;
        this.activePreset = 'custom';
    }

    toDateInput(d) {
        const y = d.getFullYear();
        const m = `${d.getMonth() + 1}`.padStart(2, '0');
        const day = `${d.getDate()}`.padStart(2, '0');
        return `${y}-${m}-${day}`;
    }

    // ── Build ──────────────────────────────────────────────────────────────────

    get buildDisabled() {
        return this.loading || !this.selectedUserId || !this.startDate || !this.endDate;
    }

    get presetButtons() {
        const presets = [
            { key: 'today', label: 'Today' },
            { key: 'yesterday', label: 'Yesterday' },
            { key: '7days', label: 'Last 7 days' },
            { key: '14days', label: 'Last 14 days' }
        ];
        return presets.map((p) => ({
            ...p,
            variant: this.activePreset === p.key ? 'brand' : 'neutral'
        }));
    }

    handleBuild() {
        if (this.buildDisabled) {
            return;
        }
        this.loading = true;
        this.errorMsg = '';
        this.hasRun = true;

        // Treat the selected dates as UTC day boundaries to align with the GMT Timestamp field.
        const startMs = Date.parse(`${this.startDate}T00:00:00.000Z`);
        const endMs = Date.parse(`${this.endDate}T23:59:59.999Z`);

        buildTimeline({ userId: this.selectedUserId, startMs, endMs })
            .then((res) => {
                this.resultUserName = res.userName || this.selectedUserLabel;
                this.totalEvents = res.totalEvents || 0;
                this.warnings = res.warnings || [];
                this.sourcesQueried = res.sourcesQueried || [];
                this.sessions = this.decorate(res.sessions || []);
            })
            .catch((err) => {
                this.errorMsg = this.reduceError(err);
                this.sessions = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    // ── View-model decoration ───────────────────────────────────────────────────

    decorate(sessions) {
        return sessions.map((s, sIdx) => {
            const events = (s.events || []).map((e, eIdx) => ({
                ...e,
                uiKey: `${sIdx}-${eIdx}`,
                expanded: false,
                timeLabel: this.formatTime(e.timeIso),
                hasDetails: (e.details || []).length > 0,
                style: `--accent: ${e.color || '#64748b'}`,
                chevron: 'utility:chevronright'
            }));
            return {
                ...s,
                uiKey: `s-${sIdx}`,
                events,
                rangeLabel: this.sessionRange(events),
                headerStyle: s.hasLogin ? '' : 'opacity:0.92'
            };
        });
    }

    handleToggleEvent(event) {
        const key = event.currentTarget.dataset.key;
        this.sessions = this.sessions.map((s) => ({
            ...s,
            events: s.events.map((e) =>
                e.uiKey === key
                    ? {
                          ...e,
                          expanded: !e.expanded,
                          chevron: !e.expanded ? 'utility:chevrondown' : 'utility:chevronright'
                      }
                    : e
            )
        }));
    }

    sessionRange(events) {
        if (!events.length) {
            return '';
        }
        const first = events[0].timeLabel;
        const last = events[events.length - 1].timeLabel;
        return first === last ? first : `${first} – ${last}`;
    }

    formatTime(iso) {
        if (!iso) {
            return '';
        }
        const d = new Date(iso);
        return d.toLocaleString(undefined, {
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit'
        });
    }

    // ── Getters ──────────────────────────────────────────────────────────────

    get hasResults() {
        return this.sessions && this.sessions.length > 0;
    }

    get showEmpty() {
        return this.hasRun && !this.loading && !this.errorMsg && !this.hasResults;
    }

    get hasWarnings() {
        return this.warnings && this.warnings.length > 0;
    }

    get sourcesLabel() {
        return this.sourcesQueried.join(',  ');
    }

    reduceError(err) {
        if (Array.isArray(err?.body)) {
            return err.body.map((e) => e.message).join(', ');
        }
        return err?.body?.message || err?.message || 'Unknown error';
    }
}

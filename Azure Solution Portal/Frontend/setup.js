// ============================================================
// CONFIGURAZIONE — aggiornata da Bootstrap.ps1
// ============================================================

const FUNCTION_APP_URL   = 'https://func-azsolportal-089fb2a1.azurewebsites.net';
const CLIENT_ID          = '4ace231a-ee3c-4bb8-aa9f-85105cecce6c';
const RESOURCE_GROUP_NAME = 'rg-azure-solution-portal';
const FUNCTION_APP_NAME  = FUNCTION_APP_URL.replace('https://', '').split('.')[0];

const MSAL_CONFIG = {
    auth: {
        clientId:              CLIENT_ID,
        authority:             'https://login.microsoftonline.com/common',
        redirectUri:           window.location.origin,
        postLogoutRedirectUri: window.location.origin
    },
    cache: { cacheLocation: 'sessionStorage', storeAuthStateInCookie: false }
};

const MGMT_SCOPE  = 'https://management.azure.com/user_impersonation';
const MGMT_API    = 'https://management.azure.com';

// ============================================================
// STATE
// ============================================================

let msalInstance       = null;
let currentAccount     = null;
let portalSubId        = null;
let workloadSubIds     = [];
let cachedSubs         = [];
let mgmtToken          = null;
let checkResults       = {};

// Checks: msal, login, sub, worksubs, funcexist, cors, funcs, ai  → 8
const TOTAL_CHECKS     = 8;

const LS_PORTAL_SUB    = 'asp.portalSubId';
const LS_WORKLOAD_SUBS = 'asp.workloadSubIds';

// ============================================================
// HELPER: UI
// ============================================================

function setCheckState(id, state, detail = '') {
    const icon  = document.getElementById(`icon-${id}`);
    const detEl = document.getElementById(`detail-${id}`);
    if (!icon) return;

    const map = {
        pending:  { cls: 'pending',  icon: 'fas fa-circle' },
        checking: { cls: 'checking', icon: 'fas fa-sync fa-spin' },
        ok:       { cls: 'ok',       icon: 'fas fa-check' },
        warning:  { cls: 'warning',  icon: 'fas fa-exclamation' },
        error:    { cls: 'error',    icon: 'fas fa-times' }
    };
    const s = map[state] || map.pending;
    icon.className = `check-icon ${s.cls}`;
    icon.innerHTML = `<i class="${s.icon}"></i>`;

    if (detEl && detail !== '') {
        detEl.textContent = detail;
        detEl.className   = `check-detail ${state === 'ok' ? 'ok' : state === 'warning' ? 'warning' : state === 'error' ? 'error' : ''}`;
    }
    checkResults[id] = state;
    updateProgress();
}

function showAction(id, html) {
    const el = document.getElementById(`action-${id}`);
    if (el) el.innerHTML = html;
}

function showBox(id, show = true) {
    const el = document.getElementById(`instr-${id}`);
    if (el) el.style.display = show ? 'block' : 'none';
}

function updateProgress() {
    const done = Object.values(checkResults).filter(s => s !== 'checking' && s !== 'pending').length;
    const pct  = Math.round((done / TOTAL_CHECKS) * 100);
    const bar  = document.getElementById('progress-bar');
    if (bar) bar.style.width = `${pct}%`;

    if (done < TOTAL_CHECKS) return;

    const allOk = Object.values(checkResults).every(s => s === 'ok' || s === 'warning');
    const sum   = document.getElementById('status-summary');
    const act   = document.getElementById('actions-desc');

    if (allOk) {
        sum.className = 'status-summary all-ok';
        sum.innerHTML = '<i class="fas fa-check-circle"></i> <span>Tutti i prerequisiti verificati. Puoi accedere al portale.</span>';
        act.textContent = 'Il portale è pronto.';
        document.getElementById('btn-portal').style.display = 'inline-flex';
        document.getElementById('btn-portal-disabled').style.display = 'none';
    } else {
        sum.className = 'status-summary partial';
        sum.innerHTML = '<i class="fas fa-exclamation-triangle"></i> <span>Alcuni prerequisiti non soddisfatti. Segui le istruzioni per risolverli.</span>';
        act.textContent = 'Risolvi i prerequisiti indicati prima di procedere.';
    }
}

// ============================================================
// AUTH HEADER UI
// ============================================================

function updateAuthHeader(isAuth, username = '') {
    const indicator = document.getElementById('auth-indicator');
    const text      = document.getElementById('auth-text');
    const btn       = document.getElementById('auth-button');
    if (!indicator) return;

    if (isAuth) {
        indicator.className = 'auth-indicator authenticated';
        indicator.querySelector('i').className = 'fas fa-user-check';
        text.textContent = username;
        btn.textContent  = 'Disconnetti';
        btn.onclick      = doLogout;
    } else {
        indicator.className = 'auth-indicator not-authenticated';
        indicator.querySelector('i').className = 'fas fa-user-slash';
        text.textContent = 'Non autenticato';
        btn.textContent  = 'Accedi con Microsoft';
        btn.onclick      = doLogin;
    }
}

// ============================================================
// CHECK 1: MSAL
// ============================================================

async function checkMSAL() {
    setCheckState('msal', 'checking');
    await new Promise(r => setTimeout(r, 800));

    if (typeof msal !== 'undefined' || window.msalLoaded) {
        setCheckState('msal', 'ok', 'MSAL Browser caricato correttamente');
    } else {
        setCheckState('msal', 'error', 'MSAL non disponibile — controlla la connessione Internet');
    }
}

// ============================================================
// CHECK 2: LOGIN
// ============================================================

async function checkLogin() {
    setCheckState('login', 'checking');

    if (!msalInstance) {
        try {
            msalInstance = new msal.PublicClientApplication(MSAL_CONFIG);
            await msalInstance.initialize();
        } catch (e) {
            setCheckState('login', 'error', `Errore inizializzazione MSAL: ${e.message}`);
            return;
        }
    }

    try { await msalInstance.handleRedirectPromise(); } catch {}

    const accounts = msalInstance.getAllAccounts();
    if (accounts.length > 0) {
        currentAccount = accounts[0];
        msalInstance.setActiveAccount(currentAccount);
        updateAuthHeader(true, currentAccount.username);
        setCheckState('login', 'ok', `Autenticato come: ${currentAccount.username}`);
        showAction('login', '');
    } else {
        updateAuthHeader(false);
        setCheckState('login', 'warning', 'Accedi per continuare il check');
        showAction('login', `<button class="btn-fix" onclick="doLogin()">
            <i class="fas fa-sign-in-alt"></i> Accedi con Microsoft
        </button>`);
    }
}

async function doLogin() {
    try {
        await msalInstance.loginRedirect({ scopes: [MGMT_SCOPE] });
        return;
    } catch (e) {
        setCheckState('login', 'error', `Login fallito: ${e.message}`);
    }
}

async function doLogout() {
    try {
        await msalInstance.logoutRedirect({ account: currentAccount, postLogoutRedirectUri: window.location.origin });
        return;
    } catch {
        // ignore
    }

    try {
        currentAccount = null;
        mgmtToken      = null;
        portalSubId    = null;
        workloadSubIds = [];
        try {
            localStorage.removeItem(LS_PORTAL_SUB);
            localStorage.removeItem(LS_WORKLOAD_SUBS);
        } catch {}
        updateAuthHeader(false);
        runAllChecks();
    } catch {}
}

// ============================================================
// ACQUIRE MANAGEMENT API TOKEN
// ============================================================

async function getManagementToken() {
    if (!currentAccount || !msalInstance) return null;
    try {
        const resp = await msalInstance.acquireTokenSilent({
            scopes:  [MGMT_SCOPE],
            account: currentAccount
        });
        return resp.accessToken;
    } catch {
        try {
            await msalInstance.acquireTokenRedirect({ scopes: [MGMT_SCOPE] });
            return null;
        } catch (e) {
            return null;
        }
    }
}

// ============================================================
// CHECK 3: SUBSCRIPTION (Management API)
// ============================================================

async function checkSubscription() {
    setCheckState('sub', 'checking');
    setCheckState('worksubs', 'checking');

    mgmtToken = await getManagementToken();
    if (!mgmtToken) {
        setCheckState('sub', 'error', 'Impossibile ottenere token Azure Management — rieffettua il login');
        setCheckState('worksubs', 'warning', 'Verificabile dopo login');
        return false;
    }

    let subs = [];
    try {
        const resp = await fetch(`${MGMT_API}/subscriptions?api-version=2022-12-01`, {
            headers: { Authorization: `Bearer ${mgmtToken}` }
        });
        const data = await resp.json();
        subs = data.value || [];
        cachedSubs = subs;
    } catch (e) {
        setCheckState('sub', 'error', `Errore Management API: ${e.message}`);
        setCheckState('worksubs', 'warning', 'Impossibile caricare subscriptions');
        return false;
    }

    if (subs.length === 0) {
        setCheckState('sub', 'error', 'Nessuna subscription Azure trovata per questo account');
        setCheckState('worksubs', 'error', 'Nessuna subscription disponibile');
        return false;
    }

    // Restore from localStorage (portal + workload)
    try {
        const savedPortal = localStorage.getItem(LS_PORTAL_SUB);
        if (savedPortal) portalSubId = savedPortal;
        const savedWork = localStorage.getItem(LS_WORKLOAD_SUBS);
        if (savedWork) workloadSubIds = JSON.parse(savedWork) || [];
    } catch {}

    // Normalize workload selection to current subscription list
    const subSet = new Set(subs.map(s => s.subscriptionId));
    workloadSubIds = Array.isArray(workloadSubIds) ? workloadSubIds.filter(id => subSet.has(id)) : [];

    // Populate workload picker (always available)
    populateWorkloadPicker(subs, workloadSubIds);
    if (workloadSubIds.length > 0) {
        setCheckState('worksubs', 'ok', `${workloadSubIds.length} workload subscription selezionate`);
        showBox('worksubs', false);
    } else {
        setCheckState('worksubs', 'warning', 'Seleziona almeno 1 workload subscription (consigliato per precheck cross-sub)');
        showBox('worksubs', true);
    }

    if (subs.length === 1) {
        portalSubId = subs[0].subscriptionId;
        setCheckState('sub', 'ok', `Portal subscription: ${subs[0].displayName} (${subs[0].subscriptionId})`);
        showBox('sub', false);
        persistSelections();
        return true;
    }

    // Multiple subscriptions: show picker
    const select = document.getElementById('sub-select');
    if (select) {
        select.innerHTML = '<option value="">— Seleziona —</option>' +
            subs.map(s => `<option value="${s.subscriptionId}">${s.displayName} (${s.subscriptionId})</option>`).join('');
        showBox('sub', true);
        if (portalSubId && subs.find(s => s.subscriptionId === portalSubId)) {
            select.value = portalSubId;
            const sub = subs.find(s => s.subscriptionId === portalSubId);
            setCheckState('sub', 'ok', `Portal subscription: ${sub.displayName} (${sub.subscriptionId})`);
            showBox('sub', false);
            persistSelections();
            return true;
        }
        setCheckState('sub', 'warning', `${subs.length} subscription disponibili — seleziona la Portal subscription`);
        return false;  // wait for user selection (portal)
    }

    // Fallback: pick first
    portalSubId = subs[0].subscriptionId;
    setCheckState('sub', 'ok', `Portal subscription: ${subs[0].displayName}`);
    persistSelections();
    return true;
}

async function onSubSelected() {
    const select = document.getElementById('sub-select');
    if (!select || !select.value) return;
    portalSubId = select.value;
    showBox('sub', false);
    const sub = cachedSubs.find(s => s.subscriptionId === portalSubId);
    setCheckState('sub', 'ok', sub ? `Portal subscription: ${sub.displayName} (${sub.subscriptionId})` : `Portal subscription: ${portalSubId}`);

    // Persist + refresh workload status
    saveWorkSubs();
    persistSelections();

    // Continue with the remaining checks
    await checkFunctionApp();
    await checkAI();
}

// ============================================================
// CHECK 4 + 5 + 6: FUNCTION APP (exist + CORS + endpoints)
// ============================================================

async function checkFunctionApp() {
    setCheckState('funcexist', 'checking');
    setCheckState('cors', 'checking');
    setCheckState('funcs', 'checking');

    // ── 4: Check Function App exists via Management API ──────────
    let funcAppFound = false;
    if (mgmtToken && portalSubId) {
        try {
            const r = await fetch(
                `${MGMT_API}/subscriptions/${portalSubId}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.Web/sites/${FUNCTION_APP_NAME}?api-version=2022-03-01`,
                { headers: { Authorization: `Bearer ${mgmtToken}` } }
            );
            if (r.ok) {
                const site = await r.json();
                const kind = (site.kind || '').toLowerCase();
                if (kind.includes('functionapp')) {
                    funcAppFound = true;
                    setCheckState('funcexist', 'ok', `Function App trovata: ${FUNCTION_APP_NAME} (${site.location})`);
                    showBox('funcexist', false);
                } else {
                    setCheckState('funcexist', 'warning', `Risorsa trovata ma non è una Function App (kind: ${site.kind})`);
                    showBox('funcexist', true);
                }
            } else if (r.status === 404) {
                setCheckState('funcexist', 'error', `Function App '${FUNCTION_APP_NAME}' non trovata nella subscription`);
                showBox('funcexist', true);
                // Can't check CORS or endpoints without the function app
                setCheckState('cors', 'warning', 'Verifica CORS non possibile — Function App non trovata');
                setCheckState('funcs', 'warning', 'Endpoint non verificabili — Function App non trovata');
                return;
            } else {
                setCheckState('funcexist', 'warning', `Management API: HTTP ${r.status} — verifica con ping diretto`);
                funcAppFound = true; // assume ok, will verify below
            }
        } catch (e) {
            setCheckState('funcexist', 'warning', `Management API non raggiungibile (${e.message}) — verifica con ping`);
            funcAppFound = true; // try ping anyway
        }
    } else {
        // No sub selected yet — try direct ping only
        setCheckState('funcexist', 'warning', 'Seleziona una subscription per verificare tramite Management API');
        funcAppFound = true;
    }

    if (!funcAppFound) return;

    // ── 5: CORS check (direct HTTP ping) ─────────────────────────
    try {
        // Prefer OPTIONS: served by Functions host (fast) and validates CORS preflight.
        const resp = await fetch(`${FUNCTION_APP_URL}/api/precheck`, {
            method: 'OPTIONS',
            signal: AbortSignal.timeout(12000)
        });

        if (!resp.ok && resp.status >= 500) {
            setCheckState('cors', 'error', `HTTP ${resp.status} — Function App non disponibile`);
            return;
        }

        setCheckState('cors', 'ok', `CORS ok — HTTP ${resp.status} da ${window.location.origin}`);
        showBox('cors', false);

    } catch (e) {
        if (e.name === 'AbortError') {
            setCheckState('cors', 'error', 'Timeout (12s) — Function App non risponde');
        } else if (e.message.toLowerCase().includes('failed to fetch') || e.message.toLowerCase().includes('cors')) {
            setCheckState('cors', 'error', `CORS non configurato per: ${window.location.origin}`);
            document.getElementById('cors-origin').textContent = window.location.origin;
            showBox('cors', true);
        } else {
            setCheckState('cors', 'error', `Errore connessione: ${e.message}`);
        }
    }

    // ── 6: Check all endpoints ────────────────────────────────────
    const endpoints = [
        { name: 'precheck (Monitor)',  path: '/api/precheck' },
        { name: 'precheck-avd',        path: '/api/precheck-avd' },
        { name: 'precheck-backup',     path: '/api/precheck-backup' },
        { name: 'precheck-defender',   path: '/api/precheck-defender' },
        { name: 'precheck-updates',    path: '/api/precheck-updates' },
        { name: 'precheck-zerotrust',  path: '/api/precheck-zerotrust' }
    ];

    const results = await Promise.all(endpoints.map(async ep => {
        try {
            const r = await fetch(`${FUNCTION_APP_URL}${ep.path}`, { method: 'OPTIONS', signal: AbortSignal.timeout(8000) });
            return { name: ep.name, ok: r.status >= 200 && r.status < 300 };
        } catch {
            return { name: ep.name, ok: false };
        }
    }));

    const okCount = results.filter(r => r.ok).length;
    if (okCount === endpoints.length) {
        setCheckState('funcs', 'ok', `Tutti e ${endpoints.length} gli endpoint precheck sono attivi`);
    } else {
        const missing = results.filter(r => !r.ok).map(r => r.name).join(', ');
        setCheckState('funcs', 'warning', `${okCount}/${endpoints.length} endpoint OK — mancanti: ${missing}`);
    }
}

// ============================================================
// CHECK 7: AZURE AI (proxy check)
// ============================================================

async function checkAI() {
    setCheckState('ai', 'checking');

    // If function app isn't reachable yet, can't check AI
    if (checkResults['cors'] !== 'ok' && checkResults['funcexist'] !== 'ok') {
        setCheckState('ai', 'warning', 'Verificabile solo dopo che la Function App è raggiungibile');
        return;
    }

    try {
        // Enterprise-friendly check: read Function App settings via ARM (no dependency on function execution/cold start).
        const token = await getManagementToken();
        if (!token || !portalSubId) {
            setCheckState('ai', 'warning', 'Verificabile dopo login + selezione subscription');
            return;
        }

        const uri = `${MGMT_API}/subscriptions/${portalSubId}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.Web/sites/${FUNCTION_APP_NAME}/config/appsettings/list?api-version=2022-03-01`;
        const resp = await fetch(uri, {
            method: 'POST',
            headers: { Authorization: `Bearer ${token}` }
        });
        if (!resp.ok) {
            setCheckState('ai', 'warning', `Impossibile leggere App Settings (HTTP ${resp.status}) — verifica permessi Reader/Contributor`);
            showBox('ai', true);
            return;
        }

        const data = await resp.json();
        const props = data?.properties || {};
        const required = ['AZURE_OPENAI_API_KEY', 'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_DEPLOYMENT'];
        const missing = required.filter(k => !props[k] || String(props[k]).trim() === '');

        if (missing.length === 0) {
            setCheckState('ai', 'ok', 'Azure OpenAI configurato — analisi AI disponibile nei precheck');
            showBox('ai', false);
        } else {
            setCheckState('ai', 'warning', `Variabili mancanti: ${missing.join(', ')}`);
            showBox('ai', true);
        }
    } catch (e) {
        if (e.name === 'TimeoutError' || e.name === 'AbortError') {
            setCheckState('ai', 'warning', 'Test AI timeout — Function App potrebbe essere in cold start (attendi 30s e ricontrolla)');
        } else {
            setCheckState('ai', 'warning', 'Impossibile verificare AI — esegui Bootstrap.ps1 per configurare Azure OpenAI');
            showBox('ai', true);
        }
    }
}

// ============================================================
// POST-LOGIN CONTINUATION
// ============================================================

async function continueAfterLogin() {
    const subOk = await checkSubscription();
    if (subOk) {
        await Promise.all([checkFunctionApp(), checkAI()]);
    }
    // If sub not ok, user will select manually via onSubSelected()
}

// ============================================================
// RUN ALL CHECKS
// ============================================================

async function runAllChecks() {
    checkResults  = {};
    mgmtToken     = null;

    // Keep persisted selection between rechecks (landing-zone friendly)
    try {
        const savedPortal = localStorage.getItem(LS_PORTAL_SUB);
        portalSubId = savedPortal || portalSubId;
        const savedWork = localStorage.getItem(LS_WORKLOAD_SUBS);
        workloadSubIds = savedWork ? (JSON.parse(savedWork) || []) : workloadSubIds;
    } catch {}

    document.getElementById('btn-portal').style.display         = 'none';
    document.getElementById('btn-portal-disabled').style.display = 'inline-flex';
    document.getElementById('progress-bar').style.width         = '0%';

    const sum = document.getElementById('status-summary');
    sum.className = 'status-summary checking';
    sum.innerHTML = '<i class="fas fa-sync fa-spin"></i> <span>Verifica prerequisiti in corso...</span>';

    ['msal','login','sub','worksubs','funcexist','cors','funcs','ai'].forEach(id => setCheckState(id, 'pending'));

    await checkMSAL();
    await checkLogin();

    if (currentAccount) {
        await continueAfterLogin();
    } else {
        // Set remaining checks to pending (waiting for login)
        ['sub','worksubs','funcexist','cors','funcs','ai'].forEach(id =>
            setCheckState(id, 'warning', 'In attesa del login Microsoft')
        );
    }
}

function persistSelections() {
    try {
        if (portalSubId) localStorage.setItem(LS_PORTAL_SUB, portalSubId);
        localStorage.setItem(LS_WORKLOAD_SUBS, JSON.stringify(workloadSubIds || []));
    } catch {}
}

function populateWorkloadPicker(subs, selectedIds) {
    const select = document.getElementById('worksubs-select');
    if (!select) return;
    select.innerHTML = subs
        .map(s => `<option value="${s.subscriptionId}">${s.displayName} (${s.subscriptionId})</option>`)
        .join('');
    const set = new Set(selectedIds || []);
    Array.from(select.options).forEach(o => { o.selected = set.has(o.value); });
}

function selectAllWorkSubs(selectAll) {
    const select = document.getElementById('worksubs-select');
    if (!select) return;
    Array.from(select.options).forEach(o => { o.selected = !!selectAll; });
}

function saveWorkSubs() {
    const select = document.getElementById('worksubs-select');
    if (!select) return;
    workloadSubIds = Array.from(select.selectedOptions).map(o => o.value).filter(Boolean);
    persistSelections();
    if (workloadSubIds.length > 0) {
        setCheckState('worksubs', 'ok', `${workloadSubIds.length} workload subscription selezionate`);
        showBox('worksubs', false);
    } else {
        setCheckState('worksubs', 'warning', 'Nessuna workload subscription selezionata');
        showBox('worksubs', true);
    }
}

// ============================================================
// INIT
// ============================================================

document.addEventListener('DOMContentLoaded', function () {
    document.getElementById('auth-button').addEventListener('click', function () {
        if (currentAccount) doLogout(); else doLogin();
    });

    // Wait for MSAL then start
    let attempts = 0;
    const wait = setInterval(() => {
        attempts++;
        if (typeof msal !== 'undefined' || attempts > 25) {
            clearInterval(wait);
            runAllChecks();
        }
    }, 200);
});

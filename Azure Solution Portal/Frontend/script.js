// ========================================
// CONFIGURAZIONE AMBIENTE
// ========================================

const API_BASE_URL = 'https://func-azsolportal-089fb2a1.azurewebsites.net';

console.log('🌍 Ambiente rilevato:', window.location.hostname === 'localhost' ? 'LOCALE' : 'AZURE');
console.log('🔗 API Base URL:', API_BASE_URL);

// ========================================
// METADATI SOLUZIONI
// ========================================

// GitHub raw base URL per i template ARM e gli script PowerShell
const GITHUB_RAW = 'https://raw.githubusercontent.com/fabiozappa1990x/Azure-Solution-Portal/main';

function deployToAzureUrl(folderEncoded) {
    const base = `${GITHUB_RAW}/${folderEncoded}`;
    const deployJsonUrl = encodeURIComponent(`${base}/portal-ui/deploy.json`);
    const createUiUrl   = encodeURIComponent(`${base}/portal-ui/createUiDefinition.json`);
    return `https://portal.azure.com/#create/Microsoft.Template/uri/${deployJsonUrl}/createUIDefinitionUri/${createUiUrl}`;
}

function psDownloadUrl(folderEncoded, scriptName) {
    return `${GITHUB_RAW}/${folderEncoded}/workload/scripts/${scriptName}`;
}

const SOLUTIONS = {
    'azure-monitor': {
        name: 'Azure Monitor Hub',
        detailsTitle: 'Azure Monitor Hub — Dettagli',
        details: {
            whatIs: 'Azure Monitor è la piattaforma di monitoraggio nativa di Azure per metriche, log (Log Analytics) e alert. Questo accelerator standardizza la raccolta dati (AMA + DCR), l’alerting e la visualizzazione per le VM.',
            features: [
                'Log Analytics Workspace e Data Collection Rules (DCR) per centralizzare i log',
                'Alert CPU/Memoria/Disco/Heartbeat con Action Group',
                'Workbook/Dashboard per overview e troubleshooting',
                'Policy per auto-enrollment delle nuove VM'
            ],
            notes: [
                'Il precheck evidenzia VM non monitorate, workspace/DCR esistenti e gap di configurazione.'
            ],
            docsAnchor: 'azure-monitor'
        },
        precheckTitle: 'Precheck Azure Monitor Hub',
        precheckDesc: 'Analizza VM, Log Analytics Workspace, DCR e agenti di monitoraggio nella sottoscrizione.',
        deployTitle: 'Deploy Azure Monitor Hub',
        deployDesc: 'Deploya Log Analytics Workspace, DCR, Alert Rules, AMA e dashboard di monitoraggio completo con 4 tab (Panoramica, Performance, Alert, Disponibilità).',
        portalUrl: deployToAzureUrl('Solution%20-%20Azure%20Monitor/Azure%20Monitor%20Hub%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Azure%20Monitor/Azure%20Monitor%20Hub%20-%20Deploy%20to%20Azure', 'Deploy-MonitorHub.ps1'),
        psCommand: '.\\Deploy-MonitorHub.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "my-monitoring"',
        apiEndpoint: '/api/precheck'
    },
    'avd': {
        name: 'Azure Virtual Desktop',
        detailsTitle: 'Azure Virtual Desktop — Dettagli',
        details: {
            whatIs: 'Azure Virtual Desktop (AVD) è il servizio Microsoft per pubblicare desktop e applicazioni virtuali (Windows 10/11 multi-session, Windows Server) con gestione centralizzata e accesso sicuro.',
            features: [
                'Host Pool (pooled/personal), Workspace e Application Group',
                'Session Hosts Windows 11 multi-session',
                'FSLogix per profili utente su Azure Files',
                'Scaling Plan per ottimizzare i costi'
            ],
            notes: [
                'Il precheck verifica prerequisiti rete, quote, identità e naming per un deploy “enterprise ready”.'
            ],
            docsAnchor: 'avd'
        },
        precheckTitle: 'Precheck Azure Virtual Desktop',
        precheckDesc: 'Verifica VNet, subnet, quote VM, join AD/AzureAD e tutti i prerequisiti per il deployment AVD.',
        deployTitle: 'Deploy Azure Virtual Desktop',
        deployDesc: 'Deploya Host Pool, Session Hosts Windows 11 multi-session, FSLogix su Azure Files (AADKERB) e Scaling Plan automatico.',
        portalUrl: deployToAzureUrl('Solution%20-%20Azure%20Virtual%20Desktop/Azure%20Virtual%20Desktop%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Azure%20Virtual%20Desktop/Azure%20Virtual%20Desktop%20-%20Deploy%20to%20Azure', 'Deploy-AVD.ps1'),
        psCommand: '.\\Deploy-AVD.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "avd-prod" -Location "westeurope" -VnetId "/subscriptions/.../virtualNetworks/vnet-prod" -SubnetName "snet-avd" -AdminUsername "avdadmin"',
        apiEndpoint: '/api/precheck-avd'
    },
    'backup': {
        name: 'Azure Backup',
        detailsTitle: 'Azure Backup — Dettagli',
        details: {
            whatIs: 'Azure Backup è il servizio per protezione e ripristino di workload (VM, file share, SQL in VM, ecc.) tramite Recovery Services Vault e policy di retention.',
            features: [
                'Creazione o utilizzo di un Recovery Services Vault (RSV)',
                'Policy di backup e retention (GFS) per VM (e policy workload opzionali)',
                'Protezione di workload selezionati (es. VM) e auto-protection via Azure Policy (opzionale)',
                'Soft delete per protezione da cancellazioni accidentali'
            ],
            notes: [
                'Per guida completa e prerequisiti dei workload, vedi la sezione Documentazione.'
            ],
            docsAnchor: 'backup'
        },
        precheckTitle: 'Precheck Azure Backup',
        precheckDesc: 'Analizza VM non protette, vault esistenti e policy di backup configurate nella sottoscrizione.',
        deployTitle: 'Deploy Azure Backup',
        deployDesc: 'Deploya Recovery Services Vault con GRS, policy GFS (Daily/Weekly/Monthly/Yearly), Enhanced Policy oraria e auto-protezione tramite Azure Policy con tag.',
        portalUrl: deployToAzureUrl('Solution%20-%20Azure%20Backup/Azure%20Backup%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Azure%20Backup/Azure%20Backup%20-%20Deploy%20to%20Azure', 'Deploy-Backup.ps1'),
        psCommand: '.\\Deploy-Backup.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "backup-prod"',
        apiEndpoint: '/api/precheck-backup'
    },
    'defender': {
        name: 'Microsoft Defender for Cloud',
        detailsTitle: 'Microsoft Defender for Cloud — Dettagli',
        details: {
            whatIs: 'Defender for Cloud combina posture management (CSPM) e protezioni avanzate (Defender Plans) per rilevare rischi e minacce su risorse Azure.',
            features: [
                'Abilitazione selettiva dei Defender Plans (Servers, Storage, Key Vault, ARM, ecc.)',
                'Security contact (email/ruoli) per notifiche e ownership',
                'Auto-provisioning (MDE/AMA) dove abilitato',
                'Assegnazione baseline (Microsoft Cloud Security Benchmark) per governance'
            ],
            notes: [
                'Per dettagli su piani, licenze e governance, vedi Documentazione (con reference accelerator Microsoft).'
            ],
            docsAnchor: 'defender'
        },
        precheckTitle: 'Precheck Microsoft Defender for Cloud',
        precheckDesc: 'Analizza piani Defender attivi, secure score, raccomandazioni critiche e copertura degli endpoint.',
        deployTitle: 'Deploy Microsoft Defender for Cloud',
        deployDesc: 'Abilita piani Defender (Server P1/P2, Storage, SQL, Key Vault, ARM, CSPM), contatti di sicurezza e auto-provisioning MDE.',
        portalUrl: deployToAzureUrl('Solution%20-%20Microsoft%20Defender/Microsoft%20Defender%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Microsoft%20Defender/Microsoft%20Defender%20-%20Deploy%20to%20Azure', 'Deploy-Defender.ps1'),
        psCommand: '.\\Deploy-Defender.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "defender-prod" -EmailRecipients "security@contoso.com"',
        apiEndpoint: '/api/precheck-defender'
    },
    'update-manager': {
        name: 'Azure Update Manager',
        detailsTitle: 'Azure Update Manager — Dettagli',
        details: {
            whatIs: 'Azure Update Manager gestisce assessment e patching di VM (Windows/Linux) con finestre di manutenzione controllate, compliance e automazione.',
            features: [
                'Maintenance Configuration (finestra/ricorrenza/timezone)',
                'Classificazioni update (Windows/Linux) e reboot policy',
                'Policy per periodic assessment e auto-patching (opzionali)',
                'Assegnazione della maintenance configuration a VM target'
            ],
            notes: [
                'Per setup consigliato e troubleshooting, vedi la sezione Documentazione.'
            ],
            docsAnchor: 'update-manager'
        },
        precheckTitle: 'Precheck Azure Update Manager',
        precheckDesc: 'Analizza VM con aggiornamenti in sospeso, Maintenance Configuration esistenti e compliance di patching.',
        deployTitle: 'Deploy Azure Update Manager',
        deployDesc: 'Deploya Maintenance Configuration con finestra di manutenzione configurabile (Weekly/Monthly), classificazioni e policy di auto-assessment/auto-patching.',
        portalUrl: deployToAzureUrl('Solution%20-%20Azure%20Update%20Manager/Azure%20Update%20Manager%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Azure%20Update%20Manager/Azure%20Update%20Manager%20-%20Deploy%20to%20Azure', 'Deploy-UpdateManager.ps1'),
        psCommand: '.\\Deploy-UpdateManager.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "updates-prod"',
        apiEndpoint: '/api/precheck-updates'
    },
    'zero-trust': {
        name: 'Zero Trust Assessment',
        detailsTitle: 'Zero Trust Assessment — Dettagli',
        details: {
            whatIs: 'Assessment tenant-scoped (Entra ID) basato su Microsoft Graph. Non effettua deploy: produce un report enterprise di posture e gap Zero Trust.',
            features: [
                'Security Defaults e baseline Conditional Access',
                'MFA registration e metodi di autenticazione',
                'Legacy authentication e controlli di accesso',
                'Governance (consent/app registration) e best practice'
            ],
            notes: [
                'Richiede permessi Microsoft Graph delegated e, tipicamente, admin consent.'
            ],
            docsAnchor: 'zero-trust'
        },
        precheckTitle: 'Zero Trust Assessment (Tenant)',
        precheckDesc: 'Analizza configurazioni Entra ID via Microsoft Graph per una valutazione Zero Trust enterprise.',
        deployTitle: 'Zero Trust Assessment',
        deployDesc: 'Assessment only: nessun deploy richiesto.',
        portalUrl: '#',
        psDownload: '',
        psCommand: 'N/A (assessment only)',
        apiEndpoint: '/api/precheck-zerotrust',
        scope: 'tenant',
        tokenScopes: ['User.Read', 'Policy.Read.All', 'Directory.Read.All', 'Reports.Read.All']
    }
};

// Soluzione correntemente selezionata
let currentSolution = 'azure-monitor';

// ========================================
// INIZIALIZZAZIONE MSAL
// ========================================

let msalInstance = null;
let currentAccessToken = null;
let currentAccount = null;
const POST_LOGIN_REDIRECT_KEY = 'asp.postLoginRedirect';

const msalConfig = {
    auth: {
        clientId: "4ace231a-ee3c-4bb8-aa9f-85105cecce6c",  // ← sostituisci con il Client ID della tua App Registration
        authority: "https://login.microsoftonline.com/common",  // oppure usa il tuo Tenant ID: "https://login.microsoftonline.com/<TENANT-ID>"
        redirectUri: window.location.origin,
        postLogoutRedirectUri: window.location.origin
    },
    cache: {
        cacheLocation: "sessionStorage",
        storeAuthStateInCookie: false
    }
};

const loginRequest = {
    scopes: ["https://management.azure.com/user_impersonation"]
};

// ========================================
// FUNZIONI DI AUTENTICAZIONE
// ========================================

async function initializeMSAL(retries = 3) {
    for (let i = 0; i < retries; i++) {
        try {
            if (typeof msal === 'undefined') {
                await new Promise(resolve => setTimeout(resolve, 1000));
                continue;
            }
            msalInstance = new msal.PublicClientApplication(msalConfig);
            await msalInstance.initialize();
            console.log('✅ MSAL inizializzato');
            return true;
        } catch (error) {
            if (i === retries - 1) {
                alert('❌ Errore nel caricamento del sistema di autenticazione.\n\n🔄 Ricarica la pagina.');
                return false;
            }
            await new Promise(resolve => setTimeout(resolve, 1000));
        }
    }
    return false;
}

async function initializeAuth() {
    const success = await initializeMSAL();
    if (!success) { updateAuthUI(false); return; }

    try {
        await msalInstance.handleRedirectPromise();
        const accounts = msalInstance.getAllAccounts();
        if (accounts.length > 0) {
            currentAccount = accounts[0];
            msalInstance.setActiveAccount(currentAccount);
            updateAuthUI(true, currentAccount.username);
	            try {
	                const response = await msalInstance.acquireTokenSilent({ ...loginRequest, account: currentAccount });
	                currentAccessToken = response.accessToken;
	            } catch {
	                currentAccessToken = null;
	            }

	            // Redirect flow may land on "/" (rewritten to setup.html). Return to original page if requested.
	            try {
	                const target = sessionStorage.getItem(POST_LOGIN_REDIRECT_KEY);
	                if (target) {
	                    sessionStorage.removeItem(POST_LOGIN_REDIRECT_KEY);
	                    if (target !== window.location.pathname + window.location.search) {
	                        window.location.href = target;
	                        return;
	                    }
	                }
	            } catch {}
	        } else {
	            updateAuthUI(false);
	        }
    } catch (error) {
        console.error("❌ Errore init auth:", error);
        updateAuthUI(false);
    }
}

async function handleAuthentication() {
    if (!msalInstance) { alert('❌ Sistema di autenticazione non disponibile.\n\n🔄 Ricarica la pagina.'); return; }
    const authButton = document.getElementById('auth-button');

    if (currentAccount) {
        try {
            // Use redirect flow to avoid popup issues under COOP/COEP policies.
            await msalInstance.logoutRedirect({ account: currentAccount, postLogoutRedirectUri: window.location.origin });
            return;
        } catch (error) {
            alert('❌ Errore durante il logout: ' + error.message);
        }
    } else {
        authButton.disabled = true;
        authButton.textContent = 'Accesso in corso...';
        try {
            // Remember current page: redirectUri is origin, SWA rewrites "/" to setup.html
            try { sessionStorage.setItem(POST_LOGIN_REDIRECT_KEY, window.location.pathname + window.location.search); } catch {}
            await msalInstance.loginRedirect(loginRequest);
            return;
        } catch (error) {
            let msg = error.message;
            if (error.errorCode === 'user_cancelled') msg = 'Login annullato';
            else if (error.errorCode === 'popup_window_error') msg = 'Popup bloccato dal browser.';
            alert("❌ Errore autenticazione:\n\n" + msg);
            updateAuthUI(false);
        } finally {
            authButton.disabled = false;
        }
    }
}

async function getAccessToken() {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    try {
        const response = await msalInstance.acquireTokenSilent({ ...loginRequest, account: currentAccount });
        currentAccessToken = response.accessToken;
        return currentAccessToken;
    } catch {
        await msalInstance.acquireTokenRedirect(loginRequest);
        return null;
    }
}

async function getAccessTokenForScopes(scopes) {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const req = { scopes, account: currentAccount };
    try {
        const response = await msalInstance.acquireTokenSilent(req);
        return response.accessToken;
    } catch {
        await msalInstance.acquireTokenRedirect(req);
        return null;
    }
}

function updateAuthUI(isAuthenticated, username = '') {
    const authIndicator = document.getElementById('auth-indicator');
    const authText = document.getElementById('auth-text');
    const authButton = document.getElementById('auth-button');
    if (!authIndicator || !authText || !authButton) return;

    const icon = authIndicator.querySelector('i');
    authButton.disabled = false;

    if (isAuthenticated) {
        authIndicator.className = 'auth-indicator authenticated';
        icon.className = 'fas fa-user-check';
        authText.textContent = username;
        authButton.textContent = 'Disconnetti';
    } else {
        authIndicator.className = 'auth-indicator not-authenticated';
        icon.className = 'fas fa-user-slash';
        authText.textContent = 'Non autenticato';
        authButton.textContent = 'Accedi con Microsoft';
    }
}

// ========================================
// INIZIALIZZAZIONE PAGINA
// ========================================

document.addEventListener('DOMContentLoaded', function() {
    console.log('✅ DOM caricato');
    initializeAuth();

    // Auth button
    document.getElementById('auth-button')?.addEventListener('click', handleAuthentication);

    // Pulsanti Precheck
    document.querySelectorAll('.btn-precheck').forEach(btn => {
        btn.addEventListener('click', function() {
            currentSolution = this.getAttribute('data-solution');
            showPrecheckModal(currentSolution);
        });
    });

    // Pulsanti Deploy
    document.querySelectorAll('.btn-deploy').forEach(btn => {
        btn.addEventListener('click', function() {
            currentSolution = this.getAttribute('data-solution');
            showDeployModal(currentSolution);
        });
    });

    // Pulsante Dettagli
    document.querySelectorAll('.btn-details').forEach(btn => {
        btn.addEventListener('click', function() {
            const sol = this.getAttribute('data-solution');
            showDetailsModal(sol);
        });
    });

    // ========================================
    // ESEGUI PRECHECK
    // ========================================

    document.getElementById('run-precheck')?.addEventListener('click', async function() {
        const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
        const scopeType = solConfig.scope || 'subscription';

        const subscriptionIds = scopeType === 'subscription' ? getSubscriptionIdsForPrecheckRun() : [];
        if (scopeType === 'subscription' && subscriptionIds.length === 0) { alert('⚠️ Inserisci o seleziona almeno una subscription'); return; }
        if (!currentAccount) { alert('⚠️ Devi effettuare il login prima di eseguire il precheck.\n\n🔐 Clicca su "Accedi con Microsoft".'); return; }

        console.log('🚀 Avvio precheck per:', currentSolution, scopeType === 'subscription' ? 'subscriptions:' : 'tenant:', scopeType === 'subscription' ? subscriptionIds : currentAccount.tenantId);

        document.querySelector('.precheck-form').style.display = 'none';
        document.getElementById('precheck-loading').style.display = 'block';
        document.getElementById('precheck-results').style.display = 'none';

	        try {
	            const accessToken = solConfig.tokenScopes ? await getAccessTokenForScopes(solConfig.tokenScopes) : await getAccessToken();
	            if (!accessToken) { return; } // interactive redirect started (consent/auth)

	            const loadingTextEl = document.querySelector('#precheck-loading p');
	            const originalLoadingText = loadingTextEl ? loadingTextEl.textContent : null;

            const resultsBySub = {};
            const orderedSubs = [];
            const errors = [];

            if (scopeType === 'tenant') {
                if (loadingTextEl) loadingTextEl.textContent = `Analisi tenant in corso... (${currentAccount.tenantId})`;
                const apiUrl = `${API_BASE_URL}${solConfig.apiEndpoint}?tenantId=${encodeURIComponent(currentAccount.tenantId)}`;
                const response = await fetch(apiUrl, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${accessToken}`,
                        'Content-Type': 'application/json'
                    }
                });

                if (!response.ok) {
                    const errorText = await response.text();
                    throw new Error(`Errore HTTP ${response.status}: ${errorText}`);
                }

                const data = await response.json();
                window.lastPrecheckResponsesBySub = null;
                window.lastPrecheckResponse = data;
                setupResultSubscriptionPicker([], {}, '');

                if (loadingTextEl && originalLoadingText) loadingTextEl.textContent = originalLoadingText;

                document.getElementById('precheck-loading').style.display = 'none';
                populatePrecheckResults(window.lastPrecheckResponse);
                document.getElementById('precheck-results').style.display = 'block';
                showTab('overview');
                return;
            }

            for (let i = 0; i < subscriptionIds.length; i++) {
                const subId = subscriptionIds[i];
                if (loadingTextEl) loadingTextEl.textContent = `Analisi in corso... (${i + 1}/${subscriptionIds.length}) Subscription: ${subId}`;

                const apiUrl = `${API_BASE_URL}${solConfig.apiEndpoint}?subscriptionId=${encodeURIComponent(subId)}`;
                const response = await fetch(apiUrl, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${accessToken}`,
                        'Content-Type': 'application/json'
                    }
                });

                if (!response.ok) {
                    const errorText = await response.text();
                    const msg =
                        response.status === 401 ? 'Token scaduto. Effettua nuovamente il login.' :
                        response.status === 403 ? 'Accesso negato. Verifica i permessi Reader sulla subscription.' :
                        response.status === 404 ? 'Subscription non trovata. Verifica l\'ID inserito.' :
                        `Errore HTTP ${response.status}: ${errorText}`;
                    errors.push({ subscriptionId: subId, message: msg });
                    continue;
                }

                const data = await response.json();
                resultsBySub[subId] = data;
                orderedSubs.push(subId);
            }

            if (loadingTextEl && originalLoadingText) loadingTextEl.textContent = originalLoadingText;

            if (orderedSubs.length === 0) {
                const details = errors.map(e => `- ${e.subscriptionId}: ${e.message}`).join('\n');
                throw new Error(`Nessun precheck completato.\n\nDettaglio:\n${details}`);
            }

            window.lastPrecheckResponsesBySub = resultsBySub;
            window.lastPrecheckResponse = resultsBySub[orderedSubs[0]];

            setupResultSubscriptionPicker(orderedSubs, resultsBySub, orderedSubs[0]);

            document.getElementById('precheck-loading').style.display = 'none';
            populatePrecheckResults(window.lastPrecheckResponse);
            document.getElementById('precheck-results').style.display = 'block';
            showTab('overview');

            if (errors.length > 0) {
                console.warn('Precheck completati parzialmente:', errors);
                alert(`⚠️ Precheck completato parzialmente: OK ${orderedSubs.length}/${subscriptionIds.length}.\n\nApri la console (F12) per i dettagli degli errori.`);
            }

        } catch (error) {
            console.error('❌ Errore precheck:', error);
            document.getElementById('precheck-loading').style.display = 'none';
            document.querySelector('.precheck-form').style.display = 'block';
            alert(`❌ Errore durante il precheck:\n\n${error.message}\n\n📋 Controlla la console per i dettagli (F12).`);
        }
    });

    // ========================================
    // POPOLA RISULTATI PRECHECK
    // ========================================

    function setTabVisible(tabId, visible) {
        const btn = document.querySelector(`.tab-button[data-tab="${tabId}"]`);
        const pane = document.getElementById(tabId);
        if (btn) btn.style.display = visible ? '' : 'none';
        if (pane) pane.style.display = visible ? '' : 'none';
    }

    function setTabText(tabId, text) {
        const btn = document.querySelector(`.tab-button[data-tab="${tabId}"]`);
        if (btn) btn.textContent = text;
    }

    function setPaneTitle(tabId, text) {
        const h = document.querySelector(`#${CSS.escape(tabId)} h4`);
        if (h) h.textContent = text;
    }

    function setTableHeaders(tableId, headers) {
        const theadRow = document.querySelector(`#${CSS.escape(tableId)} thead tr`);
        if (!theadRow) return;
        theadRow.innerHTML = headers.map(h => `<th>${h}</th>`).join('');
    }

    function setSummaryLabels(vmLabel, wsLabel) {
        const items = document.querySelectorAll('.report-summary .summary-item .summary-label');
        if (items.length >= 3) {
            items[1].textContent = vmLabel;
            items[2].textContent = wsLabel;
        }
    }

    function setOverviewLabels(labels) {
        const cards = document.querySelectorAll('#overview .overview-stats .stat-card .stat-label');
        for (let i = 0; i < Math.min(cards.length, labels.length); i++) {
            cards[i].textContent = labels[i];
        }
    }

    function setOverallStatus(text, level) {
        const statusEl = document.getElementById('overall-status');
        if (!statusEl) return;
        statusEl.textContent = text;
        if (level === 'success') statusEl.className = 'status-badge status-success';
        else if (level === 'warning') statusEl.className = 'status-badge status-warning';
        else if (level === 'danger') statusEl.className = 'status-badge status-danger';
        else statusEl.className = 'status-badge';
    }

    function renderReportHtmlInRecommendations(data) {
        const recContainer = document.getElementById('recommendations-content');
        if (!recContainer) return;
        recContainer.innerHTML = '';

        if (!data?.ReportHTML) {
            recContainer.innerHTML = '<p>Report HTML non disponibile per questa esecuzione.</p>';
            return;
        }

        const iframe = document.createElement('iframe');
        iframe.style.width = '100%';
        iframe.style.height = '720px';
        iframe.style.border = '1px solid #e1e1e1';
        iframe.style.borderRadius = '8px';
        iframe.setAttribute('sandbox', 'allow-same-origin');
        iframe.srcdoc = data.ReportHTML;
        recContainer.appendChild(iframe);
    }

    function applyPrecheckUiForSolution(solution) {
        if (solution === 'azure-monitor') {
            setSummaryLabels('VM Analizzate:', 'Workspace Esistenti:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Macchine Virtuali');
            setTabText('workspaces', 'Log Analytics');
            setTabText('dcr', 'Data Collection Rules');
            setTabText('recommendations', 'Raccomandazioni');
            setPaneTitle('overview', "Analisi dell'ambiente");
            setPaneTitle('virtual-machines', 'Dettaglio Macchine Virtuali');
            setPaneTitle('workspaces', 'Dettaglio Log Analytics Workspace');
            setPaneTitle('dcr', 'Dettaglio Data Collection Rules');
            setPaneTitle('recommendations', 'Raccomandazioni');
            setOverviewLabels(['VM Totali', 'VM Monitorate', 'Workspace', 'DCR']);
            setTableHeaders('vm-table', ['Nome VM', 'Gruppo di Risorse', 'Stato', 'Agente Monitor', 'Sistema Operativo']);
            setTableHeaders('workspace-table', ['Nome Workspace', 'Gruppo di Risorse', 'Regione', 'VM Insights', 'Retention (giorni)']);
            setTableHeaders('dcr-table', ['Nome DCR', 'Gruppo di Risorse', 'Tipo', 'Destinazione', 'VM Associate']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'avd') {
            setSummaryLabels('Session Hosts:', 'Workspaces:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Session Hosts');
            setTabText('workspaces', 'AVD Workspaces');
            setTabText('dcr', 'Rete');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', "Analisi dell'ambiente AVD");
            setPaneTitle('virtual-machines', 'Dettaglio Session Hosts');
            setPaneTitle('workspaces', 'Dettaglio Workspaces AVD');
            setPaneTitle('dcr', 'Dettaglio Virtual Network');
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Host Pool', 'Session Hosts', 'Workspaces', 'Scaling Plans']);
            setTableHeaders('vm-table', ['Host Pool', 'Session Host', 'Stato', 'Sessioni', 'Agent/OS']);
            setTableHeaders('workspace-table', ['Workspace', 'Gruppo di Risorse', 'Regione', 'App Groups', 'Note']);
            setTableHeaders('dcr-table', ['VNet', 'Gruppo di Risorse', 'Regione', 'Address Space', 'Subnet']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'backup') {
            setSummaryLabels('VM Totali:', 'Recovery Vaults:');
            setTabText('overview', 'Panoramica');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', "Stato Azure Backup");
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['VM Totali', 'VM Protette', 'VM Non Protette', 'Copertura (%)']);
            setTabVisible('virtual-machines', false);
            setTabVisible('workspaces', false);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'defender') {
            setSummaryLabels('Piani Standard:', 'Secure Score (%):');
            setTabText('overview', 'Panoramica');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', "Stato Defender for Cloud");
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Secure Score (%)', 'Piani Standard', 'High Recs', 'Security Contacts']);
            setTabVisible('virtual-machines', false);
            setTabVisible('workspaces', false);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'update-manager') {
            setSummaryLabels('VM Totali:', 'Maintenance Config:');
            setTabText('overview', 'Panoramica');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', "Stato Update Manager");
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['VM Totali', 'Auto patching', 'Manual patching', 'Critical pending']);
            setTabVisible('virtual-machines', false);
            setTabVisible('workspaces', false);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'zero-trust') {
            setSummaryLabels('Tenant:', 'Readiness:');
            setTabText('overview', 'Panoramica');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', "Zero Trust Assessment (Tenant)");
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Security Defaults', 'CA Enabled', 'MFA Reg (%)', 'Legacy Auth']);
            setTabVisible('virtual-machines', false);
            setTabVisible('workspaces', false);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        // Fallback: UI generica (mostra solo Overview + Report)
        setSummaryLabels('Risorse analizzate:', 'Metriche:');
        setTabText('overview', 'Panoramica');
        setTabText('recommendations', 'Report');
        setPaneTitle('overview', "Analisi dell'ambiente");
        setPaneTitle('recommendations', 'Report');
        setOverviewLabels(['KPI 1', 'KPI 2', 'KPI 3', 'KPI 4']);
        setTabVisible('virtual-machines', false);
        setTabVisible('workspaces', false);
        setTabVisible('dcr', false);
        setTabVisible('recommendations', true);
    }

    function renderMonitorPrecheck(data) {
        if (data.Summary) {
            document.getElementById('overview-vm-total').textContent   = data.Summary.TotalMachines || 0;
            document.getElementById('overview-vm-monitored').textContent = data.Summary.MachinesWithAMA || 0;
            document.getElementById('overview-workspaces').textContent  = data.Summary.TotalWorkspaces || 0;
            document.getElementById('overview-dcr').textContent         = data.Summary.TotalDCRs || 0;
            document.getElementById('vm-count').textContent             = data.Summary.TotalMachines || 0;
            document.getElementById('workspace-count').textContent      = data.Summary.TotalWorkspaces || 0;

            const pct = data.Summary.AMA_Coverage_Percent || 0;
            if (pct >= 80) setOverallStatus('Pronto per il deployment', 'success');
            else if (pct >= 50) setOverallStatus('Richiede configurazione', 'warning');
            else setOverallStatus('Configurazione incompleta', 'danger');
        }

        if (Array.isArray(data.AzureVMs)) {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            data.AzureVMs.forEach(vm => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${vm.Name || 'N/A'}</td>
                    <td>${vm.ResourceGroup || 'N/A'}</td>
                    <td>${vm.PowerState || 'Unknown'}</td>
                    <td>
                        ${vm.HasAMA ? '<span class="status-badge status-success">AMA</span>' : ''}
                        ${vm.HasLegacyMMA ? '<span class="status-badge status-warning">Legacy MMA</span>' : ''}
                        ${!vm.HasAMA && !vm.HasLegacyMMA ? '<span class="status-badge status-danger">Nessuno</span>' : ''}
                    </td>
                    <td>${vm.OsType || 'Unknown'}</td>`;
                tbody.appendChild(tr);
            });
        }

        if (Array.isArray(data.LogAnalyticsWorkspaces)) {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            data.LogAnalyticsWorkspaces.forEach(ws => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${ws.Name || 'N/A'}</td>
                    <td>${ws.ResourceGroup || 'N/A'}</td>
                    <td>${ws.Location || 'N/A'}</td>
                    <td>${ws.HasVMInsights ? '<span class="status-badge status-success">Abilitato</span>' : '<span class="status-badge status-danger">Disabilitato</span>'}</td>
                    <td>${ws.RetentionInDays || 'N/A'}</td>`;
                tbody.appendChild(tr);
            });
        }

        if (Array.isArray(data.DataCollectionRules)) {
            const tbody = document.querySelector('#dcr-table tbody');
            tbody.innerHTML = '';
            data.DataCollectionRules.forEach(dcr => {
                const assocCount = data.DCRAssociations
                    ? data.DCRAssociations.filter(a => a.DataCollectionRuleId === dcr.ResourceId).length
                    : 0;
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td>${dcr.Name || 'N/A'}</td>
                    <td>${dcr.ResourceGroup || 'N/A'}</td>
                    <td><span class="status-badge status-info">${dcr.Type || 'N/A'}</span></td>
                    <td>${dcr.Location || 'N/A'}</td>
                    <td>${assocCount}</td>`;
                tbody.appendChild(tr);
            });
        }

        // Raccomandazioni (solo Monitor)
        const recContainer = document.getElementById('recommendations-content');
        recContainer.innerHTML = '';
        const recs = [];

        if (data.Summary) {
            if (data.Summary.UnmonitoredMachines > 0)
                recs.push({ title: 'Installare Azure Monitor Agent', description: `${data.Summary.UnmonitoredMachines} macchine senza agenti di monitoraggio.`, priority: 'high' });
            if (data.Summary.TotalDCRs === 0)
                recs.push({ title: 'Configurare Data Collection Rules', description: 'Nessuna DCR presente. Necessaria per raccogliere metriche e log.', priority: 'high' });
            if (data.Summary.TotalActionGroups === 0)
                recs.push({ title: 'Creare Action Groups', description: 'Nessun Action Group per le notifiche. Configura almeno un gruppo.', priority: 'medium' });
            if (data.Summary.TotalMetricAlerts === 0 && data.Summary.TotalLogAlerts === 0)
                recs.push({ title: 'Configurare Alert', description: 'Nessun alert configurato. Crea alert per CPU, memoria e disco.', priority: 'medium' });
            if (data.Summary.MachinesWithLegacyMMA > 0)
                recs.push({ title: 'Migrare da Legacy MMA ad AMA', description: `${data.Summary.MachinesWithLegacyMMA} macchine usano ancora il legacy MMA.`, priority: 'medium' });
        }

        if (recs.length === 0) {
            recContainer.innerHTML = '<p style="color: #107c10;"><i class="fas fa-check-circle"></i> Nessuna raccomandazione critica. Ambiente configurato correttamente!</p>';
        } else {
            recs.forEach(rec => {
                const div = document.createElement('div');
                div.className = 'recommendation-item';
                const icon = rec.priority === 'high'
                    ? '<i class="fas fa-exclamation-triangle" style="color:#ff8c00;"></i>'
                    : '<i class="fas fa-info-circle" style="color:#0078d4;"></i>';
                div.innerHTML = `<div class="recommendation-title">${icon} ${rec.title}</div><div class="recommendation-description">${rec.description}</div>`;
                recContainer.appendChild(div);
            });
        }
    }

    function renderAvdPrecheck(data) {
        const summary = data?.Summary || {};
        const totalHostPools = summary.TotalHostPools ?? (Array.isArray(data.HostPools) ? data.HostPools.length : 0);
        const totalSessionHosts = summary.TotalSessionHosts ?? (Array.isArray(data.SessionHosts) ? data.SessionHosts.length : 0);
        const totalWorkspaces = summary.TotalWorkspaces ?? (Array.isArray(data.Workspaces) ? data.Workspaces.length : 0);
        const totalScalingPlans = summary.TotalScalingPlans ?? (Array.isArray(data.ScalingPlans) ? data.ScalingPlans.length : 0);
        const totalVNets = summary.TotalVNets ?? (Array.isArray(data.VirtualNetworks) ? data.VirtualNetworks.length : 0);

        document.getElementById('overview-vm-total').textContent = totalHostPools || 0;
        document.getElementById('overview-vm-monitored').textContent = totalSessionHosts || 0;
        document.getElementById('overview-workspaces').textContent = totalWorkspaces || 0;
        document.getElementById('overview-dcr').textContent = totalScalingPlans || 0;
        document.getElementById('vm-count').textContent = totalSessionHosts || 0;
        document.getElementById('workspace-count').textContent = totalWorkspaces || 0;

        const alreadyDeployed = Boolean(summary.AlreadyDeployed ?? (totalHostPools > 0));
        const readyForDeploy = Boolean(summary.ReadyForDeploy ?? (totalVNets > 0));
        if (alreadyDeployed) setOverallStatus('AVD già presente nella subscription', 'success');
        else if (readyForDeploy) setOverallStatus('Prerequisiti base OK (rete presente)', 'warning');
        else setOverallStatus('Prerequisiti mancanti (rete/risorse)', 'danger');

        // Session Hosts (tab "virtual-machines")
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.SessionHosts) ? data.SessionHosts : [];
            if (rows.length === 0) {
                const tr = document.createElement('tr');
                tr.innerHTML = `<td colspan="5">Nessun Session Host trovato.</td>`;
                tbody.appendChild(tr);
            } else {
                rows.forEach(sh => {
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${sh.HostPool || 'N/A'}</td>
                        <td>${sh.Name || 'N/A'}</td>
                        <td>${sh.Status || 'N/A'}</td>
                        <td>${(sh.Sessions ?? 'N/A')}</td>
                        <td>${sh.AgentVersion || sh.OSVersion || 'N/A'}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // AVD Workspaces
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.Workspaces) ? data.Workspaces : [];
            if (rows.length === 0) {
                const tr = document.createElement('tr');
                tr.innerHTML = `<td colspan="5">Nessun Workspace AVD trovato.</td>`;
                tbody.appendChild(tr);
            } else {
                rows.forEach(ws => {
                    const appGroups = Array.isArray(ws.AppGroupRefs) ? ws.AppGroupRefs.length : 0;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${ws.Name || 'N/A'}</td>
                        <td>${ws.ResourceGroup || 'N/A'}</td>
                        <td>${ws.Location || 'N/A'}</td>
                        <td>${appGroups}</td>
                        <td>${appGroups > 0 ? 'Collegato' : 'Non collegato'}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // VNets
        {
            const tbody = document.querySelector('#dcr-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.VirtualNetworks) ? data.VirtualNetworks : [];
            if (rows.length === 0) {
                const tr = document.createElement('tr');
                tr.innerHTML = `<td colspan="5">Nessuna Virtual Network trovata.</td>`;
                tbody.appendChild(tr);
            } else {
                rows.forEach(vnet => {
                    const addr = Array.isArray(vnet.AddressSpace) ? vnet.AddressSpace.join(', ') : (vnet.AddressSpace || 'N/A');
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${vnet.Name || 'N/A'}</td>
                        <td>${vnet.ResourceGroup || 'N/A'}</td>
                        <td>${vnet.Location || 'N/A'}</td>
                        <td>${addr}</td>
                        <td>${vnet.SubnetCount ?? 'N/A'}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Per AVD mostriamo direttamente il report HTML generato dal precheck.
        renderReportHtmlInRecommendations(data);
    }

    function setStatusFromReadiness(summary) {
        const score = Number(summary?.ReadinessScore);
        if (!Number.isFinite(score)) {
            setOverallStatus('Report disponibile nella tab "Report"', 'warning');
            return;
        }

        if (score >= 85) setOverallStatus(`Readiness ${score}% (Ready)`, 'success');
        else if (score >= 60) setOverallStatus(`Readiness ${score}% (Needs work)`, 'warning');
        else setOverallStatus(`Readiness ${score}% (Not ready)`, 'danger');
    }

    function renderBackupPrecheck(data) {
        const summary = data?.Summary || {};
        const totalVMs = summary.TotalVMs ?? 0;
        const protectedVMs = summary.ProtectedVMs ?? 0;
        const unprotectedVMs = summary.UnprotectedVMs ?? 0;
        const coverage = Number(summary.BackupCoverage_Pct ?? 0);
        const totalVaults = summary.TotalVaults ?? 0;

        document.getElementById('overview-vm-total').textContent = totalVMs;
        document.getElementById('overview-vm-monitored').textContent = protectedVMs;
        document.getElementById('overview-workspaces').textContent = unprotectedVMs;
        document.getElementById('overview-dcr').textContent = `${Number.isFinite(coverage) ? coverage : 0}%`;
        document.getElementById('vm-count').textContent = totalVMs;
        document.getElementById('workspace-count').textContent = totalVaults;

        setStatusFromReadiness(summary);
        renderReportHtmlInRecommendations(data);
    }

    function renderDefenderPrecheck(data) {
        const summary = data?.Summary || {};
        const secureScore = Number(summary.SecureScorePercent ?? 0);
        const enabledPlans = summary.EnabledPlans ?? 0;
        const highRecs = summary.HighSeverityRecs ?? 0;
        const contacts = summary.SecurityContactsCount ?? 0;

        document.getElementById('overview-vm-total').textContent = `${Number.isFinite(secureScore) ? secureScore : 0}%`;
        document.getElementById('overview-vm-monitored').textContent = enabledPlans;
        document.getElementById('overview-workspaces').textContent = highRecs;
        document.getElementById('overview-dcr').textContent = contacts;
        document.getElementById('vm-count').textContent = enabledPlans;
        document.getElementById('workspace-count').textContent = Number.isFinite(secureScore) ? secureScore : 0;

        setStatusFromReadiness(summary);
        renderReportHtmlInRecommendations(data);
    }

    function renderUpdatesPrecheck(data) {
        const summary = data?.Summary || {};
        const totalVMs = summary.TotalVMs ?? 0;
        const auto = summary.VMsWithAutoPatching ?? 0;
        const manual = summary.VMsWithManualPatching ?? 0;
        const critical = summary.CriticalUpdatesPending ?? 0;
        const maintenance = summary.TotalMaintenanceConfigs ?? 0;

        document.getElementById('overview-vm-total').textContent = totalVMs;
        document.getElementById('overview-vm-monitored').textContent = auto;
        document.getElementById('overview-workspaces').textContent = manual;
        document.getElementById('overview-dcr').textContent = critical;
        document.getElementById('vm-count').textContent = totalVMs;
        document.getElementById('workspace-count').textContent = maintenance;

        setStatusFromReadiness(summary);
        renderReportHtmlInRecommendations(data);
    }

    function renderZeroTrustPrecheck(data) {
        const summary = data?.Summary || {};
        const secDefaults = summary.SecurityDefaultsEnabled === true ? 'On' : (summary.SecurityDefaultsEnabled === false ? 'Off' : 'N/A');
        const caEnabled = summary.ConditionalAccessEnabledCount ?? 0;
        const mfaReg = Number(summary.MfaRegistrationPercent ?? 0);
        const legacy = summary.LegacyAuthBlocked === true ? 'Blocked' : (summary.LegacyAuthBlocked === false ? 'Allowed' : 'N/A');

        document.getElementById('overview-vm-total').textContent = secDefaults;
        document.getElementById('overview-vm-monitored').textContent = caEnabled;
        document.getElementById('overview-workspaces').textContent = `${Number.isFinite(mfaReg) ? mfaReg : 0}%`;
        document.getElementById('overview-dcr').textContent = legacy;
        document.getElementById('vm-count').textContent = summary.TenantDisplayName ?? 'Tenant';
        document.getElementById('workspace-count').textContent = summary.ReadinessScore ?? 'N/A';

        setStatusFromReadiness(summary);
        renderReportHtmlInRecommendations(data);
    }

    function populatePrecheckResults(data) {
        applyPrecheckUiForSolution(currentSolution);

        if (currentSolution === 'azure-monitor') {
            renderMonitorPrecheck(data);
            return;
        }

        if (currentSolution === 'avd') {
            renderAvdPrecheck(data);
            return;
        }

        if (currentSolution === 'backup') {
            renderBackupPrecheck(data);
            return;
        }

        if (currentSolution === 'defender') {
            renderDefenderPrecheck(data);
            return;
        }

        if (currentSolution === 'update-manager') {
            renderUpdatesPrecheck(data);
            return;
        }

        if (currentSolution === 'zero-trust') {
            renderZeroTrustPrecheck(data);
            return;
        }

        // Fallback: mostra report HTML e tenta di mettere qualche KPI
        const summary = data?.Summary || {};
        document.getElementById('overview-vm-total').textContent = summary.TotalVMs ?? summary.TotalVaults ?? summary.TotalPlans ?? summary.TotalMaintenanceConfigs ?? 0;
        document.getElementById('overview-vm-monitored').textContent = summary.ProtectedVMs ?? summary.EnabledPlans ?? summary.VMsWithAutoPatching ?? 0;
        document.getElementById('overview-workspaces').textContent = summary.UnprotectedVMs ?? summary.HighSeverityRecs ?? summary.VMsWithManualPatching ?? 0;
        document.getElementById('overview-dcr').textContent = summary.BackupCoverage_Pct ?? summary.SecureScorePercent ?? summary.CriticalUpdatesPending ?? 0;
        document.getElementById('vm-count').textContent = summary.TotalVMs ?? 0;
        document.getElementById('workspace-count').textContent = summary.TotalPolicies ?? summary.SecurityPoliciesCount ?? summary.TotalUpdatePolicies ?? 0;
        setOverallStatus('Report disponibile nella tab "Report"', 'warning');
        renderReportHtmlInRecommendations(data);
    }

    // ========================================
    // MULTI-SUBSCRIPTION SUPPORT (Precheck)
    // ========================================

    function isGuid(value) {
        return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);
    }

    function parseSubscriptionIds(raw) {
        if (!raw) return [];
        const parts = raw
            .split(/[\s,;]+/g)
            .map(s => s.trim())
            .filter(Boolean);
        const unique = [];
        const seen = new Set();
        for (const p of parts) {
            if (!isGuid(p)) continue;
            const k = p.toLowerCase();
            if (seen.has(k)) continue;
            seen.add(k);
            unique.push(p);
        }
        return unique;
    }

    function getSubscriptionIdsForPrecheckRun() {
        const picker = document.getElementById('subscription-picker');
        if (picker && picker.selectedOptions && picker.selectedOptions.length > 0) {
            return Array.from(picker.selectedOptions).map(o => o.value).filter(Boolean);
        }
        const input = document.getElementById('subscription-id');
        return parseSubscriptionIds(input ? input.value : '');
    }

	    async function listSubscriptionsForAccount() {
	        const token = await getAccessToken();
	        if (!token) return [];
	        const resp = await fetch('https://management.azure.com/subscriptions?api-version=2022-12-01', {
	            headers: { Authorization: `Bearer ${token}` }
	        });
        if (!resp.ok) throw new Error(`Management API subscriptions: HTTP ${resp.status}`);
        const data = await resp.json();
        return data.value || [];
    }

    async function loadSubscriptionsIntoPicker() {
        const wrap = document.getElementById('subscription-picker-wrap');
        const picker = document.getElementById('subscription-picker');
        if (!wrap || !picker) return;
        if (!currentAccount) {
            alert('⚠️ Fai login prima di caricare le subscription.');
            return;
        }
        const btn = document.getElementById('load-subscriptions');
        const prev = btn ? btn.textContent : null;
        if (btn) btn.textContent = 'Caricamento...';

        try {
            const subs = await listSubscriptionsForAccount();
            picker.innerHTML = subs
                .map(s => `<option value="${s.subscriptionId}">${s.displayName} (${s.subscriptionId})</option>`)
                .join('');
            wrap.style.display = 'block';
        } catch (e) {
            alert(`❌ Impossibile caricare le subscription: ${e.message}`);
        } finally {
            if (btn && prev) btn.textContent = prev;
        }
    }

    function setupResultSubscriptionPicker(orderedSubs, resultsBySub, selectedSubId) {
        const wrap = document.getElementById('sub-result-wrap');
        const select = document.getElementById('result-sub-select');
        if (!wrap || !select) return;

        if (!orderedSubs || orderedSubs.length <= 1) {
            wrap.style.display = 'none';
            select.innerHTML = '';
            return;
        }

        select.innerHTML = orderedSubs.map(subId => {
            const d = resultsBySub[subId];
            const name = d?.Subscription?.Name ? String(d.Subscription.Name) : subId;
            return `<option value="${subId}">${name} (${subId})</option>`;
        }).join('');

        wrap.style.display = '';
        select.value = selectedSubId;

        select.onchange = () => {
            const subId = select.value;
            const data = resultsBySub[subId];
            if (!data) return;
            window.lastPrecheckResponse = data;
            populatePrecheckResults(data);
            showTab('overview');
        };
    }

    document.getElementById('load-subscriptions')?.addEventListener('click', async function() {
        await loadSubscriptionsIntoPicker();
    });

    // ========================================
    // TAB
    // ========================================

    document.querySelectorAll('.tab-button').forEach(btn => {
        btn.addEventListener('click', function() { showTab(this.getAttribute('data-tab')); });
    });

    function showTab(tabId) {
        document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.tab-button').forEach(b => b.classList.remove('active'));
        document.getElementById(tabId)?.classList.add('active');
        document.querySelector(`.tab-button[data-tab="${tabId}"]`)?.classList.add('active');
    }

    // ========================================
    // DOWNLOAD REPORT
    // ========================================

    document.getElementById('download-report')?.addEventListener('click', async function() {
        try {
            if (!window.lastPrecheckResponse?.ReportHTML)
                throw new Error('Report HTML non disponibile. Esegui prima il precheck.');
            const blob = new Blob([window.lastPrecheckResponse.ReportHTML], { type: 'text/html' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `Azure-${currentSolution}-Report-${new Date().toISOString().split('T')[0]}.html`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            alert('✅ Report scaricato con successo!');
        } catch (error) {
            alert('❌ ' + error.message);
        }
    });

    // Procedi con deployment
    document.getElementById('proceed-to-deploy')?.addEventListener('click', function() {
        document.getElementById('precheck-modal').style.display = 'none';
        showDeployModal(currentSolution);
    });

    // Copia comando PowerShell
    document.getElementById('copy-precheck-command')?.addEventListener('click', function() {
        const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
        if (solConfig.scope === 'tenant') {
            alert('ℹ️ Questa soluzione è tenant-scoped (assessment only): non è previsto un comando PowerShell di deploy.');
            return;
        }
        const subIds = getSubscriptionIdsForPrecheckRun();
        const subscriptionId = subIds.length > 0 ? subIds[0] : '';
        if (!subscriptionId) { alert('⚠️ Inserisci o seleziona prima una subscription'); return; }
        const command = solConfig.psCommand.replace('YOUR-SUB-ID', subscriptionId);
        navigator.clipboard.writeText(command).then(() => {
            const orig = this.textContent;
            this.textContent = '✓ Copiato!';
            this.style.backgroundColor = '#107c10';
            setTimeout(() => { this.textContent = orig; this.style.backgroundColor = ''; }, 2000);
        }).catch(() => alert('❌ Errore nella copia'));
    });

    // ========================================
    // CHIUSURA MODALI
    // ========================================

    document.querySelectorAll('.close-modal').forEach(btn => {
        btn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            const modal = this.closest('.modal');
            if (modal) { closeModal(modal); }
        });
    });

    window.addEventListener('click', function(e) {
        if (e.target.classList.contains('modal')) { closeModal(e.target); }
    });

    function closeModal(modal) {
        modal.style.display = 'none';
        if (modal.id === 'precheck-modal') {
            document.querySelector('.precheck-form').style.display = 'block';
            document.getElementById('precheck-loading').style.display = 'none';
            document.getElementById('precheck-results').style.display = 'none';
        }
    }
});

// ========================================
// FUNZIONI GLOBALI MODALI
// ========================================

function showPrecheckModal(solution) {
    const modal = document.getElementById('precheck-modal');
    const solConfig = SOLUTIONS[solution] || SOLUTIONS['azure-monitor'];

    document.getElementById('precheck-modal-title').textContent = solConfig.precheckTitle;
    document.getElementById('precheck-modal-desc').textContent  = solConfig.precheckDesc;

    const isTenantScoped = solConfig.scope === 'tenant';
    const subGroup = document.getElementById('subscription-form-group');
    const rgGroup = document.getElementById('resourcegroup-form-group');
    if (subGroup) subGroup.style.display = isTenantScoped ? 'none' : '';
    if (rgGroup) rgGroup.style.display = isTenantScoped ? 'none' : '';

    // Reset state
    document.querySelector('.precheck-form').style.display = 'block';
    document.getElementById('precheck-loading').style.display = 'none';
    document.getElementById('precheck-results').style.display = 'none';
    document.getElementById('subscription-id').value = '';

    // Prefill from setup "workload subscriptions" if available (subscription-scoped only)
    if (!isTenantScoped) {
        try {
            const saved = localStorage.getItem('asp.workloadSubIds');
            const arr = saved ? JSON.parse(saved) : [];
            if (Array.isArray(arr) && arr.length > 0) {
                document.getElementById('subscription-id').value = arr.join('\n');
            }
        } catch {}
    }

    // Reset multi-subscription UI
    const pickerWrap = document.getElementById('subscription-picker-wrap');
    const picker = document.getElementById('subscription-picker');
    if (pickerWrap) pickerWrap.style.display = 'none';
    if (picker) picker.innerHTML = '';
    const subResultWrap = document.getElementById('sub-result-wrap');
    const resultSelect = document.getElementById('result-sub-select');
    if (subResultWrap) subResultWrap.style.display = 'none';
    if (resultSelect) resultSelect.innerHTML = '';
    window.lastPrecheckResponsesBySub = null;

    modal.style.display = 'block';
}

function showDeployModal(solution) {
    const modal = document.getElementById('deploy-modal');
    const solConfig = SOLUTIONS[solution] || SOLUTIONS['azure-monitor'];

    document.getElementById('deploy-modal-title').textContent = solConfig.deployTitle;
    document.getElementById('deploy-modal-desc').textContent  = solConfig.deployDesc;

    // ── Deploy to Azure button ──
    const portalLink   = document.getElementById('deploy-portal-link');
    const portalOption = document.getElementById('deploy-portal-option');

    // Always show Deploy to Azure (URL will be correct once repo is published)
    portalLink.href = solConfig.portalUrl;
    portalOption.style.display = 'flex';

    // ── PowerShell — download opzionale ──
    const psBlock    = document.getElementById('deploy-ps-command');
    const psDownArea = document.getElementById('deploy-ps-download-area');

    if (psBlock) {
        psBlock.innerHTML = `<code>${escapeHtml(solConfig.psCommand)}</code>`;
    }

    if (psDownArea) {
        if (solConfig.psDownload && !solConfig.psDownload.includes('PLACEHOLDER')) {
            psDownArea.innerHTML = `
                <a href="${solConfig.psDownload}" class="btn-ps-download" download target="_blank">
                    <i class="fas fa-download"></i> Scarica script PowerShell
                </a>`;
        } else {
            psDownArea.innerHTML = `
                <span class="ps-not-available">
                    <i class="fas fa-info-circle"></i>
                    Script disponibile dopo il push su GitHub
                </span>`;
        }
    }

    modal.style.display = 'block';
}

function showDetailsModal(solution) {
    const modal = document.getElementById('details-modal');
    const solConfig = SOLUTIONS[solution] || SOLUTIONS['azure-monitor'];

    const titleEl = document.getElementById('details-modal-title');
    const bodyEl = document.getElementById('details-modal-body');
    const docLink = document.getElementById('details-doc-link');

    if (titleEl) titleEl.textContent = solConfig.detailsTitle || `Dettagli — ${solConfig.name}`;

    const details = solConfig.details || {};
    const features = Array.isArray(details.features) ? details.features : [];
    const notes = Array.isArray(details.notes) ? details.notes : [];

    bodyEl.innerHTML = `
        <p style="margin-top: 0;">${escapeHtml(details.whatIs || '')}</p>
        ${features.length ? `<h4 style="margin: 18px 0 10px;">Funzionalità incluse</h4>
        <ul class="solution-features" style="margin: 0;">
            ${features.map(f => `<li><i class="fas fa-check"></i> ${escapeHtml(f)}</li>`).join('')}
        </ul>` : ''}
        ${notes.length ? `<h4 style="margin: 18px 0 10px;">Note</h4>
        <ul class="solution-features" style="margin: 0;">
            ${notes.map(n => `<li><i class="fas fa-info-circle"></i> ${escapeHtml(n)}</li>`).join('')}
        </ul>` : ''}
        <p style="margin: 18px 0 0;">Per guide operative, prerequisiti e riferimenti ufficiali, consulta la sezione <b>Documentazione</b>.</p>
    `;

    if (docLink) {
        const anchor = details.docsAnchor ? `#${details.docsAnchor}` : '';
        docLink.href = `documentation.html${anchor}`;
    }

    modal.style.display = 'block';
}

function escapeHtml(str) {
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

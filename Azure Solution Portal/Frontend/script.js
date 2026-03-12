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
        precheckTitle: 'Precheck Azure Update Manager',
        precheckDesc: 'Analizza VM con aggiornamenti in sospeso, Maintenance Configuration esistenti e compliance di patching.',
        deployTitle: 'Deploy Azure Update Manager',
        deployDesc: 'Deploya Maintenance Configuration con finestra di manutenzione configurabile (Weekly/Monthly), classificazioni e policy di auto-assessment/auto-patching.',
        portalUrl: deployToAzureUrl('Solution%20-%20Azure%20Update%20Manager/Azure%20Update%20Manager%20-%20Deploy%20to%20Azure'),
        psDownload: psDownloadUrl('Solution%20-%20Azure%20Update%20Manager/Azure%20Update%20Manager%20-%20Deploy%20to%20Azure', 'Deploy-UpdateManager.ps1'),
        psCommand: '.\\Deploy-UpdateManager.ps1 -SubscriptionId "YOUR-SUB-ID" -DeploymentName "updates-prod"',
        apiEndpoint: '/api/precheck-updates'
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
            try {
                const response = await msalInstance.acquireTokenSilent({ ...loginRequest, account: currentAccount });
                currentAccessToken = response.accessToken;
                updateAuthUI(true, currentAccount.username);
            } catch {
                currentAccessToken = null;
                updateAuthUI(false);
            }
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
            await msalInstance.logoutPopup({ account: currentAccount, postLogoutRedirectUri: window.location.origin });
            currentAccessToken = null;
            currentAccount = null;
            updateAuthUI(false);
        } catch (error) {
            alert('❌ Errore durante il logout: ' + error.message);
        }
    } else {
        authButton.disabled = true;
        authButton.textContent = 'Accesso in corso...';
        try {
            const response = await msalInstance.loginPopup(loginRequest);
            currentAccount = response.account;
            currentAccessToken = response.accessToken;
            msalInstance.setActiveAccount(currentAccount);
            updateAuthUI(true, currentAccount.username);
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
        const response = await msalInstance.acquireTokenPopup(loginRequest);
        currentAccessToken = response.accessToken;
        return currentAccessToken;
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
            alert(`ℹ️ ${SOLUTIONS[sol]?.name || sol}\n\nDocumentazione completa disponibile nella cartella docs/ della soluzione.`);
        });
    });

    // ========================================
    // ESEGUI PRECHECK
    // ========================================

    document.getElementById('run-precheck')?.addEventListener('click', async function() {
        const subscriptionId = document.getElementById('subscription-id').value.trim();

        if (!subscriptionId) { alert('⚠️ Inserisci l\'ID della sottoscrizione Azure'); return; }
        if (!currentAccount) { alert('⚠️ Devi effettuare il login prima di eseguire il precheck.\n\n🔐 Clicca su "Accedi con Microsoft".'); return; }

        console.log('🚀 Avvio precheck per:', currentSolution, 'subscription:', subscriptionId);

        document.querySelector('.precheck-form').style.display = 'none';
        document.getElementById('precheck-loading').style.display = 'block';
        document.getElementById('precheck-results').style.display = 'none';

        try {
            const accessToken = await getAccessToken();
            const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
            const apiUrl = `${API_BASE_URL}${solConfig.apiEndpoint}?subscriptionId=${encodeURIComponent(subscriptionId)}`;

            const response = await fetch(apiUrl, {
                method: 'GET',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/json'
                }
            });

            if (!response.ok) {
                const errorText = await response.text();
                if (response.status === 401) throw new Error('Token scaduto. Effettua nuovamente il login.');
                if (response.status === 403) throw new Error('Accesso negato. Verifica i permessi Reader sulla subscription.');
                if (response.status === 404) throw new Error('Subscription non trovata. Verifica l\'ID inserito.');
                throw new Error(`Errore HTTP ${response.status}: ${errorText}`);
            }

            const data = await response.json();
            window.lastPrecheckResponse = data;

            document.getElementById('precheck-loading').style.display = 'none';
            populatePrecheckResults(data);
            document.getElementById('precheck-results').style.display = 'block';
            showTab('overview');

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

    function populatePrecheckResults(data) {
        if (data.Summary) {
            document.getElementById('overview-vm-total').textContent   = data.Summary.TotalMachines || 0;
            document.getElementById('overview-vm-monitored').textContent = data.Summary.MachinesWithAMA || 0;
            document.getElementById('overview-workspaces').textContent  = data.Summary.TotalWorkspaces || 0;
            document.getElementById('overview-dcr').textContent         = data.Summary.TotalDCRs || 0;
            document.getElementById('vm-count').textContent             = data.Summary.TotalMachines || 0;
            document.getElementById('workspace-count').textContent      = data.Summary.TotalWorkspaces || 0;

            const pct = data.Summary.AMA_Coverage_Percent || 0;
            const statusEl = document.getElementById('overall-status');
            if (pct >= 80) { statusEl.textContent = 'Pronto per il deployment'; statusEl.className = 'status-badge status-success'; }
            else if (pct >= 50) { statusEl.textContent = 'Richiede configurazione'; statusEl.className = 'status-badge status-warning'; }
            else { statusEl.textContent = 'Configurazione incompleta'; statusEl.className = 'status-badge status-danger'; }
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

        // Raccomandazioni
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
        const subscriptionId = document.getElementById('subscription-id').value.trim();
        if (!subscriptionId) { alert('⚠️ Inserisci prima l\'ID della sottoscrizione'); return; }
        const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
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

    // Reset state
    document.querySelector('.precheck-form').style.display = 'block';
    document.getElementById('precheck-loading').style.display = 'none';
    document.getElementById('precheck-results').style.display = 'none';
    document.getElementById('subscription-id').value = '';

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

function escapeHtml(str) {
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

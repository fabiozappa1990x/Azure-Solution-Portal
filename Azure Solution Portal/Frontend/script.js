// ========================================
// CONFIGURAZIONE AMBIENTE
// ========================================

const API_BASE_URL = 'https://func-azsolportal-089fb2a1.azurewebsites.net';
const LS_SUBS = 'azsp.selectedSubIds';

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

function getSavedSubscriptionIds() {
    try {
        const raw = localStorage.getItem(LS_SUBS);
        if (!raw) return [];
        if (!raw.trim().startsWith('[')) return [raw].filter(Boolean);
        const arr = JSON.parse(raw);
        return Array.isArray(arr) ? arr.map(s => String(s).trim()).filter(Boolean) : [];
    } catch {
        return [];
    }
}

function parseSubscriptionIds(input) {
    const parts = String(input || '')
        .split(',')
        .map(s => s.trim())
        .filter(Boolean);

    // Keep only GUID-like ids (avoid accidental text)
    const guidRe = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
    const valid = parts.filter(p => guidRe.test(p));
    return Array.from(new Set(valid));
}

async function fetchSubscriptionsForUser(accessToken) {
    const resp = await fetch('https://management.azure.com/subscriptions?api-version=2022-12-01', {
        headers: { 'Authorization': `Bearer ${accessToken}` }
    });
    if (!resp.ok) throw new Error(`Impossibile leggere subscriptions (HTTP ${resp.status})`);
    const data = await resp.json();
    return data.value || [];
}

function renderSubscriptionPicker(container, subs, preselected) {
    const selected = new Set(preselected || []);
    const rows = subs.slice(0, 80).map(s => {
        const id = String(s.subscriptionId || '').trim();
        const name = String(s.displayName || '');
        const checked = selected.has(id) ? 'checked' : '';
        return `
            <label class="sub-item">
                <input type="checkbox" class="precheck-sub-check" value="${id}" ${checked} />
                <span class="sub-meta">
                    <span class="sub-name">${name}</span>
                    <span class="sub-id">${id}</span>
                </span>
            </label>`;
    }).join('');

    container.innerHTML = `
        <div class="sub-picker">
            <div class="sub-picker-header">
                <div class="sub-picker-title">Seleziona subscription</div>
                <div class="sub-picker-search">
                    <i class="fas fa-search" style="color:#666"></i>
                    <input type="text" id="precheck-sub-search" placeholder="Cerca per nome o ID..." />
                </div>
            </div>
            <div class="sub-picker-body" id="precheck-sub-list">
                ${rows}
            </div>
            <div class="sub-picker-actions">
                <button type="button" class="btn-primary" id="btn-use-subs">Usa selezione</button>
                <button type="button" class="btn-secondary" id="btn-hide-subs">Chiudi</button>
            </div>
            <div class="sub-picker-note">
                Mostrate ${Math.min(subs.length,80)}/${subs.length}. Per liste grandi usa la pagina Setup.
            </div>
        </div>
    `;

    const search = container.querySelector('#precheck-sub-search');
    const list = container.querySelector('#precheck-sub-list');
    if (search && list) {
        search.addEventListener('input', () => {
            const q = search.value.trim().toLowerCase();
            list.querySelectorAll('.sub-item').forEach(row => {
                const text = row.textContent.toLowerCase();
                row.style.display = !q || text.includes(q) ? '' : 'none';
            });
        });
    }
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
        apiEndpoint: '/api/precheck',
        apiEndpointV2: '/api/precheck-monitor-v2'
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
    'intune': {
        name: 'Microsoft Intune',
        detailsTitle: 'Microsoft Intune — Dettagli',
        details: {
            whatIs: 'Microsoft Intune è la soluzione cloud di Microsoft per la gestione di dispositivi mobili (MDM) e applicazioni mobili (MAM). Questo precheck analizza il tenant Intune per fornire un inventario completo: dispositivi gestiti, app rilevate sui device e applicazioni deployate.',
            features: [
                'Inventario dispositivi gestiti: Windows, iOS, Android, macOS',
                'App rilevate su ogni dispositivo con versione installata',
                'App deployate in Intune con stato di assegnazione',
                'Compliance score per piattaforma e readiness report'
            ],
            notes: [
                'Precheck: DeviceManagementApps.Read.All, DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All.',
                'Deploy Baseline: richiede anche DeviceManagementConfiguration.ReadWrite.All e DeviceManagementServiceConfig.ReadWrite.All.',
                'Il precheck è tenant-wide: la subscription viene usata solo per l\'autenticazione.'
            ],
            docsAnchor: 'intune'
        },
        precheckTitle: 'Precheck Microsoft Intune',
        precheckDesc: 'Analizza dispositivi gestiti, app rilevate e applicazioni deployate nel tenant Intune.',
        deployTitle: 'Microsoft Intune',
        deployDesc: 'Esegui prima il Precheck, poi usa il wizard "Configura Baseline Sicurezza" per deployare le policy standard mancanti nel tenant.',
        portalUrl: '#',
        psDownload: null,
        psCommand: '# Nessun deploy necessario per Intune',
        apiEndpoint: '/api/precheck-intune'
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

async function getGraphToken() {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const scopes = [
        "https://graph.microsoft.com/DeviceManagementApps.Read.All",
        "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
        "https://graph.microsoft.com/DeviceManagementConfiguration.Read.All",
        "https://graph.microsoft.com/Organization.Read.All"
    ];
    try {
        const response = await msalInstance.acquireTokenSilent({ scopes, account: currentAccount });
        return response.accessToken;
    } catch {
        // Scoppi admin-consent-required: forza popup con consenso esplicito
        try {
            const response = await msalInstance.acquireTokenPopup({ scopes, account: currentAccount, prompt: 'consent' });
            return response.accessToken;
        } catch (e) {
            // Se DeviceManagementConfiguration fallisce, riprova senza quel scope (degraded mode)
            if (e.message && (e.message.includes('400') || e.message.includes('consent') || e.message.includes('scope'))) {
                const fallbackScopes = [
                    "https://graph.microsoft.com/DeviceManagementApps.Read.All",
                    "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
                    "https://graph.microsoft.com/Organization.Read.All"
                ];
                const response = await msalInstance.acquireTokenPopup({ scopes: fallbackScopes, account: currentAccount });
                return response.accessToken;
            }
            throw e;
        }
    }
}

async function getGraphTokenWithWrite() {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const graphRequest = {
        scopes: [
            "https://graph.microsoft.com/DeviceManagementApps.Read.All",
            "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
            "https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All",
            "https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All",
            "https://graph.microsoft.com/Organization.Read.All"
        ],
        account: currentAccount
    };
    try {
        const response = await msalInstance.acquireTokenSilent(graphRequest);
        return response.accessToken;
    } catch {
        const response = await msalInstance.acquireTokenPopup(graphRequest);
        return response.accessToken;
    }
}

// ============================================================
// INTUNE BASELINE CATALOG
// ============================================================
const INTUNE_BASELINE = {
    windows: {
        label: 'Windows 10/11',
        icon: '🪟',
        policies: [
            {
                id: 'win-compliance',
                name: 'Windows - Compliance Baseline',
                category: 'Compliance',
                critical: true,
                description: 'Password 12+, BitLocker, Defender attivo, Firewall, OS minimo',
                type: 'compliancePolicy',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies',
                odataType: '#microsoft.graph.windows10CompliancePolicy',
                body: {
                    '@odata.type': '#microsoft.graph.windows10CompliancePolicy',
                    displayName: '[Baseline] Windows - Compliance',
                    description: 'Policy di conformità minima per dispositivi Windows gestiti da Intune',
                    passwordRequired: true,
                    passwordMinimumLength: 12,
                    passwordRequiredType: 'alphanumeric',
                    passwordPreviousPasswordBlockCount: 5,
                    storageRequireEncryption: true,
                    bitLockerEnabled: true,
                    secureBootEnabled: true,
                    codeIntegrityEnabled: true,
                    activeFirewallRequired: true,
                    defenderEnabled: true,
                    rtpEnabled: true,
                    antivirusRequired: true,
                    antiSpywareRequired: true,
                    scheduledActionsForRule: [{ ruleName: 'MarkAsNoncompliant', scheduledActionConfigurations: [{ actionType: 'block', gracePeriodHours: 0 }] }]
                }
            },
            {
                id: 'win-endpoint-protection',
                name: 'Windows - Endpoint Protection',
                category: 'Sicurezza',
                critical: true,
                description: 'Defender AV, real-time protection, cloud protection, PUA block, Firewall',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.windows10EndpointProtectionConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.windows10EndpointProtectionConfiguration',
                    displayName: '[Baseline] Windows - Endpoint Protection',
                    description: 'Defender Antivirus, Firewall e protezione avanzata',
                    defenderBlockEndUserAccess: false,
                    defenderRequireBehaviorMonitoring: true,
                    defenderRequireCloudProtection: true,
                    defenderRequireNetworkInspectionSystem: true,
                    defenderRequireRealTimeMonitoring: true,
                    defenderScanArchiveFiles: true,
                    defenderScanDownloads: true,
                    defenderScanNetworkFiles: true,
                    defenderScanIncomingMail: true,
                    defenderScanRemovableDrivesDuringFullScan: true,
                    defenderCloudBlockLevel: 'high',
                    defenderCloudExtendedTimeout: 50,
                    defenderPotentiallyUnwantedAppAction: 'block',
                    firewallEnabled: true
                }
            },
            {
                id: 'win-bitlocker',
                name: 'Windows - BitLocker',
                category: 'Encryption',
                critical: true,
                description: 'BitLocker OS drive AES-256, recovery key in Azure AD',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.windows10GeneralConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.windows10GeneralConfiguration',
                    displayName: '[Baseline] Windows - BitLocker',
                    description: 'Cifratura disco BitLocker con recovery key in Azure AD',
                    bitLockerEncryptDevice: true,
                    bitLockerDisableWarningForOtherDiskEncryption: true,
                    bitLockerAllowStandardUserEncryption: true,
                    bitLockerRecoverPasswordFromAad: true
                }
            },
            {
                id: 'win-screenlock',
                name: 'Windows - Screen Lock & Password',
                category: 'Password',
                critical: false,
                description: 'Blocco schermo 15 min, password 12+ alfanumerica',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.windows10GeneralConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.windows10GeneralConfiguration',
                    displayName: '[Baseline] Windows - Screen Lock',
                    description: 'Blocco schermo automatico e requisiti password',
                    passwordRequired: true,
                    passwordMinimumLength: 12,
                    passwordRequiredType: 'alphanumeric',
                    passwordPreviousPasswordBlockCount: 5,
                    passwordExpirationDays: 90,
                    passwordMinutesOfInactivityBeforeScreenTimeout: 15,
                    passwordMinimumCharacterSetCount: 3
                }
            }
        ]
    },
    macos: {
        label: 'macOS',
        icon: '🍎',
        policies: [
            {
                id: 'mac-compliance',
                name: 'macOS - Compliance Baseline',
                category: 'Compliance',
                critical: true,
                description: 'Password 12+, FileVault, SIP richiesto, OS minimo 13.0',
                type: 'compliancePolicy',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies',
                odataType: '#microsoft.graph.macOSCompliancePolicy',
                body: {
                    '@odata.type': '#microsoft.graph.macOSCompliancePolicy',
                    displayName: '[Baseline] macOS - Compliance',
                    description: 'Policy di conformità minima per dispositivi macOS gestiti da Intune',
                    passwordRequired: true,
                    passwordMinimumLength: 12,
                    passwordRequiredType: 'alphanumeric',
                    passwordPreviousPasswordBlockCount: 5,
                    passwordMaximumAgeDays: 90,
                    passwordMinutesOfInactivityBeforeLock: 15,
                    storageRequireEncryption: true,
                    systemIntegrityProtectionEnabled: true,
                    firewallEnabled: true,
                    osMinimumVersion: '13.0',
                    scheduledActionsForRule: [{ ruleName: 'MarkAsNoncompliant', scheduledActionConfigurations: [{ actionType: 'block', gracePeriodHours: 0 }] }]
                }
            },
            {
                id: 'mac-endpoint-protection',
                name: 'macOS - Endpoint Protection',
                category: 'Sicurezza',
                critical: true,
                description: 'FileVault, Firewall stealth mode, Gatekeeper app identificate',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.macOSEndpointProtectionConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.macOSEndpointProtectionConfiguration',
                    displayName: '[Baseline] macOS - Endpoint Protection',
                    description: 'FileVault, Firewall e Gatekeeper per macOS',
                    fileVaultEnabled: true,
                    fileVaultSelectedRecoveryKeyTypes: 'personalRecoveryKey',
                    fileVaultPersonalRecoveryKeyHelpMessage: 'Conserva questa chiave in luogo sicuro.',
                    fileVaultAllowDeferralUntilSignOut: true,
                    fileVaultNumberOfTimesUserCanIgnore: 3,
                    fileVaultPersonalRecoveryKeyRotationInMonths: 6,
                    firewallEnabled: true,
                    firewallBlockAllIncomingConnections: false,
                    firewallEnableStealthMode: true,
                    gatekeeperAllowedAppSource: 'macAppStoreAndIdentifiedDevelopers'
                }
            },
            {
                id: 'mac-screenlock',
                name: 'macOS - Screen Lock',
                category: 'Password',
                critical: false,
                description: 'Blocco schermo 15 min, password alfanumerica con simboli',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.macOSGeneralDeviceConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.macOSGeneralDeviceConfiguration',
                    displayName: '[Baseline] macOS - Screen Lock',
                    description: 'Timeout schermo e requisiti password per macOS',
                    passwordRequired: true,
                    passwordMinimumLength: 12,
                    passwordRequiredType: 'alphanumericWithSymbol',
                    passwordPreviousPasswordBlockCount: 5,
                    passwordMaximumAgeDays: 90,
                    passwordMinutesOfInactivityBeforeScreenTimeout: 15,
                    passwordMinutesOfInactivityBeforeLock: 15,
                    passwordMinimumCharacterSetCount: 3
                }
            }
        ]
    },
    ios: {
        label: 'iOS / iPadOS',
        icon: '📱',
        policies: [
            {
                id: 'ios-compliance',
                name: 'iOS/iPadOS - Compliance Baseline',
                category: 'Compliance',
                critical: true,
                description: 'Passcode 6+, anti-jailbreak, OS minimo iOS 16.0',
                type: 'compliancePolicy',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies',
                odataType: '#microsoft.graph.iosCompliancePolicy',
                body: {
                    '@odata.type': '#microsoft.graph.iosCompliancePolicy',
                    displayName: '[Baseline] iOS/iPadOS - Compliance',
                    description: 'Policy di conformità minima per dispositivi iOS/iPadOS',
                    passcodeRequired: true,
                    passcodeMinimumLength: 6,
                    passcodeRequiredType: 'numeric',
                    passcodeMinutesOfInactivityBeforeLock: 5,
                    passcodeExpirationDays: 90,
                    passcodePreviousPasscodeBlockCount: 5,
                    passcodeSimpleBlocked: true,
                    securityBlockJailbrokenDevices: true,
                    osMinimumVersion: '16.0',
                    scheduledActionsForRule: [{ ruleName: 'MarkAsNoncompliant', scheduledActionConfigurations: [{ actionType: 'block', gracePeriodHours: 0 }] }]
                }
            },
            {
                id: 'ios-restrictions',
                name: 'iOS/iPadOS - Restrizioni Sicurezza',
                category: 'Sicurezza',
                critical: true,
                description: 'Passcode lock 5 min, blocco clipboard cross-app, app store restrictions',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.iosGeneralDeviceConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.iosGeneralDeviceConfiguration',
                    displayName: '[Baseline] iOS - Restrizioni Sicurezza',
                    description: 'Restrizioni di sicurezza base per dispositivi iOS/iPadOS aziendali',
                    passcodeRequired: true,
                    passcodeMinimumLength: 6,
                    passcodeRequiredType: 'numeric',
                    passcodeMinutesOfInactivityBeforeScreenTimeout: 5,
                    passcodeMinutesOfInactivityBeforeLock: 5,
                    passcodeExpirationDays: 90,
                    passcodePreviousPasscodeBlockCount: 5,
                    passcodeSimpleBlocked: true,
                    safariBlockJavaScript: false,
                    safariBlockPopups: false
                }
            },
            {
                id: 'ios-email',
                name: 'iOS/iPadOS - Email Aziendale',
                category: 'Email',
                critical: false,
                description: 'Profilo email gestito da Intune, SSL, sincronizzazione calendario/contatti',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.iosEasEmailProfileConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.iosEasEmailProfileConfiguration',
                    displayName: '[Baseline] iOS - Email Aziendale',
                    description: 'Profilo email aziendale gestito da Intune',
                    accountName: 'Corporate Email',
                    authenticationMethod: 'usernameAndPassword',
                    hostName: 'outlook.office365.com',
                    requireSsl: true,
                    emailAddressSource: 'primarySmtpAddress',
                    usernameSource: 'userPrincipalName',
                    emailSyncDuration: 'oneMonth',
                    emailSyncSchedule: 'fifteenMinutes',
                    syncCalendar: true,
                    syncContacts: true,
                    syncTasks: true
                }
            }
        ]
    },
    android: {
        label: 'Android Enterprise',
        icon: '🤖',
        policies: [
            {
                id: 'android-compliance-workprofile',
                name: 'Android - Work Profile Compliance',
                category: 'Compliance',
                critical: true,
                description: 'Password 6+ numericComplx, anti-root, Play Protect, security patch 2024',
                type: 'compliancePolicy',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies',
                odataType: '#microsoft.graph.androidWorkProfileCompliancePolicy',
                body: {
                    '@odata.type': '#microsoft.graph.androidWorkProfileCompliancePolicy',
                    displayName: '[Baseline] Android - Work Profile Compliance',
                    description: 'Policy di conformità per dispositivi Android Enterprise (Work Profile)',
                    passwordRequired: true,
                    passwordMinimumLength: 6,
                    passwordRequiredType: 'numericComplex',
                    passwordExpirationDays: 90,
                    passwordPreviousPasswordBlockCount: 5,
                    passwordMinutesOfInactivityBeforeLock: 5,
                    securityPreventInstallAppsFromUnknownSources: true,
                    securityDisableUsbDebugging: true,
                    securityRequireVerifyApps: true,
                    securityBlockJailbrokenDevices: true,
                    minAndroidSecurityPatchLevel: '2024-01-01',
                    osMinimumVersion: '10.0',
                    scheduledActionsForRule: [{ ruleName: 'MarkAsNoncompliant', scheduledActionConfigurations: [{ actionType: 'block', gracePeriodHours: 0 }] }]
                }
            },
            {
                id: 'android-compliance-deviceowner',
                name: 'Android - Fully Managed Compliance',
                category: 'Compliance',
                critical: false,
                description: 'Compliance per dispositivi Android Fully Managed / Device Owner',
                type: 'compliancePolicy',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies',
                odataType: '#microsoft.graph.androidDeviceOwnerCompliancePolicy',
                body: {
                    '@odata.type': '#microsoft.graph.androidDeviceOwnerCompliancePolicy',
                    displayName: '[Baseline] Android - Device Owner Compliance',
                    description: 'Policy conformità per Android Fully Managed/Device Owner',
                    passwordRequired: true,
                    passwordMinimumLength: 6,
                    passwordRequiredType: 'numericComplex',
                    passwordExpirationDays: 90,
                    passwordPreviousPasswordBlockCount: 5,
                    passwordMinutesOfInactivityBeforeLock: 5,
                    securityRequireVerifyApps: true,
                    minAndroidSecurityPatchLevel: '2024-01-01',
                    osMinimumVersion: '10.0',
                    scheduledActionsForRule: [{ ruleName: 'MarkAsNoncompliant', scheduledActionConfigurations: [{ actionType: 'block', gracePeriodHours: 0 }] }]
                }
            },
            {
                id: 'android-config-workprofile',
                name: 'Android - Work Profile Config',
                category: 'Sicurezza',
                critical: true,
                description: 'Work profile password, blocco copy-paste cross-profile, permessi app',
                type: 'configurationProfile',
                endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
                odataType: '#microsoft.graph.androidWorkProfileGeneralDeviceConfiguration',
                body: {
                    '@odata.type': '#microsoft.graph.androidWorkProfileGeneralDeviceConfiguration',
                    displayName: '[Baseline] Android - Work Profile Config',
                    description: 'Configurazione sicurezza work profile Android Enterprise',
                    workProfilePasswordRequired: true,
                    workProfilePasswordMinimumLength: 6,
                    workProfilePasswordRequiredType: 'numericComplex',
                    workProfilePasswordExpirationDays: 90,
                    workProfilePasswordPreviousPasswordBlockCount: 5,
                    workProfilePasswordMinutesOfInactivityBeforeScreenTimeout: 5,
                    workProfileBlockCrossProfileCopyPaste: true,
                    workProfileDefaultAppPermissionPolicy: 'prompt'
                }
            }
        ]
    }
};

// ============================================================
// INTUNE BASELINE WIZARD
// ============================================================
function openIntuneBaselineWizard() {
    const modal = document.getElementById('intune-baseline-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    initBaselineWizard();
}

function initBaselineWizard() {
    // Reset step 1
    document.getElementById('baseline-step-1').style.display = '';
    document.getElementById('baseline-step-2').style.display = 'none';
    document.getElementById('baseline-step-3').style.display = 'none';
    updateBaselineStepIndicator(1);

    // Platform card toggle
    document.querySelectorAll('.baseline-platform-card').forEach(card => {
        const inner = card.querySelector('div');
        const checkbox = card.querySelector('input[type=checkbox]');
        checkbox.checked = false;
        inner.style.borderColor = '#e0e7ef';
        inner.style.background = '';

        // Remove old listener by cloning
        const newCard = card.cloneNode(true);
        card.parentNode.replaceChild(newCard, card);
        newCard.addEventListener('click', () => {
            const cb = newCard.querySelector('input[type=checkbox]');
            cb.checked = !cb.checked;
            const div = newCard.querySelector('div');
            if (cb.checked) {
                div.style.borderColor = '#0078d4';
                div.style.background = '#f0f6ff';
            } else {
                div.style.borderColor = '#e0e7ef';
                div.style.background = '';
            }
            const anySelected = document.querySelectorAll('.baseline-platform-card input:checked').length > 0;
            document.getElementById('baseline-step1-next').disabled = !anySelected;
        });
    });

    document.getElementById('baseline-step1-next').disabled = true;

    // Step1 → Step2
    const nextBtn = document.getElementById('baseline-step1-next');
    const newNext = nextBtn.cloneNode(true);
    nextBtn.parentNode.replaceChild(newNext, nextBtn);
    newNext.addEventListener('click', () => renderBaselineStep2());

    // Step2 back
    const backBtn = document.getElementById('baseline-step2-back');
    const newBack = backBtn.cloneNode(true);
    backBtn.parentNode.replaceChild(newBack, backBtn);
    newBack.addEventListener('click', () => {
        document.getElementById('baseline-step-2').style.display = 'none';
        document.getElementById('baseline-step-1').style.display = '';
        updateBaselineStepIndicator(1);
    });

    // Step2 deploy
    const deployBtn = document.getElementById('baseline-step2-deploy');
    const newDeploy = deployBtn.cloneNode(true);
    deployBtn.parentNode.replaceChild(newDeploy, deployBtn);
    newDeploy.addEventListener('click', () => runBaselineDeploy());

    // Step3 close
    const closeBtn = document.getElementById('baseline-step3-close');
    const newClose = closeBtn.cloneNode(true);
    closeBtn.parentNode.replaceChild(newClose, closeBtn);
    newClose.addEventListener('click', () => {
        document.getElementById('intune-baseline-modal').style.display = 'none';
    });

    // Modal close X
    const closeX = document.getElementById('intune-baseline-close');
    const newCloseX = closeX.cloneNode(true);
    closeX.parentNode.replaceChild(newCloseX, closeX);
    newCloseX.addEventListener('click', () => {
        document.getElementById('intune-baseline-modal').style.display = 'none';
    });
}

function updateBaselineStepIndicator(activeStep) {
    document.querySelectorAll('.baseline-step-indicator').forEach(el => {
        const step = parseInt(el.dataset.step);
        if (step === activeStep) {
            el.style.background = '#0078d4';
            el.style.color = 'white';
        } else if (step < activeStep) {
            el.style.background = '#107c10';
            el.style.color = 'white';
        } else {
            el.style.background = '#e0e7ef';
            el.style.color = '#666';
        }
    });
}

function getBaselineExistingTypes() {
    const data = window.lastPrecheckResponse || {};
    const compPolicies = Array.isArray(data.ExistingCompliancePolicies) ? data.ExistingCompliancePolicies : [];
    const configProfiles = Array.isArray(data.ExistingConfigProfiles) ? data.ExistingConfigProfiles : [];
    const allTypes = new Set();
    [...compPolicies, ...configProfiles].forEach(p => {
        if (p.OdataType) allTypes.add(p.OdataType.toLowerCase());
    });
    return allTypes;
}

function isPolicyPresent(policy, existingTypes) {
    const type = policy.odataType.toLowerCase();
    // Also check display name match for [Baseline] policies already deployed
    const data = window.lastPrecheckResponse || {};
    const compPolicies = Array.isArray(data.ExistingCompliancePolicies) ? data.ExistingCompliancePolicies : [];
    const configProfiles = Array.isArray(data.ExistingConfigProfiles) ? data.ExistingConfigProfiles : [];
    const allNames = [...compPolicies, ...configProfiles].map(p => (p.DisplayName || '').toLowerCase());
    const baselineName = policy.body.displayName.toLowerCase();
    if (allNames.some(n => n === baselineName)) return true;
    return existingTypes.has(type);
}

function renderBaselineStep2() {
    document.getElementById('baseline-step-1').style.display = 'none';
    document.getElementById('baseline-step-2').style.display = '';
    updateBaselineStepIndicator(2);

    const selectedPlatforms = Array.from(document.querySelectorAll('.baseline-platform-card input:checked')).map(cb => cb.value);
    const existingTypes = getBaselineExistingTypes();
    const container = document.getElementById('baseline-policy-list');
    container.innerHTML = '';

    selectedPlatforms.forEach(platform => {
        const platformData = INTUNE_BASELINE[platform];
        if (!platformData) return;

        const platformHeader = document.createElement('div');
        platformHeader.style.cssText = 'padding:10px 14px;background:#f0f6ff;font-weight:700;font-size:13px;border-bottom:1px solid #e0e7ef;display:flex;align-items:center;gap:8px;';
        platformHeader.innerHTML = `<span>${platformData.icon}</span><span>${platformData.label}</span>`;
        container.appendChild(platformHeader);

        platformData.policies.forEach(policy => {
            const present = isPolicyPresent(policy, existingTypes);
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;gap:12px;padding:10px 14px;border-bottom:1px solid #f0f0f0;';
            row.innerHTML = `
                <input type="checkbox" class="baseline-policy-check" data-platform="${platform}" data-id="${policy.id}" ${present ? 'disabled' : ''} style="width:16px;height:16px;flex-shrink:0;">
                <div style="flex:1;min-width:0;">
                    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
                        <span style="font-weight:600;font-size:13px;">${escapeHtml(policy.name)}</span>
                        ${policy.critical ? '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">CRITICA</span>' : ''}
                        <span style="background:#e3f2fd;color:#0078d4;border-radius:4px;padding:1px 6px;font-size:10px;">${escapeHtml(policy.category)}</span>
                    </div>
                    <div style="font-size:12px;color:#666;margin-top:2px;">${escapeHtml(policy.description)}</div>
                </div>
                <span style="flex-shrink:0;background:${present ? '#107c10' : '#d13438'};color:white;border-radius:4px;padding:2px 10px;font-size:11px;font-weight:700;white-space:nowrap;">${present ? 'PRESENTE' : 'MANCANTE'}</span>`;
            container.appendChild(row);
        });
    });

    // Select all missing by default
    container.querySelectorAll('.baseline-policy-check:not([disabled])').forEach(cb => {
        cb.checked = true;
    });
    updateBaselineDeployCount();

    // Live count update
    container.addEventListener('change', updateBaselineDeployCount);
}

function updateBaselineDeployCount() {
    const checked = document.querySelectorAll('.baseline-policy-check:checked:not([disabled])').length;
    const countEl = document.getElementById('baseline-selected-count');
    const deployBtn = document.getElementById('baseline-step2-deploy');
    if (countEl) countEl.textContent = `${checked} policy selezionate`;
    if (deployBtn) deployBtn.disabled = checked === 0;
}

async function runBaselineDeploy() {
    document.getElementById('baseline-step-2').style.display = 'none';
    document.getElementById('baseline-step-3').style.display = '';
    updateBaselineStepIndicator(3);

    const logEl = document.getElementById('baseline-deploy-log');
    const summaryEl = document.getElementById('baseline-deploy-summary');
    const closeBtn = document.getElementById('baseline-step3-close');
    logEl.innerHTML = '';

    function log(msg, color) {
        const line = document.createElement('div');
        line.style.color = color || '#d4d4d4';
        line.textContent = msg;
        logEl.appendChild(line);
        logEl.scrollTop = logEl.scrollHeight;
    }

    log('Acquisizione token Graph con permessi di scrittura...', '#569cd6');
    let token;
    try {
        token = await getGraphTokenWithWrite();
        log('✓ Token acquisito.', '#4ec9b0');
    } catch (e) {
        log(`✗ Errore token: ${e.message}`, '#f44747');
        summaryEl.textContent = '❌ Impossibile acquisire il token. Verifica i permessi dell\'App Registration.';
        summaryEl.style.color = '#d13438';
        closeBtn.style.display = '';
        return;
    }

    const selectedChecks = Array.from(document.querySelectorAll('.baseline-policy-check:checked:not([disabled])'));
    const toDeployIds = selectedChecks.map(cb => cb.dataset.id);

    let deployed = 0, failed = 0;

    for (const platform of Object.keys(INTUNE_BASELINE)) {
        for (const policy of INTUNE_BASELINE[platform].policies) {
            if (!toDeployIds.includes(policy.id)) continue;
            log(`→ Deploy: ${policy.name}`, '#9cdcfe');
            try {
                const resp = await fetch(policy.endpoint, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(policy.body)
                });
                if (resp.ok) {
                    const result = await resp.json();
                    log(`  ✓ Creata: ${result.displayName || policy.name} (id: ${result.id || '?'})`, '#4ec9b0');
                    deployed++;
                } else {
                    const errText = await resp.text();
                    let errMsg = errText;
                    try { errMsg = JSON.parse(errText)?.error?.message || errText; } catch {}
                    log(`  ✗ Errore HTTP ${resp.status}: ${errMsg}`, '#f44747');
                    failed++;
                }
            } catch (e) {
                log(`  ✗ Errore rete: ${e.message}`, '#f44747');
                failed++;
            }
        }
    }

    log('', '');
    log(`=== COMPLETATO: ${deployed} policy create, ${failed} errori ===`, failed > 0 ? '#ff8c00' : '#4ec9b0');
    summaryEl.textContent = `${deployed} policy deployate con successo${failed > 0 ? `, ${failed} errori` : ''}.`;
    summaryEl.style.color = failed > 0 ? '#d13438' : '#107c10';
    closeBtn.style.display = '';
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

    document.getElementById('btn-load-subs')?.addEventListener('click', async function() {
        try {
            if (!currentAccount) { alert('⚠️ Effettua il login prima di caricare le subscriptions.'); return; }
            const accessToken = await getAccessToken();
            const subs = await fetchSubscriptionsForUser(accessToken);

            const picker = document.getElementById('precheck-sub-picker');
            if (!picker) return;
            picker.style.display = 'block';

            const current = parseSubscriptionIds(document.getElementById('subscription-id')?.value || '');
            const saved = getSavedSubscriptionIds();
            const preselected = current.length ? current : saved;

            renderSubscriptionPicker(picker, subs, preselected);

            picker.querySelector('#btn-hide-subs')?.addEventListener('click', () => { picker.style.display = 'none'; });
            picker.querySelector('#btn-use-subs')?.addEventListener('click', () => {
                const checked = Array.from(picker.querySelectorAll('.precheck-sub-check'))
                    .filter(el => el.checked)
                    .map(el => String(el.value || '').trim())
                    .filter(Boolean);
                if (!checked.length) { alert('⚠️ Seleziona almeno una subscription.'); return; }
                document.getElementById('subscription-id').value = checked.join(',');
                try { localStorage.setItem(LS_SUBS, JSON.stringify(checked)); } catch {}
                picker.style.display = 'none';
            });
        } catch (e) {
            alert('❌ Errore nel caricamento subscriptions: ' + e.message);
        }
    });

    document.getElementById('run-precheck')?.addEventListener('click', async function() {
        if (!currentAccount) { alert('⚠️ Devi effettuare il login prima di eseguire il precheck.\n\n🔐 Clicca su "Accedi con Microsoft".'); return; }

        // Intune è tenant-wide: non richiede una subscription Azure
        let subscriptionIds;
        if (currentSolution === 'intune') {
            subscriptionIds = ['tenant-only'];
        } else {
            const subscriptionInput = document.getElementById('subscription-id').value.trim();
            subscriptionIds = parseSubscriptionIds(subscriptionInput);
            if (!subscriptionIds.length) { alert('⚠️ Inserisci almeno un SubscriptionId valido (GUID).'); return; }
        }

        console.log('🚀 Avvio precheck per:', currentSolution, 'subscriptions:', subscriptionIds.join(','));

        document.querySelector('.precheck-form').style.display = 'none';
        document.getElementById('precheck-loading').style.display = 'block';
        document.getElementById('precheck-results').style.display = 'none';

        try {
            const accessToken = await getAccessToken();
            const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
            const useV2 = (currentSolution === 'azure-monitor') && document.getElementById('use-precheck2')?.checked && solConfig.apiEndpointV2;
            const endpoint = useV2 ? solConfig.apiEndpointV2 : solConfig.apiEndpoint;
            const results = [];

            // Per Intune è necessario un token Graph separato (audience diverso)
            let graphToken = null;
            if (currentSolution === 'intune') {
                try {
                    graphToken = await getGraphToken();
                } catch (e) {
                    throw new Error(`Impossibile ottenere il token Microsoft Graph.\n\nAssicurati che l'App Registration abbia il consenso per DeviceManagementApps.Read.All e DeviceManagementManagedDevices.Read.All.\n\nDettaglio: ${e.message}`);
                }
            }

            for (const subId of subscriptionIds) {
                const apiUrl = `${API_BASE_URL}${endpoint}?subscriptionId=${encodeURIComponent(subId)}`;
                const reqHeaders = {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/json'
                };
                if (graphToken) reqHeaders['X-Graph-Token'] = graphToken;
                const response = await fetch(apiUrl, {
                    method: 'GET',
                    headers: reqHeaders
                });

                if (!response.ok) {
                    const errorText = await response.text();
                    if (response.status === 401) throw new Error('Token scaduto. Effettua nuovamente il login.');
                    if (response.status === 403) throw new Error(`Accesso negato sulla subscription ${subId}. Verifica i permessi Reader.`);
                    if (response.status === 404) throw new Error(`Subscription non trovata: ${subId}.`);
                    throw new Error(`Errore HTTP ${response.status} su ${subId}: ${errorText}`);
                }

                const data = await response.json();
                results.push({ subscriptionId: subId, data });
            }

            const data = (results.length === 1)
                ? results[0].data
                : { multi: true, results };

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

        if (solution === 'updates') {
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

        if (solution === 'intune') {
            setSummaryLabels('Dispositivi Gestiti:', 'App Rilevate:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Dispositivi');
            setTabText('workspaces', 'App Rilevate');
            setTabText('dcr', 'App Deployate');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', 'Stato Microsoft Intune');
            setPaneTitle('virtual-machines', 'Dispositivi Gestiti');
            setPaneTitle('workspaces', 'App Rilevate sui Dispositivi');
            setPaneTitle('dcr', 'App Deployate in Intune');
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Dispositivi Gestiti', 'Conformi', 'App Rilevate', 'App Deployate']);
            setTableHeaders('vm-table', ['Nome Dispositivo', 'OS', 'Versione OS', 'Conformità', 'Ultimo Sync', 'Utente']);
            setTableHeaders('workspace-table', ['Nome App', 'Versione', 'Publisher', 'N° Dispositivi', 'Piattaforma']);
            setTableHeaders('dcr-table', ['Nome App', 'Tipo', 'Publisher', 'Assegnata', 'Stato']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
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

    function renderIntunePrecheck(data) {
        const summary = data?.Summary || {};
        const totalDevices   = summary.TotalManagedDevices ?? 0;
        const compliant      = summary.CompliantDevices ?? 0;
        const totalDetected  = summary.TotalDetectedApps ?? 0;
        const totalDeployed  = summary.TotalDeployedApps ?? 0;
        const compliancePct  = summary.CompliancePct ?? 0;

        document.getElementById('overview-vm-total').textContent    = totalDevices;
        document.getElementById('overview-vm-monitored').textContent = compliant;
        document.getElementById('overview-workspaces').textContent   = totalDetected;
        document.getElementById('overview-dcr').textContent          = totalDeployed;
        document.getElementById('vm-count').textContent              = totalDevices;
        document.getElementById('workspace-count').textContent       = totalDetected;

        if (compliancePct >= 80) setOverallStatus(`Conformità ${compliancePct}% — Ambiente OK`, 'success');
        else if (compliancePct >= 50) setOverallStatus(`Conformità ${compliancePct}% — Richiede attenzione`, 'warning');
        else setOverallStatus(`Conformità ${compliancePct}% — Dispositivi non conformi`, 'danger');

        // Tab Dispositivi
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.ManagedDevices) ? data.ManagedDevices : [];
            if (rows.length === 0) {
                tbody.innerHTML = `<tr><td colspan="6">Nessun dispositivo gestito trovato.</td></tr>`;
            } else {
                rows.slice(0, 200).forEach(d => {
                    const compClass = d.Compliance === 'compliant' ? 'status-success' : d.Compliance === 'noncompliant' ? 'status-danger' : '';
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${escapeHtml(d.Name || 'N/A')}</td>
                        <td>${escapeHtml(d.OS || 'N/A')}</td>
                        <td>${escapeHtml(d.OSVersion || 'N/A')}</td>
                        <td><span class="status-badge ${compClass}">${escapeHtml(d.Compliance || 'N/A')}</span></td>
                        <td>${escapeHtml(d.LastSync || 'N/A')}</td>
                        <td>${escapeHtml(d.User || '')}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab App Rilevate
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.DetectedApps) ? data.DetectedApps : [];
            if (rows.length === 0) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna app rilevata.</td></tr>`;
            } else {
                rows.slice(0, 100).forEach(app => {
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${escapeHtml(app.DisplayName || 'N/A')}</td>
                        <td>${escapeHtml(app.Version || 'N/A')}</td>
                        <td>${escapeHtml(app.Publisher || 'N/A')}</td>
                        <td><strong>${app.DeviceCount ?? 0}</strong></td>
                        <td>${escapeHtml(app.Platform || 'N/A')}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab App Deployate
        {
            const tbody = document.querySelector('#dcr-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.DeployedApps) ? data.DeployedApps : [];
            if (rows.length === 0) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna app deployata trovata.</td></tr>`;
            } else {
                rows.forEach(app => {
                    const assignedBadge = app.IsAssigned
                        ? '<span class="status-badge status-success">Si</span>'
                        : '<span class="status-badge">No</span>';
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td>${escapeHtml(app.DisplayName || 'N/A')}</td>
                        <td>${escapeHtml(app.Type || 'N/A')}</td>
                        <td>${escapeHtml(app.Publisher || 'N/A')}</td>
                        <td>${assignedBadge}</td>
                        <td>${escapeHtml(app.PublishingState || 'N/A')}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Baseline button in overview
        const overviewPane = document.getElementById('overview');
        const existingBaselineBtn = document.getElementById('intune-baseline-btn-overview');
        if (existingBaselineBtn) existingBaselineBtn.remove();

        const existingComp = Array.isArray(data.ExistingCompliancePolicies) ? data.ExistingCompliancePolicies.length : '?';
        const existingConf = Array.isArray(data.ExistingConfigProfiles) ? data.ExistingConfigProfiles.length : '?';
        const baselineBanner = document.createElement('div');
        baselineBanner.id = 'intune-baseline-btn-overview';
        baselineBanner.style.cssText = 'margin-top:20px;padding:16px;background:linear-gradient(135deg,#f0f6ff,#e8f0fe);border:1px solid #c0d4f5;border-radius:10px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;';
        baselineBanner.innerHTML = `
            <div>
                <div style="font-weight:700;font-size:15px;color:#0078d4;margin-bottom:4px;">🛡 Baseline Sicurezza Intune</div>
                <div style="font-size:13px;color:#444;">Policy di compliance trovate: <strong>${existingComp}</strong> &nbsp;|&nbsp; Configuration profile trovati: <strong>${existingConf}</strong></div>
                <div style="font-size:12px;color:#666;margin-top:4px;">Configura le policy standard di sicurezza mancanti per il tuo tenant.</div>
            </div>
            <button id="open-intune-baseline-wizard" class="btn-primary" style="flex-shrink:0;">Configura Baseline →</button>`;
        overviewPane.appendChild(baselineBanner);

        document.getElementById('open-intune-baseline-wizard')?.addEventListener('click', () => openIntuneBaselineWizard());

        renderReportHtmlInRecommendations(data);
    }

    function populatePrecheckResultsSingle(data) {
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

        if (currentSolution === 'updates') {
            renderUpdatesPrecheck(data);
            return;
        }

        if (currentSolution === 'intune') {
            renderIntunePrecheck(data);
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

    function populatePrecheckResults(data) {
        // Multi-subscription: let the user switch between reports
        if (data?.multi && Array.isArray(data.results)) {
            const container = document.getElementById('multi-sub-container');
            const select = document.getElementById('multi-sub-select');
            if (container && select) {
                container.style.display = 'block';
                select.innerHTML = data.results.map((r, idx) => {
                    const subName = r.data?.Subscription?.Name ? ` — ${r.data.Subscription.Name}` : '';
                    return `<option value="${idx}">${r.subscriptionId}${subName}</option>`;
                }).join('');
                select.onchange = () => {
                    const i = Number(select.value || 0);
                    const picked = data.results[i]?.data;
                    if (picked) {
                        window.lastPrecheckResponse = picked;
                        populatePrecheckResultsSingle(picked);
                    }
                };
            }

            const first = data.results[0]?.data;
            if (first) {
                window.lastPrecheckResponse = first;
                populatePrecheckResultsSingle(first);
            }
            return;
        }

        const container = document.getElementById('multi-sub-container');
        if (container) container.style.display = 'none';

        populatePrecheckResultsSingle(data);
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
        const input = document.getElementById('subscription-id').value.trim();
        const subs = parseSubscriptionIds(input);
        const subscriptionId = subs[0] || '';
        if (!subscriptionId) { alert('⚠️ Inserisci prima un SubscriptionId valido'); return; }
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
    const saved = getSavedSubscriptionIds();
    document.getElementById('subscription-id').value = saved.length ? saved.join(',') : '';

    // Show Precheck 2.0 toggle only for Azure Monitor
    const toggleRow = document.getElementById('monitor-precheck2-toggle');
    if (toggleRow) toggleRow.style.display = (solution === 'azure-monitor') ? 'block' : 'none';
    const cb = document.getElementById('use-precheck2');
    if (cb) cb.checked = false;

    // Intune è tenant-wide: nascondi il campo subscription
    const subGroup = document.getElementById('subscription-id')?.closest('.form-group');
    const rgGroup = document.getElementById('resource-group')?.closest('.form-group');
    if (solution === 'intune') {
        if (subGroup) subGroup.style.display = 'none';
        if (rgGroup) rgGroup.style.display = 'none';
        // Mostra nota tenant-wide se non già presente
        let note = document.getElementById('intune-tenant-note');
        if (!note) {
            note = document.createElement('div');
            note.id = 'intune-tenant-note';
            note.style.cssText = 'padding:12px 14px;background:#f0f6ff;border:1px solid #c0d4f5;border-radius:8px;margin-bottom:14px;font-size:13px;color:#0078d4;';
            note.innerHTML = '<strong>ℹ️ Intune è tenant-wide</strong> — non richiede una subscription Azure. Il precheck verrà eseguito direttamente sul tenant associato al tuo account.';
            document.querySelector('.precheck-form').insertBefore(note, document.getElementById('run-precheck'));
        }
        note.style.display = '';
    } else {
        if (subGroup) subGroup.style.display = '';
        if (rgGroup) rgGroup.style.display = '';
        const note = document.getElementById('intune-tenant-note');
        if (note) note.style.display = 'none';
    }

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

// ========================================
// CONFIGURAZIONE AMBIENTE
// ========================================

const API_BASE_URL = 'https://func-azsolportal-089fb2a1.azurewebsites.net';
const LS_SUBS = 'azsp.selectedSubIds';
const LS_TENANT = 'azsp.selectedTenantId';
const GUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
let lastLoadedSubscriptions = [];

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

function rawFileUrl(pathEncoded) {
    return `${GITHUB_RAW}/${pathEncoded}`;
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

function getSavedTenantId() {
    try {
        const raw = String(localStorage.getItem(LS_TENANT) || '').trim();
        return GUID_RE.test(raw) ? raw : '';
    } catch {
        return '';
    }
}

function parseTenantId(input) {
    const raw = String(input || '').trim();
    return GUID_RE.test(raw) ? raw : '';
}

function saveTenantId(tenantId) {
    try {
        const valid = parseTenantId(tenantId);
        if (valid) localStorage.setItem(LS_TENANT, valid);
        else localStorage.removeItem(LS_TENANT);
    } catch {}
}

function getSelectedTenantId() {
    const input = document.getElementById('tenant-id');
    return parseTenantId(input?.value || '');
}

function getAuthorityForTenant(tenantId) {
    const tid = parseTenantId(tenantId);
    return tid ? `https://login.microsoftonline.com/${tid}` : undefined;
}

function parseSubscriptionIds(input) {
    const parts = String(input || '')
        .split(',')
        .map(s => s.trim())
        .filter(Boolean);

    // Keep only GUID-like ids (avoid accidental text)
    const valid = parts.filter(p => GUID_RE.test(p));
    return Array.from(new Set(valid));
}

function isTenantWideSolution(solutionKey) {
    return ['intune', 'defender-xdr', 'conditional-access', 'assessment-365'].includes(String(solutionKey || '').trim());
}

async function fetchSubscriptionsForUser(accessToken) {
    const resp = await fetch('https://management.azure.com/subscriptions?api-version=2022-12-01', {
        headers: { 'Authorization': `Bearer ${accessToken}` }
    });
    if (!resp.ok) throw new Error(`Impossibile leggere subscriptions (HTTP ${resp.status})`);
    const data = await resp.json();
    return data.value || [];
}

async function fetchTenantsForUser(accessToken) {
    const resp = await fetch('https://management.azure.com/tenants?api-version=2022-12-01', {
        headers: { 'Authorization': `Bearer ${accessToken}` }
    });
    if (!resp.ok) throw new Error(`Impossibile leggere tenants (HTTP ${resp.status})`);
    const data = await resp.json();
    return data.value || [];
}

function renderSubscriptionPicker(container, subs, preselected) {
    const selected = new Set(preselected || []);
    const rows = subs.slice(0, 80).map(s => {
        const id = String(s.subscriptionId || '').trim();
        const name = String(s.displayName || '');
        const tenant = parseTenantId(s.tenantId);
        const checked = selected.has(id) ? 'checked' : '';
        return `
            <label class="sub-item">
                <input type="checkbox" class="precheck-sub-check" value="${id}" ${checked} />
                <span class="sub-meta">
                    <span class="sub-name">${name}</span>
                    <span class="sub-id">${id}${tenant ? ` · tenant ${tenant}` : ''}</span>
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

function renderTenantPicker(container, tenants, selectedTenantId) {
    const selected = parseTenantId(selectedTenantId);
    const rows = tenants.slice(0, 120).map(t => {
        const tid = parseTenantId(t.tenantId || t.tenantID || t.id || '');
        const label = String(t.displayName || t.tenantType || 'Directory');
        const checked = (tid && tid === selected) ? 'checked' : '';
        return `
            <label class="sub-item">
                <input type="radio" name="precheck-tenant-radio" class="precheck-tenant-radio" value="${tid}" ${checked} />
                <span class="sub-meta">
                    <span class="sub-name">${label}</span>
                    <span class="sub-id">${tid || 'Tenant non disponibile'}</span>
                </span>
            </label>`;
    }).join('');

    container.innerHTML = `
        <div class="sub-picker">
            <div class="sub-picker-header">
                <div class="sub-picker-title">Seleziona directory</div>
                <div class="sub-picker-search">
                    <i class="fas fa-search" style="color:#666"></i>
                    <input type="text" id="precheck-tenant-search" placeholder="Cerca directory..." />
                </div>
            </div>
            <div class="sub-picker-body" id="precheck-tenant-list">
                ${rows}
            </div>
            <div class="sub-picker-actions">
                <button type="button" class="btn-primary" id="btn-use-tenant">Usa directory</button>
                <button type="button" class="btn-secondary" id="btn-hide-tenant">Chiudi</button>
            </div>
            <div class="sub-picker-note">
                Mostrate ${Math.min(tenants.length, 120)}/${tenants.length}.
            </div>
        </div>
    `;

    const search = container.querySelector('#precheck-tenant-search');
    const list = container.querySelector('#precheck-tenant-list');
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
    'defender-xdr': {
        name: 'Microsoft Defender for Endpoint',
        detailsTitle: 'Microsoft Defender for Endpoint — Dettagli',
        details: {
            whatIs: 'Microsoft Defender for Endpoint (MDE) è la piattaforma EDR di Microsoft per la protezione degli endpoint. Integra Next-Gen AV, Attack Surface Reduction, EDR onboarding via Intune, Threat & Vulnerability Management e Automated Investigation & Response.',
            features: [
                'AV Next-Gen Protection: cloud block High+, real-time, behavior, PUA block',
                '16 regole ASR (Attack Surface Reduction) in audit/block mode',
                'EDR onboarding via Intune connector (auto-populate onboarding blob)',
                'Tamper Protection + Network Protection in Block mode',
                'Secure Score M365 e alert attivi in tempo reale'
            ],
            notes: [
                'Precheck: DeviceManagementConfiguration.Read.All (policy Intune) + SecurityEvents.Read.All (Secure Score/Alert, opzionale).',
                'Deploy Baseline: DeviceManagementConfiguration.ReadWrite.All + DeviceManagementServiceConfig.ReadWrite.All.',
                'Richiede che il connettore Intune-MDE sia attivo in security.microsoft.com → Endpoints → Advanced Features.'
            ],
            docsAnchor: 'defender-xdr'
        },
        precheckTitle: 'Precheck Microsoft Defender for Endpoint',
        precheckDesc: 'Analizza il tenant per gap analysis MDE: policy Intune esistenti, Secure Score, alert attivi e baseline missing.',
        deployTitle: 'Microsoft Defender for Endpoint',
        deployDesc: 'Esegui prima il Precheck, poi usa il wizard "Configura Baseline MDE" per deployare le policy mancanti via Intune.',
        portalUrl: '#',
        psDownload: null,
        psCommand: '# Deploy tramite wizard baseline nel portale',
        apiEndpoint: '/api/precheck-defender-xdr'
    },
    'conditional-access': {
        name: 'Conditional Access Baseline',
        detailsTitle: 'Conditional Access — Dettagli',
        details: {
            whatIs: 'Conditional Access è il motore delle policy di accesso condizionale di Microsoft Entra ID. Questa soluzione deploya 27 policy baseline ispirate alla guida di j0eyv su GitHub: copertura completa per utenti, admin, guest, service account e dispositivi.',
            features: [
                'CA000-CA006: 7 policy globali (MFA, blocco legacy auth, device code, app protection)',
                'CA100-CA105: 6 policy per admin (MFA portali, phishing-resistant, CAE, sign-in frequency)',
                'CA200-CA209: 10 policy utenti interni (compliance Windows/macOS, risk-based block)',
                'CA300-CA301: 2 policy service account (MFA + location block)',
                'CA400-CA404: 5 policy guest (MFA, blocco app non-guest, admin portals block)'
            ],
            notes: [
                'Tutte le policy vengono deployate in Report-Only: zero impatto sulla produzione. Abilita manualmente dopo revisione.',
                'Richiede consenso admin per Policy.ReadWrite.ConditionalAccess e Group.ReadWrite.All.',
                'Viene creato automaticamente il gruppo "CA-BreakGlass-Exclusion" da aggiungere agli account break glass.'
            ],
            docsAnchor: 'conditional-access'
        },
        precheckTitle: 'Precheck Conditional Access',
        precheckDesc: 'Analizza le CA policy esistenti nel tenant e identifica le coperture mancanti rispetto alla baseline (j0eyv/ConditionalAccessBaseline).',
        deployTitle: 'Conditional Access Baseline',
        deployDesc: 'Deploya le 27 policy CA baseline in modalità Report-Only. Abilita manualmente dopo revisione.',
        portalUrl: '#',
        psCommand: '# Deploy tramite wizard baseline nel portale',
        psDownload: null,
        apiEndpoint: null
    },
    'assessment-security-m365-azure': {
        name: 'Assessment Security M365 + Azure',
        detailsTitle: 'Assessment Security M365 + Azure — Dettagli',
        details: {
            whatIs: 'Framework PowerShell unico per assessment sicurezza e offensive simulation controllata su Microsoft 365, Entra ID e Azure. Produce finding con severita, evidenze, remediation e kill-chain simulata.',
            features: [
                'Assessment read-only su Identity, M365 e risorse Azure',
                'Simulation non distruttiva di attack chain cloud (MITRE ATT&CK)',
                'Modalita operative: Assessment, Simulation, Full, ReportOnly',
                'Report HTML executive-ready con prioritizzazione dei rischi'
            ],
            notes: [
                'Usare solo su tenant autorizzati: alcune simulazioni possono generare alert in Sentinel/Defender.',
                'Richiede PowerShell 7+ e moduli Microsoft.Graph/Az (gestiti dallo script).',
                'Assessment cloud disponibile via Azure Function del portale.',
                'Il pulsante "Scarica Script" resta utile per esecuzione locale avanzata.'
            ],
            docsAnchor: 'assessment-security-m365-azure'
        },
        precheckTitle: 'Assessment Security M365 + Azure',
        precheckDesc: 'Esegue un assessment cloud su Azure + Entra ID via Function App e genera report HTML nel portale.',
        deployTitle: 'Scarica script Assessment Security M365 + Azure',
        deployDesc: 'Scarica lo script PowerShell per esecuzione locale (assessment/simulation avanzata).',
        portalUrl: '#',
        psDownload: rawFileUrl('Solution%20-%20Assessment%20Security%20M365_Azure/Invoke-M365AzurePentest.ps1'),
        psCommand: '.\\Invoke-M365AzurePentest.ps1 -Mode Full -AttackIntensity High',
        apiEndpoint: '/api/precheck-assessment-security'
    },
    'assessment-365': {
        name: 'Assessment 365',
        detailsTitle: 'Assessment 365 (M365-Assess) — Dettagli',
        details: {
            whatIs: 'Assessment 365 integra il progetto M365-Assess (Galvnyz): un framework PowerShell read-only per valutare la postura di sicurezza Microsoft 365 con output consulenziale pronto per stakeholder tecnici e compliance.',
            features: [
                'Assessment multi-sezione: Tenant, Identity, Email, Intune, Security, Collaboration, Hybrid, PowerBI, SOC2',
                'Report HTML + export CSV + compliance matrix XLSX',
                'Modalità QuickScan, NonInteractive, baseline compare e white-label',
                'Mapping a framework di compliance (NIST, ISO 27001, SOC2, CIS, PCI DSS, HIPAA...)'
            ],
            notes: [
                'Assessment cloud disponibile via Azure Function (bottone "Esegui Assessment").',
                'Il pulsante "Scarica Script" resta disponibile per esecuzione locale.',
                'Il codice sorgente completo della soluzione è incluso nella cartella Solution - Assessment 365.',
                'Prerequisiti principali: PowerShell 7, Microsoft.Graph, ExchangeOnlineManagement.'
            ],
            docsAnchor: 'assessment-365'
        },
        precheckTitle: 'Esegui Assessment 365',
        precheckDesc: 'Esegue l\'assessment M365-Assess direttamente in Azure Function e mostra il report nel portale.',
        deployTitle: 'Scarica script Assessment 365',
        deployDesc: 'Scarica il wrapper PowerShell e avvia M365-Assess in locale con i parametri desiderati.',
        portalUrl: '#',
        psDownload: rawFileUrl('Solution%20-%20Assessment%20365/Invoke-M365Assessment-Portal.ps1'),
        psCommand: '.\\Invoke-M365Assessment-Portal.ps1 -TenantId "contoso.onmicrosoft.com" -QuickScan -OpenReport',
        apiEndpoint: '/api/execute-assessment-365'
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

                // Se stavamo aspettando il consenso Graph per Intune, riavvia il precheck
                if (sessionStorage.getItem('intune_graph_consent_pending') === '1') {
                    sessionStorage.removeItem('intune_graph_consent_pending');
                    setTimeout(() => {
                        showPrecheckModal('intune');
                        document.getElementById('run-precheck')?.click();
                    }, 800);
                }

                // Se stavamo aspettando il consenso Graph per Assessment Security M365+Azure, riavvia il precheck
                if (sessionStorage.getItem('assessment_graph_consent_pending') === '1') {
                    sessionStorage.removeItem('assessment_graph_consent_pending');
                    setTimeout(() => {
                        showPrecheckModal('assessment-security-m365-azure');
                        document.getElementById('run-precheck')?.click();
                    }, 800);
                }

                if (sessionStorage.getItem('assessment365_graph_consent_pending') === '1') {
                    sessionStorage.removeItem('assessment365_graph_consent_pending');
                    setTimeout(() => {
                        showPrecheckModal('assessment-365');
                        document.getElementById('run-precheck')?.click();
                    }, 800);
                }

                // Se stavamo aspettando il consenso Graph per Conditional Access, riavvia il precheck
                const caPending = sessionStorage.getItem('ca_consent_pending');
                if (caPending) {
                    sessionStorage.removeItem('ca_consent_pending');
                    setTimeout(() => {
                        showPrecheckModal('conditional-access');
                        document.getElementById('run-precheck')?.click();
                    }, 800);
                }
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

async function getAccessToken(tenantId = '') {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const authority = getAuthorityForTenant(tenantId);
    const tokenRequest = authority
        ? { ...loginRequest, account: currentAccount, authority }
        : { ...loginRequest, account: currentAccount };
    try {
        const response = await msalInstance.acquireTokenSilent(tokenRequest);
        currentAccessToken = response.accessToken;
        return currentAccessToken;
    } catch {
        const response = await msalInstance.acquireTokenPopup(tokenRequest);
        currentAccessToken = response.accessToken;
        return currentAccessToken;
    }
}

const GRAPH_SCOPES_INTUNE = [
    "https://graph.microsoft.com/DeviceManagementApps.Read.All",
    "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
    "https://graph.microsoft.com/DeviceManagementConfiguration.Read.All",
    "https://graph.microsoft.com/DeviceManagementServiceConfig.Read.All",
    "https://graph.microsoft.com/Organization.Read.All"
];

const GRAPH_SCOPES_ASSESSMENT = [
    "https://graph.microsoft.com/Directory.Read.All",
    "https://graph.microsoft.com/Policy.Read.All",
    "https://graph.microsoft.com/Organization.Read.All",
    "https://graph.microsoft.com/User.Read.All"
];

const GRAPH_SCOPES_ASSESSMENT365 = [
    "https://graph.microsoft.com/Directory.Read.All",
    "https://graph.microsoft.com/Group.Read.All",
    "https://graph.microsoft.com/Organization.Read.All",
    "https://graph.microsoft.com/Policy.Read.All",
    "https://graph.microsoft.com/RoleManagement.Read.Directory",
    "https://graph.microsoft.com/User.Read.All"
];

async function getGraphToken(tenantId = '') {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const authority = getAuthorityForTenant(tenantId);
    const tokenRequest = authority
        ? { scopes: GRAPH_SCOPES_INTUNE, account: currentAccount, authority }
        : { scopes: GRAPH_SCOPES_INTUNE, account: currentAccount };
    try {
        const response = await msalInstance.acquireTokenSilent(tokenRequest);
        return response.accessToken;
    } catch {
        // Popup bloccato da COOP → usa redirect flow che non usa finestre popup
        sessionStorage.setItem('intune_graph_consent_pending', '1');
        await msalInstance.acquireTokenRedirect({ ...tokenRequest, prompt: 'consent' });
        // La riga seguente non viene mai raggiunta (pagina si ricarica dopo il redirect)
        throw new Error('Redirect in corso per il consenso...');
    }
}

async function getAssessmentGraphToken(tenantId = '') {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const authority = getAuthorityForTenant(tenantId);
    const tokenRequest = authority
        ? { scopes: GRAPH_SCOPES_ASSESSMENT, account: currentAccount, authority }
        : { scopes: GRAPH_SCOPES_ASSESSMENT, account: currentAccount };
    try {
        const response = await msalInstance.acquireTokenSilent(tokenRequest);
        return response.accessToken;
    } catch {
        sessionStorage.setItem('assessment_graph_consent_pending', '1');
        await msalInstance.acquireTokenRedirect({ ...tokenRequest, prompt: 'consent' });
        throw new Error('Redirect in corso per il consenso...');
    }
}

async function getAssessment365GraphToken(tenantId = '') {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const authority = getAuthorityForTenant(tenantId);
    const tokenRequest = authority
        ? { scopes: GRAPH_SCOPES_ASSESSMENT365, account: currentAccount, authority }
        : { scopes: GRAPH_SCOPES_ASSESSMENT365, account: currentAccount };
    try {
        const response = await msalInstance.acquireTokenSilent(tokenRequest);
        return response.accessToken;
    } catch {
        sessionStorage.setItem('assessment365_graph_consent_pending', '1');
        await msalInstance.acquireTokenRedirect({ ...tokenRequest, prompt: 'consent' });
        throw new Error('Redirect in corso per il consenso...');
    }
}

async function getGraphTokenWithWrite(tenantId = '') {
    if (!msalInstance) throw new Error("Autenticazione non inizializzata");
    if (!currentAccount) throw new Error("Non autenticato. Effettua prima il login.");
    const authority = getAuthorityForTenant(tenantId);
    const graphRequest = authority ? {
        scopes: [
            "https://graph.microsoft.com/DeviceManagementApps.Read.All",
            "https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All",
            "https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All",
            "https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All",
            "https://graph.microsoft.com/Organization.Read.All"
        ],
        account: currentAccount,
        authority
    } : {
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
// CONDITIONAL ACCESS — SCOPES + TOKEN
// ============================================================
const CA_SCOPES_READ = [
    "https://graph.microsoft.com/Policy.Read.All",
    "https://graph.microsoft.com/Directory.Read.All"
];
const CA_SCOPES_WRITE = [
    "https://graph.microsoft.com/Policy.ReadWrite.ConditionalAccess",
    "https://graph.microsoft.com/Policy.Read.All",
    "https://graph.microsoft.com/Group.ReadWrite.All",
    "https://graph.microsoft.com/Directory.Read.All"
];

async function getCaToken(write = false, tenantId = '') {
    if (!msalInstance || !currentAccount) throw new Error("Non autenticato.");
    const scopes = write ? CA_SCOPES_WRITE : CA_SCOPES_READ;
    const authority = getAuthorityForTenant(tenantId);
    const tokenRequest = authority
        ? { scopes, account: currentAccount, authority }
        : { scopes, account: currentAccount };
    try {
        const r = await msalInstance.acquireTokenSilent(tokenRequest);
        return r.accessToken;
    } catch {
        sessionStorage.setItem('ca_consent_pending', write ? 'write' : 'read');
        await msalInstance.acquireTokenRedirect({ ...tokenRequest, prompt: 'consent' });
        throw new Error('Redirect in corso...');
    }
}

// ============================================================
// CONDITIONAL ACCESS BASELINE (j0eyv/ConditionalAccessBaseline)
// ============================================================
// Admin role IDs sono uguali in tutti i tenant Microsoft Entra
const CA_ADMIN_ROLES = [
    '62e90394-69f5-4237-9190-012177145e10', // Global Administrator
    'e8611ab8-c189-46e8-94e1-60213ab1f814', // Privileged Role Administrator
    'fe930be7-5e62-47db-91af-98c3a49a38b1', // User Administrator
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c', // SharePoint Administrator
    '29232cdf-9323-42fd-aea2-88a2b1a08ee4', // Exchange Administrator
    'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9', // Conditional Access Administrator
    '194ae4cb-b126-40b2-bd5b-6091b380977d', // Security Administrator
    '17315797-102d-40b4-93e0-432062caca18', // Compliance Administrator
    'c4e39bd9-1100-46d3-8c65-fb160da0071f', // Authentication Administrator
    '729827e3-9c14-49f7-bb1b-9608f156bbb8', // Helpdesk Administrator
    '69091246-20e8-4a56-aa4d-066075b2a7a8', // Teams Administrator
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c1', // Application Administrator
    '158c047a-c907-4556-b7ef-446551a6b5f7', // Cloud Application Administrator
    '3a2c62db-5318-420d-8d74-23affee5d9d5', // Intune Administrator
    'b0f54661-2d74-4c50-afa3-1ec803f12efe', // Billing Administrator
    '9360feb5-f418-4baa-8175-e2a00bac4301'  // Directory Writers
];

// Crea il body di ogni policy: bg = break glass group ID, sa = service accounts group ID
function caBody(code, displayName, state, conditions, grantControls, sessionControls) {
    return { displayName: `${code}-${displayName}`, state, conditions, grantControls: grantControls || null, sessionControls: sessionControls || null };
}

const CA_BASELINE = [
    // ── GLOBAL ──────────────────────────────────────────────────────────
    {
        id: 'ca000', code: 'CA000', category: 'Global', critical: true,
        name: 'MFA — Tutti gli utenti, tutte le app',
        description: 'Richiede MFA per tutti gli utenti su qualsiasi applicazione cloud.',
        why: 'La policy più fondamentale: senza MFA il 99% degli account compromessi non avrebbe subito danni secondo i dati Microsoft. Un attaccante che ottiene la password non può accedere senza il secondo fattore. Viene deployata in Report-Only: monitora chi avrebbe ricevuto la challenge MFA prima di abilitarla.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeUsers?.includes('All') && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA000', 'Global-IdentityProtection-AnyApp-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca001', code: 'CA001', category: 'Global', critical: false,
        name: 'Blocco per Paese — Allowlist',
        description: 'Blocca accessi da paesi non nella lista consentita (richiede Named Location).',
        why: 'Riduce drasticamente la superficie di attacco bloccando accessi da paesi non operativi. Attenzione: viene creata una Named Location "CA-Allowed-Countries" con Europa+NA che puoi personalizzare in seguito in Entra ID → Named Locations.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.grantControls?.builtInControls?.includes('block') && (p.conditions?.locations?.excludeLocations?.length > 0 || p.conditions?.locations?.includeLocations?.some(l => l !== 'All' && l !== 'AllTrusted'))),
        getBody: (bg, locs) => caBody('CA001', 'Global-AttackSurfaceReduction-AnyApp-AnyPlatform-BLOCK-CountryWhitelist', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'], locations: { includeLocations: ['All'], excludeLocations: locs?.allowed ? [locs.allowed] : ['AllTrusted'] } },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca002', code: 'CA002', category: 'Global', critical: true,
        name: 'Blocca Legacy Authentication',
        description: 'Blocca tutti i client che usano autenticazione legacy (SMTP AUTH, IMAP, POP3, Basic Auth).',
        why: 'I protocolli legacy non supportano MFA: chiunque abbia la password può autenticarsi. Il 99% degli attacchi password spray colpisce proprio questi protocolli. Bloccarli è sicuro in qualsiasi tenant moderno — Office 365/M365 non usa più questi protocolli per default.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.grantControls?.builtInControls?.includes('block') && (p.conditions?.clientAppTypes?.includes('exchangeActiveSync') || p.conditions?.clientAppTypes?.includes('other'))),
        getBody: (bg) => caBody('CA002', 'Global-IdentityProtection-AnyApp-AnyPlatform-Block-LegacyAuthentication', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['exchangeActiveSync', 'other'] },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca003', code: 'CA003', category: 'Global', critical: true,
        name: 'MFA — Registrazione / Join dispositivo',
        description: 'Richiede MFA quando un utente registra o aggiunge un dispositivo a Entra ID.',
        why: 'Senza questa policy un attaccante con le credenziali può registrare il proprio dispositivo nel tenant e ottenere un token persistente. Richiedere MFA per il join device blocca questo vettore di attacco.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.applications?.includeUserActions?.includes('urn:user:registerdevice') && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA003', 'Global-BaseProtection-RegisterOrJoin-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeUserActions: ['urn:user:registerdevice'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca004', code: 'CA004', category: 'Global', critical: true,
        name: 'Blocca Device Code Flow e Auth Transfer',
        description: 'Blocca i flussi di autenticazione Device Code e Authentication Transfer.',
        why: 'Il Device Code Flow è usato in attacchi di phishing avanzati (token stealing via link "entra questo codice"): l\'utente pensa di fare login ma sta dando il token all\'attaccante. L\'Authentication Transfer permette di trasferire sessioni tra device. Entrambi sono raramente necessari in produzione e molto pericolosi.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.grantControls?.builtInControls?.includes('block') && p.conditions?.authenticationFlows?.transferMethods),
        getBody: (bg) => caBody('CA004', 'Global-IdentityProtection-AnyApp-AnyPlatform-AuthenticationFlows', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'], authenticationFlows: { transferMethods: 'deviceCodeFlow,authenticationTransfer' } },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca005', code: 'CA005', category: 'Global', critical: false,
        name: 'App Protection — Office 365 su dispositivi non gestiti (iOS/Android)',
        description: 'Richiede App Protection Policy (MAM) per accedere a Office 365 da dispositivi iOS/Android non gestiti.',
        why: 'Quando un dipendente usa il proprio smartphone personale (non MDM), non puoi controllare il dispositivo. L\'App Protection Policy permette comunque di proteggere i dati aziendali dentro l\'app (es. Outlook) impedendo copia/incolla verso app personali, richiedendo PIN, e potendo fare wipe selettivo solo dei dati aziendali.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && (p.conditions?.platforms?.includePlatforms?.includes('android') || p.conditions?.platforms?.includePlatforms?.includes('iOS')) && (p.grantControls?.builtInControls?.includes('compliantApplication') || p.grantControls?.builtInControls?.includes('approvedApplication'))),
        getBody: (bg) => caBody('CA005', 'Global-DataProtection-Office365-iOSAndroid-RequireAppProtection', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['Office365'] }, clientAppTypes: ['mobileAppsAndDesktopClients'], platforms: { includePlatforms: ['android', 'iOS'] } },
            { operator: 'OR', builtInControls: ['compliantApplication'] })
    },
    {
        id: 'ca006', code: 'CA006', category: 'Global', critical: false,
        name: 'App Protection — Office apps mobile (sessione)',
        description: 'Applica restrizioni di sessione per app Office su iOS/Android.',
        why: 'Complementa CA005 aggiungendo Application Enforced Restrictions nelle sessioni browser su mobile, impedendo download di file e operazioni non sicure anche via browser mobile.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && (p.conditions?.platforms?.includePlatforms?.includes('android') || p.conditions?.platforms?.includePlatforms?.includes('iOS')) && p.sessionControls?.applicationEnforcedRestrictions?.isEnabled),
        getBody: (bg) => caBody('CA006', 'Global-DataProtection-Office365-iOSAndroid-SessionControls', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['Office365'] }, clientAppTypes: ['browser'], platforms: { includePlatforms: ['android', 'iOS'] } },
            null, { applicationEnforcedRestrictions: { isEnabled: true } })
    },
    // ── ADMINS ──────────────────────────────────────────────────────────
    {
        id: 'ca100', code: 'CA100', category: 'Admins', critical: true,
        name: 'MFA — Admin su portali amministrativi',
        description: 'Richiede MFA a tutti gli admin quando accedono ai portali Microsoft (Azure, Entra, M365 Admin).',
        why: 'I portali admin sono il target principale degli attaccanti: da qui si possono modificare utenti, aggiungere app con permessi globali, esfiltrare dati. MFA obbligatoria per admin sui portali è il minimo assoluto e va abilitata subito anche in produzione.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.applications?.includeApplications?.includes('MicrosoftAdminPortals') && p.conditions?.users?.includeRoles?.length > 0 && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA100', 'Admins-IdentityProtection-AdminPortals-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['MicrosoftAdminPortals'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca101', code: 'CA101', category: 'Admins', critical: true,
        name: 'MFA — Admin su tutte le app',
        description: 'Richiede MFA agli admin su qualsiasi applicazione.',
        why: 'Gli admin devono fare MFA non solo sui portali Microsoft ma su QUALSIASI app cloud. Un admin che accede a Salesforce, GitHub o qualsiasi SaaS senza MFA è un rischio: quella sessione può essere dirottata per pivot verso risorse aziendali.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.applications?.includeApplications?.includes('All') && p.conditions?.users?.includeRoles?.length > 0 && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA101', 'Admins-IdentityProtection-AnyApp-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['browser', 'mobileAppsAndDesktopClients'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca102', code: 'CA102', category: 'Admins', critical: false,
        name: 'Sign-in Frequency 12h — Admin',
        description: 'Forza re-autenticazione ogni 12 ore per gli admin.',
        why: 'Le sessioni degli admin non devono essere permanenti. Se un attaccante ruba un token admin, la finestra di utilizzo viene limitata a 12 ore. Combina primary e secondary authentication per impedire token refresh automatico.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeRoles?.length > 0 && p.sessionControls?.signInFrequency?.isEnabled && p.sessionControls?.signInFrequency?.value <= 12),
        getBody: (bg) => caBody('CA102', 'Admins-IdentityProtection-AllApps-AnyPlatform-SigninFrequency', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            null, { signInFrequency: { value: 12, type: 'hours', isEnabled: true, authenticationType: 'primaryAndSecondaryAuthentication', frequencyInterval: 'timeBased' } })
    },
    {
        id: 'ca103', code: 'CA103', category: 'Admins', critical: false,
        name: 'No Sessione Browser Persistente — Admin',
        description: 'Impedisce sessioni browser persistenti per gli admin.',
        why: 'Senza questa policy un admin che fa login su un browser condiviso o lascia il laptop incustodito rimane autenticato. "Persistent browser never" forza il logout alla chiusura del browser.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeRoles?.length > 0 && p.sessionControls?.persistentBrowser?.isEnabled && p.sessionControls?.persistentBrowser?.mode === 'never'),
        getBody: (bg) => caBody('CA103', 'Admins-IdentityProtection-AllApps-AnyPlatform-PersistentBrowser', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['browser'] },
            null, { persistentBrowser: { mode: 'never', isEnabled: true } })
    },
    {
        id: 'ca104', code: 'CA104', category: 'Admins', critical: false,
        name: 'Continuous Access Evaluation — Admin',
        description: 'Abilita CAE in modalità strictLocation per gli admin.',
        why: 'CAE (Continuous Access Evaluation) revoca i token in tempo reale quando l\'IP cambia drasticamente o l\'account viene disabilitato/compromesso. Senza CAE un token admin rubato rimane valido fino alla scadenza naturale (1-24h). Con strictLocation la revoca avviene in secondi.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeRoles?.length > 0 && p.sessionControls?.continuousAccessEvaluation?.mode),
        getBody: (bg) => caBody('CA104', 'Admins-IdentityProtection-AllApps-AnyPlatform-CAE', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            null, { continuousAccessEvaluation: { mode: 'strictLocation' } })
    },
    {
        id: 'ca105', code: 'CA105', category: 'Admins', critical: false,
        name: 'MFA Phishing-Resistant — Admin',
        description: 'Richiede MFA phishing-resistant (FIDO2, Windows Hello, Certificato) per gli admin.',
        why: 'L\'MFA classica (SMS, TOTP) è vulnerabile al phishing in tempo reale: siti come Evilginx2 rubano il token MFA nel momento dell\'inserimento. FIDO2/Windows Hello sono legati al dominio e fisicamente impossibili da intercettare via phishing. Ideale per gli account admin più privilegiati.',
        detectFn: (ps) => ps.some(p => p.conditions?.users?.includeRoles?.length > 0 && p.grantControls?.authenticationStrength),
        getBody: (bg) => caBody('CA105', 'Admins-IdentityProtection-AnyApp-AnyPlatform-PhishingResistantMFA', 'enabledForReportingButNotEnforced',
            { users: { includeRoles: CA_ADMIN_ROLES, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            { operator: 'OR', authenticationStrength: { id: '00000000-0000-0000-0000-000000000004' } })
    },
    // ── INTERNALS ────────────────────────────────────────────────────────
    {
        id: 'ca200', code: 'CA200', category: 'Internals', critical: true,
        name: 'MFA — Utenti interni, tutte le app',
        description: 'MFA per tutti gli utenti membri (non guest) su tutte le app.',
        why: 'Versione esplicita di CA000 dedicata agli utenti interni. In alcuni tenant CA000 copre tutto ma avere una policy dedicata per i soli membri facilita la gestione delle eccezioni e il reporting separato.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && (p.conditions?.users?.includeUsers?.includes('All') || p.conditions?.users?.includeUsers?.includes('GuestsOrExternalUsers') === false) && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA200', 'Internals-IdentityProtection-AnyApp-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'], excludeApplications: ['d4ebce55-015a-49b5-a083-c8d1797ae8c3'] }, clientAppTypes: ['browser', 'mobileAppsAndDesktopClients'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca201', code: 'CA201', category: 'Internals', critical: true,
        name: 'Blocca utenti ad alto rischio',
        description: 'Blocca automaticamente gli utenti con segnale di rischio "High" da Entra ID Protection.',
        why: 'Entra ID Protection calcola il rischio utente analizzando dark web, comportamenti anomali, leaked credentials. Se un account è classificato "High Risk" (es. credenziali trovate in un breach), questa policy lo blocca automaticamente anche prima che l\'IT team se ne accorga. Richiede licenza Entra ID P2.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.grantControls?.builtInControls?.includes('block') && p.conditions?.userRiskLevels?.includes('high')),
        getBody: (bg) => caBody('CA201', 'Internals-IdentityProtection-AnyApp-AnyPlatform-BLOCK-HighRiskUser', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'], userRiskLevels: ['high'] },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca202', code: 'CA202', category: 'Internals', critical: false,
        name: 'Sign-in Frequency 12h — Dispositivi non gestiti',
        description: 'Forza re-auth ogni 12h su Windows/macOS non gestiti da Intune.',
        why: 'Un PC personale non gestito non ha le stesse garanzie di sicurezza di un device aziendale. Limitare la durata della sessione a 12h riduce l\'esposizione in caso di device perso o condiviso.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && (p.conditions?.platforms?.includePlatforms?.includes('windows') || p.conditions?.platforms?.includePlatforms?.includes('macOS')) && p.sessionControls?.signInFrequency?.isEnabled),
        getBody: (bg) => caBody('CA202', 'Internals-IdentityProtection-AllApps-WindowsMacOS-SigninFrequency-UnmanagedDevices', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'], platforms: { includePlatforms: ['windows', 'macOS'] }, devices: { deviceFilter: { mode: 'exclude', rule: 'device.isCompliant -eq True -or device.trustType -eq "ServerAD"' } } },
            null, { signInFrequency: { value: 12, type: 'hours', isEnabled: true, authenticationType: 'primaryAndSecondaryAuthentication', frequencyInterval: 'timeBased' } })
    },
    {
        id: 'ca203', code: 'CA203', category: 'Internals', critical: false,
        name: 'MFA — Enrollment Intune',
        description: 'Richiede MFA durante il processo di enrollment dei dispositivi in Intune.',
        why: 'Senza MFA sull\'enrollment Intune, un attaccante con le credenziali può enrollare il proprio device e ottenere accesso alle risorse aziendali come se fosse un device aziendale. Con MFA, l\'enrollment richiede la presenza fisica o il dispositivo MFA dell\'utente legittimo.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.applications?.includeApplications?.some(a => a === 'd4ebce55-015a-49b5-a083-c8d1797ae8c3') && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA203', 'Internals-AppProtection-MicrosoftIntuneEnrollment-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['d4ebce55-015a-49b5-a083-c8d1797ae8c3'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca204', code: 'CA204', category: 'Internals', critical: false,
        name: 'Blocca piattaforme sconosciute',
        description: 'Blocca accessi da piattaforme non riconosciute (non Windows, macOS, iOS, Android, Linux).',
        why: 'Piattaforme "unknown" includono vecchi browser, device IoT, script automatizzati senza user agent noto. Bloccarle elimina una classe di tentativi di accesso non legittimi senza impatto sugli utenti reali.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.grantControls?.builtInControls?.includes('block') && p.conditions?.platforms?.includePlatforms?.includes('all') && p.conditions?.platforms?.excludePlatforms?.length > 0),
        getBody: (bg) => caBody('CA204', 'Internals-AttackSurfaceReduction-AllApps-AnyPlatform-BlockUnknownPlatforms', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'], platforms: { includePlatforms: ['all'], excludePlatforms: ['android', 'iOS', 'windows', 'macOS', 'linux', 'windowsPhone'] } },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca205', code: 'CA205', category: 'Internals', critical: false,
        name: 'Compliance obbligatoria — Windows',
        description: 'Blocca accessi da Windows non conformi o non joined a Entra ID.',
        why: 'Un PC Windows non gestito da Intune non ha garanzie: niente AV policy, niente patch management, niente encryption. Richiedere compliance o AADJ assicura che solo device aziendali gestiti possano accedere alle risorse.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.platforms?.includePlatforms?.includes('windows') && (p.grantControls?.builtInControls?.includes('compliantDevice') || p.grantControls?.builtInControls?.includes('domainJoinedDevice'))),
        getBody: (bg) => caBody('CA205', 'Internals-BaseProtection-AnyApp-Windows-CompliantOrAADHJ', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'], excludeApplications: ['d4ebce55-015a-49b5-a083-c8d1797ae8c3'] }, clientAppTypes: ['all'], platforms: { includePlatforms: ['windows'] } },
            { operator: 'OR', builtInControls: ['compliantDevice', 'domainJoinedDevice'] })
    },
    {
        id: 'ca206', code: 'CA206', category: 'Internals', critical: false,
        name: 'No Sessione Browser Persistente — Utenti non gestiti',
        description: 'Impedisce sessioni browser persistenti su device non gestiti.',
        why: 'Su un PC personale o condiviso, una sessione browser persistente significa che chiunque apra il browser trova l\'utente già loggato su Outlook, Teams, SharePoint. "Persistent never" forza il login a ogni apertura del browser.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.clientAppTypes?.includes('browser') && p.sessionControls?.persistentBrowser?.mode === 'never' && !p.conditions?.users?.includeRoles?.length),
        getBody: (bg) => caBody('CA206', 'Internals-IdentityProtection-AllApps-AnyPlatform-PersistentBrowser', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['browser'], devices: { deviceFilter: { mode: 'exclude', rule: 'device.isCompliant -eq True -or device.trustType -eq "ServerAD"' } } },
            null, { persistentBrowser: { mode: 'never', isEnabled: true } })
    },
    {
        id: 'ca208', code: 'CA208', category: 'Internals', critical: false,
        name: 'Compliance obbligatoria — macOS',
        description: 'Blocca accessi da macOS non conformi (non gestiti da Intune).',
        why: 'Come CA205 per Windows, questa policy assicura che i Mac aziendali siano gestiti da Intune. Senza gestione MDM su macOS non si ha visibilità su encryption FileVault, aggiornamenti di sicurezza e configurazioni.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.platforms?.includePlatforms?.includes('macOS') && p.grantControls?.builtInControls?.includes('compliantDevice')),
        getBody: (bg) => caBody('CA208', 'Internals-BaseProtection-AnyApp-MacOS-Compliant', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'], excludeApplications: ['d4ebce55-015a-49b5-a083-c8d1797ae8c3'] }, clientAppTypes: ['all'], platforms: { includePlatforms: ['macOS'] } },
            { operator: 'OR', builtInControls: ['compliantDevice'] })
    },
    {
        id: 'ca209', code: 'CA209', category: 'Internals', critical: false,
        name: 'Continuous Access Evaluation — Tutti',
        description: 'Abilita CAE strictLocation per tutti gli utenti.',
        why: 'CAE garantisce che i token vengano revocati in tempo reale invece di aspettare la scadenza naturale. Se un utente viene disabilitato o il suo IP cambia radicalmente, l\'accesso viene bloccato in secondi anziché ore. Impatto sulle performance: minimo.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeUsers?.includes('All') && p.sessionControls?.continuousAccessEvaluation?.mode),
        getBody: (bg) => caBody('CA209', 'Internals-IdentityProtection-AllApps-AnyPlatform-CAE', 'enabledForReportingButNotEnforced',
            { users: { includeUsers: ['All'], excludeUsers: ['GuestsOrExternalUsers'], excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            null, { continuousAccessEvaluation: { mode: 'strictLocation' } })
    },
    // ── GUEST USERS ──────────────────────────────────────────────────────
    {
        id: 'ca400', code: 'CA400', category: 'Guest', critical: true,
        name: 'MFA — Utenti Guest',
        description: 'Richiede MFA a tutti gli utenti guest/esterni su qualsiasi app.',
        why: 'Gli account guest (B2B) sono gestiti dal tenant di origine: non hai controllo sulla loro sicurezza. Un guest senza MFA è un rischio elevato perché il suo account potrebbe non avere le stesse policy del tuo tenant. MFA obbligatoria garantisce un secondo fattore indipendente.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeGuestsOrExternalUsers && p.grantControls?.builtInControls?.includes('mfa')),
        getBody: (bg) => caBody('CA400', 'GuestUsers-IdentityProtection-AnyApp-AnyPlatform-MFA', 'enabledForReportingButNotEnforced',
            { users: { includeGuestsOrExternalUsers: { guestOrExternalUserTypes: 'internalGuest,b2bCollaborationGuest,b2bCollaborationMember,b2bDirectConnectUser,otherExternalUser,serviceProvider', externalTenants: { membershipKind: 'all' } }, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['mfa'] })
    },
    {
        id: 'ca401', code: 'CA401', category: 'Guest', critical: true,
        name: 'Blocca Guest su app non-guest',
        description: 'Blocca i guest dall\'accesso a tutte le app eccetto Office 365.',
        why: 'I guest dovrebbero accedere SOLO a ciò che serve per collaborare (Teams, SharePoint condiviso). Questa policy impedisce ai guest di accedere ad app aziendali come ERP, CRM, o qualsiasi SaaS interno che non hanno bisogno di vedere.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeGuestsOrExternalUsers && p.grantControls?.builtInControls?.includes('block') && p.conditions?.applications?.excludeApplications?.length > 0),
        getBody: (bg) => caBody('CA401', 'GuestUsers-AttackSurfaceReduction-AllApps-AnyPlatform-BlockNonGuestAppAccess', 'enabledForReportingButNotEnforced',
            { users: { includeGuestsOrExternalUsers: { guestOrExternalUserTypes: 'internalGuest,b2bCollaborationGuest,b2bCollaborationMember,b2bDirectConnectUser,otherExternalUser,serviceProvider', externalTenants: { membershipKind: 'all' } }, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'], excludeApplications: ['Office365'] }, clientAppTypes: ['all'] },
            { operator: 'OR', builtInControls: ['block'] })
    },
    {
        id: 'ca402', code: 'CA402', category: 'Guest', critical: false,
        name: 'Sign-in Frequency 12h — Guest',
        description: 'Forza re-autenticazione ogni 12h per i guest.',
        why: 'I guest accedono da dispositivi non controllati. Limitare la durata della sessione riduce il rischio che una sessione aperta su un dispositivo condiviso rimanga accessibile a lungo.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeGuestsOrExternalUsers && p.sessionControls?.signInFrequency?.isEnabled),
        getBody: (bg) => caBody('CA402', 'GuestUsers-IdentityProtection-AllApps-AnyPlatform-SigninFrequency', 'enabledForReportingButNotEnforced',
            { users: { includeGuestsOrExternalUsers: { guestOrExternalUserTypes: 'internalGuest,b2bCollaborationGuest,b2bCollaborationMember,b2bDirectConnectUser,otherExternalUser,serviceProvider', externalTenants: { membershipKind: 'all' } }, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['all'] },
            null, { signInFrequency: { value: 12, type: 'hours', isEnabled: true, frequencyInterval: 'timeBased' } })
    },
    {
        id: 'ca403', code: 'CA403', category: 'Guest', critical: false,
        name: 'No Sessione Browser Persistente — Guest',
        description: 'Impedisce sessioni browser persistenti per i guest.',
        why: 'Un guest non dovrebbe rimanere loggato permanentemente nel browser. "Persistent never" forza il login esplicito ad ogni sessione browser, limitando l\'esposizione su device condivisi.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeGuestsOrExternalUsers && p.sessionControls?.persistentBrowser?.mode === 'never'),
        getBody: (bg) => caBody('CA403', 'GuestUsers-IdentityProtection-AllApps-AnyPlatform-PersistentBrowser', 'enabledForReportingButNotEnforced',
            { users: { includeGuestsOrExternalUsers: { guestOrExternalUserTypes: 'internalGuest,b2bCollaborationGuest,b2bCollaborationMember,b2bDirectConnectUser,otherExternalUser,serviceProvider', externalTenants: { membershipKind: 'all' } }, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['All'] }, clientAppTypes: ['browser'] },
            null, { persistentBrowser: { mode: 'never', isEnabled: true } })
    },
    {
        id: 'ca404', code: 'CA404', category: 'Guest', critical: true,
        name: 'Blocca Guest su portali amministrativi',
        description: 'Impedisce ai guest di accedere ai portali Microsoft Admin.',
        why: 'I guest non devono MAI avere accesso ai portali Azure, M365 Admin, Entra ID. Questa policy è un safety net che blocca questo accesso anche se qualche configurazione errata concedesse permissions admin a un guest.',
        detectFn: (ps) => ps.some(p => p.state !== 'disabled' && p.conditions?.users?.includeGuestsOrExternalUsers && p.conditions?.applications?.includeApplications?.includes('MicrosoftAdminPortals') && p.grantControls?.builtInControls?.includes('block')),
        getBody: (bg) => caBody('CA404', 'GuestUsers-AttackSurfaceReduction-AdminPortals-AnyPlatform-BLOCK', 'enabledForReportingButNotEnforced',
            { users: { includeGuestsOrExternalUsers: { guestOrExternalUserTypes: 'internalGuest,b2bCollaborationGuest,b2bCollaborationMember,b2bDirectConnectUser,otherExternalUser,serviceProvider', externalTenants: { membershipKind: 'all' } }, excludeGroups: bg ? [bg] : [] }, applications: { includeApplications: ['MicrosoftAdminPortals'] }, clientAppTypes: ['browser', 'mobileAppsAndDesktopClients'] },
            { operator: 'OR', builtInControls: ['block'] })
    }
];

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
// ============================================================
// MDE / DEFENDER XDR BASELINE CATALOG
// Fonte: Jeffrey Appel MDE Series + Microsoft Docs
// ============================================================
const MDE_BASELINE = [
    {
        id: 'mde-edr-onboarding',
        name: 'EDR Onboarding — Connettore Intune',
        category: 'EDR',
        critical: true,
        description: 'Onboarding automatico a Defender for Endpoint tramite connettore Intune.',
        why: 'Senza onboarding, gli endpoint non inviano segnali telemetrici al portale security.microsoft.com: niente alert, niente risposta automatica agli incidenti, niente threat hunting. È il prerequisito di tutto. Il connettore Intune elimina la necessità di script di onboarding manuali e garantisce che ogni device gestito sia automaticamente protetto da EDR.',
        detectFn: (cfgs, intents=[]) =>
            cfgs.some(p => (p['@odata.type']||'').toLowerCase().includes('windowsdefenderadvancedthreatprotectionconfiguration')) ||
            intents.some(i => ['e44c2ca3-2f9a-400a-a113-6cc88efd773d','a239407c-698d-4ef6-b525-8f0f50b4ecf6'].includes((i.templateId||'').toLowerCase())),
        odataType: '#microsoft.graph.windowsDefenderAdvancedThreatProtectionConfiguration',
        endpoint: 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windowsDefenderAdvancedThreatProtectionConfiguration',
            displayName: '[Baseline] MDE - EDR Onboarding',
            description: 'Onboarding automatico a Defender for Endpoint tramite connettore Intune',
            advancedThreatProtectionAutoPopulateOnboardingBlob: true,
            allowSampleSharing: true,
            enableExpeditedTelemetryReporting: false
        }
    },
    {
        id: 'mde-av-nextgen',
        name: 'AV Next-Gen Protection',
        category: 'Antivirus',
        critical: true,
        description: 'Protezione real-time, cloud block level High, behavior monitoring, blocco PUA.',
        why: 'Configura Defender AV con le impostazioni raccomandate da Microsoft e Jeffrey Appel: cloud protection High aumenta la detection rate fino al 99%+, behavior monitoring rileva malware zero-day che l\'AV signature-based non vede, il blocco PUA (Potentially Unwanted Apps) elimina adware e bundleware, network inspection analizza il traffico in real-time. Senza questa policy, Defender AV opera con impostazioni default che possono variare per device.',
        detectFn: (cfgs, intents=[]) => {
            const avProps = ['defenderRequireRealTimeMonitoring','defenderRequireCloudProtection','defenderRequireBehaviorMonitoring','defenderCloudBlockLevel','defenderPotentiallyUnwantedAppAction','defenderRequireNetworkInspectionSystem'];
            return cfgs.some(p => (p['@odata.type']||'').toLowerCase().includes('windows10endpointprotectionconfiguration') &&
                avProps.some(prop => p[prop] === true || (p[prop] && p[prop] !== 'notConfigured' && p[prop] !== 'userDefined'))) ||
                intents.some(i => { const t=(i.templateId||'').toLowerCase(); return t.includes('4356d05c') || t.includes('windows10antivirus'); });
        },
        odataType: '#microsoft.graph.windows10EndpointProtectionConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10EndpointProtectionConfiguration',
            displayName: '[Baseline] MDE - AV Next-Gen Protection',
            description: 'Defender AV baseline MDE: cloud protection High, PUA block, tamper protection, network inspection',
            defenderRequireRealTimeMonitoring: true,
            defenderRequireBehaviorMonitoring: true,
            defenderRequireCloudProtection: true,
            defenderCloudBlockLevel: 'high',
            defenderCloudExtendedTimeout: 50,
            defenderScanArchiveFiles: true,
            defenderScanDownloads: true,
            defenderScanNetworkFiles: true,
            defenderScanIncomingMail: true,
            defenderScanRemovableDrivesDuringFullScan: true,
            defenderPotentiallyUnwantedAppAction: 'block',
            defenderRequireNetworkInspectionSystem: true,
            defenderBlockEndUserAccess: false,
            firewallEnabled: true
        }
    },
    {
        id: 'mde-tamper-protection',
        name: 'Tamper Protection',
        category: 'Protezione',
        critical: true,
        description: 'Impedisce che malware o utenti locali disabilitino Defender AV/EDR (OMA-URI valore 5).',
        why: 'Uno dei primi obiettivi di un attaccante è disabilitare l\'antivirus prima di eseguire il payload. Tamper Protection blocca qualsiasi tentativo di modificare le impostazioni di Defender — incluse operazioni PowerShell, modifiche al registro, e strumenti di terze parti — anche con privilegi di amministratore locale. Il valore 5 significa "gestito da Intune": solo Intune può modificarlo, non l\'utente o un malware.',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('tamperprotection') &&
                (o.value==5||o.value==='5'||o.integerValue==5))),
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - Tamper Protection',
            description: 'Tamper Protection abilitata via OMA-URI (valore 5 = Enabled managed by Intune)',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingInteger',
                    displayName: 'Tamper Protection - Enabled via Intune (5)',
                    description: 'Prevents disabling Defender AV/EDR. Value 5 = Enabled, managed by Intune.',
                    omaUri: './Vendor/MSFT/Defender/Configuration/TamperProtection',
                    value: 5
                }
            ]
        }
    },
    {
        id: 'mde-network-protection',
        name: 'Network Protection',
        category: 'Network',
        critical: true,
        description: 'Blocca connessioni a IP, domini e URL malevoli in Block mode (OMA-URI valore 1).',
        why: 'Network Protection estende SmartScreen a tutto il traffico di rete, non solo al browser. Blocca in tempo reale le connessioni verso C2 (Command & Control), phishing, exploit kit e IOC (Indicators of Compromise) caricati da MDE. In modalità Block (valore 1), la connessione viene interrotta prima che il payload raggiunga il device. Valore 2 = Audit (solo log), valore 1 = Block (raccomandato per produzione).',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('enablenetworkprotection') &&
                [1,'1',2,'2'].includes(o.value ?? o.integerValue))),
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - Network Protection (Block)',
            description: 'Network Protection in Block mode per MDE (valore 1 = Enabled/Block)',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingInteger',
                    displayName: 'Enable Network Protection - Block mode',
                    description: '1 = Block mode, 2 = Audit mode. Block is recommended by Jeffrey Appel.',
                    omaUri: './Vendor/MSFT/Policy/Config/Defender/EnableNetworkProtection',
                    value: 1
                }
            ]
        }
    },
    {
        id: 'mde-asr-audit',
        name: 'ASR Rules — Tutte in Audit mode',
        category: 'Attack Surface Reduction',
        critical: false,
        description: 'Tutte le 16 regole ASR in modalità Audit (2) — monitora senza bloccare.',
        why: 'Le Attack Surface Reduction Rules riducono la superficie d\'attacco bloccando comportamenti tipici del malware (es. Office che crea processi child, LSASS dump, script offuscati, USB non autorizzati). Prima di passare a Block è essenziale fare un periodo di Audit per verificare che nessuna applicazione legittima venga impattata. Il report in security.microsoft.com → Reports → Attack Surface Reduction mostra quali regole avrebbero bloccato cosa.',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('attacksurfacereductionrules'))) ||
            intents.some(i => ['0e237410-1367-4844-bd7f-15fb0f08943b','e8c053d6-9f6e-41c9-b196-6e4fa8c9d0e4'].includes((i.templateId||'').toLowerCase())),
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - ASR Rules (Audit)',
            description: 'Tutte le 16 regole Attack Surface Reduction in modalità Audit (2) per assessment impatto',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingString',
                    displayName: 'ASR Rules - All in Audit mode (2)',
                    description: 'All 16 ASR rules: 56a863a9=signed drivers | 7674ba52=Adobe Reader | d4f940ab=Office child process | 9e6c4e1f=LSASS | be9ba2d9=email executable | 01443614=untrusted exe | 5beb7efe=obfuscated script | d3e037e1=JS/VBS download | 3b576869=Office executable content | 75668c1f=Office inject | 26190899=Office comm child | e6db77e5=WMI persistence | d1e49aac=PSExec/WMI | b2b3f03d=USB untrusted | 92e97fa1=Win32 from Office macro | c1db55ab=ransomware',
                    omaUri: './Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionRules',
                    value: '56a863a9-875e-4185-98a7-b882c64b5ce5=2|7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c=2|d4f940ab-401b-4efc-aadc-ad5f3c50688a=2|9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2=2|be9ba2d9-53ea-4cdc-84e5-9b1eeee46550=2|01443614-cd74-433a-b99e-2ecdc07bfc25=2|5beb7efe-fd9a-4556-801d-275e5ffc04cc=2|d3e037e1-3eb8-44c8-a917-57927947596d=2|3b576869-a4ec-4529-8536-b80a7769e899=2|75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84=2|26190899-1602-49e8-8b27-eb1d0a1ce869=2|e6db77e5-3df2-4cf1-b95a-636979351e5b=2|d1e49aac-8f56-4280-b9ba-993a6d77406c=2|b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4=2|92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b=2|c1db55ab-c21a-4637-bb3f-a12568109d35=2'
                }
            ]
        }
    },
    {
        id: 'mde-asr-block-safe',
        name: 'ASR Rules — Critiche in Block mode',
        category: 'Attack Surface Reduction',
        critical: true,
        description: '4 regole ASR ad alto impatto di sicurezza e basso rischio di falsi positivi in Block mode.',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('attacksurfacereductionrules') &&
                ((o.value||o.stringValue||'').match(/=1/g)||[]).length >= 1)) ||
            intents.some(i => ['0e237410-1367-4844-bd7f-15fb0f08943b','e8c053d6-9f6e-41c9-b196-6e4fa8c9d0e4'].includes((i.templateId||'').toLowerCase())),
        why: 'Queste 4 regole sono considerate sicure da mettere in Block anche senza periodo di audit: (1) LSASS credential dump — blocca Mimikatz e simili, (2) Vulnerable signed drivers — previene driver-based escalation, (3) WMI event subscription persistence — tecnica comune per persistenza fileless, (4) Ransomware protection avanzata. Secondo Jeffrey Appel, queste 4 hanno un impatto minimo su applicazioni legittime e possono essere deployate subito in Block.',
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - ASR Rules (Block - critiche)',
            description: 'Regole ASR critiche e sicure in Block mode (1): LSASS, signed vulnerable drivers, WMI persistence, ransomware',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingString',
                    displayName: 'ASR Rules - Critical block (LSASS, signed drivers, WMI, ransomware)',
                    description: 'Safe to block immediately: LSASS credential stealing, vulnerable signed drivers, WMI event subscription, ransomware protection',
                    omaUri: './Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionRules',
                    value: '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2=1|56a863a9-875e-4185-98a7-b882c64b5ce5=1|e6db77e5-3df2-4cf1-b95a-636979351e5b=1|c1db55ab-c21a-4637-bb3f-a12568109d35=1'
                }
            ]
        }
    },
    {
        id: 'mde-asr-block-full',
        name: 'ASR Rules — Complete in Block mode',
        category: 'Attack Surface Reduction',
        critical: false,
        description: 'Tutte le 16 regole ASR in Block mode — deployrare dopo aver validato l\'Audit.',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('attacksurfacereductionrules') &&
                ((o.value||o.stringValue||'').match(/=1/g)||[]).length >= 8)) ||
            intents.some(i => ['0e237410-1367-4844-bd7f-15fb0f08943b','e8c053d6-9f6e-41c9-b196-6e4fa8c9d0e4'].includes((i.templateId||'').toLowerCase())),
        why: 'Dopo aver analizzato il report Audit e confermato che nessuna app legittima viene bloccata, questa policy porta tutte le 16 regole in modalità Block per la massima protezione. Copre scenari come: Office che scarica executable, script offuscati, processi da USB non autorizzati, iniezioni di codice nei processi Office, child process da client email. Attenzione: valutare esclusioni per software specifici prima del deploy in produzione.',
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - ASR Rules (Block - complete)',
            description: 'Tutte le 16 regole ASR in Block mode (1) — deployrare dopo validazione in Audit',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingString',
                    displayName: 'ASR Rules - All in Block mode (1)',
                    omaUri: './Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionRules',
                    value: '56a863a9-875e-4185-98a7-b882c64b5ce5=1|7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c=1|d4f940ab-401b-4efc-aadc-ad5f3c50688a=1|9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2=1|be9ba2d9-53ea-4cdc-84e5-9b1eeee46550=1|01443614-cd74-433a-b99e-2ecdc07bfc25=1|5beb7efe-fd9a-4556-801d-275e5ffc04cc=1|d3e037e1-3eb8-44c8-a917-57927947596d=1|3b576869-a4ec-4529-8536-b80a7769e899=1|75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84=1|26190899-1602-49e8-8b27-eb1d0a1ce869=1|e6db77e5-3df2-4cf1-b95a-636979351e5b=1|d1e49aac-8f56-4280-b9ba-993a6d77406c=1|b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4=1|92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b=1|c1db55ab-c21a-4637-bb3f-a12568109d35=1'
                }
            ]
        }
    },
    {
        id: 'mde-file-hash',
        name: 'File Hash Computation',
        category: 'Telemetry',
        critical: false,
        description: 'Calcolo automatico degli hash SHA-256 di tutti i file eseguiti sull\'endpoint.',
        detectFn: (cfgs, intents=[]) => cfgs.some(p =>
            (p['@odata.type']||'').toLowerCase().includes('windows10customconfiguration') && Array.isArray(p.omaSettings) &&
            p.omaSettings.some(o => (o.omaUri||'').toLowerCase().includes('enablefilehashcomputation') &&
                (o.value==1||o.value==='1'||o.integerValue==1))),
        why: 'MDE usa gli hash per abbinare i file agli indicatori di compromissione (IOC) personalizzati che puoi caricare in security.microsoft.com. Senza questa impostazione, non puoi creare regole "blocca file con hash X" né vedere gli hash degli eseguibili nei log di Advanced Hunting (tabella DeviceFileEvents). Essenziale per threat hunting e response. Attenzione: può aumentare leggermente il carico CPU su macchine con alto I/O di file.',
        odataType: '#microsoft.graph.windows10CustomConfiguration',
        endpoint: 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations',
        body: {
            '@odata.type': '#microsoft.graph.windows10CustomConfiguration',
            displayName: '[Baseline] MDE - File Hash Computation',
            description: 'EnableFileHashComputation = 1 per migliorare Advanced Hunting e IOC matching',
            omaSettings: [
                {
                    '@odata.type': '#microsoft.graph.omaSettingInteger',
                    displayName: 'Enable File Hash Computation',
                    description: 'Required for custom indicators matching in MDE. Test performance impact on endpoints.',
                    omaUri: './Vendor/MSFT/Defender/Configuration/EnableFileHashComputation',
                    value: 1
                }
            ]
        }
    }
];

// ============================================================
// MDE BASELINE WIZARD
// ============================================================

// Descrizione leggibile di un config profile esistente basata su @odata.type e settings
function describeExistingProfile(p) {
    const type = (p['@odata.type'] || '').toLowerCase();
    if (type.includes('windowsdefenderadvancedthreatprotection')) return 'Defender for Endpoint Onboarding';
    if (type.includes('windows10endpointprotection')) {
        const parts = [];
        if (p.defenderRequireRealTimeMonitoring || p.defenderRequireCloudProtection) parts.push('AV / Cloud Protection');
        if (p.firewallEnabled) parts.push('Firewall');
        if (p.bitLockerEnabled || p.bitLockerEncryptDevice) parts.push('BitLocker');
        return parts.length ? parts.join(', ') : 'Endpoint Protection';
    }
    if (type.includes('windows10customconfiguration') && Array.isArray(p.omaSettings)) {
        const uris = p.omaSettings.map(o => {
            const u = (o.omaUri||'').toLowerCase();
            if (u.includes('tamperprotection')) return 'Tamper Protection';
            if (u.includes('enablenetworkprotection')) return 'Network Protection';
            if (u.includes('attacksurfacereductionrules')) return 'ASR Rules';
            if (u.includes('enablefilehashcomputation')) return 'File Hash Computation';
            const seg = (o.omaUri||'').split('/').pop();
            return seg || o.omaUri;
        });
        const uniq = [...new Set(uris)];
        return 'OMA-URI: ' + uniq.slice(0, 3).join(', ') + (uniq.length > 3 ? ` +${uniq.length-3}` : '');
    }
    if (type.includes('windows10generalconfiguration')) return 'Impostazioni generali Windows (browser, lock, account...)';
    if (type.includes('devicemanagementconfigurationpolicy')) return 'Settings Catalog';
    if (type.includes('grouppolicyconfiguration')) return 'Administrative Templates (ADMX/GPO)';
    if (type.includes('iosgeneral') || type.includes('ipadgeneral')) return 'Impostazioni generali iOS/iPadOS';
    if (type.includes('android')) return 'Configurazione Android';
    if (type.includes('macos')) return 'Configurazione macOS';
    return type.replace('#microsoft.graph.', '').replace(/([A-Z])/g, ' $1').trim() || 'Configuration Profile';
}

// Fetcha tutti i device configs con full settings e calcola copertura per ogni entry MDE_BASELINE
async function scanMdeCoverage() {
    try {
        const token = await getGraphToken(getSelectedTenantId());
        const h = { 'Authorization': `Bearer ${token}` };

        let configs = [], url = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$top=100';
        while (url) {
            const r = await fetch(url, { headers: h });
            if (!r.ok) break;
            const j = await r.json();
            configs = configs.concat(j.value || []);
            url = j['@odata.nextLink'] || null;
        }

        let intents = [];
        try {
            const ir = await fetch('https://graph.microsoft.com/beta/deviceManagement/intents?$top=100', { headers: h });
            if (ir.ok) intents = (await ir.json()).value || [];
        } catch {}

        const map = {};
        for (const entry of MDE_BASELINE) {
            if (!entry.detectFn) { map[entry.id] = { present: false, coveredBy: null, coveredByDesc: null }; continue; }
            const present = entry.detectFn(configs, intents);
            let coveredBy = null, coveredByDesc = null;
            if (present) {
                for (const p of configs) {
                    if (entry.detectFn([p], [])) {
                        coveredBy = p.displayName || p.name || 'Policy sconosciuta';
                        coveredByDesc = describeExistingProfile(p);
                        break;
                    }
                }
                if (!coveredBy) {
                    for (const i of intents) {
                        if (entry.detectFn([], [i])) {
                            coveredBy = i.displayName || 'Endpoint Security Policy';
                            coveredByDesc = 'Endpoint Security Intent';
                            break;
                        }
                    }
                }
            }
            map[entry.id] = { present, coveredBy, coveredByDesc };
        }
        return { map, configs, intents };
    } catch (e) {
        console.warn('scanMdeCoverage failed:', e.message);
        return { map: {}, configs: [], intents: [] };
    }
}

function openCaBaselineWizard() {
    const modal = document.getElementById('ca-baseline-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    initCaBaselineWizard();
    renderCaPolicyList();
}

async function openMdeBaselineWizard() {
    const modal = document.getElementById('mde-baseline-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    initMdeBaselineWizard();

    // Loading state nel policy list
    const listEl = document.getElementById('mde-policy-list');
    if (listEl) listEl.innerHTML = '<div style="padding:24px;text-align:center;color:#666;"><i class="fas fa-spinner fa-spin" style="margin-right:8px;"></i>Analisi policy esistenti nel tenant...</div>';

    // Fetch full configs e calcola copertura
    const { map } = await scanMdeCoverage();
    window.mdeCoverageMap = map;
    renderMdePolicyList();
}

function initMdeBaselineWizard() {
    document.getElementById('mde-step-1').style.display = '';
    document.getElementById('mde-step-2').style.display = 'none';
    updateMdeStepIndicator(1);
    const logEl = document.getElementById('mde-deploy-log');
    if (logEl) logEl.innerHTML = '';

    // Close X
    const closeX = document.getElementById('mde-baseline-close');
    const newCloseX = closeX.cloneNode(true);
    closeX.parentNode.replaceChild(newCloseX, closeX);
    newCloseX.addEventListener('click', () => { document.getElementById('mde-baseline-modal').style.display = 'none'; });

    // Step2 close
    const closeBtn = document.getElementById('mde-step2-close');
    const newClose = closeBtn.cloneNode(true);
    closeBtn.parentNode.replaceChild(newClose, closeBtn);
    newClose.addEventListener('click', () => { document.getElementById('mde-baseline-modal').style.display = 'none'; });

    // Deploy button
    const deployBtn = document.getElementById('mde-step1-deploy');
    const newDeploy = deployBtn.cloneNode(true);
    deployBtn.parentNode.replaceChild(newDeploy, deployBtn);
    newDeploy.addEventListener('click', () => runMdeBaselineDeploy());

    renderMdePolicyList();
}

function initCaBaselineWizard() {
    document.getElementById('ca-step-1').style.display = '';
    document.getElementById('ca-step-2').style.display = 'none';

    const closeX = document.getElementById('ca-baseline-close');
    if (closeX) { const n = closeX.cloneNode(true); closeX.parentNode.replaceChild(n, closeX); n.addEventListener('click', () => { document.getElementById('ca-baseline-modal').style.display = 'none'; }); }
    const closeBtn = document.getElementById('ca-step2-close');
    if (closeBtn) { const n = closeBtn.cloneNode(true); closeBtn.parentNode.replaceChild(n, closeBtn); n.addEventListener('click', () => { document.getElementById('ca-baseline-modal').style.display = 'none'; }); }
    const deployBtn = document.getElementById('ca-step1-deploy');
    if (deployBtn) { const n = deployBtn.cloneNode(true); deployBtn.parentNode.replaceChild(n, deployBtn); n.addEventListener('click', () => runCaBaselineDeploy()); }
}

function updateMdeStepIndicator(activeStep) {
    document.querySelectorAll('.mde-step-indicator').forEach(el => {
        const step = parseInt(el.dataset.step);
        el.style.background = step === activeStep ? '#0a2342' : (step < activeStep ? '#107c10' : '#e0e7ef');
        el.style.color = step <= activeStep ? 'white' : '#666';
    });
}

function renderMdePolicyList() {
    // Priorità: mdeCoverageMap (scan real-time) > PolicyGapAnalysis (dal precheck XDR)
    const coverageMap = window.mdeCoverageMap || null;
    const gapMap = {};
    if (!coverageMap) {
        const data = window.lastPrecheckResponse || {};
        const POLICY_TO_GAP = {
            'mde-edr-onboarding': 'edr-onboarding', 'mde-av-nextgen': 'av-nextgen',
            'mde-tamper-protection': 'tamper-protection', 'mde-network-protection': 'network-protection',
            'mde-asr-audit': 'asr-rules', 'mde-asr-block-safe': 'asr-rules',
            'mde-asr-block-full': 'asr-rules', 'mde-file-hash': 'file-hash'
        };
        if (Array.isArray(data.PolicyGapAnalysis)) data.PolicyGapAnalysis.forEach(g => { gapMap[g.Id] = g.Present; });
        MDE_BASELINE.forEach(p => { if (!gapMap[POLICY_TO_GAP[p.id]]) gapMap[p.id] = false; });
    }

    const container = document.getElementById('mde-policy-list');
    container.innerHTML = '';

    const categoryColors = { 'EDR': '#6f42c1', 'Antivirus': '#0078d4', 'Protezione': '#107c10', 'Network': '#0a2342', 'Attack Surface Reduction': '#d13438', 'Telemetry': '#666' };

    let lastCategory = '';
    MDE_BASELINE.forEach(policy => {
        if (policy.category !== lastCategory) {
            lastCategory = policy.category;
            const hdr = document.createElement('div');
            hdr.style.cssText = `padding:8px 14px;background:${categoryColors[policy.category] || '#333'};color:white;font-size:12px;font-weight:700;letter-spacing:.5px;`;
            hdr.textContent = policy.category.toUpperCase();
            container.appendChild(hdr);
        }

        // Determina stato: usa coverageMap se disponibile, altrimenti gapMap
        let present = false, coveredBy = null, coveredByDesc = null;
        if (coverageMap && coverageMap[policy.id]) {
            present = coverageMap[policy.id].present;
            coveredBy = coverageMap[policy.id].coveredBy;
            coveredByDesc = coverageMap[policy.id].coveredByDesc;
        } else {
            const POLICY_TO_GAP = { 'mde-edr-onboarding': 'edr-onboarding', 'mde-av-nextgen': 'av-nextgen', 'mde-tamper-protection': 'tamper-protection', 'mde-network-protection': 'network-protection', 'mde-asr-audit': 'asr-rules', 'mde-asr-block-safe': 'asr-rules', 'mde-asr-block-full': 'asr-rules', 'mde-file-hash': 'file-hash' };
            const gapId = POLICY_TO_GAP[policy.id];
            present = gapId ? (gapMap[gapId] === true) : false;
        }

        const row = document.createElement('div');
        row.style.cssText = `display:flex;align-items:flex-start;gap:12px;padding:10px 14px;border-bottom:1px solid #f0f0f0;${present ? 'background:#f6fff6;' : ''}`;
        const detailsId = `mde-details-${policy.id}`;

        const coveredByHtml = coveredBy ? `
            <div style="margin-top:5px;padding:6px 10px;background:#e8f5e9;border-left:3px solid #107c10;border-radius:0 4px 4px 0;font-size:11px;color:#1b5e20;">
                <strong>Coperta da:</strong> ${escapeHtml(coveredBy)}
                ${coveredByDesc ? `<span style="color:#555;"> — ${escapeHtml(coveredByDesc)}</span>` : ''}
            </div>` : '';

        row.innerHTML = `
            <input type="checkbox" class="mde-policy-check" data-id="${policy.id}" ${present ? 'disabled' : ''} style="width:16px;height:16px;flex-shrink:0;margin-top:3px;">
            <div style="flex:1;min-width:0;">
                <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
                    <span style="font-weight:600;font-size:13px;">${escapeHtml(policy.name)}</span>
                    ${policy.critical ? '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">CRITICA</span>' : ''}
                    <span style="flex-shrink:0;background:${present ? '#107c10' : '#d13438'};color:white;border-radius:4px;padding:1px 8px;font-size:10px;font-weight:700;">${present ? '✓ PRESENTE' : 'MANCANTE'}</span>
                </div>
                <div style="font-size:12px;color:#555;margin-top:3px;">${escapeHtml(policy.description)}</div>
                ${coveredByHtml}
                ${policy.why ? `
                <button onclick="document.getElementById('${detailsId}').style.display=document.getElementById('${detailsId}').style.display==='none'?'block':'none'"
                    style="background:none;border:none;color:#0078d4;font-size:11px;cursor:pointer;padding:3px 0;text-decoration:underline;">
                    Perché è importante?
                </button>
                <div id="${detailsId}" style="display:none;margin-top:6px;padding:10px 12px;background:#f0f6ff;border-left:3px solid #0078d4;border-radius:0 6px 6px 0;font-size:12px;color:#333;line-height:1.5;">
                    ${escapeHtml(policy.why)}
                </div>` : ''}
            </div>`;
        container.appendChild(row);
    });

    // Seleziona di default solo le MANCANTI critiche
    container.querySelectorAll('.mde-policy-check:not([disabled])').forEach(cb => {
        const policy = MDE_BASELINE.find(p => p.id === cb.dataset.id);
        cb.checked = policy?.critical ?? true;
    });
    updateMdeDeployCount();
    container.addEventListener('change', updateMdeDeployCount);
}

function updateMdeDeployCount() {
    const checked = document.querySelectorAll('.mde-policy-check:checked:not([disabled])').length;
    const countEl = document.getElementById('mde-selected-count');
    const deployBtn = document.getElementById('mde-step1-deploy');
    if (countEl) countEl.textContent = `${checked} policy selezionate`;
    if (deployBtn) deployBtn.disabled = checked === 0;
}

async function runMdeBaselineDeploy() {
    document.getElementById('mde-step-1').style.display = 'none';
    document.getElementById('mde-step-2').style.display = '';
    updateMdeStepIndicator(2);

    const logEl = document.getElementById('mde-deploy-log');
    const summaryEl = document.getElementById('mde-deploy-summary');
    const closeBtn = document.getElementById('mde-step2-close');
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
        token = await getGraphTokenWithWrite(getSelectedTenantId());
        log('✓ Token acquisito.', '#4ec9b0');
    } catch (e) {
        log(`✗ Errore token: ${e.message}`, '#f44747');
        summaryEl.textContent = '❌ Impossibile acquisire il token. Verifica i permessi nell\'App Registration.';
        summaryEl.style.color = '#d13438';
        closeBtn.style.display = '';
        return;
    }

    const selectedIds = Array.from(document.querySelectorAll('.mde-policy-check:checked:not([disabled])')).map(cb => cb.dataset.id);
    let deployed = 0, failed = 0;

    for (const policy of MDE_BASELINE) {
        if (!selectedIds.includes(policy.id)) continue;
        log(`→ Deploy: ${policy.name}`, '#9cdcfe');
        try {
            const resp = await fetch(policy.endpoint, {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
                body: JSON.stringify(policy.body)
            });
            if (resp.ok) {
                const result = await resp.json();
                log(`  ✓ Creata: ${result.displayName || policy.name} (id: ${result.id || '?'})`, '#4ec9b0');
                deployed++;
            } else {
                const errText = await resp.text();
                let errMsg = '';
                try { errMsg = JSON.parse(errText)?.error?.message || JSON.parse(errText)?.Message || ''; } catch {}
                if (!errMsg) errMsg = errText.substring(0, 200);
                log(`  ✗ Errore HTTP ${resp.status}: ${errMsg}`, '#f44747');
                failed++;
            }
        } catch (e) {
            log(`  ✗ Errore rete: ${e.message}`, '#f44747');
            failed++;
        }
    }

    log('', '');
    log(`=== COMPLETATO: ${deployed} policy create, ${failed} errori ===`, failed > 0 ? '#ff8c00' : '#4ec9b0');
    summaryEl.textContent = `${deployed} policy MDE deployate${failed > 0 ? `, ${failed} errori` : ''}.`;
    summaryEl.style.color = failed > 0 ? '#d13438' : '#107c10';
    closeBtn.style.display = '';
}

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
        token = await getGraphTokenWithWrite(getSelectedTenantId());
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
            if (currentSolution === 'defender-xdr' || currentSolution === 'intune' || currentSolution === 'conditional-access') {
                showPrecheckModal(currentSolution);
                return;
            }
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

    document.getElementById('btn-load-tenants')?.addEventListener('click', async function() {
        try {
            if (!currentAccount) { alert('⚠️ Effettua il login prima di caricare le directory.'); return; }
            const accessToken = await getAccessToken();
            const tenants = await fetchTenantsForUser(accessToken);
            const picker = document.getElementById('precheck-tenant-picker');
            if (!picker) return;
            picker.style.display = 'block';

            renderTenantPicker(picker, tenants, getSelectedTenantId() || getSavedTenantId());

            picker.querySelector('#btn-hide-tenant')?.addEventListener('click', () => { picker.style.display = 'none'; });
            picker.querySelector('#btn-use-tenant')?.addEventListener('click', () => {
                const selected = picker.querySelector('.precheck-tenant-radio:checked');
                const tenantId = parseTenantId(selected?.value || '');
                if (!tenantId) { alert('⚠️ Seleziona una directory valida.'); return; }
                const tenantInput = document.getElementById('tenant-id');
                if (tenantInput) tenantInput.value = tenantId;
                saveTenantId(tenantId);
                // Reset subscriptions when tenant changes to avoid stale selection
                document.getElementById('subscription-id').value = '';
                try { localStorage.removeItem(LS_SUBS); } catch {}
                picker.style.display = 'none';
            });
        } catch (e) {
            alert('❌ Errore nel caricamento directory: ' + e.message);
        }
    });

    document.getElementById('btn-load-subs')?.addEventListener('click', async function() {
        try {
            if (!currentAccount) { alert('⚠️ Effettua il login prima di caricare le subscriptions.'); return; }
            const selectedTenantId = getSelectedTenantId();
            if (!selectedTenantId) {
                alert('⚠️ Seleziona prima la Directory/Tenant.');
                document.getElementById('btn-load-tenants')?.click();
                return;
            }
            let subs = [];
            let fallbackMode = '';

            // 1) Try strict tenant token first
            try {
                const accessToken = await getAccessToken(selectedTenantId);
                subs = await fetchSubscriptionsForUser(accessToken);
            } catch {
                // ignore here, fallback below
            }

            // 2) Fallback robusto multi-tenant/B2B:
            // prova a enumerare i tenant accessibili e raccogliere le subscription per ciascun tenant.
            if (!Array.isArray(subs) || subs.length === 0) {
                const globalToken = await getAccessToken();
                const tenants = await fetchTenantsForUser(globalToken).catch(() => []);
                const tenantIds = Array.from(new Set(
                    (Array.isArray(tenants) ? tenants : [])
                        .map(t => parseTenantId(t.tenantId || t.tenantID || t.id || ''))
                        .filter(Boolean)
                ));
                if (selectedTenantId && !tenantIds.includes(selectedTenantId)) {
                    tenantIds.unshift(selectedTenantId);
                }

                const merged = [];
                const seen = new Set();
                for (const tid of tenantIds) {
                    try {
                        const tkn = await getAccessToken(tid);
                        const tenantSubs = await fetchSubscriptionsForUser(tkn);
                        (Array.isArray(tenantSubs) ? tenantSubs : []).forEach(s => {
                            const sid = String(s.subscriptionId || '').trim();
                            if (!sid || seen.has(sid)) return;
                            seen.add(sid);
                            if (!parseTenantId(s.tenantId)) s.tenantId = tid;
                            merged.push(s);
                        });
                    } catch {
                        // ignora tenant non accessibili
                    }
                }

                // ultimo tentativo: endpoint subscriptions con token globale
                if (!merged.length) {
                    const allSubs = await fetchSubscriptionsForUser(globalToken).catch(() => []);
                    (Array.isArray(allSubs) ? allSubs : []).forEach(s => {
                        const sid = String(s.subscriptionId || '').trim();
                        if (!sid || seen.has(sid)) return;
                        seen.add(sid);
                        merged.push(s);
                    });
                }

                const tenantMatched = merged.filter(s => parseTenantId(s.tenantId) === selectedTenantId);
                if (tenantMatched.length > 0) {
                    subs = tenantMatched;
                    fallbackMode = 'filtered';
                } else {
                    subs = merged;
                    fallbackMode = 'all';
                }
            }

            lastLoadedSubscriptions = Array.isArray(subs) ? subs : [];

            const picker = document.getElementById('precheck-sub-picker');
            if (!picker) return;
            picker.style.display = 'block';

            const current = parseSubscriptionIds(document.getElementById('subscription-id')?.value || '');
            const saved = getSavedSubscriptionIds();
            const preselected = current.length ? current : saved;

            renderSubscriptionPicker(picker, subs, preselected);

            if (!subs.length) {
                picker.insertAdjacentHTML('beforeend', `
                    <div style="margin-top:10px;padding:10px 12px;border:1px solid #ffd8a8;background:#fff4e6;border-radius:8px;color:#8a4b08;font-size:13px;">
                        Nessuna subscription visibile nel tenant selezionato <code>${selectedTenantId}</code>.
                        Verifica ruolo RBAC in quel tenant oppure prova logout/login.
                    </div>`);
            } else if (fallbackMode === 'filtered') {
                picker.insertAdjacentHTML('beforeend', `
                    <div style="margin-top:10px;padding:10px 12px;border:1px solid #c0d4f5;background:#f0f6ff;border-radius:8px;color:#0b4f9c;font-size:13px;">
                        Elenco subscription ottenuto con fallback e filtrato per tenant selezionato.
                    </div>`);
            } else if (fallbackMode === 'all') {
                picker.insertAdjacentHTML('beforeend', `
                    <div style="margin-top:10px;padding:10px 12px;border:1px solid #c0d4f5;background:#f0f6ff;border-radius:8px;color:#0b4f9c;font-size:13px;">
                        Nessuna subscription trovata nel tenant selezionato. Mostro tutte le subscription accessibili dal tuo account (scenario multi-tenant/B2B).
                    </div>`);
            }

            picker.querySelector('#btn-hide-subs')?.addEventListener('click', () => { picker.style.display = 'none'; });
            picker.querySelector('#btn-use-subs')?.addEventListener('click', () => {
                const checked = Array.from(picker.querySelectorAll('.precheck-sub-check'))
                    .filter(el => el.checked)
                    .map(el => String(el.value || '').trim())
                    .filter(Boolean);
                if (!checked.length) { alert('⚠️ Seleziona almeno una subscription.'); return; }
                document.getElementById('subscription-id').value = checked.join(',');
                try { localStorage.setItem(LS_SUBS, JSON.stringify(checked)); } catch {}
                const matchedTenants = Array.from(new Set(
                    (lastLoadedSubscriptions || [])
                        .filter(s => checked.includes(String(s.subscriptionId || '').trim()))
                        .map(s => parseTenantId(s.tenantId))
                        .filter(Boolean)
                ));
                if (matchedTenants.length === 1 && !isTenantWideSolution(currentSolution)) {
                    const tenantInput = document.getElementById('tenant-id');
                    if (tenantInput && parseTenantId(tenantInput.value) !== matchedTenants[0]) {
                        tenantInput.value = matchedTenants[0];
                    }
                    saveTenantId(matchedTenants[0]);
                }
                picker.style.display = 'none';
            });
        } catch (e) {
            alert('❌ Errore nel caricamento subscriptions: ' + e.message);
        }
    });

    document.getElementById('tenant-id')?.addEventListener('change', function() {
        const valid = parseTenantId(this.value);
        if (this.value.trim() && !valid) {
            alert('⚠️ Tenant ID non valido. Inserisci un GUID valido.');
            return;
        }
        saveTenantId(valid);
    });

    document.getElementById('run-precheck')?.addEventListener('click', async function() {
        if (!currentAccount) { alert('⚠️ Devi effettuare il login prima di eseguire il precheck.\n\n🔐 Clicca su "Accedi con Microsoft".'); return; }
        const selectedTenantId = getSelectedTenantId();
        if (document.getElementById('tenant-id')?.value && !selectedTenantId) {
            alert('⚠️ Tenant ID non valido. Inserisci un GUID valido oppure lascia vuoto.');
            return;
        }
        if (!selectedTenantId) {
            alert('⚠️ Seleziona prima la Directory/Tenant dal pulsante "Seleziona directory".');
            return;
        }
        saveTenantId(selectedTenantId);

        // Defender XDR e Conditional Access: precheck diretto browser → Graph API
        if (currentSolution === 'defender-xdr') { await runDefenderXdrPrecheckClientSide(selectedTenantId); return; }
        if (currentSolution === 'conditional-access') { await runCaPrecheckClientSide(selectedTenantId); return; }

        // Soluzioni tenant-wide: non richiedono subscription Azure
        let subscriptionIds;
        if (isTenantWideSolution(currentSolution)) {
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
            const accessToken = await getAccessToken(selectedTenantId);
            const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
            const useV2 = (currentSolution === 'azure-monitor') && document.getElementById('use-precheck2')?.checked && solConfig.apiEndpointV2;
            const endpoint = useV2 ? solConfig.apiEndpointV2 : solConfig.apiEndpoint;
            const results = [];

            // Per Intune e Defender XDR è necessario un token Graph separato
            let graphToken = null;
            if (currentSolution === 'intune' || currentSolution === 'defender-xdr') {
                try {
                    graphToken = await getGraphToken(selectedTenantId);
                } catch (e) {
                    throw new Error(`Impossibile ottenere il token Microsoft Graph.\n\nAssicurati che l'App Registration abbia il consenso per DeviceManagementApps.Read.All e DeviceManagementManagedDevices.Read.All.\n\nDettaglio: ${e.message}`);
                }
            }
            if (currentSolution === 'assessment-security-m365-azure') {
                try {
                    graphToken = await getAssessmentGraphToken(selectedTenantId);
                } catch (e) {
                    throw new Error(`Impossibile ottenere il token Microsoft Graph per l'assessment.\n\nConcedi il consenso admin agli scope: Directory.Read.All, Policy.Read.All, Organization.Read.All, User.Read.All.\n\nDettaglio: ${e.message}`);
                }
            }
            if (currentSolution === 'assessment-365') {
                try {
                    graphToken = await getAssessment365GraphToken(selectedTenantId);
                } catch (e) {
                    throw new Error(`Impossibile ottenere il token Microsoft Graph per Assessment 365.\n\nConcedi il consenso admin agli scope richiesti (Directory/Group/Organization/Policy/User read).\n\nDettaglio: ${e.message}`);
                }
            }

            for (const subId of subscriptionIds) {
                const tenantPart = selectedTenantId ? `&tenantId=${encodeURIComponent(selectedTenantId)}` : '';
                const apiUrl = `${API_BASE_URL}${endpoint}?subscriptionId=${encodeURIComponent(subId)}${tenantPart}`;
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
                    let apiError = errorText;
                    try {
                        const parsed = JSON.parse(errorText);
                        apiError = parsed?.error || errorText;
                    } catch {}
                    if (response.status === 401) {
                        const msg = String(apiError || '');
                        if (msg.toLowerCase().includes('subscription non accessibile')) {
                            throw new Error(`Token valido ma senza accesso alla subscription ${subId} nel tenant selezionato.`);
                        }
                        throw new Error(`Autenticazione non valida per la chiamata API: ${msg || '401 Unauthorized'}`);
                    }
                    if (response.status === 403) throw new Error(`Accesso negato sulla subscription ${subId}: ${apiError}`);
                    if (response.status === 404) throw new Error(`Subscription non trovata: ${subId}.`);
                    throw new Error(`Errore HTTP ${response.status} su ${subId}: ${apiError}`);
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

    // Shared: render Checks array (from PS EnterprisePrecheck) as styled table + optional extra HTML blocks + iframe fallback
    function renderNativeEnterpriseReport(data, extraBlocks) {
        const recContainer = document.getElementById('recommendations-content');
        if (!recContainer) return;
        recContainer.innerHTML = '';

        const checks = Array.isArray(data?.Checks) ? data.Checks : [];

        // Coverage bar if readiness available
        const readiness = data?.Readiness;
        const score = Number(data?.Summary?.ReadinessScore ?? readiness?.score ?? null);
        if (Number.isFinite(score)) {
            const color = score >= 85 ? '#107c10' : score >= 60 ? '#d97706' : '#b3261e';
            const bg    = score >= 85 ? '#e6f4ea' : score >= 60 ? '#fff8eb' : '#fce8e6';
            const bar = document.createElement('div');
            bar.style.cssText = `margin-bottom:16px;padding:14px 16px;background:${bg};border:1px solid ${color}33;border-radius:10px;`;
            bar.innerHTML = `
                <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;">
                    <span style="font-weight:700;color:${color};font-size:15px;">Readiness Score</span>
                    <span style="font-weight:800;font-size:22px;color:${color};">${score}%</span>
                </div>
                <div style="background:#e0e0e0;border-radius:6px;height:10px;overflow:hidden;">
                    <div style="width:${score}%;height:100%;background:${color};border-radius:6px;transition:width .5s;"></div>
                </div>`;
            recContainer.appendChild(bar);
        }

        // Enterprise checks table
        if (checks.length) {
            const failed = checks.filter(c => !c.Passed && c.status !== 'Pass');
            const passed = checks.filter(c => c.Passed || c.status === 'Pass');
            const box = document.createElement('div');
            box.style.cssText = 'margin-bottom:16px;padding:14px 16px;border:1px solid #cfd8dc;background:#f9fbfc;border-radius:10px;';
            const rows = checks.map(c => {
                const ok = (c.Passed === true || String(c.status||'').toLowerCase() === 'pass');
                const sev = String(c.Severity || c.severity || '').toLowerCase();
                const sevBadge = ok
                    ? '<span style="background:#e6f4ea;color:#137333;border-radius:4px;padding:2px 7px;font-size:10px;font-weight:700;">OK</span>'
                    : sev === 'critical'
                        ? '<span style="background:#fce8e6;color:#b3261e;border-radius:4px;padding:2px 7px;font-size:10px;font-weight:700;">CRITICO</span>'
                        : sev === 'high'
                            ? '<span style="background:#fff0e6;color:#c44d00;border-radius:4px;padding:2px 7px;font-size:10px;font-weight:700;">ALTO</span>'
                            : '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:2px 7px;font-size:10px;font-weight:700;">ATTENZIONE</span>';
                const title = escapeHtml(c.Title || c.title || '');
                const area  = escapeHtml(c.Area || c.area || '');
                const rec   = escapeHtml(c.Remediation || c.remediation || c.Recommendation || '');
                const rat   = escapeHtml(c.Rationale || c.rationale || '');
                return `<tr style="border-bottom:1px solid #e8edf0;">
                    <td style="padding:8px 10px;vertical-align:top;width:90px;">${sevBadge}</td>
                    <td style="padding:8px 10px;vertical-align:top;">
                        <div style="font-weight:600;color:#1a2e3b;">${title}</div>
                        ${area ? `<div style="font-size:11px;color:#5a7082;margin-top:1px;">${area}</div>` : ''}
                        ${rat  ? `<div style="font-size:12px;color:#555;margin-top:3px;">${rat}</div>`  : ''}
                        ${!ok && rec ? `<div style="font-size:12px;color:#0078d4;margin-top:4px;font-style:italic;">→ ${rec}</div>` : ''}
                    </td>
                </tr>`;
            }).join('');
            box.innerHTML = `
                <div style="font-weight:700;color:#0f3d56;margin-bottom:6px;font-size:14px;">Check Enterprise Microsoft</div>
                <div style="font-size:13px;color:#37566b;margin-bottom:10px;">
                    Totale: <strong>${checks.length}</strong> &nbsp;·&nbsp; OK: <strong>${passed.length}</strong> &nbsp;·&nbsp; Gap: <strong>${failed.length}</strong>
                </div>
                <div style="max-height:340px;overflow:auto;border:1px solid #dde6ea;border-radius:8px;background:white;">
                    <table style="width:100%;border-collapse:collapse;">${rows}</table>
                </div>`;
            recContainer.appendChild(box);
        }

        // Extra content blocks (solution-specific tables)
        if (Array.isArray(extraBlocks)) {
            extraBlocks.forEach(block => {
                if (!block) return;
                const el = document.createElement('div');
                el.style.cssText = 'margin-bottom:16px;';
                el.innerHTML = block;
                recContainer.appendChild(el);
            });
        }

        // Iframe report at the bottom (collapsible)
        if (data?.ReportHTML) {
            const details = document.createElement('details');
            details.style.cssText = 'margin-top:8px;border:1px solid #d1dce5;border-radius:8px;overflow:hidden;';
            details.innerHTML = `<summary style="padding:10px 14px;background:#f0f4f8;cursor:pointer;font-weight:600;color:#0f3d56;font-size:13px;">Report HTML completo (appendice tecnica)</summary>`;
            const iframe = document.createElement('iframe');
            iframe.style.cssText = 'width:100%;height:680px;border:none;display:block;';
            iframe.setAttribute('sandbox', 'allow-same-origin');
            iframe.srcdoc = data.ReportHTML;
            details.appendChild(iframe);
            recContainer.appendChild(details);
        }
    }

    function applyPrecheckUiForSolution(solution) {
        setTabVisible('intune-compliance', false);
        setTabVisible('intune-configuration', false);

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
            setTabText('virtual-machines', 'VM Azure');
            setTabText('workspaces', 'Vault');
            setTabText('dcr', 'Policy Backup');
            setTabText('recommendations', 'Analisi');
            setPaneTitle('overview', "Stato Azure Backup");
            setPaneTitle('virtual-machines', 'Macchine Virtuali Azure');
            setPaneTitle('workspaces', 'Recovery Services Vault');
            setPaneTitle('dcr', 'Policy di Backup');
            setPaneTitle('recommendations', 'Analisi e Raccomandazioni');
            setOverviewLabels(['VM Totali', 'VM Protette', 'VM Non Protette', 'Copertura']);
            setTableHeaders('vm-table', ['Nome VM', 'Gruppo di Risorse', 'Location', 'OS', 'Backup']);
            setTableHeaders('workspace-table', ['Vault', 'Gruppo di Risorse', 'Location', 'Ridondanza', 'SoftDelete']);
            setTableHeaders('dcr-table', ['Vault', 'Policy', 'Workload', 'Tipo', '']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'defender') {
            setSummaryLabels('Piani Standard:', 'Secure Score (%):');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Defender Plans');
            setTabText('workspaces', 'Raccomandazioni');
            setTabText('recommendations', 'Analisi');
            setPaneTitle('overview', "Stato Defender for Cloud");
            setPaneTitle('virtual-machines', 'Defender Plans');
            setPaneTitle('workspaces', 'Top Raccomandazioni');
            setPaneTitle('recommendations', 'Analisi e Raccomandazioni');
            setOverviewLabels(['Secure Score (%)', 'Piani Standard', 'High Recs', 'Security Contacts']);
            setTableHeaders('vm-table', ['Piano', 'Tier', 'SubPlan', '', '']);
            setTableHeaders('workspace-table', ['Severità', 'Raccomandazione', 'Tipo risorsa', '', '']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'updates') {
            setSummaryLabels('VM Totali:', 'Maintenance Config:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'VM Azure');
            setTabText('workspaces', 'Maintenance Config');
            setTabText('dcr', 'Update Pendenti');
            setTabText('recommendations', 'Analisi');
            setPaneTitle('overview', "Stato Update Manager");
            setPaneTitle('virtual-machines', 'Macchine Virtuali Azure');
            setPaneTitle('workspaces', 'Maintenance Configurations');
            setPaneTitle('dcr', 'Update Pendenti (campione VM)');
            setPaneTitle('recommendations', 'Analisi e Raccomandazioni');
            setOverviewLabels(['VM Totali', 'Auto patching', 'Manual patching', 'Critical pending']);
            setTableHeaders('vm-table', ['Nome VM', 'Gruppo di Risorse', 'OS', 'Patch Mode', '']);
            setTableHeaders('workspace-table', ['Nome', 'Gruppo di Risorse', 'Location', 'Schedule', 'Assegnate']);
            setTableHeaders('dcr-table', ['VM', 'OS', 'Ultimo Assessment', 'Critical', 'Security']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'intune') {
            setSummaryLabels('Dispositivi Gestiti:', 'App Rilevate:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Dispositivi');
            setTabText('workspaces', 'App Rilevate');
            setTabText('dcr', 'App Deployate');
            setTabText('intune-compliance', 'Compliance');
            setTabText('intune-configuration', 'Configuration');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', 'Stato Microsoft Intune');
            setPaneTitle('virtual-machines', 'Dispositivi Gestiti');
            setPaneTitle('workspaces', 'App Rilevate sui Dispositivi');
            setPaneTitle('dcr', 'App Deployate in Intune');
            setPaneTitle('intune-compliance', 'Compliance Policies');
            setPaneTitle('intune-configuration', 'Configuration Profiles');
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Dispositivi Gestiti', 'Conformi', 'App Rilevate', 'App Deployate']);
            setTableHeaders('vm-table', ['Nome Dispositivo', 'OS', 'Versione OS', 'Conformità', 'Ultimo Sync', 'Utente']);
            setTableHeaders('workspace-table', ['Nome App', 'Versione', 'Publisher', 'N° Dispositivi', 'Piattaforma']);
            setTableHeaders('dcr-table', ['Nome App', 'Tipo', 'Publisher', 'Assegnata', 'Stato']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', true);
            setTabVisible('intune-compliance', true);
            setTabVisible('intune-configuration', true);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'defender-xdr') {
            setSummaryLabels('MDE Readiness:', 'Policy Mancanti:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Gap Analysis');
            setTabText('workspaces', 'Policy Esistenti');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', 'Stato Microsoft Defender for Endpoint');
            setPaneTitle('virtual-machines', 'Gap Analysis — Baseline MDE');
            setPaneTitle('workspaces', 'Policy Intune Esistenti');
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['Readiness Score', 'Policy Critiche Missing', 'Secure Score M365', 'Alert High']);
            setTableHeaders('vm-table', ['Policy', 'Stato', 'Priorità']);
            setTableHeaders('workspace-table', ['Nome Policy', 'Tipo']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', true);
            return;
        }

        if (solution === 'conditional-access') {
            setSummaryLabels('CA Readiness:', 'Policy Mancanti:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Gap Analysis');
            setTabText('workspaces', 'Policy Esistenti');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', 'Stato Conditional Access');
            setPaneTitle('virtual-machines', 'Gap Analysis — Baseline CA');
            setPaneTitle('workspaces', 'CA Policy nel Tenant');
            setOverviewLabels(['Readiness Score', 'Critiche Mancanti', 'Policy nel Tenant', 'Baseline Coperta']);
            setTableHeaders('vm-table', ['Policy', 'Stato', 'Priorità']);
            setTableHeaders('workspace-table', ['Nome Policy', 'Stato']);
            setTabVisible('virtual-machines', true);
            setTabVisible('workspaces', true);
            setTabVisible('dcr', false);
            setTabVisible('recommendations', false);
            return;
        }

        if (solution === 'assessment-security-m365-azure') {
            setSummaryLabels('VM Analizzate:', 'Findings:');
            setTabText('overview', 'Panoramica');
            setTabText('virtual-machines', 'Azure Inventory');
            setTabText('workspaces', 'Identity Controls');
            setTabText('dcr', 'Security KPIs');
            setTabText('recommendations', 'Report');
            setPaneTitle('overview', 'Stato Assessment Security M365 + Azure');
            setPaneTitle('virtual-machines', 'Inventario workload Azure');
            setPaneTitle('workspaces', 'Controlli Identity');
            setPaneTitle('dcr', 'KPI sicurezza');
            setPaneTitle('recommendations', 'Report');
            setOverviewLabels(['VM Totali', 'CA Enabled', 'Findings High', 'Secure Score (%)']);
            setTableHeaders('vm-table', ['Risorsa', 'RG', 'Stato', 'Dettaglio', 'Valore']);
            setTableHeaders('workspace-table', ['Controllo', 'Valore', 'Ambito', 'Area', 'Note']);
            setTableHeaders('dcr-table', ['Metrica', 'RG', 'Scope', 'Tipo', 'Valore']);
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

        // Enterprise checks + iframe appendix if available
        if (Array.isArray(data.Checks) && data.Checks.length) {
            renderNativeEnterpriseReport(data, []);
        } else if (data?.ReportHTML) {
            const details = document.createElement('details');
            details.style.cssText = 'margin-top:8px;border:1px solid #d1dce5;border-radius:8px;overflow:hidden;';
            details.innerHTML = `<summary style="padding:10px 14px;background:#f0f4f8;cursor:pointer;font-weight:600;color:#0f3d56;font-size:13px;">Report HTML completo (appendice tecnica)</summary>`;
            const iframe = document.createElement('iframe');
            iframe.style.cssText = 'width:100%;height:680px;border:none;display:block;';
            iframe.setAttribute('sandbox', 'allow-same-origin');
            iframe.srcdoc = data.ReportHTML;
            details.appendChild(iframe);
            recContainer.appendChild(details);
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

        // AVD: native checks + appendix
        const scalingPlans = Array.isArray(data.ScalingPlans) ? data.ScalingPlans : [];
        const storage = Array.isArray(data.StorageAccounts) ? data.StorageAccounts : [];
        let avdExtra = '';
        if (scalingPlans.length) {
            const spRows = scalingPlans.map(sp =>
                `<tr style="border-bottom:1px solid #e8edf0;"><td style="padding:6px 10px;">${escapeHtml(sp.Name||'N/A')}</td><td style="padding:6px 10px;">${escapeHtml(sp.ResourceGroup||'')}</td><td style="padding:6px 10px;">${escapeHtml(sp.Location||'')}</td><td style="padding:6px 10px;">${escapeHtml(sp.FriendlyName||'')}</td></tr>`
            ).join('');
            avdExtra += `<div style="padding:14px 16px;background:#f0f6ff;border:1px solid #c0d4f5;border-radius:10px;">
                <div style="font-weight:700;color:#0a3f78;margin-bottom:8px;">Scaling Plans (${scalingPlans.length})</div>
                <table style="width:100%;border-collapse:collapse;">
                    <thead><tr style="background:#e8f0fe;"><th style="padding:6px 10px;text-align:left;">Nome</th><th style="padding:6px 10px;text-align:left;">RG</th><th style="padding:6px 10px;text-align:left;">Location</th><th style="padding:6px 10px;text-align:left;">Descrizione</th></tr></thead>
                    <tbody>${spRows}</tbody>
                </table>
            </div>`;
        }
        if (storage.length) {
            const stRows = storage.map(s => {
                const fslogix = s.FSLogixReady || s.AADKerbEnabled
                    ? '<span class="status-badge status-success">FSLogix OK</span>'
                    : '<span class="status-badge">No AADKERB</span>';
                return `<tr style="border-bottom:1px solid #e8edf0;"><td style="padding:6px 10px;">${escapeHtml(s.Name||'N/A')}</td><td style="padding:6px 10px;">${escapeHtml(s.ResourceGroup||'')}</td><td style="padding:6px 10px;">${escapeHtml(s.Location||'')}</td><td style="padding:6px 10px;">${fslogix}</td></tr>`;
            }).join('');
            avdExtra += `<div style="padding:14px 16px;background:#f9fbfc;border:1px solid #cfd8dc;border-radius:10px;">
                <div style="font-weight:700;color:#0f3d56;margin-bottom:8px;">Storage Accounts (FSLogix)</div>
                <table style="width:100%;border-collapse:collapse;">
                    <thead><tr style="background:#eceff1;"><th style="padding:6px 10px;text-align:left;">Account</th><th style="padding:6px 10px;text-align:left;">RG</th><th style="padding:6px 10px;text-align:left;">Location</th><th style="padding:6px 10px;text-align:left;">FSLogix</th></tr></thead>
                    <tbody>${stRows}</tbody>
                </table>
            </div>`;
        }
        renderNativeEnterpriseReport(data, avdExtra ? [avdExtra] : []);
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

        // Tab VM Azure
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.AzureVMs) ? data.AzureVMs : [];
            if (!rows.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna VM trovata nella subscription.</td></tr>`;
            } else {
                rows.forEach(vm => {
                    const badge = vm.IsProtected
                        ? '<span class="status-badge status-success">Protetta</span>'
                        : '<span class="status-badge status-danger">Non protetta</span>';
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(vm.Name||'N/A')}</td><td>${escapeHtml(vm.ResourceGroup||'')}</td><td>${escapeHtml(vm.Location||'')}</td><td>${escapeHtml(vm.OsType||'')}</td><td>${badge}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab Recovery Services Vault
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.RecoveryServicesVaults) ? data.RecoveryServicesVaults : [];
            if (!rows.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessun Recovery Services Vault trovato.</td></tr>`;
            } else {
                rows.forEach(v => {
                    const sdBadge = v.SoftDeleteEnabled
                        ? '<span class="status-badge status-success">Sì</span>'
                        : '<span class="status-badge status-danger">No</span>';
                    const redundClass = (v.StorageType === 'GeoRedundant') ? 'status-success' : '';
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(v.Name||'N/A')}</td><td>${escapeHtml(v.ResourceGroup||'')}</td><td>${escapeHtml(v.Location||'')}</td><td><span class="status-badge ${redundClass}">${escapeHtml(v.StorageType||'N/A')}</span></td><td>${sdBadge}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab Policy Backup
        {
            const tbody = document.querySelector('#dcr-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.BackupPolicies) ? data.BackupPolicies : [];
            if (!rows.length) {
                tbody.innerHTML = `<tr><td colspan="4">Nessuna backup policy trovata.</td></tr>`;
            } else {
                rows.forEach(p => {
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(p.VaultName||'')}</td><td>${escapeHtml(p.Name||'N/A')}</td><td>${escapeHtml(p.WorkloadType||'')}</td><td>${escapeHtml(p.PolicyType||'')}</td><td></td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Extra: unprotected VMs list + auto policies
        const unprotected = (Array.isArray(data.AzureVMs) ? data.AzureVMs : []).filter(v => !v.IsProtected);
        let extraHtml = '';
        if (unprotected.length) {
            const vmRows = unprotected.slice(0, 80).map(v =>
                `<tr style="border-bottom:1px solid #f0e8e8;"><td style="padding:6px 10px;color:#b3261e;font-weight:600;">${escapeHtml(v.Name||'N/A')}</td><td style="padding:6px 10px;">${escapeHtml(v.ResourceGroup||'')}</td><td style="padding:6px 10px;">${escapeHtml(v.Location||'')}</td><td style="padding:6px 10px;">${escapeHtml(v.OsType||'')}</td></tr>`
            ).join('');
            extraHtml = `<div style="padding:14px 16px;background:#fce8e6;border:1px solid #f5c2bf;border-radius:10px;">
                <div style="font-weight:700;color:#b3261e;margin-bottom:8px;">VM non protette da backup (${unprotected.length})</div>
                <div style="max-height:220px;overflow:auto;border-radius:6px;background:white;">
                    <table style="width:100%;border-collapse:collapse;">
                        <thead><tr style="background:#fce8e6;"><th style="padding:6px 10px;text-align:left;">VM</th><th style="padding:6px 10px;text-align:left;">RG</th><th style="padding:6px 10px;text-align:left;">Location</th><th style="padding:6px 10px;text-align:left;">OS</th></tr></thead>
                        <tbody>${vmRows}</tbody>
                    </table>
                </div>
            </div>`;
        }

        const autoPols = Array.isArray(data.AutoBackupPolicies) ? data.AutoBackupPolicies : [];
        if (autoPols.length) {
            const polRows = autoPols.map(p =>
                `<tr style="border-bottom:1px solid #e8edf0;"><td style="padding:6px 10px;">${escapeHtml(p.DisplayName||p.Name||'N/A')}</td><td style="padding:6px 10px;">${escapeHtml(p.Enforcement||'')}</td></tr>`
            ).join('');
            extraHtml += `<div style="padding:14px 16px;background:#f0f6ff;border:1px solid #c0d4f5;border-radius:10px;">
                <div style="font-weight:700;color:#0a3f78;margin-bottom:8px;">Azure Policy — Auto-backup (${autoPols.length})</div>
                <table style="width:100%;border-collapse:collapse;">
                    <thead><tr style="background:#e8f0fe;"><th style="padding:6px 10px;text-align:left;">Policy</th><th style="padding:6px 10px;text-align:left;">Enforcement</th></tr></thead>
                    <tbody>${polRows}</tbody>
                </table>
            </div>`;
        }

        renderNativeEnterpriseReport(data, extraHtml ? [extraHtml] : []);
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

        // Tab Defender Plans
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const plans = Array.isArray(data.DefenderPlans) ? data.DefenderPlans : [];
            if (!plans.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessun Defender plan trovato.</td></tr>`;
            } else {
                plans.forEach(p => {
                    const tierBadge = p.PricingTier === 'Standard'
                        ? '<span class="status-badge status-success">Standard</span>'
                        : '<span class="status-badge">Free</span>';
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(p.Name||'N/A')}</td><td>${tierBadge}</td><td>${escapeHtml(p.SubPlan||'—')}</td><td></td><td></td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab Top Recommendations
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const recs = Array.isArray(data.TopRecommendations) ? data.TopRecommendations : [];
            if (!recs.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna raccomandazione trovata.</td></tr>`;
            } else {
                recs.forEach(r => {
                    const sev = String(r.Severity||'').toLowerCase();
                    const sevBadge = sev === 'high'
                        ? '<span class="status-badge status-danger">High</span>'
                        : sev === 'medium'
                            ? '<span class="status-badge status-warning">Medium</span>'
                            : `<span class="status-badge">${escapeHtml(r.Severity||'N/A')}</span>`;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${sevBadge}</td><td>${escapeHtml(r.DisplayName||r.Title||'N/A')}</td><td>${escapeHtml(r.ResourceType||'')}</td><td></td><td></td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Extra: Secure Score gauge + contacts + auto-provisioning
        const scoreColor = secureScore >= 80 ? '#107c10' : secureScore >= 50 ? '#d97706' : '#b3261e';
        const scoreBg    = secureScore >= 80 ? '#e6f4ea' : secureScore >= 50 ? '#fff8eb' : '#fce8e6';
        let extraHtml = `<div style="padding:14px 16px;background:${scoreBg};border:1px solid ${scoreColor}33;border-radius:10px;">
            <div style="font-weight:700;color:${scoreColor};font-size:14px;margin-bottom:8px;">Secure Score: ${secureScore}%</div>
            <div style="background:#e0e0e0;border-radius:6px;height:12px;overflow:hidden;">
                <div style="width:${secureScore}%;height:100%;background:${scoreColor};border-radius:6px;"></div>
            </div>
            <div style="margin-top:8px;font-size:12px;color:#555;">
                Piani Standard: <strong>${enabledPlans}</strong> / ${summary.TotalPlans||0} &nbsp;·&nbsp;
                Raccomandazioni High: <strong>${highRecs}</strong> &nbsp;·&nbsp;
                Medium: <strong>${summary.MediumSeverityRecs||0}</strong>
            </div>
        </div>`;

        const contacts_ = Array.isArray(data.SecurityContacts) ? data.SecurityContacts : [];
        if (contacts_.length) {
            const cRows = contacts_.map(c =>
                `<tr style="border-bottom:1px solid #e8edf0;"><td style="padding:6px 10px;">${escapeHtml(c.Name||'N/A')}</td><td style="padding:6px 10px;">${escapeHtml(c.Emails||'')}</td><td style="padding:6px 10px;">${escapeHtml(c.AlertNotifs||'')}</td></tr>`
            ).join('');
            extraHtml += `<div style="padding:14px 16px;background:#f0f6ff;border:1px solid #c0d4f5;border-radius:10px;">
                <div style="font-weight:700;color:#0a3f78;margin-bottom:8px;">Security Contacts (${contacts_.length})</div>
                <table style="width:100%;border-collapse:collapse;">
                    <thead><tr style="background:#e8f0fe;"><th style="padding:6px 10px;text-align:left;">Nome</th><th style="padding:6px 10px;text-align:left;">Email</th><th style="padding:6px 10px;text-align:left;">Notifiche</th></tr></thead>
                    <tbody>${cRows}</tbody>
                </table>
            </div>`;
        }

        const autoProv = Array.isArray(data.AutoProvisionings) ? data.AutoProvisionings : [];
        if (autoProv.length) {
            const apRows = autoProv.map(ap => {
                const onBadge = ap.AutoProvision === 'On'
                    ? '<span class="status-badge status-success">On</span>'
                    : '<span class="status-badge status-warning">Off</span>';
                return `<tr style="border-bottom:1px solid #e8edf0;"><td style="padding:6px 10px;">${escapeHtml(ap.Name||'N/A')}</td><td style="padding:6px 10px;">${onBadge}</td></tr>`;
            }).join('');
            extraHtml += `<div style="padding:14px 16px;background:#f9fbfc;border:1px solid #cfd8dc;border-radius:10px;">
                <div style="font-weight:700;color:#0f3d56;margin-bottom:8px;">Auto Provisioning Settings</div>
                <table style="width:100%;border-collapse:collapse;">
                    <thead><tr style="background:#eceff1;"><th style="padding:6px 10px;text-align:left;">Agent</th><th style="padding:6px 10px;text-align:left;">Stato</th></tr></thead>
                    <tbody>${apRows}</tbody>
                </table>
            </div>`;
        }

        renderNativeEnterpriseReport(data, [extraHtml]);
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

        // Tab VM Azure — patch mode
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const vms = Array.isArray(data.AzureVMs) ? data.AzureVMs : [];
            if (!vms.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna VM trovata nella subscription.</td></tr>`;
            } else {
                vms.forEach(vm => {
                    const pm = vm.PatchMode || 'NotConfigured';
                    const isAuto = pm === 'AutomaticByPlatform' || pm === 'AutomaticByOS';
                    const patchBadge = isAuto
                        ? `<span class="status-badge status-success">${escapeHtml(pm)}</span>`
                        : `<span class="status-badge status-warning">${escapeHtml(pm)}</span>`;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(vm.Name||'N/A')}</td><td>${escapeHtml(vm.ResourceGroup||'')}</td><td>${escapeHtml(vm.OsType||'')}</td><td>${patchBadge}</td><td></td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab Maintenance Configurations
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const mcs = Array.isArray(data.MaintenanceConfigurations) ? data.MaintenanceConfigurations : [];
            if (!mcs.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessuna Maintenance Configuration trovata.</td></tr>`;
            } else {
                mcs.forEach(mc => {
                    const assigned = mc.AssignedResourceCount ?? 0;
                    const assignBadge = assigned > 0
                        ? `<span class="status-badge status-success">${assigned}</span>`
                        : `<span class="status-badge status-warning">0</span>`;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(mc.Name||'N/A')}</td><td>${escapeHtml(mc.ResourceGroup||'')}</td><td>${escapeHtml(mc.Location||'')}</td><td>${escapeHtml(mc.RecurEvery||'N/A')}</td><td>${assignBadge}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Tab Update Pendenti
        {
            const tbody = document.querySelector('#dcr-table tbody');
            tbody.innerHTML = '';
            const pending = Array.isArray(data.PendingUpdates) ? data.PendingUpdates : [];
            if (!pending.length) {
                tbody.innerHTML = `<tr><td colspan="5">Nessun dato di assessment disponibile (campione VM).</td></tr>`;
            } else {
                pending.sort((a, b) => (b.CriticalUpdateCount||0) - (a.CriticalUpdateCount||0)).forEach(p => {
                    const crit = p.CriticalUpdateCount ?? 0;
                    const critBadge = crit > 0
                        ? `<span class="status-badge status-danger">${crit}</span>`
                        : `<span class="status-badge status-success">0</span>`;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(p.VMName||'N/A')}</td><td>${escapeHtml(p.OsType||'')}</td><td>${escapeHtml(p.LastAssessmentTime||'N/A')}</td><td>${critBadge}</td><td>${p.SecurityUpdateCount??0}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Extra: auto patching coverage gauge
        const autoPct = totalVMs > 0 ? Math.round((auto / totalVMs) * 100) : 0;
        const pctColor = autoPct >= 70 ? '#107c10' : autoPct >= 30 ? '#d97706' : '#b3261e';
        const pctBg    = autoPct >= 70 ? '#e6f4ea' : autoPct >= 30 ? '#fff8eb' : '#fce8e6';
        const extraHtml = `<div style="padding:14px 16px;background:${pctBg};border:1px solid ${pctColor}33;border-radius:10px;">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;">
                <span style="font-weight:700;color:${pctColor};font-size:14px;">Copertura Auto Patching</span>
                <span style="font-weight:800;font-size:20px;color:${pctColor};">${autoPct}%</span>
            </div>
            <div style="background:#e0e0e0;border-radius:6px;height:10px;overflow:hidden;">
                <div style="width:${autoPct}%;height:100%;background:${pctColor};border-radius:6px;"></div>
            </div>
            <div style="margin-top:8px;font-size:12px;color:#555;">
                Auto: <strong>${auto}</strong> &nbsp;·&nbsp; Manual/NotConfigured: <strong>${manual}</strong> &nbsp;·&nbsp;
                Maintenance Config: <strong>${maintenance}</strong> &nbsp;·&nbsp; Critical pending: <strong style="color:${critical > 0 ? '#b3261e' : '#107c10'}">${critical}</strong>
            </div>
        </div>`;

        renderNativeEnterpriseReport(data, [extraHtml]);
    }

    function classifyIntuneDevicePlatform(osName) {
        const os = String(osName || '').toLowerCase();
        if (os.includes('windows')) return 'windows';
        if (os.includes('ios') || os.includes('ipad')) return 'ios';
        if (os.includes('android')) return 'android';
        if (os.includes('mac')) return 'macos';
        return 'other';
    }

    function labelPlatform(platform) {
        const p = String(platform || '').toLowerCase();
        if (p === 'windows') return 'Windows';
        if (p === 'ios') return 'iOS/iPadOS';
        if (p === 'android') return 'Android';
        if (p === 'macos') return 'macOS';
        return 'Other';
    }

    function normalizeConfigSource(src) {
        const s = String(src || '').toLowerCase();
        if (s === 'deviceconfigurations') return 'Device Configurations';
        if (s === 'configurationpolicies') return 'Settings Catalog';
        if (s === 'grouppolicyconfigurations') return 'Admin Templates';
        return 'Other';
    }

    function buildIntuneBaselineGap(data, managedRows) {
        const existingTypes = getBaselineExistingTypes();
        const seenPlatforms = new Set(
            (managedRows || [])
                .map(d => classifyIntuneDevicePlatform(d.OS))
                .filter(p => p !== 'other' && INTUNE_BASELINE[p])
        );

        const targetPlatforms = seenPlatforms.size
            ? Array.from(seenPlatforms)
            : Object.keys(INTUNE_BASELINE);

        const missingPolicies = [];
        const presentPolicies = [];

        targetPlatforms.forEach(platform => {
            const cfg = INTUNE_BASELINE[platform];
            if (!cfg || !Array.isArray(cfg.policies)) return;
            cfg.policies.forEach(policy => {
                const present = isPolicyPresent(policy, existingTypes);
                const item = {
                    platform,
                    platformLabel: cfg.label,
                    name: policy.name,
                    category: policy.category,
                    critical: Boolean(policy.critical),
                    present
                };
                if (present) presentPolicies.push(item);
                else missingPolicies.push(item);
            });
        });

        return {
            targetPlatforms,
            missingPolicies,
            presentPolicies,
            totalPolicies: missingPolicies.length + presentPolicies.length,
            criticalMissing: missingPolicies.filter(p => p.critical).length
        };
    }

    function renderIntuneRecommendations(data, gap) {
        const recContainer = document.getElementById('recommendations-content');
        if (!recContainer) return;
        recContainer.innerHTML = '';

        const diagnostics = data?.Diagnostics || {};
        const hints = Array.isArray(diagnostics.PermissionHints) ? diagnostics.PermissionHints : [];
        const graphErrors = Array.isArray(diagnostics.GraphErrors) ? diagnostics.GraphErrors : [];
        const inventory = data?.Inventory || {};
        const checks = Array.isArray(data?.BestPracticeChecks) ? data.BestPracticeChecks : [];

        const platformSnapshot = document.createElement('div');
        platformSnapshot.style.cssText = 'margin-bottom:14px;padding:12px 14px;border:1px solid #d5e2f3;background:#f8fbff;border-radius:8px;';
        const devicesByPlatform = inventory.DevicesByPlatform || {};
        const compByPlatform = inventory.ComplianceByPlatform || {};
        const confByPlatform = inventory.ConfigProfilesByPlatform || {};
        platformSnapshot.innerHTML = `
            <div style="font-weight:700;color:#0a3f78;margin-bottom:8px;">Fotografia Tenant Intune (snapshot)</div>
            <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;font-size:12px;color:#334;">
                <div><strong>Windows</strong><br>Device: ${Number(devicesByPlatform.windows || 0)} · Compliance: ${Number(compByPlatform.windows || 0)} · Config: ${Number(confByPlatform.windows || 0)}</div>
                <div><strong>iOS/iPadOS</strong><br>Device: ${Number(devicesByPlatform.ios || 0)} · Compliance: ${Number(compByPlatform.ios || 0)} · Config: ${Number(confByPlatform.ios || 0)}</div>
                <div><strong>Android</strong><br>Device: ${Number(devicesByPlatform.android || 0)} · Compliance: ${Number(compByPlatform.android || 0)} · Config: ${Number(confByPlatform.android || 0)}</div>
                <div><strong>macOS</strong><br>Device: ${Number(devicesByPlatform.macos || 0)} · Compliance: ${Number(compByPlatform.macos || 0)} · Config: ${Number(confByPlatform.macos || 0)}</div>
            </div>
        `;
        recContainer.appendChild(platformSnapshot);

        if (hints.length || graphErrors.length) {
            const box = document.createElement('div');
            box.style.cssText = 'margin-bottom:14px;padding:12px 14px;border:1px solid #f1c27d;background:#fff8eb;border-radius:8px;';
            const topErrors = graphErrors.slice(0, 8).map(e => {
                const ep = escapeHtml(e.Endpoint || 'endpoint');
                const code = Number(e.StatusCode || 0);
                return `<li><strong>${ep}</strong>${code ? ` (HTTP ${code})` : ''}</li>`;
            }).join('');
            box.innerHTML = `
                <div style="font-weight:700;color:#8a5200;margin-bottom:6px;">Diagnostica accesso Graph</div>
                ${hints.length ? `<ul style="margin:0 0 0 18px;color:#6f4a12;">${hints.map(h => `<li>${escapeHtml(h)}</li>`).join('')}</ul>` : ''}
                ${topErrors ? `<div style="margin-top:8px;color:#6f4a12;font-size:12px;">Endpoint con errore:</div><ul style="margin:4px 0 0 18px;color:#6f4a12;font-size:12px;">${topErrors}</ul>` : ''}
            `;
            recContainer.appendChild(box);
        }

        if (checks.length) {
            const failed = checks.filter(c => !c.Passed);
            const checksBox = document.createElement('div');
            checksBox.style.cssText = 'margin-bottom:14px;padding:12px 14px;border:1px solid #cfd8dc;background:#f9fbfc;border-radius:8px;';
            const rows = checks.map(c => {
                const ok = Boolean(c.Passed);
                const sev = String(c.Severity || '').toLowerCase();
                const sevBadge = ok
                    ? '<span style="background:#e6f4ea;color:#137333;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">OK</span>'
                    : sev === 'critical'
                        ? '<span style="background:#fce8e6;color:#b3261e;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">CRITICO</span>'
                        : '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">ATTENZIONE</span>';
                const recommendation = ok ? '' : `<div style="font-size:12px;color:#666;margin-top:3px;">${escapeHtml(c.Recommendation || '')}${c.DeployHint ? ` · <strong>${escapeHtml(c.DeployHint)}</strong>` : ''}</div>`;
                return `
                    <tr>
                        <td style="padding:7px 8px;vertical-align:top;">${sevBadge}</td>
                        <td style="padding:7px 8px;vertical-align:top;">
                            <div style="font-weight:600;">${escapeHtml(c.Title || '')}</div>
                            <div style="font-size:12px;color:#4f6472;">${escapeHtml(c.Area || '')}</div>
                            ${recommendation}
                        </td>
                    </tr>
                `;
            }).join('');
            checksBox.innerHTML = `
                <div style="font-weight:700;color:#0f3d56;margin-bottom:6px;">Best Practice Microsoft (valutazione tenant)</div>
                <div style="font-size:13px;color:#37566b;margin-bottom:8px;">
                    Check totali: <strong>${checks.length}</strong> · OK: <strong>${checks.length - failed.length}</strong> · Gap: <strong>${failed.length}</strong>
                </div>
                <div style="max-height:320px;overflow:auto;border:1px solid #dde6ea;border-radius:6px;background:white;">
                    <table style="width:100%;border-collapse:collapse;">${rows}</table>
                </div>
            `;
            recContainer.appendChild(checksBox);
        }

        const gapBox = document.createElement('div');
        gapBox.style.cssText = 'margin-bottom:14px;padding:12px 14px;border:1px solid #c0d4f5;background:#f0f6ff;border-radius:8px;';
        const missingTop = (gap?.missingPolicies || []).slice(0, 16);
        const missingRows = missingTop.map(m => {
            const critical = m.critical ? '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">CRITICA</span>' : '';
            return `<li><strong>${escapeHtml(m.name)}</strong> (${escapeHtml(m.platformLabel)}${m.category ? ` · ${escapeHtml(m.category)}` : ''}) ${critical}</li>`;
        }).join('');
        gapBox.innerHTML = `
            <div style="font-weight:700;color:#0a3f78;margin-bottom:6px;">Gap Analysis Baseline Intune</div>
            <div style="font-size:13px;color:#2d4f7a;">
                Policy baseline analizzate: <strong>${gap?.totalPolicies ?? 0}</strong> ·
                Presenti: <strong>${gap?.presentPolicies?.length ?? 0}</strong> ·
                Mancanti: <strong>${gap?.missingPolicies?.length ?? 0}</strong> ·
                Critiche mancanti: <strong>${gap?.criticalMissing ?? 0}</strong>
            </div>
            ${(gap?.missingPolicies?.length ?? 0) > 0 ? `<ul style="margin:8px 0 0 18px;color:#2d4f7a;font-size:13px;">${missingRows}</ul>` : '<div style="margin-top:8px;color:#107c10;font-weight:600;">Nessuna policy baseline mancante sulle piattaforme rilevate.</div>'}
        `;
        recContainer.appendChild(gapBox);

        if (data?.ReportHTML) {
            const details = document.createElement('details');
            details.style.cssText = 'margin-top:8px;border:1px solid #d1dce5;border-radius:8px;overflow:hidden;';
            details.innerHTML = `<summary style="padding:10px 14px;background:#f0f4f8;cursor:pointer;font-weight:600;color:#0f3d56;font-size:13px;">Report HTML completo (appendice tecnica)</summary>`;
            const iframe = document.createElement('iframe');
            iframe.style.cssText = 'width:100%;height:680px;border:none;display:block;';
            iframe.setAttribute('sandbox', 'allow-same-origin');
            iframe.srcdoc = data.ReportHTML;
            details.appendChild(iframe);
            recContainer.appendChild(details);
        }
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
            const rows = Array.isArray(data.ManagedDevices) ? data.ManagedDevices : [];
            const tbody = document.querySelector('#vm-table tbody');
            const vmPane = document.getElementById('virtual-machines');
            let filterWrap = document.getElementById('intune-device-filter-wrap');
            if (vmPane && !filterWrap) {
                filterWrap = document.createElement('div');
                filterWrap.id = 'intune-device-filter-wrap';
                filterWrap.style.cssText = 'margin:8px 0 10px;display:flex;justify-content:flex-end;';
                const tableContainer = vmPane.querySelector('.resource-table-container');
                if (tableContainer) vmPane.insertBefore(filterWrap, tableContainer);
            }

            const platformCounts = { windows: 0, ios: 0, android: 0, macos: 0, other: 0 };
            rows.forEach(d => { platformCounts[classifyIntuneDevicePlatform(d.OS)]++; });
            const selectedBefore = document.getElementById('intune-device-filter')?.value || 'all';
            if (filterWrap) {
                filterWrap.innerHTML = `
                    <label for="intune-device-filter" style="font-size:12px;color:#555;display:flex;align-items:center;gap:8px;">
                        Filtra piattaforma:
                        <select id="intune-device-filter" style="padding:6px 8px;border:1px solid #cbd5e1;border-radius:6px;background:#fff;">
                            <option value="all">Tutti (${rows.length})</option>
                            <option value="windows">Windows (${platformCounts.windows})</option>
                            <option value="ios">iOS/iPadOS (${platformCounts.ios})</option>
                            <option value="android">Android (${platformCounts.android})</option>
                            <option value="macos">macOS (${platformCounts.macos})</option>
                            <option value="other">Altri (${platformCounts.other})</option>
                        </select>
                    </label>
                `;
            }

            const filterSelect = document.getElementById('intune-device-filter');
            if (filterSelect && Array.from(filterSelect.options).some(o => o.value === selectedBefore)) {
                filterSelect.value = selectedBefore;
            }

            const renderDeviceRows = () => {
                tbody.innerHTML = '';
                const platform = document.getElementById('intune-device-filter')?.value || 'all';
                const filteredRows = (platform === 'all')
                    ? rows
                    : rows.filter(d => classifyIntuneDevicePlatform(d.OS) === platform);

                if (filteredRows.length === 0) {
                    tbody.innerHTML = `<tr><td colspan="6">Nessun dispositivo trovato per il filtro selezionato.</td></tr>`;
                    return;
                }

                filteredRows.slice(0, 300).forEach(d => {
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

                if (filteredRows.length > 300) {
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td colspan="6" style="color:#666;font-size:12px;">Mostrati i primi 300 dispositivi su ${filteredRows.length} del filtro corrente.</td>`;
                    tbody.appendChild(tr);
                }
            };

            filterSelect?.addEventListener('change', renderDeviceRows);
            renderDeviceRows();
        }

        // Tab App Rilevate
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const rows = Array.isArray(data.DetectedApps) ? data.DetectedApps : [];
            if (rows.length === 0) {
                const hasErrors = Array.isArray(data?.Diagnostics?.EndpointStatus) && data.Diagnostics.EndpointStatus.some(e => String(e.Label || '').startsWith('DetectedApps') && e.Status === 'error');
                tbody.innerHTML = `<tr><td colspan="5">${hasErrors ? 'Nessuna app rilevata (endpoint Graph non accessibile con i permessi correnti).' : 'Nessuna app rilevata.'}</td></tr>`;
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
                const hasErrors = Array.isArray(data?.Diagnostics?.EndpointStatus) && data.Diagnostics.EndpointStatus.some(e => String(e.Label || '').startsWith('MobileApps') && e.Status === 'error');
                tbody.innerHTML = `<tr><td colspan="5">${hasErrors ? 'Nessuna app deployata rilevata (endpoint Graph non accessibile con i permessi correnti).' : 'Nessuna app deployata trovata.'}</td></tr>`;
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

        // Tab Compliance
        {
            const tbody = document.querySelector('#intune-compliance-table tbody');
            if (tbody) {
                tbody.innerHTML = '';
                const rows = Array.isArray(data.ExistingCompliancePolicies) ? data.ExistingCompliancePolicies : [];
                if (!rows.length) {
                    tbody.innerHTML = `<tr><td colspan="5">Nessuna compliance policy rilevata.</td></tr>`;
                } else {
                    rows.forEach(p => {
                        const assigned = p.IsAssigned
                            ? '<span class="status-badge status-success">Si</span>'
                            : '<span class="status-badge status-warning">No</span>';
                        const assessment = String(p.Assessment || 'WARN').toUpperCase();
                        const assessmentBadge = assessment === 'OK'
                            ? '<span class="status-badge status-success">OK</span>'
                            : '<span class="status-badge status-warning">Da rivedere</span>';
                        const settings = Number(p.ConfiguredSettings || 0);
                        const notes = p.Findings ? `<div style="font-size:11px;color:#666;margin-top:2px;">${escapeHtml(p.Findings)}</div>` : '';
                        const tr = document.createElement('tr');
                        tr.innerHTML = `
                            <td>${escapeHtml(p.DisplayName || 'N/A')}${notes}</td>
                            <td>${escapeHtml(labelPlatform(p.Platform))}</td>
                            <td>${assigned}</td>
                            <td>${settings}</td>
                            <td>${assessmentBadge}</td>`;
                        tbody.appendChild(tr);
                    });
                }
            }
        }

        // Tab Configuration
        {
            const tbody = document.querySelector('#intune-configuration-table tbody');
            if (tbody) {
                tbody.innerHTML = '';
                const rows = Array.isArray(data.ExistingConfigProfiles) ? data.ExistingConfigProfiles : [];
                if (!rows.length) {
                    tbody.innerHTML = `<tr><td colspan="5">Nessun configuration profile rilevato.</td></tr>`;
                } else {
                    rows.forEach(p => {
                        const assigned = p.IsAssigned
                            ? '<span class="status-badge status-success">Si</span>'
                            : '<span class="status-badge status-warning">No</span>';
                        const assessment = String(p.Assessment || 'WARN').toUpperCase();
                        const assessmentBadge = assessment === 'OK'
                            ? '<span class="status-badge status-success">OK</span>'
                            : '<span class="status-badge status-warning">Da rivedere</span>';
                        const platform = p.Platform || (Array.isArray(p.Platforms) && p.Platforms.length ? p.Platforms[0] : '');
                        const settings = Number(p.ConfiguredSettings || 0);
                        const notes = p.Findings ? `<div style="font-size:11px;color:#666;margin-top:2px;">${escapeHtml(p.Findings)}</div>` : '';
                        const tr = document.createElement('tr');
                        tr.innerHTML = `
                            <td>${escapeHtml(p.DisplayName || 'N/A')}${notes}<div style="font-size:11px;color:#888;">Setting: ${settings}</div></td>
                            <td>${escapeHtml(normalizeConfigSource(p.Source))}</td>
                            <td>${escapeHtml(labelPlatform(platform))}</td>
                            <td>${assigned}</td>
                            <td>${assessmentBadge}</td>`;
                        tbody.appendChild(tr);
                    });
                }
            }
        }

        // Baseline button in overview
        const overviewPane = document.getElementById('overview');
        const existingBaselineBtn = document.getElementById('intune-baseline-btn-overview');
        if (existingBaselineBtn) existingBaselineBtn.remove();

        const existingComp = Array.isArray(data.ExistingCompliancePolicies) ? data.ExistingCompliancePolicies.length : '?';
        const existingConf = Array.isArray(data.ExistingConfigProfiles) ? data.ExistingConfigProfiles.length : '?';
        const gap = buildIntuneBaselineGap(data, Array.isArray(data.ManagedDevices) ? data.ManagedDevices : []);
        const endpointErrors = Number(data?.Diagnostics?.EndpointErrorCount ?? 0);
        const baselineBanner = document.createElement('div');
        baselineBanner.id = 'intune-baseline-btn-overview';
        baselineBanner.style.cssText = 'margin-top:20px;padding:16px;background:linear-gradient(135deg,#f0f6ff,#e8f0fe);border:1px solid #c0d4f5;border-radius:10px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;';
        baselineBanner.innerHTML = `
            <div>
                <div style="font-weight:700;font-size:15px;color:#0078d4;margin-bottom:4px;">🛡 Baseline Sicurezza Intune</div>
                <div style="font-size:13px;color:#444;">Policy di compliance trovate: <strong>${existingComp}</strong> &nbsp;|&nbsp; Configuration profile trovati: <strong>${existingConf}</strong></div>
                <div style="font-size:13px;color:#444;margin-top:3px;">Baseline mancanti: <strong>${gap.missingPolicies.length}</strong> (${gap.criticalMissing} critiche) &nbsp;|&nbsp; Endpoint Graph in errore: <strong>${endpointErrors}</strong></div>
                <div style="font-size:12px;color:#666;margin-top:4px;">Configura le policy standard mancanti e verifica i permessi Graph se alcuni conteggi risultano a zero.</div>
            </div>
            <button id="open-intune-baseline-wizard" class="btn-primary" style="flex-shrink:0;">Configura Baseline →</button>`;
        overviewPane.appendChild(baselineBanner);

        document.getElementById('open-intune-baseline-wizard')?.addEventListener('click', () => openIntuneBaselineWizard());

        renderIntuneRecommendations(data, gap);
    }

    async function runDefenderXdrPrecheckClientSide(tenantId = '') {
        document.querySelector('.precheck-form').style.display = 'none';
        document.getElementById('precheck-loading').style.display = 'block';
        document.getElementById('precheck-results').style.display = 'none';

        try {
            const token = await getGraphToken(tenantId || getSelectedTenantId());
            const headers = { 'Authorization': `Bearer ${token}` };

            // Usa /beta per avere tutti i campi (v1.0 taglia proprietà come advancedThreatProtectionAutoPopulateOnboardingBlob)
            let allConfigs = [];
            let url = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$top=100';
            while (url) {
                const r = await fetch(url, { headers });
                if (!r.ok) break;
                const j = await r.json();
                allConfigs = allConfigs.concat(j.value || []);
                url = j['@odata.nextLink'] || null;
            }

            // Endpoint Security Intents
            let allIntents = [];
            const ir = await fetch('https://graph.microsoft.com/beta/deviceManagement/intents?$select=id,displayName,templateId', { headers });
            if (ir.ok) { allIntents = (await ir.json()).value || []; }

            // -------------------------------------------------------
            // Rilevamento funzionale: controlla tipo e settings reali
            // -------------------------------------------------------
            function detectMdeFeatures(configs, intents) {
                const found = { edr: false, av: false, tamper: false, network: false, asr: false, fileHash: false };

                for (const p of configs) {
                    const type = (p['@odata.type'] || '').toLowerCase();

                    // EDR Onboarding: il solo fatto che esista una policy di questo tipo = EDR configurato
                    // (non esiste altro motivo per creare windowsDefenderAdvancedThreatProtectionConfiguration)
                    if (type.includes('windowsdefenderadvancedthreatprotectionconfiguration')) {
                        found.edr = true;
                    }

                    // AV Next-Gen: tipo EndpointProtection con almeno una proprietà defender configurata
                    // Accetta true, stringhe non-vuote e valori non-null/notConfigured
                    if (type.includes('windows10endpointprotectionconfiguration')) {
                        const avProps = [p.defenderRequireRealTimeMonitoring, p.defenderRequireCloudProtection,
                            p.defenderRequireBehaviorMonitoring, p.defenderCloudBlockLevel,
                            p.defenderPotentiallyUnwantedAppAction, p.defenderRequireNetworkInspectionSystem];
                        if (avProps.some(v => v === true || (v && v !== 'notConfigured' && v !== 'userDefined'))) {
                            found.av = true;
                        }
                    }

                    // Custom OMA-URI: ispeziona ogni impostazione
                    if (type.includes('windows10customconfiguration') && Array.isArray(p.omaSettings)) {
                        for (const oma of p.omaSettings) {
                            const uri = (oma.omaUri || '').toLowerCase();
                            const val = oma.value ?? oma.integerValue ?? oma.stringValue ?? '';

                            if (uri.includes('tamperprotection') && (val == 5 || val === '5')) found.tamper = true;
                            if (uri.includes('enablenetworkprotection') && (val == 1 || val === '1' || val == 2 || val === '2')) found.network = true;
                            if (uri.includes('attacksurfacereductionrules')) found.asr = true;
                            if (uri.includes('enablefilehashcomputation') && (val == 1 || val === '1')) found.fileHash = true;
                        }
                    }
                }

                // Endpoint Security Intents: templateId noti per MDE
                const EDR_TEMPLATES  = ['e44c2ca3-2f9a-400a-a113-6cc88efd773d', 'a239407c-698d-4ef6-b525-8f0f50b4ecf6'];
                const ASR_TEMPLATES  = ['0e237410-1367-4844-bd7f-15fb0f08943b', 'e8c053d6-9f6e-41c9-b196-6e4fa8c9d0e4'];
                const AV_TEMPLATES   = ['4356d05c-a4ab-4a07-9ece-739f7c792910', 'windows10antivirus'];
                for (const i of intents) {
                    const tid = (i.templateId || '').toLowerCase();
                    if (EDR_TEMPLATES.includes(tid)) found.edr = true;
                    if (ASR_TEMPLATES.includes(tid)) found.asr = true;
                    if (AV_TEMPLATES.some(t => tid.includes(t))) found.av = true;
                }

                return found;
            }

            const detected = detectMdeFeatures(allConfigs, allIntents);

            // Gap analysis basata su funzionalità rilevate
            const gapAnalysis = [
                { Id: 'edr-onboarding',     Name: 'EDR Onboarding (Intune connector)',       Critical: true,  Present: detected.edr },
                { Id: 'av-nextgen',         Name: 'AV Next-Gen Protection',                  Critical: true,  Present: detected.av },
                { Id: 'tamper-protection',  Name: 'Tamper Protection',                        Critical: true,  Present: detected.tamper },
                { Id: 'network-protection', Name: 'Network Protection (Block mode)',          Critical: true,  Present: detected.network },
                { Id: 'asr-rules',          Name: 'ASR Rules (Attack Surface Reduction)',     Critical: false, Present: detected.asr },
                { Id: 'file-hash',          Name: 'File Hash Computation',                   Critical: false, Present: detected.fileHash }
            ].map(g => ({ ...g, Status: g.Present ? 'OK' : 'MISSING' }));

            // Secure Score (opzionale, può mancare il permesso)
            let secureScore = { Available: false, Percentage: 0 };
            try {
                const ssr = await fetch('https://graph.microsoft.com/v1.0/security/secureScores?$top=1&$select=currentScore,maxScore', { headers });
                if (ssr.ok) {
                    const ssj = await ssr.json();
                    if (ssj.value?.length > 0) {
                        const ss = ssj.value[0];
                        const pct = ss.maxScore > 0 ? Math.round(ss.currentScore / ss.maxScore * 100) : 0;
                        secureScore = { Available: true, Current: ss.currentScore, Max: ss.maxScore, Percentage: pct };
                    }
                }
            } catch {}

            // Alerts (opzionale)
            let alerts = { Available: false, Total: 0, High: 0 };
            try {
                const alr = await fetch("https://graph.microsoft.com/v1.0/security/alerts_v2?$top=100&$filter=status ne 'resolved'&$select=id,severity", { headers });
                if (alr.ok) {
                    const alj = await alr.json();
                    const list = alj.value || [];
                    alerts = { Available: true, Total: list.length, High: list.filter(a => a.severity === 'high').length };
                }
            } catch {}

            const critMissing = gapAnalysis.filter(g => g.Critical && !g.Present).length;
            const critTotal   = gapAnalysis.filter(g => g.Critical).length;
            const readiness   = critTotal > 0 ? Math.round((critTotal - critMissing) / critTotal * 100) : 100;

            const data = {
                Summary: {
                    ReadinessScore: readiness,
                    CriticalMissing: critMissing,
                    TotalExistingPolicies: allConfigs.length + allIntents.length,
                    SecureScorePercent: secureScore.Percentage,
                    AlertsHigh: alerts.High,
                    AlertsTotal: alerts.Total
                },
                PolicyGapAnalysis: gapAnalysis,
                ExistingMdePolicies: allConfigs.map(p => ({ Id: p.id, DisplayName: p.displayName, OdataType: '', LastModified: p.lastModifiedDateTime || '' })),
                SecureScore: secureScore,
                Alerts: alerts
            };

            window.lastPrecheckResponse = data;
            document.getElementById('precheck-loading').style.display = 'none';
            applyPrecheckUiForSolution('defender-xdr');
            renderDefenderXdrPrecheck(data);
            document.getElementById('precheck-results').style.display = 'block';
            showTab('overview');

        } catch (err) {
            document.getElementById('precheck-loading').style.display = 'none';
            document.querySelector('.precheck-form').style.display = 'block';
            alert(`❌ Errore precheck Defender XDR:\n\n${err.message}`);
        }
    }

    function renderDefenderXdrPrecheck(data) {
        const summary = data?.Summary || {};
        const readiness       = summary.ReadinessScore ?? 0;
        const critMissing     = summary.CriticalMissing ?? 0;
        const ssPercent       = summary.SecureScorePercent ?? 0;
        const alertsHigh      = summary.AlertsHigh ?? 0;

        document.getElementById('overview-vm-total').textContent    = readiness + '%';
        document.getElementById('overview-vm-monitored').textContent = critMissing;
        document.getElementById('overview-workspaces').textContent   = data?.SecureScore?.Available ? ssPercent + '%' : 'N/D';
        document.getElementById('overview-dcr').textContent          = data?.Alerts?.Available ? alertsHigh : 'N/D';
        document.getElementById('vm-count').textContent              = readiness + '%';
        document.getElementById('workspace-count').textContent       = summary.TotalExistingPolicies ?? 0;

        const rdColor = readiness >= 80 ? '#107c10' : readiness >= 50 ? '#ff8c00' : '#d13438';
        if (readiness >= 80)      setOverallStatus(`Readiness ${readiness}% — Baseline MDE OK`, 'success');
        else if (readiness >= 50) setOverallStatus(`Readiness ${readiness}% — Policy critiche mancanti`, 'warning');
        else                      setOverallStatus(`Readiness ${readiness}% — Baseline MDE incompleta`, 'danger');

        // Gap analysis tab
        {
            const tbody = document.querySelector('#vm-table tbody');
            tbody.innerHTML = '';
            const gaps = Array.isArray(data.PolicyGapAnalysis) ? data.PolicyGapAnalysis : [];

            // Mappa descrizioni e why dal catalogo MDE_BASELINE (per gap analysis ID)
            const GAP_INFO = {
                'edr-onboarding':     { desc: 'Onboarding automatico degli endpoint a Defender for Endpoint tramite connettore Intune.', why: 'Senza onboarding gli endpoint non inviano telemetria a security.microsoft.com: niente alert, niente risposta agli incidenti, niente threat hunting. È il prerequisito di tutto.' },
                'av-nextgen':         { desc: 'Protezione AV real-time con cloud block level High, behavior monitoring e blocco PUA.', why: 'Cloud protection High aumenta la detection rate al 99%+. Behavior monitoring rileva malware zero-day che le signature non vedono. Senza questa policy Defender AV opera con impostazioni default variabili per device.' },
                'tamper-protection':  { desc: 'Impedisce che malware o utenti locali disabilitino Defender AV/EDR (valore 5 = gestito da Intune).', why: 'Uno dei primi obiettivi di un attaccante è disabilitare l\'antivirus. Tamper Protection blocca qualsiasi tentativo — incluse operazioni PowerShell e modifiche al registro — anche con privilegi di amministratore locale.' },
                'network-protection': { desc: 'Blocca in tempo reale connessioni a C2, phishing, exploit kit e IOC caricati da MDE (Block mode).', why: 'Estende SmartScreen a tutto il traffico di rete, non solo al browser. Senza questo, un malware può comunicare liberamente con il suo server di comando anche se il file è stato rilevato.' },
                'asr-rules':          { desc: 'Regole Attack Surface Reduction — riducono i vettori di attacco tipici del malware (Office, script, LSASS, USB).', why: 'Bloccano comportamenti usati quasi esclusivamente da malware: dump delle credenziali LSASS, script offuscati, Office che crea processi child, persistenza via WMI. Partire in Audit permette di valutare l\'impatto prima del Block.' },
                'file-hash':          { desc: 'Calcolo automatico degli hash SHA-256 di tutti i file eseguiti sull\'endpoint.', why: 'Necessario per le regole custom IOC in MDE (blocca file con hash X) e per Advanced Hunting (tabella DeviceFileEvents). Senza hash non puoi correlare file sospetti con intelligence esterna.' }
            };

            if (!gaps.length) {
                tbody.innerHTML = '<tr><td colspan="3">Nessun dato gap analysis.</td></tr>';
            } else {
                gaps.forEach(g => {
                    const statusClass = g.Present ? 'status-success' : 'status-danger';
                    const statusLabel = g.Present ? '✓ PRESENTE' : '✗ MANCANTE';
                    const priorita    = g.Critical ? '<span style="background:#fff3cd;color:#856404;border-radius:3px;padding:1px 6px;font-size:11px;font-weight:700;">CRITICA</span>' : '<span style="color:#888;font-size:12px;">Consigliata</span>';
                    const info        = GAP_INFO[g.Id] || {};
                    const detId       = `gap-why-${g.Id}`;
                    const tr = document.createElement('tr');
                    tr.innerHTML = `
                        <td style="padding:10px 8px;">
                            <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:3px;">
                                <strong style="font-size:13px;">${escapeHtml(g.Name)}</strong>
                                ${priorita}
                            </div>
                            ${info.desc ? `<div style="font-size:12px;color:#555;margin-bottom:4px;">${escapeHtml(info.desc)}</div>` : ''}
                            ${info.why ? `
                            <button onclick="var el=document.getElementById('${detId}');el.style.display=el.style.display==='none'?'block':'none'"
                                style="background:none;border:none;color:#0078d4;font-size:11px;cursor:pointer;padding:0;text-decoration:underline;">
                                Perché è importante?
                            </button>
                            <div id="${detId}" style="display:none;margin-top:6px;padding:8px 10px;background:#f0f6ff;border-left:3px solid #0078d4;border-radius:0 4px 4px 0;font-size:12px;color:#333;line-height:1.5;">
                                ${escapeHtml(info.why)}
                            </div>` : ''}
                        </td>
                        <td style="white-space:nowrap;padding:10px 8px;"><span class="status-badge ${statusClass}">${statusLabel}</span></td>
                        <td style="white-space:nowrap;padding:10px 8px;">${priorita}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Existing policies tab
        {
            const tbody = document.querySelector('#workspace-table tbody');
            tbody.innerHTML = '';
            const policies = Array.isArray(data.ExistingMdePolicies) ? data.ExistingMdePolicies : [];
            if (!policies.length) {
                tbody.innerHTML = '<tr><td colspan="2">Nessuna policy MDE Intune trovata.</td></tr>';
            } else {
                policies.slice(0, 200).forEach(p => {
                    const type = (p.OdataType || '').replace('#microsoft.graph.', '');
                    const tr = document.createElement('tr');
                    tr.innerHTML = `<td>${escapeHtml(p.DisplayName || 'N/A')}</td><td>${escapeHtml(type)}</td>`;
                    tbody.appendChild(tr);
                });
            }
        }

        // Baseline button in overview
        const overviewPane = document.getElementById('overview');
        document.getElementById('mde-baseline-btn-overview')?.remove();
        const critMissingCount = Array.isArray(data.PolicyGapAnalysis) ? data.PolicyGapAnalysis.filter(g => g.Critical && !g.Present).length : 0;
        const banner = document.createElement('div');
        banner.id = 'mde-baseline-btn-overview';
        banner.style.cssText = 'margin-top:20px;padding:16px;background:linear-gradient(135deg,#0a2342,#1a4a8a);color:white;border-radius:10px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;';
        banner.innerHTML = `
            <div>
                <div style="font-weight:700;font-size:15px;margin-bottom:4px;">🛡 Baseline Microsoft Defender XDR</div>
                <div style="font-size:13px;opacity:.9;">Policy critiche mancanti: <strong>${critMissingCount}</strong> &nbsp;|&nbsp; Policy totali Intune: <strong>${summary.TotalExistingPolicies ?? 0}</strong></div>
                <div style="font-size:12px;opacity:.75;margin-top:4px;">Deploya le policy MDE standard (Jeffrey Appel baseline) nel tenant.</div>
            </div>
            <button id="open-mde-baseline-wizard" style="background:white;color:#0a2342;border:none;padding:10px 20px;border-radius:8px;font-weight:700;font-size:13px;cursor:pointer;flex-shrink:0;">Configura Baseline MDE →</button>`;
        overviewPane.appendChild(banner);
        document.getElementById('open-mde-baseline-wizard')?.addEventListener('click', () => openMdeBaselineWizard());

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

        if (currentSolution === 'defender-xdr') {
            renderDefenderXdrPrecheck(data);
            return;
        }

        if (currentSolution === 'conditional-access') {
            renderCaPrecheck(data);
            return;
        }

        if (currentSolution === 'assessment-security-m365-azure') {
            renderAssessmentSecurityPrecheck(data);
            return;
        }

        if (currentSolution === 'assessment-365') {
            renderAssessment365Precheck(data);
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
        if (currentSolution === 'defender-xdr') { openMdeBaselineWizard(); return; }
        if (currentSolution === 'intune') { openIntuneBaselineWizard(); return; }
        if (currentSolution === 'conditional-access') { openCaBaselineWizard(); return; }
        showDeployModal(currentSolution);
    });

    // Copia comando PowerShell
    document.getElementById('copy-precheck-command')?.addEventListener('click', function() {
        const input = document.getElementById('subscription-id').value.trim();
        const tenantId = getSelectedTenantId();
        const subs = parseSubscriptionIds(input);
        const subscriptionId = subs[0] || '';
        if (!subscriptionId) { alert('⚠️ Inserisci prima un SubscriptionId valido'); return; }
        const solConfig = SOLUTIONS[currentSolution] || SOLUTIONS['azure-monitor'];
        const commandBase = solConfig.psCommand.replace('YOUR-SUB-ID', subscriptionId);
        const command = tenantId ? `${commandBase} -TenantId "${tenantId}"` : commandBase;
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

    // Expose selected UI helpers for global feature modules (e.g. Conditional Access)
    window.applyPrecheckUiForSolution = applyPrecheckUiForSolution;
    window.showTab = showTab;
    window.setOverallStatus = setOverallStatus;
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
    const tenantInput = document.getElementById('tenant-id');
    if (tenantInput && !tenantInput.value.trim()) tenantInput.value = getSavedTenantId();

    // Show Precheck 2.0 toggle only for Azure Monitor
    const toggleRow = document.getElementById('monitor-precheck2-toggle');
    if (toggleRow) toggleRow.style.display = (solution === 'azure-monitor') ? 'block' : 'none';
    const cb = document.getElementById('use-precheck2');
    if (cb) cb.checked = false;

    // Intune è tenant-wide: nascondi il campo subscription
    const subGroup = document.getElementById('subscription-id')?.closest('.form-group');
    const tenantGroup = document.getElementById('tenant-id')?.closest('.form-group');
    const rgGroup = document.getElementById('resource-group')?.closest('.form-group');
    if (isTenantWideSolution(solution)) {
        if (subGroup) subGroup.style.display = 'none';
        if (tenantGroup) tenantGroup.style.display = '';
        if (rgGroup) rgGroup.style.display = 'none';
        let note = document.getElementById('intune-tenant-note');
        if (!note) {
            note = document.createElement('div');
            note.id = 'intune-tenant-note';
            note.style.cssText = 'padding:12px 14px;background:#f0f6ff;border:1px solid #c0d4f5;border-radius:8px;margin-bottom:14px;font-size:13px;color:#0078d4;';
            document.querySelector('.precheck-form').insertBefore(note, document.getElementById('run-precheck'));
        }
        const label = solution === 'defender-xdr'
            ? 'Defender XDR'
            : solution === 'conditional-access'
                ? 'Conditional Access'
                : solution === 'assessment-365'
                    ? 'Assessment 365'
                    : 'Intune';
        note.innerHTML = `<strong>ℹ️ ${label} è tenant-wide</strong> — non richiede una subscription Azure. Seleziona il Tenant ID corretto per evitare mismatch directory.`;
        note.style.display = '';
    } else {
        if (subGroup) subGroup.style.display = '';
        if (tenantGroup) tenantGroup.style.display = '';
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

    if (solConfig.portalUrl && solConfig.portalUrl !== '#') {
        portalLink.href = solConfig.portalUrl;
        portalOption.style.display = 'flex';
    } else {
        portalOption.style.display = 'none';
    }

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

// Global helper for assessment renderers defined in the outer scope.
function renderReportHtmlInRecommendationsGlobal(data) {
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

function renderAssessmentSecurityPrecheck(data) {
    const summary = data?.Summary || {};

    document.getElementById('overview-vm-total').textContent = summary.TotalVMs ?? 0;
    document.getElementById('overview-vm-monitored').textContent = summary.EnabledCaPolicies ?? 0;
    document.getElementById('overview-workspaces').textContent = summary.HighFindings ?? 0;
    document.getElementById('overview-dcr').textContent = summary.SecureScorePercent ?? 'N/A';
    document.getElementById('vm-count').textContent = summary.TotalVMs ?? 0;
    document.getElementById('workspace-count').textContent = summary.TotalFindings ?? 0;

    const crit = Number(summary.CriticalFindings || 0);
    const high = Number(summary.HighFindings || 0);
    if (crit > 0) setOverallStatus('Rischio elevato: findings critici presenti', 'error');
    else if (high > 0) setOverallStatus('Rischio medio-alto: findings high presenti', 'warning');
    else setOverallStatus('Assessment completato: nessun finding critico/high', 'success');

    const vmTbody = document.querySelector('#vm-table tbody');
    if (vmTbody) {
        vmTbody.innerHTML = `
            <tr><td>Virtual Machines</td><td>N/A</td><td>Inventario</td><td>N/A</td><td>${summary.TotalVMs ?? 0}</td></tr>
            <tr><td>Storage Accounts</td><td>N/A</td><td>Inventario</td><td>N/A</td><td>${summary.TotalStorageAccounts ?? 0}</td></tr>
            <tr><td>Key Vaults</td><td>N/A</td><td>Inventario</td><td>N/A</td><td>${summary.TotalKeyVaults ?? 0}</td></tr>`;
    }

    const wsTbody = document.querySelector('#workspace-table tbody');
    if (wsTbody) {
        wsTbody.innerHTML = `
            <tr><td>Conditional Access (Enabled)</td><td>${summary.EnabledCaPolicies ?? 0}</td><td>Tenant</td><td>Identity</td><td>N/A</td></tr>
            <tr><td>Conditional Access (Report-Only)</td><td>${summary.ReportOnlyCaPolicies ?? 0}</td><td>Tenant</td><td>Identity</td><td>N/A</td></tr>
            <tr><td>Security Defaults</td><td>${summary.SecurityDefaultsEnabled ? 'Enabled' : 'Disabled'}</td><td>Tenant</td><td>Identity</td><td>N/A</td></tr>`;
    }

    const dcrTbody = document.querySelector('#dcr-table tbody');
    if (dcrTbody) {
        dcrTbody.innerHTML = `
            <tr><td>Defender Secure Score</td><td>N/A</td><td>N/A</td><td>Percentage</td><td>${summary.SecureScorePercent ?? 'N/A'}</td></tr>
            <tr><td>Findings Critical</td><td>N/A</td><td>N/A</td><td>Count</td><td>${summary.CriticalFindings ?? 0}</td></tr>
            <tr><td>Findings High</td><td>N/A</td><td>N/A</td><td>Count</td><td>${summary.HighFindings ?? 0}</td></tr>`;
    }

    renderReportHtmlInRecommendationsGlobal(data);
}

function renderAssessment365Precheck(data) {
    const summary = data?.Summary || {};
    const findings = Array.isArray(data?.Findings) ? data.Findings : [];

    document.getElementById('overview-vm-total').textContent = summary.TotalChecks ?? findings.length ?? 0;
    document.getElementById('overview-vm-monitored').textContent = summary.CriticalFindings ?? 0;
    document.getElementById('overview-workspaces').textContent = summary.HighFindings ?? 0;
    document.getElementById('overview-dcr').textContent = summary.PassRate ?? 'N/A';
    document.getElementById('vm-count').textContent = summary.TotalChecks ?? findings.length ?? 0;
    document.getElementById('workspace-count').textContent = summary.FailedChecks ?? findings.length ?? 0;

    const crit = Number(summary.CriticalFindings || 0);
    const high = Number(summary.HighFindings || 0);
    if (crit > 0) setOverallStatus('Assessment completato: criticità elevate presenti', 'error');
    else if (high > 0) setOverallStatus('Assessment completato: presenti finding High', 'warning');
    else setOverallStatus('Assessment completato: nessun finding critico/high', 'success');

    const vmTbody = document.querySelector('#vm-table tbody');
    if (vmTbody) {
        vmTbody.innerHTML = '';
        findings.slice(0, 50).forEach(f => {
            const sev = String(f.Severity || 'Info');
            const sevCls = sev.toLowerCase() === 'critical' ? 'status-danger' : sev.toLowerCase() === 'high' ? 'status-warning' : 'status-success';
            const tr = document.createElement('tr');
            tr.innerHTML = `
                <td>${escapeHtml(f.CheckId || f.Id || 'N/A')}</td>
                <td>${escapeHtml(f.Area || 'M365')}</td>
                <td><span class="status-badge ${sevCls}">${escapeHtml(sev)}</span></td>
                <td>${escapeHtml(f.Title || 'N/A')}</td>
                <td>${escapeHtml(f.Remediation || '')}</td>`;
            vmTbody.appendChild(tr);
        });
        if (!findings.length) vmTbody.innerHTML = '<tr><td colspan="5">Nessun finding disponibile.</td></tr>';
    }

    const wsTbody = document.querySelector('#workspace-table tbody');
    if (wsTbody) {
        wsTbody.innerHTML = `
            <tr><td>Tenant</td><td>${escapeHtml(data?.Tenant?.DisplayName || 'N/A')}</td><td>Directory</td><td>M365</td><td>${escapeHtml(data?.Tenant?.TenantId || '')}</td></tr>
            <tr><td>Total Checks</td><td>${summary.TotalChecks ?? 0}</td><td>Assessment</td><td>Execution</td><td>N/A</td></tr>
            <tr><td>Failed Checks</td><td>${summary.FailedChecks ?? 0}</td><td>Assessment</td><td>Execution</td><td>N/A</td></tr>`;
    }

    const dcrTbody = document.querySelector('#dcr-table tbody');
    if (dcrTbody) {
        dcrTbody.innerHTML = `
            <tr><td>Critical Findings</td><td>N/A</td><td>M365</td><td>Count</td><td>${summary.CriticalFindings ?? 0}</td></tr>
            <tr><td>High Findings</td><td>N/A</td><td>M365</td><td>Count</td><td>${summary.HighFindings ?? 0}</td></tr>
            <tr><td>Pass Rate</td><td>N/A</td><td>M365</td><td>Percentage</td><td>${summary.PassRate ?? 'N/A'}</td></tr>`;
    }

    renderReportHtmlInRecommendationsGlobal(data);
}

// ============================================================
// CONDITIONAL ACCESS — PRECHECK CLIENT-SIDE
// ============================================================
async function runCaPrecheckClientSide(tenantId = '') {
    document.querySelector('.precheck-form').style.display = 'none';
    document.getElementById('precheck-loading').style.display = 'block';
    document.getElementById('precheck-results').style.display = 'none';
    try {
        const token = await getCaToken(false, tenantId || getSelectedTenantId());
        const headers = { 'Authorization': `Bearer ${token}` };

        let allPolicies = [];
        let url = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$top=200';
        while (url) {
            const r = await fetch(url, { headers });
            if (!r.ok) { const e = await r.json(); throw new Error(e?.error?.message || `HTTP ${r.status}`); }
            const j = await r.json();
            allPolicies = allPolicies.concat(j.value || []);
            url = j['@odata.nextLink'] || null;
        }

        const gapAnalysis = CA_BASELINE.map(c => {
            const present = c.detectFn(allPolicies);
            return { Id: c.id, Code: c.code, Name: c.name, Category: c.category, Critical: c.critical, Present: present, Status: present ? 'OK' : 'MISSING' };
        });

        const critMissing = gapAnalysis.filter(g => g.Critical && !g.Present).length;
        const critTotal   = gapAnalysis.filter(g => g.Critical).length;
        const readiness   = critTotal > 0 ? Math.round((critTotal - critMissing) / critTotal * 100) : 100;

        const data = {
            Summary: { ReadinessScore: readiness, CriticalMissing: critMissing, TotalPolicies: allPolicies.length, TotalBaseline: CA_BASELINE.length },
            PolicyGapAnalysis: gapAnalysis,
            ExistingCaPolicies: allPolicies.map(p => ({ Id: p.id, DisplayName: p.displayName, State: p.state }))
        };
        window.lastPrecheckResponse = data;
        document.getElementById('precheck-loading').style.display = 'none';
        window.applyPrecheckUiForSolution?.('conditional-access');
        renderCaPrecheck(data);
        document.getElementById('precheck-results').style.display = 'block';
        window.showTab?.('overview');
    } catch (err) {
        document.getElementById('precheck-loading').style.display = 'none';
        document.querySelector('.precheck-form').style.display = 'block';
        alert(`❌ Errore precheck Conditional Access:\n\n${err.message}`);
    }
}

function renderCaPrecheck(data) {
    const summary = data?.Summary || {};
    const readiness   = summary.ReadinessScore ?? 0;
    const critMissing = summary.CriticalMissing ?? 0;
    const total       = summary.TotalPolicies ?? 0;
    const baseline    = summary.TotalBaseline ?? CA_BASELINE.length;

    document.getElementById('overview-vm-total').textContent    = readiness + '%';
    document.getElementById('overview-vm-monitored').textContent = critMissing;
    document.getElementById('overview-workspaces').textContent   = total;
    document.getElementById('overview-dcr').textContent          = baseline - (data?.PolicyGapAnalysis?.filter(g => !g.Present).length ?? 0);
    document.getElementById('vm-count').textContent              = readiness + '%';
    document.getElementById('workspace-count').textContent       = total;

    if (readiness >= 80)      window.setOverallStatus?.(`Readiness ${readiness}% — Baseline CA OK`, 'success');
    else if (readiness >= 50) window.setOverallStatus?.(`Readiness ${readiness}% — Policy critiche mancanti`, 'warning');
    else                      window.setOverallStatus?.(`Readiness ${readiness}% — Baseline CA incompleta`, 'danger');

    // Tab Gap Analysis
    {
        const tbody = document.querySelector('#vm-table tbody');
        tbody.innerHTML = '';
        const gaps = Array.isArray(data.PolicyGapAnalysis) ? data.PolicyGapAnalysis : [];
        const categories = [...new Set(gaps.map(g => g.Category))];
        categories.forEach(cat => {
            const tr = document.createElement('tr');
            tr.innerHTML = `<td colspan="3" style="background:#f0f4ff;font-weight:700;font-size:12px;color:#0a2342;padding:6px 10px;">${cat.toUpperCase()}</td>`;
            tbody.appendChild(tr);
            gaps.filter(g => g.Category === cat).forEach(g => {
                const sc = g.Present ? 'status-success' : 'status-danger';
                const tr2 = document.createElement('tr');
                tr2.innerHTML = `<td><span style="font-size:11px;color:#888;margin-right:6px;">${g.Code}</span>${escapeHtml(g.Name)}</td>
                    <td><span class="status-badge ${sc}">${g.Present ? 'PRESENTE' : 'MANCANTE'}</span></td>
                    <td>${g.Critical ? '<span style="color:#856404;font-weight:700;font-size:11px;">CRITICA</span>' : ''}</td>`;
                tbody.appendChild(tr2);
            });
        });
    }

    // Tab Policy esistenti
    {
        const tbody = document.querySelector('#workspace-table tbody');
        tbody.innerHTML = '';
        const policies = Array.isArray(data.ExistingCaPolicies) ? data.ExistingCaPolicies : [];
        if (!policies.length) { tbody.innerHTML = '<tr><td colspan="2">Nessuna CA policy trovata nel tenant.</td></tr>'; return; }
        policies.forEach(p => {
            const stateColor = p.State === 'enabled' ? '#107c10' : p.State === 'enabledForReportingButNotEnforced' ? '#ff8c00' : '#888';
            const stateLabel = p.State === 'enabled' ? 'ATTIVA' : p.State === 'enabledForReportingButNotEnforced' ? 'REPORT-ONLY' : 'DISABILITATA';
            const tr = document.createElement('tr');
            tr.innerHTML = `<td>${escapeHtml(p.DisplayName || 'N/A')}</td><td><span style="background:${stateColor};color:white;border-radius:4px;padding:1px 8px;font-size:10px;font-weight:700;">${stateLabel}</span></td>`;
            tbody.appendChild(tr);
        });
    }

    // Banner baseline
    const overviewPane = document.getElementById('overview');
    document.getElementById('ca-baseline-btn-overview')?.remove();
    const missing = Array.isArray(data.PolicyGapAnalysis) ? data.PolicyGapAnalysis.filter(g => !g.Present).length : 0;
    const banner = document.createElement('div');
    banner.id = 'ca-baseline-btn-overview';
    banner.style.cssText = 'margin-top:20px;padding:16px;background:linear-gradient(135deg,#1a1a2e,#16213e);color:white;border-radius:10px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;';
    banner.innerHTML = `
        <div>
            <div style="font-weight:700;font-size:15px;margin-bottom:4px;">🔐 Conditional Access Baseline</div>
            <div style="font-size:13px;opacity:.9;">Policy critiche mancanti: <strong>${critMissing}</strong> &nbsp;|&nbsp; Policy totali nel tenant: <strong>${total}</strong> &nbsp;|&nbsp; Mancanti: <strong>${missing}</strong></div>
            <div style="font-size:12px;opacity:.7;margin-top:4px;">Tutte le policy vengono deployate in Report-Only — zero impatto sulla produzione.</div>
        </div>
        <button id="open-ca-baseline-wizard" style="background:white;color:#1a1a2e;border:none;padding:10px 20px;border-radius:8px;font-weight:700;font-size:13px;cursor:pointer;flex-shrink:0;">Configura Baseline CA →</button>`;
    overviewPane.appendChild(banner);
    document.getElementById('open-ca-baseline-wizard')?.addEventListener('click', () => openCaBaselineWizard());
}

function openCaBaselineWizard() {
    const modal = document.getElementById('ca-baseline-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    renderCaPolicyList();
}

function renderCaPolicyList() {
    const data = window.lastPrecheckResponse || {};
    const gapMap = {};
    if (Array.isArray(data.PolicyGapAnalysis)) data.PolicyGapAnalysis.forEach(g => { gapMap[g.Id] = g.Present; });

    const container = document.getElementById('ca-policy-list');
    if (!container) return;
    container.innerHTML = '';

    const catColors = { 'Global': '#0078d4', 'Admins': '#d13438', 'Internals': '#107c10', 'Guest': '#6f42c1' };
    let lastCat = '';
    CA_BASELINE.forEach(policy => {
        if (policy.category !== lastCat) {
            lastCat = policy.category;
            const hdr = document.createElement('div');
            hdr.style.cssText = `padding:8px 14px;background:${catColors[policy.category] || '#333'};color:white;font-size:12px;font-weight:700;letter-spacing:.5px;`;
            hdr.textContent = policy.category.toUpperCase();
            container.appendChild(hdr);
        }
        const present = gapMap[policy.id] === true;
        const detailsId = `ca-why-${policy.id}`;
        const row = document.createElement('div');
        row.style.cssText = 'display:flex;align-items:flex-start;gap:12px;padding:10px 14px;border-bottom:1px solid #f0f0f0;';
        row.innerHTML = `
            <input type="checkbox" class="ca-policy-check" data-id="${policy.id}" ${present ? 'disabled' : ''} style="width:16px;height:16px;flex-shrink:0;margin-top:3px;">
            <div style="flex:1;min-width:0;">
                <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
                    <span style="font-size:11px;font-weight:700;color:${catColors[policy.category]||'#333'};background:${catColors[policy.category]||'#333'}18;border-radius:3px;padding:1px 5px;">${policy.code}</span>
                    <span style="font-weight:600;font-size:13px;">${escapeHtml(policy.name)}</span>
                    ${policy.critical ? '<span style="background:#fff3cd;color:#856404;border-radius:4px;padding:1px 6px;font-size:10px;font-weight:700;">CRITICA</span>' : ''}
                    <span style="flex-shrink:0;background:${present ? '#107c10' : '#d13438'};color:white;border-radius:4px;padding:1px 8px;font-size:10px;font-weight:700;">${present ? 'PRESENTE' : 'MANCANTE'}</span>
                </div>
                <div style="font-size:12px;color:#555;margin-top:3px;">${escapeHtml(policy.description)}</div>
                <button onclick="document.getElementById('${detailsId}').style.display=document.getElementById('${detailsId}').style.display==='none'?'block':'none'"
                    style="background:none;border:none;color:#0078d4;font-size:11px;cursor:pointer;padding:3px 0;text-decoration:underline;">
                    Perché è importante?
                </button>
                <div id="${detailsId}" style="display:none;margin-top:6px;padding:10px 12px;background:#f0f6ff;border-left:3px solid #0078d4;border-radius:0 6px 6px 0;font-size:12px;color:#333;line-height:1.5;">
                    ${escapeHtml(policy.why)}
                </div>
            </div>`;
        container.appendChild(row);
    });

    container.querySelectorAll('.ca-policy-check:not([disabled])').forEach(cb => {
        const p = CA_BASELINE.find(x => x.id === cb.dataset.id);
        cb.checked = p?.critical ?? false;
    });
    updateCaDeployCount();
    container.addEventListener('change', updateCaDeployCount);
}

function updateCaDeployCount() {
    const checked = document.querySelectorAll('.ca-policy-check:checked:not([disabled])').length;
    const el = document.getElementById('ca-selected-count');
    const btn = document.getElementById('ca-step1-deploy');
    if (el) el.textContent = `${checked} policy selezionate`;
    if (btn) btn.disabled = checked === 0;
}

async function runCaBaselineDeploy() {
    document.getElementById('ca-step-1').style.display = 'none';
    document.getElementById('ca-step-2').style.display = '';

    const logEl = document.getElementById('ca-deploy-log');
    const summaryEl = document.getElementById('ca-deploy-summary');
    const closeBtn = document.getElementById('ca-step2-close');
    logEl.innerHTML = '';

    function log(msg, color) {
        const line = document.createElement('div');
        line.style.color = color || '#d4d4d4';
        line.textContent = msg;
        logEl.appendChild(line);
        logEl.scrollTop = logEl.scrollHeight;
    }

    log('Acquisizione token con permessi CA + Group...', '#569cd6');
    let token;
    try {
        token = await getCaToken(true, getSelectedTenantId());
        log('✓ Token acquisito.', '#4ec9b0');
    } catch (e) {
        log(`✗ Errore token: ${e.message}`, '#f44747');
        summaryEl.textContent = '❌ Impossibile acquisire il token. Verifica i permessi nell\'App Registration.';
        summaryEl.style.color = '#d13438';
        if (closeBtn) closeBtn.style.display = '';
        return;
    }

    const headers = { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' };

    // Crea/trova il gruppo BreakGlass
    let bgGroupId = null;
    log('→ Ricerca gruppo CA-BreakGlass-Exclusion...', '#9cdcfe');
    try {
        const gResp = await fetch('https://graph.microsoft.com/v1.0/groups?$filter=displayName eq \'CA-BreakGlass-Exclusion\'&$select=id,displayName', { headers });
        const gJson = await gResp.json();
        if (gJson.value?.length > 0) {
            bgGroupId = gJson.value[0].id;
            log(`  ✓ Gruppo esistente: ${bgGroupId}`, '#4ec9b0');
        } else {
            const cResp = await fetch('https://graph.microsoft.com/v1.0/groups', {
                method: 'POST', headers,
                body: JSON.stringify({ displayName: 'CA-BreakGlass-Exclusion', mailEnabled: false, mailNickname: 'CA-BreakGlass-Exclusion', securityEnabled: true, description: 'Gruppo di esclusione per account Break Glass dalle Conditional Access policy.' })
            });
            if (cResp.ok) { const cj = await cResp.json(); bgGroupId = cj.id; log(`  ✓ Gruppo creato: ${bgGroupId}`, '#4ec9b0'); }
            else { log('  ⚠ Impossibile creare il gruppo BreakGlass, procedo senza.', '#ff8c00'); }
        }
    } catch (e) { log(`  ⚠ Errore gruppo BreakGlass: ${e.message}`, '#ff8c00'); }

    // Crea Named Location per CA001 se necessaria
    let allowedLocId = null;
    const selectedIds = Array.from(document.querySelectorAll('.ca-policy-check:checked:not([disabled])')).map(cb => cb.dataset.id);
    if (selectedIds.includes('ca001')) {
        log('→ Creazione Named Location "CA-Allowed-Countries"...', '#9cdcfe');
        try {
            const locResp = await fetch('https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations?$filter=displayName eq \'CA-Allowed-Countries\'', { headers });
            const locJson = await locResp.json();
            if (locJson.value?.length > 0) {
                allowedLocId = locJson.value[0].id;
                log(`  ✓ Named Location esistente: ${allowedLocId}`, '#4ec9b0');
            } else {
                const nlResp = await fetch('https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations', {
                    method: 'POST', headers,
                    body: JSON.stringify({ '@odata.type': '#microsoft.graph.countryNamedLocation', displayName: 'CA-Allowed-Countries', includeUnknownCountriesAndRegions: false, countriesAndRegions: ['IT','DE','FR','GB','NL','BE','CH','AT','SE','NO','DK','FI','ES','PT','PL','CZ','HU','RO','US','CA','AU','NZ'] })
                });
                if (nlResp.ok) { const nlj = await nlResp.json(); allowedLocId = nlj.id; log(`  ✓ Named Location creata (personalizza in Entra ID): ${allowedLocId}`, '#4ec9b0'); }
                else { log('  ⚠ Impossibile creare Named Location, CA001 verrà saltata.', '#ff8c00'); }
            }
        } catch (e) { log(`  ⚠ Errore Named Location: ${e.message}`, '#ff8c00'); }
    }

    let deployed = 0, failed = 0, skipped = 0;
    for (const policy of CA_BASELINE) {
        if (!selectedIds.includes(policy.id)) continue;
        log(`→ Deploy: [${policy.code}] ${policy.name}`, '#9cdcfe');
        try {
            const locs = policy.id === 'ca001' ? { allowed: allowedLocId } : null;
            if (policy.id === 'ca001' && !allowedLocId) { log('  ⚠ Saltata (Named Location non disponibile)', '#ff8c00'); skipped++; continue; }
            const body = policy.getBody(bgGroupId, locs);
            const resp = await fetch('https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies', { method: 'POST', headers, body: JSON.stringify(body) });
            if (resp.ok) {
                const result = await resp.json();
                log(`  ✓ Creata in Report-Only: ${result.displayName} (${result.id})`, '#4ec9b0');
                deployed++;
            } else {
                const ej = await resp.json();
                const msg = ej?.error?.message || `HTTP ${resp.status}`;
                log(`  ✗ Errore: ${msg}`, '#f44747');
                failed++;
            }
        } catch (e) { log(`  ✗ Errore rete: ${e.message}`, '#f44747'); failed++; }
    }

    log('', '');
    log(`=== COMPLETATO: ${deployed} policy create, ${failed} errori, ${skipped} saltate ===`, failed > 0 ? '#ff8c00' : '#4ec9b0');
    if (bgGroupId) log(`⚠ Aggiungi i tuoi account Break Glass al gruppo CA-BreakGlass-Exclusion (${bgGroupId})`, '#ff8c00');
    log('⚠ Tutte le policy sono in Report-Only. Vai su Entra ID → CA → verifica i report → abilita manualmente.', '#ff8c00');
    summaryEl.textContent = `${deployed} policy CA deployate in Report-Only${failed > 0 ? ` — ${failed} errori` : ''}.`;
    summaryEl.style.color = failed > 0 ? '#d13438' : '#107c10';
    if (closeBtn) closeBtn.style.display = '';
}

function escapeHtml(str) {
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

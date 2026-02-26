// ========================================
// CONFIGURAZIONE AMBIENTE
// ========================================

const API_BASE_URL = window.location.hostname === 'localhost'
    ? 'http://localhost:8787'
    : 'https://func-azure-solution-monitor-precheck-dac4ewdca4h3agbv.westeurope-01.azurewebsites.net';

console.log('🌍 Ambiente rilevato:', window.location.hostname === 'localhost' ? 'LOCALE' : 'AZURE');
console.log('🔗 API Base URL:', API_BASE_URL);

// ========================================
// INIZIALIZZAZIONE MSAL
// ========================================

let msalInstance = null;
let currentAccessToken = null;
let currentAccount = null;

const msalConfig = {
    auth: {
        clientId: "f28f9af6-6681-4e31-afbc-e8327d2010b6", // Azure CLI Public Client
        authority: "https://login.microsoftonline.com/common",
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
                console.warn(`⚠️ Tentativo ${i + 1}/${retries}: MSAL non ancora caricato, attendo...`);
                await new Promise(resolve => setTimeout(resolve, 1000));
                continue;
            }

            msalInstance = new msal.PublicClientApplication(msalConfig);
            await msalInstance.initialize();
            console.log('✅ MSAL inizializzato correttamente');
            return true;
        } catch (error) {
            console.error(`❌ Errore inizializzazione MSAL (tentativo ${i + 1}):`, error);
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
    if (!success) {
        updateAuthUI(false);
        return;
    }

    try {
        await msalInstance.handleRedirectPromise();
        
        const accounts = msalInstance.getAllAccounts();
        if (accounts.length > 0) {
            currentAccount = accounts[0];
            msalInstance.setActiveAccount(currentAccount);
            
            try {
                const response = await msalInstance.acquireTokenSilent({
                    ...loginRequest,
                    account: currentAccount
                });
                currentAccessToken = response.accessToken;
                updateAuthUI(true, currentAccount.username);
                console.log('✅ Token ottenuto silenziosamente');
            } catch (error) {
                console.log("⚠️ Token silenzioso fallito:", error);
                currentAccessToken = null;
                updateAuthUI(false);
            }
        } else {
            updateAuthUI(false);
        }
    } catch (error) {
        console.error("❌ Errore inizializzazione auth:", error);
        updateAuthUI(false);
    }
}

async function handleAuthentication() {
    if (!msalInstance) {
        alert('❌ Sistema di autenticazione non disponibile.\n\n🔄 Ricarica la pagina.');
        return;
    }

    const authButton = document.getElementById('auth-button');
    if (!authButton) {
        console.error('❌ Pulsante auth-button non trovato');
        return;
    }

    if (currentAccount) {
        // LOGOUT
        try {
            await msalInstance.logoutPopup({
                account: currentAccount,
                postLogoutRedirectUri: window.location.origin
            });
            currentAccessToken = null;
            currentAccount = null;
            updateAuthUI(false);
            console.log('✅ Logout completato');
        } catch (error) {
            console.error("❌ Errore logout:", error);
            alert('❌ Errore durante il logout: ' + error.message);
        }
    } else {
        // LOGIN
        authButton.disabled = true;
        authButton.textContent = 'Accesso in corso...';
        
        try {
            const response = await msalInstance.loginPopup(loginRequest);
            currentAccount = response.account;
            currentAccessToken = response.accessToken;
            msalInstance.setActiveAccount(currentAccount);
            updateAuthUI(true, currentAccount.username);
            console.log('✅ Login completato, token ottenuto');
        } catch (error) {
            console.error("❌ Errore login:", error);
            
            let errorMessage = error.message;
            if (error.errorCode === 'user_cancelled') {
                errorMessage = 'Login annullato dall\'utente';
            } else if (error.errorCode === 'popup_window_error') {
                errorMessage = 'Impossibile aprire il popup. Verifica che i popup non siano bloccati.';
            }
            
            alert("❌ Errore durante l'autenticazione:\n\n" + errorMessage);
            updateAuthUI(false);
        } finally {
            authButton.disabled = false;
        }
    }
}

async function getAccessToken() {
    if (!msalInstance) {
        throw new Error("Sistema di autenticazione non inizializzato");
    }

    if (!currentAccount) {
        throw new Error("Non autenticato. Effettua prima il login.");
    }

    try {
        const response = await msalInstance.acquireTokenSilent({
            ...loginRequest,
            account: currentAccount
        });
        currentAccessToken = response.accessToken;
        console.log('✅ Token rinnovato silenziosamente');
        return currentAccessToken;
    } catch (error) {
        console.warn("⚠️ Token silenzioso fallito, richiedo popup:", error);
        
        try {
            const response = await msalInstance.acquireTokenPopup(loginRequest);
            currentAccessToken = response.accessToken;
            console.log('✅ Token ottenuto tramite popup');
            return currentAccessToken;
        } catch (popupError) {
            console.error("❌ Errore acquisizione token:", popupError);
            throw new Error("Impossibile ottenere il token di accesso ad Azure.");
        }
    }
}

function updateAuthUI(isAuthenticated, username = '') {
    const authIndicator = document.getElementById('auth-indicator');
    const authText = document.getElementById('auth-text');
    const authButton = document.getElementById('auth-button');
    
    if (!authIndicator || !authText || !authButton) {
        console.error('❌ Elementi UI autenticazione non trovati');
        return;
    }

    const icon = authIndicator.querySelector('i');
    if (!icon) {
        console.error('❌ Icona autenticazione non trovata');
        return;
    }

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
    console.log('✅ DOM caricato, inizializzazione in corso...');
    
    // Inizializza autenticazione
    initializeAuth();
    
    // ========================================
    // EVENT LISTENER: PULSANTE ACCEDI
    // ========================================
    const authButton = document.getElementById('auth-button');
    if (authButton) {
        authButton.addEventListener('click', handleAuthentication);
        console.log('✅ Event listener autenticazione collegato');
    } else {
        console.error('❌ Pulsante auth-button non trovato nel DOM');
    }
    
    // ========================================
    // EVENT LISTENER: PULSANTI PRECHECK E DEPLOY
    // ========================================
    document.querySelectorAll('.btn-precheck').forEach(btn => {
        btn.addEventListener('click', function() {
            const solution = this.getAttribute('data-solution');
            showPrecheckOptions(solution);
        });
    });
    
    document.querySelectorAll('.btn-deploy').forEach(btn => {
        btn.addEventListener('click', function() {
            const solution = this.getAttribute('data-solution');
            showDeployOptions(solution);
        });
    });
    
    console.log('✅ Event listeners per Precheck/Deploy collegati');
    
    // ========================================
    // EVENT LISTENER: ESEGUI PRECHECK
    // ========================================
    const runPrecheckBtn = document.getElementById('run-precheck');
    if (runPrecheckBtn) {
        runPrecheckBtn.addEventListener('click', async function() {
            const subscriptionId = document.getElementById('subscription-id').value.trim();
            
            if (!subscriptionId) {
                alert('⚠️ Inserisci l\'ID della sottoscrizione Azure');
                return;
            }

            if (!currentAccount) {
                alert('⚠️ Devi effettuare il login prima di eseguire il precheck.\n\n🔐 Clicca sul pulsante "Accedi con Microsoft" in alto a destra.');
                return;
            }

            console.log('🚀 Avvio precheck per subscription:', subscriptionId);

            document.querySelector('.precheck-form').style.display = 'none';
            document.getElementById('precheck-loading').style.display = 'block';
            document.getElementById('precheck-results').style.display = 'none';

            try {
                const accessToken = await getAccessToken();
                console.log('🔑 Token ottenuto per API call');

                const apiUrl = `${API_BASE_URL}/api/precheck?subscriptionId=${encodeURIComponent(subscriptionId)}`;
                console.log('📡 Chiamata API:', apiUrl);

                const response = await fetch(apiUrl, {
                    method: 'GET',
                    headers: {
                        'Authorization': `Bearer ${accessToken}`,
                        'Content-Type': 'application/json'
                    }
                });

                if (!response.ok) {
                    const errorText = await response.text();
                    console.error('❌ Errore HTTP:', response.status, errorText);
                    
                    if (response.status === 401) {
                        throw new Error('Token scaduto o non valido. Effettua nuovamente il login.');
                    } else if (response.status === 403) {
                        throw new Error('Accesso negato. Verifica di avere i permessi Reader sulla subscription.');
                    } else if (response.status === 404) {
                        throw new Error('Subscription non trovata. Verifica l\'ID inserito.');
                    } else {
                        throw new Error(`Errore HTTP ${response.status}: ${errorText}`);
                    }
                }

                const data = await response.json();
                console.log('✅ Dati ricevuti:', data);

                // ✅ QUESTA RIGA SALVA LA RISPOSTA GLOBALMENTE
                window.lastPrecheckResponse = data;
                console.log('💾 Risposta salvata per download report');

                document.getElementById('precheck-loading').style.display = 'none';
                populatePrecheckResults(data);
                document.getElementById('precheck-results').style.display = 'block';
                showTab('overview');

            } catch (error) {
                console.error('❌ Errore precheck:', error);
                document.getElementById('precheck-loading').style.display = 'none';
                document.querySelector('.precheck-form').style.display = 'block';
                
                alert(`❌ Errore durante l'esecuzione del precheck:\n\n${error.message}\n\n📋 Controlla la console per maggiori dettagli (F12).`);
            }
        });
    }
    // ========================================
    // FUNZIONE PER POPOLARE I RISULTATI
    // ========================================
    function populatePrecheckResults(data) {
        console.log('📊 Popolamento risultati con dati:', data);
        
        if (data.Summary) {
            document.getElementById('overview-vm-total').textContent = data.Summary.TotalMachines || 0;
            document.getElementById('overview-vm-monitored').textContent = data.Summary.MachinesWithAMA || 0;
            document.getElementById('overview-workspaces').textContent = data.Summary.TotalWorkspaces || 0;
            document.getElementById('overview-dcr').textContent = data.Summary.TotalDCRs || 0;
            
            document.getElementById('vm-count').textContent = data.Summary.TotalMachines || 0;
            document.getElementById('workspace-count').textContent = data.Summary.TotalWorkspaces || 0;
            
            const statusElement = document.getElementById('overall-status');
            if (data.Summary.AMA_Coverage_Percent >= 80) {
                statusElement.textContent = 'Pronto per il deployment';
                statusElement.className = 'status-badge status-success';
            } else if (data.Summary.AMA_Coverage_Percent >= 50) {
                statusElement.textContent = 'Richiede configurazione';
                statusElement.className = 'status-badge status-warning';
            } else {
                statusElement.textContent = 'Configurazione incompleta';
                statusElement.className = 'status-badge status-danger';
            }
        }
        
        if (data.AzureVMs && Array.isArray(data.AzureVMs)) {
            const vmTableBody = document.querySelector('#vm-table tbody');
            vmTableBody.innerHTML = '';
            
            data.AzureVMs.forEach(vm => {
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${vm.Name || 'N/A'}</td>
                    <td>${vm.ResourceGroup || 'N/A'}</td>
                    <td>${vm.PowerState || 'Unknown'}</td>
                    <td>
                        ${vm.HasAMA ? '<span class="status-badge status-success">AMA</span>' : ''}
                        ${vm.HasLegacyMMA ? '<span class="status-badge status-warning">Legacy MMA</span>' : ''}
                        ${!vm.HasAMA && !vm.HasLegacyMMA ? '<span class="status-badge status-danger">Nessuno</span>' : ''}
                    </td>
                    <td>${vm.OsType || 'Unknown'}</td>
                `;
                vmTableBody.appendChild(row);
            });
        }
        
        if (data.LogAnalyticsWorkspaces && Array.isArray(data.LogAnalyticsWorkspaces)) {
            const wsTableBody = document.querySelector('#workspace-table tbody');
            wsTableBody.innerHTML = '';
            
            data.LogAnalyticsWorkspaces.forEach(ws => {
                const row = document.createElement('tr');
                row.innerHTML = `
                    <td>${ws.Name || 'N/A'}</td>
                    <td>${ws.ResourceGroup || 'N/A'}</td>
                    <td>${ws.Location || 'N/A'}</td>
                    <td>${ws.HasVMInsights ? '<span class="status-badge status-success">Abilitato</span>' : '<span class="status-badge status-danger">Disabilitato</span>'}</td>
                    <td>${ws.RetentionInDays || 'N/A'}</td>
                `;
                wsTableBody.appendChild(row);
            });
        }
        
        if (data.DataCollectionRules && Array.isArray(data.DataCollectionRules)) {
            const dcrTableBody = document.querySelector('#dcr-table tbody');
            dcrTableBody.innerHTML = '';
            
            data.DataCollectionRules.forEach(dcr => {
                const row = document.createElement('tr');
                
                const associatedVMs = data.DCRAssociations ? 
                    data.DCRAssociations.filter(a => a.DataCollectionRuleId === dcr.ResourceId).length : 0;
                
                row.innerHTML = `
                    <td>${dcr.Name || 'N/A'}</td>
                    <td>${dcr.ResourceGroup || 'N/A'}</td>
                    <td><span class="status-badge status-info">${dcr.Type || 'N/A'}</span></td>
                    <td>${dcr.Location || 'N/A'}</td>
                    <td>${associatedVMs}</td>
                `;
                dcrTableBody.appendChild(row);
            });
        }
        
        const recommendationsContainer = document.getElementById('recommendations-content');
        recommendationsContainer.innerHTML = '';
        
        const recommendations = [];
        
        if (data.Summary) {
            if (data.Summary.UnmonitoredMachines > 0) {
                recommendations.push({
                    title: 'Installare Azure Monitor Agent',
                    description: `${data.Summary.UnmonitoredMachines} macchine non hanno agenti di monitoraggio installati. Si consiglia di distribuire AMA.`,
                    priority: 'high'
                });
            }
            
            if (data.Summary.TotalDCRs === 0) {
                recommendations.push({
                    title: 'Configurare Data Collection Rules',
                    description: 'Non sono presenti Data Collection Rules. Configurare DCR per raccogliere metriche e log.',
                    priority: 'high'
                });
            }
            
            if (data.Summary.TotalActionGroups === 0) {
                recommendations.push({
                    title: 'Creare Action Groups',
                    description: 'Non sono configurati Action Groups per le notifiche. Configurare almeno un gruppo per ricevere alert.',
                    priority: 'medium'
                });
            }
            
            if (data.Summary.TotalMetricAlerts === 0 && data.Summary.TotalLogAlerts === 0) {
                recommendations.push({
                    title: 'Configurare Alert',
                    description: 'Non sono presenti alert configurati. Si consiglia di creare alert per CPU, memoria e disco.',
                    priority: 'medium'
                });
            }
            
            if (data.Summary.MachinesWithLegacyMMA > 0) {
                recommendations.push({
                    title: 'Migrare da Legacy MMA ad AMA',
                    description: `${data.Summary.MachinesWithLegacyMMA} macchine utilizzano ancora il legacy MMA. Pianificare la migrazione ad Azure Monitor Agent.`,
                    priority: 'medium'
                });
            }
        }
        
        if (recommendations.length === 0) {
            recommendationsContainer.innerHTML = '<p style="color: #107c10;"><i class="fas fa-check-circle"></i> Nessuna raccomandazione critica. L\'ambiente è configurato correttamente!</p>';
        } else {
            recommendations.forEach(rec => {
                const div = document.createElement('div');
                div.className = 'recommendation-item';
                
                const icon = rec.priority === 'high' ? 
                    '<i class="fas fa-exclamation-triangle" style="color: #ff8c00;"></i>' : 
                    '<i class="fas fa-info-circle" style="color: #0078d4;"></i>';
                
                div.innerHTML = `
                    <div class="recommendation-title">${icon} ${rec.title}</div>
                    <div class="recommendation-description">${rec.description}</div>
                `;
                recommendationsContainer.appendChild(div);
            });
        }
    }

    // ========================================
    // GESTIONE TAB
    // ========================================
    const tabButtons = document.querySelectorAll('.tab-button');
    tabButtons.forEach(button => {
        button.addEventListener('click', function() {
            const tabId = this.getAttribute('data-tab');
            showTab(tabId);
        });
    });

    function showTab(tabId) {
        document.querySelectorAll('.tab-pane').forEach(pane => {
            pane.classList.remove('active');
        });
        
        document.querySelectorAll('.tab-button').forEach(btn => {
            btn.classList.remove('active');
        });
        
        const selectedPane = document.getElementById(tabId);
        if (selectedPane) {
            selectedPane.classList.add('active');
        }
        
        const selectedButton = document.querySelector(`.tab-button[data-tab="${tabId}"]`);
        if (selectedButton) {
            selectedButton.classList.add('active');
        }
    }

    // ========================================
    // DOWNLOAD REPORT
    // ========================================
    const downloadBtn = document.getElementById('download-report');
if (downloadBtn) {
    downloadBtn.addEventListener('click', async function() {
        try {
            // ✅ USA L'HTML SALVATO
            if (!window.lastPrecheckResponse || !window.lastPrecheckResponse.ReportHTML) {
                throw new Error('Report HTML non disponibile. Esegui prima il precheck.');
            }
            
            console.log('📥 Download report...');
            
            const htmlContent = window.lastPrecheckResponse.ReportHTML;
            const blob = new Blob([htmlContent], { type: 'text/html' });
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `Azure-Monitor-Report-${new Date().toISOString().split('T')[0]}.html`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            window.URL.revokeObjectURL(url);
            
            alert('✅ Report scaricato con successo!');
        } catch (error) {
            console.error('❌ Errore download:', error);
            alert('❌ ' + error.message);
        }
    });
}

    // ========================================
    // PROCEDI CON DEPLOYMENT
    // ========================================
    const proceedBtn = document.getElementById('proceed-to-deploy');
    if (proceedBtn) {
        proceedBtn.addEventListener('click', function() {
            document.getElementById('precheck-modal').style.display = 'none';
            document.getElementById('deploy-modal').style.display = 'block';
        });
    }

    // ========================================
    // COPIA COMANDO POWERSHELL
    // ========================================
    const copyBtn = document.getElementById('copy-precheck-command');
    if (copyBtn) {
        copyBtn.addEventListener('click', function() {
            const subscriptionId = document.getElementById('subscription-id').value.trim();
            
            if (!subscriptionId) {
                alert('⚠️ Inserisci prima l\'ID della sottoscrizione');
                return;
            }

            const command = `.\\scripts\\testluca.ps1 -SubscriptionId "${subscriptionId}"`;

            navigator.clipboard.writeText(command).then(() => {
                const originalText = copyBtn.textContent;
                copyBtn.textContent = '✓ Copiato!';
                copyBtn.style.backgroundColor = '#107c10';
                setTimeout(() => {
                    copyBtn.textContent = originalText;
                    copyBtn.style.backgroundColor = '';
                }, 2000);
            }).catch(err => {
                console.error('❌ Errore copia:', err);
                alert('❌ Errore nella copia del comando');
            });
        });
    }

    // ========================================
    // CHIUSURA MODALI
    // ========================================
    const closeButtons = document.querySelectorAll('.close-modal');
    closeButtons.forEach(button => {
        button.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            
            const modal = this.closest('.modal');
            if (modal) {
                modal.style.display = 'none';
                
                if (modal.id === 'precheck-modal') {
                    document.querySelector('.precheck-form').style.display = 'block';
                    document.getElementById('precheck-loading').style.display = 'none';
                    document.getElementById('precheck-results').style.display = 'none';
                }
            }
            
            console.log('✅ Modal chiuso');
        });
    });

    window.addEventListener('click', function(event) {
        if (event.target.classList.contains('modal')) {
            event.target.style.display = 'none';
            
            if (event.target.id === 'precheck-modal') {
                document.querySelector('.precheck-form').style.display = 'block';
                document.getElementById('precheck-loading').style.display = 'none';
                document.getElementById('precheck-results').style.display = 'none';
            }
            
            console.log('✅ Modal chiuso (click esterno)');
        }
    });
});

// ========================================
// FUNZIONI GLOBALI PER I MODALI
// ========================================
function showPrecheckOptions(solution) {
    console.log('📋 Apertura modal precheck per:', solution);
    const modal = document.getElementById('precheck-modal');
    if (modal) {
        modal.style.display = 'block';
    } else {
        console.error('❌ Modal precheck non trovato');
    }
}

function showDeployOptions(solution) {
    console.log('🚀 Apertura modal deploy per:', solution);
    const modal = document.getElementById('deploy-modal');
    if (modal) {
        modal.style.display = 'block';
    } else {
        console.error('❌ Modal deploy non trovato');
    }
}
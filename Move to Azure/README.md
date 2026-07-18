# Move to Azure — Deploy one-click

Distribuisce l'**intera Azure Solution Portal** (backend + portale + AI) sull'Azure
del cliente, sul **tenant e sottoscrizione con cui effettui il login**.

## Come si usa

1. Doppio-click su **`Deploy.cmd`** (unico file da lanciare).
2. Si apre il login Azure: accedi con un utente del **tenant del cliente** (con diritti
   di creazione risorse; per l'admin-consent dell'App Registration servono diritti da
   Global Administrator).
3. Scegli la sottoscrizione quando richiesto.
4. Attendi il completamento: a fine deploy vengono stampati **URL del portale** e **URL backend**.

> In alternativa da PowerShell:
> ```powershell
> ./Deploy-ToAzure.ps1 -ResourceGroup "azure-solution-portal" -Location "westeurope"
> ```

## Cosa crea (tutto in un unico Resource Group)

| Risorsa | Scopo |
|---|---|
| Resource Group | contenitore di tutto |
| Storage Account + **static website** | ospita il portale (frontend) + queue/container per Assessment 365 |
| **App Registration** (Azure AD) | login MSAL del portale (SPA redirect + permesso Azure Service Management) |
| **Azure OpenAI** + deployment `gpt-5-mini` | executive summary AI nei report |
| **Function App** (PowerShell 7.4, Consumption) | tutti gli endpoint precheck/assessment |

Tutto **pay-per-use** (Consumption + OpenAI a consumo): costo ~0 da fermo.

## Parametri (opzionali)

| Parametro | Default | Note |
|---|---|---|
| `-ResourceGroup` | `azure-solution-portal` | nome RG |
| `-Location` | `westeurope` | region compute/storage |
| `-OpenAILocation` | `swedencentral` | region Azure OpenAI (quota modello) |
| `-SubscriptionId` | *(interattivo)* | forza la sottoscrizione |
| `-Prefix` | `azsolportal` | prefisso nomi risorse |
| `-OpenAIModel` / `-OpenAIModelVersion` | `gpt-5-mini` / `2025-08-07` | modello chat |
| `-SkipOpenAI` | *(off)* | salta l'AI (report senza executive summary) |

## Note

- **Idempotente**: rilanciandolo aggiorna le risorse esistenti (stessi nomi, suffisso dal subscriptionId).
- Se in region non c'è **quota** per il modello OpenAI, il deploy continua **senza AI** e lo segnala:
  puoi configurare `AZURE_OPENAI_*` sul Function App in un secondo momento.
- Gli scope Graph avanzati (Directory.Read.All, ecc.) per i moduli Assessment/Intune richiedono
  admin-consent al primo utilizzo (gestito dal portale con redirect di consenso).
- **Assessment 365** (full M365-Assess) richiede i moduli Graph/Exchange non inclusi nel piano
  Consumption: usarlo in locale tramite il pulsante "Scarica Script".

## Prerequisiti

- [Azure CLI](https://aka.ms/installazurecli) installata.
- Eseguire lo script **da dentro il repo** (questa cartella deve stare nella root del progetto:
  lo script prende il codice da `..\Azure Solution Portal\FunctionApp` e `..\Azure Solution Portal\Frontend`).

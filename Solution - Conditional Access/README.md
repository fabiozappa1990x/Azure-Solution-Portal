# Solution - Conditional Access Baseline

Soluzione per il deployment di una Baseline di 24 policy di Conditional Access per Microsoft Entra ID.

Basata sul progetto open source: https://github.com/j0eyv/ConditionalAccessBaseline

## Architettura

Questa soluzione è **completamente client-side** — il precheck e il deploy avvengono direttamente dal browser tramite Microsoft Graph API, senza passare per una Azure Function.

Il browser chiede i permessi Graph:
- `Policy.ReadWrite.ConditionalAccess`
- `Policy.Read.All`
- `Group.ReadWrite.All`
- `Directory.Read.All`

## Struttura delle policy

| Codice | Categoria | Descrizione |
|--------|-----------|-------------|
| CA001 | Global | Block countries outside whitelist |
| CA002 | Global | Block Legacy Authentication |
| CA003 | Global | MFA per registrazione/join dispositivi |
| CA004 | Global | Block Authentication Flows (Device Code, Transfer) |
| CA100-CA105 | Admins | MFA, FIDO2, compliant device per admin roles |
| CA200-CA210 | Internals | MFA, compliant app/device, sessioni per utenti interni |
| CA300-CA304 | Guests | MFA, blocco legacy, app approvate per guest |

## Precheck

Il precheck analizza le policy esistenti nel tenant e verifica:
1. Se ogni funzionalità baseline è già coperta da policy esistenti (indipendentemente dal nome)
2. Quante policy mancano e quali aggiungere

## Deploy

Il wizard permette di:
1. Selezionare le policy da deployare
2. Creare automaticamente il gruppo `CA-BreakGlass-Exclusion`
3. Creare la Named Location per CA001 (paese di esclusione)
4. Deployare tutte le policy in modalità **Report-Only** (nessun impatto operativo immediato)

## Note operative

- Tutte le policy vengono create in stato `Report-Only` — nessuna interruzione al login
- Prima di attivare, monitora l'impatto in **Entra ID > Sign-in logs > Report-only**
- Il gruppo `CA-BreakGlass-Exclusion` deve contenere gli account di emergenza

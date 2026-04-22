# Conditional Access Baseline - Riferimento Policy

## CA001 - Global: Block Countries Outside Whitelist
Blocca l'accesso da tutti i paesi tranne quelli in whitelist (Named Location).
Riduce drasticamente la superficie di attacco da IP geografici non attesi.

## CA002 - Global: Block Legacy Authentication
Blocca tutti i client che usano autenticazione legacy (SMTP AUTH, POP3, IMAP, ecc.).
Il 99% degli attacchi password spray usa legacy auth — bloccarla elimina questa superficie.

## CA003 - Global: MFA for Device Registration/Join
Richiede MFA per registrare o joinare dispositivi a Entra ID.
Impedisce che un attaccante con credenziali rubate registri un dispositivo malevolo.

## CA004 - Global: Block Authentication Transfer Flows
Blocca Device Code Flow e Authentication Transfer — tecniche usate in phishing moderno (AiTM).

## CA100 - Admins: MFA Any Platform
MFA obbligatoria per tutti gli admin role su qualsiasi piattaforma.

## CA101 - Admins: FIDO2 Only (Windows/macOS)
Su desktop, gli admin devono usare FIDO2/Passkey — resiste al phishing.

## CA102 - Admins: Compliant Device
Gli admin devono operare da dispositivi compliant Intune.

## CA103 - Admins: No Persistent Browser Session
Nessuna sessione browser persistente per gli admin.

## CA104 - Admins: Sign-in Frequency 4h
Gli admin devono ri-autenticarsi ogni 4 ore.

## CA105 - Admins: Block Non-Windows/macOS
Gli admin non possono accedere da piattaforme non gestite (Android/iOS/Linux).

## CA200 - Internals: MFA Any Platform
MFA per tutti gli utenti interni su qualsiasi piattaforma e app.

## CA201 - Internals: Approved App or Compliant (Android/iOS - MAM)
Su mobile, solo app approvate da Intune o dispositivi compliant.

## CA202 - Internals: App Enforced Restrictions (Android/iOS - Browser)
Browser su mobile: restrizioni app enforcement (Outlook Web in modalità limitata).

## CA203 - Internals: Sign-in Frequency + Compliant/Hybrid (Windows/macOS)
Desktop managed: re-auth periodica su dispositivi non compliant/hybrid-joined.

## CA204 - Internals: Block Unknown Platforms
Blocca piattaforme non riconosciute (tutto ciò che non è Android, iOS, Windows, macOS, Linux, WindowsPhone).

## CA205 - Internals: Compliant or Hybrid Windows
Su Windows, richiede dispositivo compliant Intune o hybrid Azure AD joined.

## CA206 - Internals: Compliant macOS
Su macOS, richiede dispositivo compliant Intune.

## CA207 - Internals: SSPR MFA
MFA per Self-Service Password Reset (Azure AD reset).

## CA208 - Internals: Block High Risk Users
Blocca utenti con risk level "high" (Identity Protection).

## CA209 - Internals: Block High Risk Sign-in
Blocca sign-in con risk level "high".

## CA210 - Internals: Sign-in Frequency Global
Re-auth periodica per tutti gli utenti su tutti i client.

## CA300 - Guests: MFA
MFA obbligatoria per tutti i guest/external users.

## CA301 - Guests: Block Legacy Auth
Blocca legacy authentication per i guest.

## CA302 - Guests: No Persistent Session
Nessuna sessione persistente per i guest.

## CA303 - Guests: Block Non-Office365 Apps
I guest possono accedere solo a Office365, non ad altre app aziendali.

## CA304 - Guests: Block Admin Portal
I guest non possono accedere ai portali di amministrazione Microsoft.

Set-StrictMode -Version Latest

function New-PrecheckCheck {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')] [string] $Severity,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Skip')] [string] $Status,
        [Parameter(Mandatory)] [string] $Rationale,
        [Parameter()] [string] $Remediation = '',
        [Parameter()] $Evidence = $null
    )

    return [ordered]@{
        id          = $Id
        title       = $Title
        severity    = $Severity
        status      = $Status
        rationale   = $Rationale
        remediation = $Remediation
        evidence    = $Evidence
    }
}

function Get-PrecheckReadiness {
    param(
        [Parameter(Mandatory)] [array] $Checks
    )

    $weights = @{
        Critical = 10
        High     = 6
        Medium   = 3
        Low      = 1
        Info     = 0
    }

    $total = 0
    $penalty = 0

    foreach ($c in $Checks) {
        $sev = [string]$c.severity
        $w = if ($weights.ContainsKey($sev)) { [int]$weights[$sev] } else { 0 }
        $total += $w

        switch ([string]$c.status) {
            'Fail' { $penalty += $w }
            'Warn' { $penalty += [math]::Ceiling($w * 0.45) }
            default { }
        }
    }

    if ($total -le 0) {
        return [ordered]@{ score = 100; level = 'Ready' }
    }

    $score = [math]::Max(0, [math]::Min(100, [math]::Round(100 * (1 - ($penalty / $total)), 0)))
    $level = if ($score -ge 85) { 'Ready' } elseif ($score -ge 60) { 'NeedsWork' } else { 'NotReady' }

    return [ordered]@{
        score = $score
        level = $level
    }
}

function Convert-ChecksToHtml {
    param(
        [Parameter(Mandatory)] [array] $Checks
    )

    $rows = foreach ($c in $Checks) {
        $status = [string]$c.status
        $sev = [string]$c.severity
        $badgeClass = switch ($status) {
            'Pass' { 'badge pass' }
            'Warn' { 'badge warn' }
            'Fail' { 'badge fail' }
            default { 'badge skip' }
        }
        @"
<tr>
  <td><span class="sev sev-$($sev.ToLower())">$sev</span></td>
  <td><span class="$badgeClass">$status</span></td>
  <td><div class="t">$([System.Net.WebUtility]::HtmlEncode([string]$c.title))</div><div class="s">$([System.Net.WebUtility]::HtmlEncode([string]$c.rationale))</div></td>
</tr>
"@
    }

    return ($rows -join "`n")
}

function New-EnterpriseHtmlReport {
    param(
        [Parameter(Mandatory)] [string] $SolutionName,
        [Parameter(Mandatory)] [hashtable] $Summary,
        [Parameter(Mandatory)] [array] $Checks,
        [Parameter()] [array] $ImplementationGuide = @(),
        [Parameter()] [string] $AiHtml = '',
        [Parameter()] [string] $LegacyHtml = '',
        [Parameter()] [hashtable] $Context = @{}
    )

    $readiness = Get-PrecheckReadiness -Checks $Checks
    $checksHtml = Convert-ChecksToHtml -Checks $Checks

    $subName = if ($Context.SubscriptionName) { [string]$Context.SubscriptionName } else { '' }
    $subId   = if ($Context.SubscriptionId) { [string]$Context.SubscriptionId } else { '' }
    $ts      = if ($Context.Timestamp) { [string]$Context.Timestamp } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

    $score = [int]$readiness.score
    $pill = if ($readiness.level -eq 'Ready') { 'pill ok' } elseif ($readiness.level -eq 'NeedsWork') { 'pill warn' } else { 'pill fail' }
    $levelText = switch ($readiness.level) {
        'Ready' { 'Ready' }
        'NeedsWork' { 'Needs work' }
        default { 'Not ready' }
    }

    $k1 = $Summary.Kpi1Label; $v1 = $Summary.Kpi1Value
    $k2 = $Summary.Kpi2Label; $v2 = $Summary.Kpi2Value
    $k3 = $Summary.Kpi3Label; $v3 = $Summary.Kpi3Value
    $k4 = $Summary.Kpi4Label; $v4 = $Summary.Kpi4Value

    $legacySection = ''
    if ($LegacyHtml) {
        $legacySection = @"
<details class="legacy">
  <summary>Dettaglio tecnico (legacy report)</summary>
  <div class="legacy-body">$LegacyHtml</div>
</details>
"@
    }

    $guideSection = ''
    if ($ImplementationGuide -and $ImplementationGuide.Count -gt 0) {
        $items = foreach ($s in $ImplementationGuide) {
            if ($s -is [string]) {
                "<li>$([System.Net.WebUtility]::HtmlEncode($s))</li>"
                continue
            }

            $title = if ($s.title) { [string]$s.title } else { '' }
            $why   = if ($s.why) { [string]$s.why } else { '' }
            $how   = if ($s.how) { [string]$s.how } else { '' }
            $when  = if ($s.when) { [string]$s.when } else { '' }

            $parts = @()
            if ($why)  { $parts += ('<div class="s"><strong>Perché:</strong> ' + [System.Net.WebUtility]::HtmlEncode($why) + '</div>') }
            if ($how)  { $parts += ('<div class="s"><strong>Cosa fare:</strong> ' + [System.Net.WebUtility]::HtmlEncode($how) + '</div>') }
            if ($when) { $parts += ('<div class="s"><strong>Priorità:</strong> ' + [System.Net.WebUtility]::HtmlEncode($when) + '</div>') }
            $body = ($parts -join '')

            @"
<li class="g">
  <div class="t">$([System.Net.WebUtility]::HtmlEncode($title))</div>
  $body
</li>
"@
        }

        $guideSection = @"
<div class="card">
  <h2>Guida operativa (action plan)</h2>
  <div class="muted">Passi consigliati, basati sull’ambiente rilevato, per rendere la soluzione operativa.</div>
  <ol class="guide" style="margin-top:12px;padding-left:18px">$($items -join "`n")</ol>
</div>
"@
    }

@"
<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>$SolutionName — Precheck Enterprise</title>
  <style>
    :root{
      --bg:#f7f8fb; --card:#ffffff; --text:#0f172a; --muted:rgba(15,23,42,.70);
      --border:rgba(15,23,42,.10); --shadow:0 14px 40px rgba(2,6,23,.12);
      --brand1:#1d4ed8; --brand2:#06b6d4;
      --ok:#16a34a; --warn:#f59e0b; --fail:#ef4444;
      --radius:16px;
      font-synthesis-weight:none;
    }
    *{box-sizing:border-box;font-family:Inter,Segoe UI,Arial,sans-serif}
    body{margin:0;background:radial-gradient(900px 420px at 15% 0%, rgba(29,78,216,.16), rgba(255,255,255,0) 60%),
                   radial-gradient(700px 380px at 85% 10%, rgba(6,182,212,.14), rgba(255,255,255,0) 60%), var(--bg);
         color:var(--text); padding:28px;}
    .wrap{max-width:1100px;margin:0 auto}
    .top{background:linear-gradient(135deg, rgba(29,78,216,.95), rgba(6,182,212,.88)); color:#fff;border-radius:var(--radius);
         padding:22px 22px 18px; box-shadow:var(--shadow); border:1px solid rgba(255,255,255,.18)}
    .brand{display:flex;gap:12px;align-items:center}
    .mark{width:44px;height:44px;border-radius:14px;background:linear-gradient(135deg,#0ea5e9,#22c55e);
          display:grid;place-items:center;font-weight:800;letter-spacing:.5px}
    h1{margin:0;font-size:20px;line-height:1.2}
    .sub{opacity:.90;font-size:13px;margin-top:2px}
    .meta{margin-top:14px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
    .meta .chip{background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.22);padding:7px 10px;border-radius:12px;font-size:12.5px}
    .pill{padding:7px 10px;border-radius:999px;font-size:12.5px;font-weight:700;border:1px solid rgba(255,255,255,.25)}
    .pill.ok{background:rgba(22,163,74,.22)} .pill.warn{background:rgba(245,158,11,.22)} .pill.fail{background:rgba(239,68,68,.22)}

    .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:14px}
    .kpi{background:rgba(255,255,255,.16);border:1px solid rgba(255,255,255,.22);border-radius:14px;padding:12px 12px 10px}
    .kpi .k{font-size:12px;opacity:.92}
    .kpi .v{font-size:20px;font-weight:800;margin-top:4px}

    .card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);box-shadow:0 10px 26px rgba(2,6,23,.08);
          padding:18px;margin-top:16px}
    .card h2{margin:0 0 10px;font-size:16px}
    .muted{color:var(--muted)}
    table{width:100%;border-collapse:separate;border-spacing:0;margin-top:10px;overflow:hidden;border:1px solid var(--border);border-radius:14px}
    th,td{padding:10px 12px;text-align:left;font-size:13px;border-bottom:1px solid var(--border);vertical-align:top}
    th{background:rgba(15,23,42,.04);font-weight:700}
    tr:last-child td{border-bottom:none}
    .badge{display:inline-block;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:700}
    .badge.pass{background:rgba(22,163,74,.12);color:var(--ok);border:1px solid rgba(22,163,74,.25)}
    .badge.warn{background:rgba(245,158,11,.12);color:var(--warn);border:1px solid rgba(245,158,11,.25)}
    .badge.fail{background:rgba(239,68,68,.12);color:var(--fail);border:1px solid rgba(239,68,68,.25)}
    .badge.skip{background:rgba(100,116,139,.10);color:rgba(100,116,139,1);border:1px solid rgba(100,116,139,.25)}
    .sev{font-weight:800;font-size:12px;padding:3px 8px;border-radius:10px;border:1px solid var(--border);display:inline-block}
    .sev-critical{background:rgba(239,68,68,.08);color:var(--fail)}
    .sev-high{background:rgba(245,158,11,.10);color:#b45309}
    .sev-medium{background:rgba(29,78,216,.08);color:var(--brand1)}
    .sev-low{background:rgba(100,116,139,.08);color:rgba(100,116,139,1)}
    .sev-info{background:rgba(6,182,212,.08);color:var(--brand2)}
    .t{font-weight:700}
    .s{color:var(--muted);margin-top:3px}
    details.legacy summary{cursor:pointer;font-weight:700}
    details.legacy{margin-top:14px}
    .legacy-body{margin-top:10px;border-top:1px solid var(--border);padding-top:12px}

    @media(max-width:900px){ .grid{grid-template-columns:repeat(2,1fr)} }
    @media(max-width:520px){ .grid{grid-template-columns:1fr} body{padding:16px} }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div class="brand">
        <div class="mark">SJ</div>
        <div>
          <h1>$SolutionName — Precheck Enterprise</h1>
          <div class="sub">Lutech SoftJam • Subscription: $([System.Net.WebUtility]::HtmlEncode($subName))</div>
        </div>
      </div>
      <div class="meta">
        <div class="chip">SubscriptionId: $([System.Net.WebUtility]::HtmlEncode($subId))</div>
        <div class="chip">Generated: $([System.Net.WebUtility]::HtmlEncode($ts))</div>
        <div class="$pill">Readiness: $score% • $levelText</div>
      </div>
      <div class="grid">
        <div class="kpi"><div class="k">$k1</div><div class="v">$v1</div></div>
        <div class="kpi"><div class="k">$k2</div><div class="v">$v2</div></div>
        <div class="kpi"><div class="k">$k3</div><div class="v">$v3</div></div>
        <div class="kpi"><div class="k">$k4</div><div class="v">$v4</div></div>
      </div>
    </div>

    <div class="card">
      <h2>Executive Summary</h2>
      <div class="muted">Sintesi dei principali rischi e azioni consigliate.</div>
      <div style="margin-top:12px">$AiHtml</div>
    </div>

    $guideSection

    <div class="card">
      <h2>Controls & Checks</h2>
      <div class="muted">Valutazione “enterprise readiness” con severità, stato e razionale.</div>
      <table>
        <thead>
          <tr><th>Sev</th><th>Status</th><th>Dettaglio</th></tr>
        </thead>
        <tbody>
          $checksHtml
        </tbody>
      </table>
      $legacySection
    </div>
  </div>
</body>
</html>
"@
}

function Invoke-EnterpriseOpenAIHtml {
    param(
        [Parameter(Mandatory)] [string] $SolutionName,
        [Parameter(Mandatory)] $Payload,
        [Parameter()] [int] $MaxTokens = 1300
    )

    $apiKey         = $env:AZURE_OPENAI_API_KEY
    $endpointBase   = $env:AZURE_OPENAI_ENDPOINT
    $deploymentName = $env:AZURE_OPENAI_DEPLOYMENT
    $openAiApiVer   = if ($env:AZURE_OPENAI_API_VERSION) { $env:AZURE_OPENAI_API_VERSION } else { '2025-01-01-preview' }

    if (-not $apiKey -or -not $endpointBase -or -not $deploymentName) {
        return '<p class="muted">AI disabilitata: configura AZURE_OPENAI_ENDPOINT / AZURE_OPENAI_DEPLOYMENT / AZURE_OPENAI_API_KEY.</p>'
    }

    $endpoint = ($endpointBase.TrimEnd('/') + "/openai/deployments/$deploymentName/chat/completions?api-version=$openAiApiVer")
    $dataJson = $Payload | ConvertTo-Json -Depth 10 -Compress

    $prompt = @"
Sei un Azure Solutions Architect enterprise.
Obiettivo: fornire un EXECUTIVE SUMMARY in italiano per la soluzione: $SolutionName.

Vincoli:
- output SOLO HTML (no markdown), max ~15 righe
- tono professionale, senza emoji
- includi: Top 5 rischi (priorità), Top 5 azioni (remediation), e una frase su readiness

INPUT JSON:
$dataJson
"@

    $headers = @{ 'Content-Type' = 'application/json'; 'api-key' = $apiKey }
    $body = @{
        messages = @(
            @{ role = 'system'; content = 'You are an expert Azure enterprise architect. Return only HTML.' }
            @{ role = 'user'; content = $prompt }
        )
        max_completion_tokens = $MaxTokens
    } | ConvertTo-Json -Depth 6

    $maxRetries = 5
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $endpoint -Method POST -Headers $headers -Body $body -TimeoutSec 120
            $html = $resp.choices[0].message.content
            if ($html) { return $html }
        } catch {
            $msg = $_.Exception.Message
            $statusCode = $null
            try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}

            if ($statusCode -eq 429 -or $statusCode -ge 500) {
                $sleep = [math]::Min(30, [math]::Pow(2, $i) + (Get-Random -Minimum 0 -Maximum 3))
                Start-Sleep -Seconds $sleep
                continue
            }
            return ('<p class="muted">AI non disponibile: ' + [System.Net.WebUtility]::HtmlEncode($msg) + '</p>')
        }
    }

    return '<p class="muted">AI non disponibile: rate limit o errore temporaneo.</p>'
}

Export-ModuleMember -Function `
    New-PrecheckCheck, `
    Get-PrecheckReadiness, `
    New-EnterpriseHtmlReport, `
    Invoke-EnterpriseOpenAIHtml

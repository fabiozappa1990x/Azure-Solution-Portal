$files = Get-ChildItem -Recurse -Filter "run.ps1" -Path "Azure Solution Portal\FunctionApp"
foreach ($file in $files) {
    Write-Host "Processing $($file.FullName)"
    $content = Get-Content $file.FullName -Raw
    
    # Remove CORS from OPTIONS
    $content = $content -replace "if \(`\$Request\.Method -eq 'OPTIONS'\) \{.*?StatusCode = 200.*?Headers = @\{.*?Access-Control-Allow-Origin.*?\}", "if (`$Request.Method -eq 'OPTIONS') {`n    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{`n        StatusCode = 200"
    
    # Remove CORS from corsHeaders or manual headers
    $content = $content -replace "'Access-Control-Allow-Origin'\s*=\s*'.*?'", ""
    $content = $content -replace "'Access-Control-Allow-Methods'\s*=\s*'.*?'", ""
    $content = $content -replace "'Access-Control-Allow-Headers'\s*=\s*'.*?'", ""
    
    # Clean up empty Header blocks or trailing commas
    $content = $content -replace "Headers = @\{\s+\}", "Headers = @{}"
    $content = $content -replace ",\s+\}", "`n        }"
    
    Set-Content $file.FullName -Value $content -Force
}

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$patchScript = Join-Path $scriptDir "patch_codex_gpt56.py"
$storeScript = Join-Path $scriptDir "patch-windows-store.ps1"
$configScript = Join-Path $scriptDir "configure_codex_gpt56.mjs"
$forwardedArgs = @($args)

function Has-Argument([string]$name) {
    return @($forwardedArgs | Where-Object { $_ -eq $name -or $_ -like "$name=*" }).Count -gt 0
}

function Get-ArgumentValue([string]$name) {
    for ($index = 0; $index -lt $forwardedArgs.Count; $index++) {
        $value = [string]$forwardedArgs[$index]
        if ($value -eq $name -and $index + 1 -lt $forwardedArgs.Count) {
            return [string]$forwardedArgs[$index + 1]
        }
        if ($value -like "$name=*") {
            return $value.Substring($name.Length + 1)
        }
    }
    return $null
}

function Quote-ProcessArgument([string]$value) {
    return '"' + $value.Replace('"', '\"') + '"'
}

function Invoke-Python([string]$filePath, [string[]]$baseArgs, [string[]]$pythonArgs) {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $filePath @baseArgs @pythonArgs | Out-Host
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldErrorActionPreference
    return $exitCode
}

function Invoke-StorePatch([string]$filePath, [string[]]$baseArgs) {
    $invocationFile = Join-Path $env:TEMP ("codex-gpt56-store-{0}.json" -f [guid]::NewGuid().ToString("N"))
    $invocation = [ordered]@{
        patchScript = $patchScript
        pythonPath = $filePath
        pythonBaseArgs = @($baseArgs)
        disableUltra = Has-Argument "--disable-ultra"
    }
    [System.IO.File]::WriteAllText(
        $invocationFile,
        ($invocation | ConvertTo-Json -Depth 4),
        [System.Text.UTF8Encoding]::new($true)
    )

    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
        $helperArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $storeScript,
            "-InvocationFile", $invocationFile
        )
        if ($isAdmin) {
            & powershell.exe @helperArgs | Out-Host
            return $LASTEXITCODE
        }

        Write-Host "Microsoft Store installation detected. Requesting UAC elevation..."
        $argumentLine = ($helperArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
        $process = Start-Process `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -FilePath "powershell.exe" `
            -ArgumentList $argumentLine
        return $process.ExitCode
    }
    finally {
        if (Test-Path -LiteralPath $invocationFile) {
            [System.IO.File]::Delete($invocationFile)
        }
    }
}

function Get-StoreLaunchIdentity {
    $package = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue
    if ($null -eq $package) {
        return $null
    }
    return "$($package.PackageFamilyName)!App"
}

$py = Get-Command py -ErrorAction SilentlyContinue
$python = Get-Command python -ErrorAction SilentlyContinue
$node = Get-Command node -ErrorAction SilentlyContinue

if ($null -ne $py) {
    $pythonPath = $py.Source
    $pythonBaseArgs = @("-3")
}
elseif ($null -ne $python) {
    $pythonPath = $python.Source
    $pythonBaseArgs = @()
}
elseif ($null -ne $node) {
    Write-Host "Python was not found. Running the Node.js configuration-only fallback."
    & $node.Source $configScript "--yes" @forwardedArgs
    exit $LASTEXITCODE
}
else {
    Write-Error "Neither Python nor Node.js was found. Install Python 3.10+ for the full Desktop patch, or Node.js 20+ for configuration-only mode."
    exit 2
}

$storePackage = Get-AppxPackage OpenAI.Codex -ErrorAction SilentlyContinue
$explicitApp = Get-ArgumentValue "--app"
$explicitStoreApp = $false
if ($null -ne $explicitApp -and $null -ne $storePackage) {
    try {
        $explicitStoreApp = [System.IO.Path]::GetFullPath($explicitApp).StartsWith(
            [System.IO.Path]::GetFullPath($storePackage.InstallLocation),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        $explicitStoreApp = $explicitApp -like "*\WindowsApps\*"
    }
}

$storeMode = $null -ne $storePackage `
    -and -not (Has-Argument "--output") `
    -and -not (Has-Argument "--catalog-only") `
    -and -not (Has-Argument "--verify-only") `
    -and -not (Has-Argument "--self-test") `
    -and -not (Has-Argument "--help") `
    -and -not (Has-Argument "-h") `
    -and ($null -eq $explicitApp -or $explicitStoreApp)

if ($storeMode -and -not (Has-Argument "--dry-run")) {
    $exitCode = Invoke-StorePatch $pythonPath $pythonBaseArgs
    if ($exitCode -ne 0) {
        exit $exitCode
    }

    if (-not (Has-Argument "--desktop-only")) {
        Write-Host "Updating the current user's model catalog and config..."
        $catalogArgs = @($patchScript, "--catalog-only", "--yes") + $forwardedArgs
        $exitCode = Invoke-Python $pythonPath $pythonBaseArgs $catalogArgs
        if ($exitCode -ne 0) {
            exit $exitCode
        }

        Write-Host "Verifying the deployed package and runtime model list..."
        $installedPackage = Get-AppxPackage OpenAI.Codex -ErrorAction Stop
        $tiers = Get-ArgumentValue "--tiers"
        if ([string]::IsNullOrWhiteSpace($tiers)) {
            $tiers = "sol,terra,luna"
        }
        $verifyArgs = @(
            $patchScript,
            "--verify-only",
            "--app", (Join-Path $installedPackage.InstallLocation "app"),
            "--tiers", $tiers
        )
        if (Has-Argument "--disable-ultra") {
            $verifyArgs += "--disable-ultra"
        }
        $exitCode = Invoke-Python $pythonPath $pythonBaseArgs $verifyArgs
        if ($exitCode -ne 0) {
            exit $exitCode
        }
    }

    $launchIdentity = Get-StoreLaunchIdentity
    if ([string]::IsNullOrWhiteSpace($launchIdentity)) {
        Write-Host "WARNING: Could not resolve the installed Store shortcut identity; launch skipped."
    }
    else {
        Write-Host "Launching Store shortcut identity: $launchIdentity"
        Start-Process explorer.exe "shell:AppsFolder\$launchIdentity"
    }
    exit 0
}

$directArgs = @($patchScript, "--yes") + $forwardedArgs
exit (Invoke-Python $pythonPath $pythonBaseArgs $directArgs)

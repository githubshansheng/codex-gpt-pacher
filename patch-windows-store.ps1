param(
    [Parameter(Mandatory = $true)]
    [string]$InvocationFile
)

$ErrorActionPreference = "Stop"

function Invoke-Native([string]$filePath, [string[]]$arguments, [string]$errorMessage) {
    & $filePath @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$errorMessage (exit code $LASTEXITCODE)"
    }
}

function Get-WindowsSdkArchitecture {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_IDENTIFIER -like "*ARM*") {
        return "arm64"
    }
    return "x64"
}

function Get-WindowsSdkBinRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $environmentRoots = @(
        $env:WindowsSdkDir,
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10" }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Windows Kits\10" })
    )
    foreach ($root in $environmentRoots) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $binRoot = if ([System.IO.Path]::GetFileName($root.TrimEnd('\')) -eq "bin") {
                $root
            }
            else {
                Join-Path $root "bin"
            }
            if ((Test-Path -LiteralPath $binRoot) -and -not $roots.Contains($binRoot)) {
                $roots.Add($binRoot)
            }
        }
    }

    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
    )) {
        try {
            $kitsRoot = [string](Get-ItemPropertyValue -LiteralPath $registryPath -Name "KitsRoot10" -ErrorAction Stop)
            $binRoot = Join-Path $kitsRoot "bin"
            if ((Test-Path -LiteralPath $binRoot) -and -not $roots.Contains($binRoot)) {
                $roots.Add($binRoot)
            }
        }
        catch {
        }
    }
    return @($roots)
}

function Find-WindowsSdkTool([string]$name, [string[]]$additionalRoots = @()) {
    if ($additionalRoots.Count -eq 0) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    $architecture = Get-WindowsSdkArchitecture
    $roots = if ($additionalRoots.Count -gt 0) {
        @($additionalRoots)
    }
    else {
        @(Get-WindowsSdkBinRoots)
    }
    $tools = foreach ($root in $roots | Select-Object -Unique) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.Name -eq $architecture }
        }
    }
    $tool = $tools |
        Sort-Object `
            @{ Expression = {
                try { [version]$_.VersionInfo.FileVersion }
                catch { [version]"0.0" }
            }; Descending = $true }, `
            @{ Expression = { $_.FullName }; Descending = $true } |
        Select-Object -First 1
    if ($null -ne $tool) {
        return $tool.FullName
    }
    return $null
}

function Install-PortableWindowsSdkBuildTools {
    $packageId = "microsoft.windows.sdk.buildtools"
    $apiRoot = "https://api.nuget.org/v3-flatcontainer/$packageId"
    $cacheBase = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:LOCALAPPDATA "CodexGPT56Patcher\tools\Microsoft.Windows.SDK.BuildTools"
    }
    else {
        Join-Path $env:TEMP "CodexGPT56Patcher\tools\Microsoft.Windows.SDK.BuildTools"
    }
    [System.IO.Directory]::CreateDirectory($cacheBase) | Out-Null

    $cachedRoots = Get-ChildItem -LiteralPath $cacheBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ".complete") } |
        Sort-Object {
            try { [version]$_.Name }
            catch { [version]"0.0" }
        } -Descending
    foreach ($cachedRoot in $cachedRoots) {
        $cachedMakeAppx = Find-WindowsSdkTool "makeappx.exe" @($cachedRoot.FullName)
        $cachedSignTool = Find-WindowsSdkTool "signtool.exe" @($cachedRoot.FullName)
        if ($null -ne $cachedMakeAppx -and $null -ne $cachedSignTool) {
            Write-Host "Using cached Microsoft.Windows.SDK.BuildTools $($cachedRoot.Name)"
            return $cachedRoot.FullName
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "Windows SDK packaging tools were not found; checking the official Microsoft Build Tools package..."
        $index = Invoke-RestMethod -UseBasicParsing -Uri "$apiRoot/index.json"
        $versions = @($index.versions | Where-Object { $_ -notmatch '-' })
        if ($versions.Count -eq 0) {
            throw "The NuGet package did not report a stable version."
        }
        # The 26100 SDK build tools run on both supported Windows 10 and Windows 11 hosts.
        # Prefer that family over a future SDK whose binaries may require a newer OS.
        $compatibleVersions = @($versions | Where-Object { $_ -like "10.0.26100.*" })
        if ($compatibleVersions.Count -gt 0) {
            $versions = $compatibleVersions
        }
        $version = $versions |
            Sort-Object { [version]$_ } -Descending |
            Select-Object -First 1
    }
    catch {
        throw "makeappx.exe and signtool.exe were not found, and the official Microsoft Build Tools package could not be queried. Check the internet connection or install the Windows 10/11 SDK. $($_.Exception.Message)"
    }

    $toolRoot = Join-Path $cacheBase $version
    $marker = Join-Path $toolRoot ".complete"
    if (-not (Test-Path -LiteralPath $marker)) {
        $downloadRoot = Join-Path $env:TEMP ("codex-gpt56-sdk-{0}" -f [guid]::NewGuid().ToString("N"))
        $packagePath = Join-Path $downloadRoot "$packageId.$version.nupkg"
        $zipPath = Join-Path $downloadRoot "$packageId.$version.zip"
        [System.IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
        [System.IO.Directory]::CreateDirectory($toolRoot) | Out-Null
        try {
            $packageUrl = "$apiRoot/$version/$packageId.$version.nupkg"
            Write-Host "Downloading Microsoft.Windows.SDK.BuildTools $version (one-time cache)..."
            Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $packagePath
            Copy-Item -LiteralPath $packagePath -Destination $zipPath -Force
            Expand-Archive -LiteralPath $zipPath -DestinationPath $toolRoot -Force

            $architecture = Get-WindowsSdkArchitecture
            $makeAppx = Find-WindowsSdkTool "makeappx.exe" @($toolRoot)
            $signTool = Find-WindowsSdkTool "signtool.exe" @($toolRoot)
            if ($null -eq $makeAppx -or $null -eq $signTool -or
                -not $makeAppx.StartsWith($toolRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not $signTool.StartsWith($toolRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "The downloaded package does not contain the required $architecture tools."
            }
            [System.IO.File]::WriteAllText($marker, $version, [System.Text.UTF8Encoding]::new($false))
        }
        catch {
            throw "Failed to download or extract Microsoft.Windows.SDK.BuildTools $version. Install the Windows 10/11 SDK or retry with internet access. $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -LiteralPath $packagePath) {
                [System.IO.File]::Delete($packagePath)
            }
            if (Test-Path -LiteralPath $zipPath) {
                [System.IO.File]::Delete($zipPath)
            }
            if (Test-Path -LiteralPath $downloadRoot) {
                [System.IO.Directory]::Delete($downloadRoot, $false)
            }
        }
    }
    return $toolRoot
}

function Resolve-WindowsSdkTools {
    $makeAppx = Find-WindowsSdkTool "makeappx.exe"
    $signTool = Find-WindowsSdkTool "signtool.exe"
    if ($null -eq $makeAppx -or $null -eq $signTool) {
        $portableRoot = Install-PortableWindowsSdkBuildTools
        $makeAppx = Find-WindowsSdkTool "makeappx.exe" @($portableRoot)
        $signTool = Find-WindowsSdkTool "signtool.exe" @($portableRoot)
    }
    if ($null -eq $makeAppx -or $null -eq $signTool) {
        throw "makeappx.exe or signtool.exe could not be resolved. Install the Windows 10/11 SDK and retry."
    }
    Write-Host "Using MakeAppx: $makeAppx"
    Write-Host "Using SignTool: $signTool"
    return @{
        MakeAppx = $makeAppx
        SignTool = $signTool
    }
}

function Get-NextPackageVersion([version]$version) {
    if ($version.Revision -lt 65535) {
        return [version]::new($version.Major, $version.Minor, $version.Build, $version.Revision + 1)
    }
    if ($version.Build -lt 65535) {
        return [version]::new($version.Major, $version.Minor, $version.Build + 1, 0)
    }
    throw "The package version cannot be incremented: $version"
}

function Select-WorkDrive([long]$minimumFreeBytes) {
    $drive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Free -ge $minimumFreeBytes -and (Test-Path -LiteralPath $_.Root) } |
        Sort-Object Free -Descending |
        Select-Object -First 1
    if ($null -eq $drive) {
        $requiredGb = [math]::Ceiling($minimumFreeBytes / 1GB)
        throw "No writable drive has at least $requiredGb GB free for the MSIX build."
    }
    return $drive
}

function Get-OrCreateSigningCertificate([string]$publisher, [string]$certificatePath) {
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object {
            $_.Subject -eq $publisher -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt (Get-Date).AddDays(7)
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
    if ($null -eq $certificate) {
        $certificate = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $publisher `
            -KeyUsage DigitalSignature `
            -FriendlyName "Codex GPT56 Local MSIX" `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @(
                "2.5.29.37={text}1.3.6.1.5.5.7.3.3",
                "2.5.29.19={text}"
            )
    }

    $trusted = Get-ChildItem Cert:\LocalMachine\TrustedPeople |
        Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
        Select-Object -First 1
    if ($null -eq $trusted) {
        Export-Certificate -Cert $certificate -FilePath $certificatePath -Force | Out-Null
        Import-Certificate -FilePath $certificatePath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
    }
    return $certificate
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Administrator privileges are required for Microsoft Store package deployment."
}
if (-not (Test-Path -LiteralPath $InvocationFile)) {
    throw "Invocation file was not found: $InvocationFile"
}

$invocationJson = [System.IO.File]::ReadAllText(
    $InvocationFile,
    [System.Text.UTF8Encoding]::new($true, $true)
)
$invocation = $invocationJson | ConvertFrom-Json
$patchScript = [string]$invocation.patchScript
$pythonPath = [string]$invocation.pythonPath
$pythonBaseArgs = @($invocation.pythonBaseArgs | ForEach-Object { [string]$_ })
$disableUltra = $false
if ($invocation.PSObject.Properties.Name -contains "disableUltra") {
    $disableUltra = [bool]$invocation.disableUltra
}
elseif ($invocation.PSObject.Properties.Name -contains "enableUltra") {
    $disableUltra = -not [bool]$invocation.enableUltra
}

$package = Get-AppxPackage OpenAI.Codex -ErrorAction Stop
$sourceRoot = [string]$package.InstallLocation
$sourceApp = Join-Path $sourceRoot "app"
$sourceManifest = Join-Path $sourceRoot "AppxManifest.xml"
if (-not (Test-Path -LiteralPath $sourceManifest)) {
    throw "The installed Microsoft Store manifest was not found: $sourceManifest"
}

$systemDrive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':')
$minimumSystemFree = 3GB
if ($systemDrive.Free -lt $minimumSystemFree) {
    $freeGb = [math]::Round($systemDrive.Free / 1GB, 2)
    throw "The system drive has only $freeGb GB free. Free at least 3 GB before installing the patched MSIX update."
}

$sdkTools = Resolve-WindowsSdkTools
$makeAppx = [string]$sdkTools.MakeAppx
$signTool = [string]$sdkTools.SignTool
$packageArchitecture = Get-WindowsSdkArchitecture

$workDrive = Select-WorkDrive 8GB
$artifactRoot = Join-Path $workDrive.Root "CodexGPT56Patcher"
$packageRoot = Join-Path $artifactRoot "packages"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$workRoot = Join-Path $artifactRoot ("build-{0}" -f $timestamp)
$buildRoot = Join-Path $workRoot "package"
$certificatePath = Join-Path $workRoot "CodexGPT56Local.cer"
[System.IO.Directory]::CreateDirectory($packageRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($buildRoot) | Out-Null

Write-Host "Building a same-identity Microsoft Store update on $($workDrive.Root)"
Write-Host "Installed package: $($package.PackageFullName)"

$robocopyArgs = @(
    $sourceRoot,
    $buildRoot,
    "/E",
    "/COPY:DAT",
    "/DCOPY:DAT",
    "/R:1",
    "/W:1",
    "/NFL",
    "/NDL",
    "/NJH",
    "/NJS",
    "/NP",
    "/XD",
    "app",
    "AppxMetadata",
    "microsoft.system.package.metadata",
    "/XF",
    "AppxBlockMap.xml",
    "AppxSignature.p7x"
)
& robocopy.exe @robocopyArgs | Out-Host
if ($LASTEXITCODE -gt 7) {
    throw "Failed to copy the Microsoft Store package shell (robocopy exit code $LASTEXITCODE)."
}

$patchedApp = Join-Path $buildRoot "app"
$patchArgs = @($pythonBaseArgs) + @(
    $patchScript,
    "--app", $sourceApp,
    "--output", $patchedApp,
    "--desktop-only",
    "--yes"
)
if ($disableUltra) {
    $patchArgs += "--disable-ultra"
}
Invoke-Native $pythonPath $patchArgs "Desktop ASAR patch failed"

$resources = Join-Path $patchedApp "resources"
$originalAsar = Join-Path $resources "app.asar.original"
if (Test-Path -LiteralPath $originalAsar) {
    [System.IO.File]::Delete($originalAsar)
}
Get-ChildItem -LiteralPath $resources -Filter "app.asar.backup-*" -File -ErrorAction SilentlyContinue |
    ForEach-Object { [System.IO.File]::Delete($_.FullName) }

[xml]$manifest = Get-Content -LiteralPath (Join-Path $buildRoot "AppxManifest.xml") -Raw
$currentVersion = [version]$manifest.Package.Identity.Version
$newVersion = Get-NextPackageVersion $currentVersion
$manifest.Package.Identity.Version = $newVersion.ToString()
$publisher = [string]$manifest.Package.Identity.Publisher
$manifestSettings = [System.Xml.XmlWriterSettings]::new()
$manifestSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$manifestSettings.Indent = $true
$writer = [System.Xml.XmlWriter]::Create((Join-Path $buildRoot "AppxManifest.xml"), $manifestSettings)
try {
    $manifest.Save($writer)
}
finally {
    $writer.Dispose()
}

$certificate = Get-OrCreateSigningCertificate $publisher $certificatePath
$msixPath = Join-Path $packageRoot ("OpenAI.Codex.GPT56_{0}_{1}.msix" -f $newVersion, $packageArchitecture)
if (Test-Path -LiteralPath $msixPath) {
    [System.IO.File]::Delete($msixPath)
}

Invoke-Native $makeAppx @("pack", "/d", $buildRoot, "/p", $msixPath, "/o") "MSIX packaging failed"
Invoke-Native $signTool @("sign", "/fd", "SHA256", "/sha1", $certificate.Thumbprint, $msixPath) "MSIX signing failed"
Invoke-Native $signTool @("verify", "/pa", $msixPath) "MSIX signature verification failed"

Get-Process ChatGPT, Codex -ErrorAction SilentlyContinue | Stop-Process -Force
$unlockKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
$unlockName = "AllowDevelopmentWithoutDevLicense"
$hadUnlockValue = $false
$oldUnlockValue = $null
try {
    $oldUnlockValue = Get-ItemPropertyValue -LiteralPath $unlockKey -Name $unlockName -ErrorAction Stop
    $hadUnlockValue = $true
}
catch {
}
New-Item -Path $unlockKey -Force | Out-Null
Set-ItemProperty -LiteralPath $unlockKey -Name $unlockName -Type DWord -Value 1
try {
    Add-AppxPackage `
        -Path $msixPath `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion `
        -RetainFilesOnFailure
}
finally {
    if ($hadUnlockValue) {
        Set-ItemProperty -LiteralPath $unlockKey -Name $unlockName -Type DWord -Value $oldUnlockValue
    }
    else {
        Remove-ItemProperty -LiteralPath $unlockKey -Name $unlockName -ErrorAction SilentlyContinue
    }
}

$installed = Get-AppxPackage OpenAI.Codex -ErrorAction Stop
if ([version]$installed.Version -ne $newVersion) {
    throw "The installed package version is $($installed.Version), expected $newVersion."
}
$builtAsar = Join-Path $patchedApp "resources\app.asar"
$installedAsar = Join-Path $installed.InstallLocation "app\resources\app.asar"
$builtHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $builtAsar).Hash
$installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedAsar).Hash
if ($builtHash -ne $installedHash) {
    throw "The installed app.asar hash does not match the patched build."
}

$metadataRoot = Join-Path $env:USERPROFILE ".codex\backups\codex-gpt56\store-packages"
[System.IO.Directory]::CreateDirectory($metadataRoot) | Out-Null
$metadataPath = Join-Path $metadataRoot ("{0}.json" -f $timestamp)
$metadata = [ordered]@{
    previousPackage = $package.PackageFullName
    installedPackage = $installed.PackageFullName
    packageFamilyName = $installed.PackageFamilyName
    launchIdentity = "$($installed.PackageFamilyName)!App"
    architecture = $packageArchitecture
    msixPath = $msixPath
    installedAsarSha256 = $installedHash
    signingCertificateThumbprint = $certificate.Thumbprint
    createdAt = [DateTimeOffset]::Now.ToString("O")
}
[System.IO.File]::WriteAllText(
    $metadataPath,
    ($metadata | ConvertTo-Json -Depth 4),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Microsoft Store patch installed successfully."
Write-Host "Package: $($installed.PackageFullName)"
Write-Host "Original shortcut identity: $($installed.PackageFamilyName)!App"
Write-Host "MSIX artifact: $msixPath"
Write-Host "Installed ASAR SHA256: $installedHash"

try {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
    Write-Host "Cleaned temporary build directory: $workRoot"
}
catch {
    Write-Host "WARNING: Could not remove temporary build directory: $workRoot"
    Write-Host $_.Exception.Message
}

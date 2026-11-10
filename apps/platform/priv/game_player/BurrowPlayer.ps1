param([string]$ConfigPath = "$PSScriptRoot\player.json", [string]$DataRoot = "", [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$origin = [Uri]$config.base_url
if (($origin.Scheme -ne 'https' -and -not $origin.IsLoopback) -or $origin.UserInfo -or $origin.AbsolutePath -ne '/') { throw 'Invalid Burrow address.' }
if ($config.slug -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid game.' }
if (-not $DataRoot) { $DataRoot = Join-Path $env:LOCALAPPDATA "BurrowPlayer\$($config.slug)" }
[IO.Directory]::CreateDirectory($DataRoot) | Out-Null
$script:busy = $false
function Get-Url([string]$path) { return $origin.GetLeftPart([UriPartial]::Authority) + $path }
function Get-Release {
    $request = [Net.HttpWebRequest]::Create((Get-Url "/games/$($config.slug)/updates"))
    $request.AllowAutoRedirect = $false; $request.Timeout = 30000
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $release = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
    if ($release.version -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$' -or $release.version -in @('.', '..') -or $release.sha256 -notmatch '^[a-f0-9]{64}$' -or $release.byte_size -lt 1 -or $release.byte_size -gt 1073741824) { throw 'Invalid release information.' }
    if ($release.download_path -cne "/games/$($config.slug)/player/releases/$($release.version)" -or $release.launch_path -cne 'Play Voltron.bat') { throw 'Invalid release location.' }
    return $release
}
function Get-Installed {
    $path = Join-Path $DataRoot 'current.json'
    if (Test-Path -LiteralPath $path) { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    return $null
}
function Set-Status([string]$text) {
    if ($CheckOnly) { Write-Host $text } else { $status.Text = $text; $status.Refresh() }
}
function Update-Game {
    Set-Status 'Checking for updates...'
    $release = Get-Release
    $installed = Get-Installed
    $folder = Join-Path $DataRoot "versions\$($release.version)-$($release.sha256.Substring(0,12))"
    $launch = Join-Path $folder $release.launch_path
    if ($installed -and $installed.version -eq $release.version -and $installed.sha256 -eq $release.sha256 -and (Test-Path -LiteralPath $launch)) {
        Set-Status "Ready to play - $($release.version)"; return $launch
    }
    $staging = Join-Path $DataRoot ('.update-' + [Guid]::NewGuid().ToString('N'))
    $zipPath = "$staging.zip"
    try {
        Set-Status "Downloading $($release.version)..."
        $request = [Net.HttpWebRequest]::Create((Get-Url $release.download_path))
        $request.AllowAutoRedirect = $false; $request.Timeout = 30000; $request.ReadWriteTimeout = 30000
        $request.Headers['Authorization'] = 'Bearer ' + $config.token
        $response = $request.GetResponse()
        try {
            if ([int]$response.StatusCode -ne 200) { throw 'Download was not accepted.' }
            $inputStream = $response.GetResponseStream(); $output = [IO.File]::Create($zipPath)
            try {
                $buffer = New-Object byte[] 65536; $total = 0L
                while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $count
                    if ($total -gt $release.byte_size) { throw 'Download size mismatch.' }
                    $output.Write($buffer, 0, $count)
                }
            } finally { $output.Dispose(); $inputStream.Dispose() }
        } finally { $response.Dispose() }
        if ((Get-Item -LiteralPath $zipPath).Length -ne $release.byte_size -or (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $release.sha256) { throw 'Download verification failed. Your installed version is unchanged.' }
        Set-Status 'Installing verified update...'
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $prefix = [IO.Path]::GetFullPath($staging) + [IO.Path]::DirectorySeparatorChar
            $expanded = 0L
            foreach ($entry in $archive.Entries) {
                $target = [IO.Path]::GetFullPath((Join-Path $staging $entry.FullName))
                $expanded += $entry.Length
                if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':') -or $expanded -gt 2147483648) { throw 'Invalid game archive.' }
            }
        } finally { $archive.Dispose() }
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $staging)
        if (-not (Test-Path -LiteralPath (Join-Path $staging $release.launch_path))) { throw 'Game start file is missing.' }
        [IO.Directory]::CreateDirectory((Split-Path $folder)) | Out-Null
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $staging -Recurse -Force } else { Move-Item -LiteralPath $staging -Destination $folder }
        $state = @{version=$release.version; sha256=$release.sha256; folder=$folder}
        $temp = Join-Path $DataRoot 'current.next.json'; $current = Join-Path $DataRoot 'current.json'
        $state | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
        if (Test-Path -LiteralPath $current) { [IO.File]::Replace($temp, $current, (Join-Path $DataRoot "current.previous.json")) } else { [IO.File]::Move($temp, $current) }
        Set-Status "Ready to play - $($release.version)"
        return $launch
    } finally {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}
# One updater per game; a second click cannot replace the active version pointer.
$mutex = New-Object Threading.Mutex($false, ('Local\BurrowPlayer-' + $config.slug))
if (-not $mutex.WaitOne(0)) { throw 'Burrow Player is already open for this game.' }
try {
    if ($CheckOnly) { $result = Update-Game; Write-Output "INSTALLED $result"; exit 0 }
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object Windows.Forms.Form; $form.Text = 'Voltron - Burrow Player'; $form.Size = New-Object Drawing.Size(470,330); $form.StartPosition='CenterScreen'; $form.BackColor=[Drawing.Color]::FromArgb(20,22,28); $form.ForeColor=[Drawing.Color]::White
    $title = New-Object Windows.Forms.Label; $title.Text='VOLTRON'; $title.Location=New-Object Drawing.Point(24,20); $title.Size=New-Object Drawing.Size(410,40); $title.Font=New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold); $form.Controls.Add($title)
    $status = New-Object Windows.Forms.Label; $status.Text='Play checks for updates before launching.'; $status.Location=New-Object Drawing.Point(24,68); $status.Size=New-Object Drawing.Size(410,55); $form.Controls.Add($status)
    function New-Button($text,$x,$y,$width,$action) {
        $b=New-Object Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object Drawing.Point($x,$y); $b.Size=New-Object Drawing.Size($width,42); $b.FlatStyle='Flat'; $b.Add_Click($action); $form.Controls.Add($b); return $b
    }
    $play=New-Button 'Play' 24 130 200 {
        try { $play.Enabled=$false; $update.Enabled=$false; $launch=Update-Game; Start-Process -FilePath $launch -WorkingDirectory (Split-Path $launch) }
        catch { $status.Text='Update failed. You can still play the installed version, or renew sign-in on the game page.'; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Could not update') | Out-Null }
        finally { $play.Enabled=$true; $update.Enabled=$true }
    }; $play.BackColor=[Drawing.Color]::FromArgb(244,119,33); $play.ForeColor=[Drawing.Color]::Black
    $update=New-Button 'Check for updates' 236 130 200 {
        try { $play.Enabled=$false; $update.Enabled=$false; $null=Update-Game }
        catch { $status.Text='Update failed. Your installed version is unchanged.'; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Could not update') | Out-Null }
        finally { $play.Enabled=$true; $update.Enabled=$true }
    }
    $null=New-Button 'Chat / renew sign-in' 24 188 200 { Start-Process (Get-Url "/games/$($config.slug)?tab=community") }
    $null=New-Button 'Play installed version' 236 188 200 {
        try { $installed=Get-Installed; if (-not $installed) { throw 'Install the game using Play first.' }; $launch=Join-Path $installed.folder 'Play Voltron.bat'; Start-Process -FilePath $launch -WorkingDirectory $installed.folder }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message) | Out-Null }
    }
    [Windows.Forms.Application]::Run($form)
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }

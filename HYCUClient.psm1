<#
================================================================================
 HYCU AD Recovery Tool - HYCU REST client
 --------------------------------------------------------------------------------
 Talks to the HYCU controller so the tool can:
   - authenticate (Basic or API token/key)              -> Connect-HYCUController
   - browse protected VMs                                -> Get-HYCUProtectedVM
   - browse a VM's restore points                        -> Get-HYCURestorePoint
   - track a HYCU job                                    -> Get-HYCUJob / Wait-HYCUJob
   - orchestrate retrieval of C:\Windows\NTDS
     (file-level restore) to a share, then watch that
     share until ntds.dit is available                   -> Start-HYCUFileLevelRestore
                                                             Wait-HYCURestoredNtds

 Start-HYCUFileLevelRestore returns a folder ready to pass to
 Connect-HYCUADSnapshot -SourcePath (HYCUADRecovery.psm1 engine).

 HYCU REST API (verified against a live controller; field names may vary by version):
   Base    : https://<controller>:8443/rest/<version>/   (default version v1.0)
   Auth    : Bearer token (Authorization: Bearer <token>) on recent controllers; some
             deployments accept Basic (Authorization: Basic base64(user:pwd)).
   Envelope: { version, metadata, message, entities }. message.title carries the status
             (e.g. 'vm.read.ok', 'error.unauthorized'). Pagination uses metadata + entities.
   GET /vms                      -> protected VMs (paged pageSize/pageNumber)
   GET /vms/{uuid}/backups       -> restore points
   GET /jobs/{uuid}              -> job state

 IMPORTANT - file-level restore: HYCU drives granular file restore from its UI/agent; there
 is no guaranteed public REST endpoint to trigger it. The tool therefore favors the
 "share handoff" (reliable, version-independent): HYCU restores C:\Windows\NTDS to a share
 and the tool watches that share. A best-effort REST trigger is available if you set
 HycuRestoreFilesUriTemplate (Set-HYCUADConfig).

 NOTE (TLS): Windows PowerShell 5.1 / .NET Framework can fail the TLS handshake against some
 controllers. TLS 1.2 is forced below; if the handshake still fails, run under PowerShell 7
 or shell out to curl.exe.
================================================================================
#>
#requires -Version 5.1

# TLS is raised to 1.2 by Set-HYCUTls12, which Invoke-HYCURest calls before every HTTPS request -
# that is the single source of truth (no separate import-time mutation to drift out of sync).

# ----------------------------------------------------------------------------
# Logging: delegate to the engine's Write-HYCULog if present, else Write-*.
# ----------------------------------------------------------------------------
function Write-HYCUClientLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO'
    )
    if ($null -eq $Message) { $Message = '' }
    if (Get-Command -Name Write-HYCULog -ErrorAction SilentlyContinue) {
        Write-HYCULog -Message $Message -Level $Level
    } else {
        switch ($Level) {
            'ERROR'  { Write-Host $Message -ForegroundColor Red }
            'WARN'   { Write-Host $Message -ForegroundColor Yellow }
            'SUCCESS'{ Write-Host $Message -ForegroundColor Green }
            'DEBUG'  { Write-Verbose $Message }
            default  { Write-Host $Message }
        }
    }
}

# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------
function ConvertFrom-HYCUSecureString {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-HYCUFirstProperty {
    # Returns the first non-empty property among candidate names. Null-safe and untyped on
    # purpose: HYCU responses vary by version, and a typed [pscustomobject] param could throw a
    # coercion ArgumentException on unexpected shapes.
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject -and $Object.PSObject.Properties[$n] -and $null -ne $Object.$n -and "$($Object.$n)" -ne '') {
            return $Object.$n
        }
    }
    return $null
}

function Get-HYCUConfigValue {
    # Reads an engine config value (if the module is loaded), else $Default.
    param([string]$Key, $Default)
    if (Get-Command -Name Get-HYCUADConfig -ErrorAction SilentlyContinue) {
        $cfg = Get-HYCUADConfig
        if ($cfg.Contains($Key) -and $null -ne $cfg[$Key] -and "$($cfg[$Key])" -ne '') { return $cfg[$Key] }
    }
    return $Default
}

function ConvertTo-HYCUDateTime {
    # HYCU timestamps come as Unix epoch (milliseconds or seconds). Convert to a local
    # DateTime for display/sorting; pass through anything that is not a numeric epoch.
    param($Value)
    if ($null -eq $Value) { return $null }
    $n = 0L
    if ([Int64]::TryParse([string]$Value, [ref]$n)) {
        if ($n -gt 1000000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($n).LocalDateTime }
        if ($n -gt 1000000000)    { return [DateTimeOffset]::FromUnixTimeSeconds($n).LocalDateTime }
    }
    return $Value
}

# ----------------------------------------------------------------------------
# Connection / REST session
# ----------------------------------------------------------------------------
function Connect-HYCUController {
    <#
    .SYNOPSIS
      Opens and validates a session to the HYCU controller.
    .DESCRIPTION
      Builds the authentication header (Basic or token) and returns a reusable session
      object. The session is validated with a lightweight GET /vms?pageSize=1 call.
    .PARAMETER Credential
      Credentials for Basic authentication (-AuthMode Basic).
    .PARAMETER ApiToken
      API token/key (SecureString) for token authentication (-AuthMode Token).
    .EXAMPLE
      $h = Connect-HYCUController -Server hycu.corp.local -Credential (Get-Credential) -SkipCertificateCheck
    .EXAMPLE
      $h = Connect-HYCUController -Server hycu.corp.local -AuthMode Token -ApiToken $secureToken
    #>
    [CmdletBinding()]
    param(
        [string]$Server = (Get-HYCUConfigValue 'HycuServer' ''),
        [int]$Port = [int](Get-HYCUConfigValue 'HycuPort' 8443),
        [string]$ApiVersion = (Get-HYCUConfigValue 'HycuApiVersion' 'v1.0'),
        [string]$BaseUrl,                                   # full override (else https://Server:Port/rest/ApiVersion)
        [ValidateSet('Basic','Token')][string]$AuthMode = (Get-HYCUConfigValue 'HycuAuthMode' 'Basic'),
        [System.Management.Automation.PSCredential]$Credential,
        [System.Security.SecureString]$ApiToken,
        [string]$TokenHeader = (Get-HYCUConfigValue 'HycuTokenHeader' 'Authorization'),
        [string]$TokenScheme = (Get-HYCUConfigValue 'HycuTokenScheme' 'Bearer'),
        [switch]$SkipCertificateCheck,
        [switch]$NoValidate
    )

    # Mode inference: a token supplied without an explicit -AuthMode => Token.
    if ($ApiToken -and -not $PSBoundParameters.ContainsKey('AuthMode')) { $AuthMode = 'Token' }
    if (-not $BaseUrl) {
        if (-not $Server) { throw "No HYCU controller specified (use -Server or Set-HYCUADConfig -HycuServer ...)." }
        $BaseUrl = "https://{0}:{1}/rest/{2}" -f $Server, $Port, $ApiVersion
    }
    $BaseUrl = $BaseUrl.TrimEnd('/')

    # Authentication header
    $headers = @{ 'Accept' = 'application/json' }
    switch ($AuthMode) {
        'Basic' {
            if (-not $Credential) { throw "Basic mode: -Credential is required." }
            $pair  = "{0}:{1}" -f $Credential.UserName, $Credential.GetNetworkCredential().Password
            $b64   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
            $headers['Authorization'] = "Basic $b64"
        }
        'Token' {
            if (-not $ApiToken) { throw "Token mode: -ApiToken (SecureString) is required." }
            $tok = ConvertFrom-HYCUSecureString $ApiToken
            $headers[$TokenHeader] = if ($TokenScheme) { "$TokenScheme $tok" } else { $tok }
        }
    }

    # Self-signed certificates are the norm on HYCU controllers, so certificate validation is
    # skipped by default. An explicit -SkipCertificateCheck:$false (or HycuSkipCertCheck $false)
    # re-enables validation for controllers that present a CA-trusted certificate.
    $skip = if ($PSBoundParameters.ContainsKey('SkipCertificateCheck')) { [bool]$SkipCertificateCheck }
            else { [bool](Get-HYCUConfigValue 'HycuSkipCertCheck' $true) }

    # Windows PowerShell 5.1: no per-request -SkipCertificateCheck. Instead of a blanket global
    # callback (which would disable validation for EVERY HTTPS connection in the process and never be
    # restored), scope the bypass to the HYCU controller host(s) only. When validation is re-enabled
    # (skip=$false), clear any bypass a previous connection may have installed, so it does not leak.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if ($skip) {
            try {
                if (-not $script:HYCUBypassHosts) {
                    $script:HYCUBypassHosts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                }
                # Key the bypass on the ACTUAL host: with only -BaseUrl supplied, $Server is empty and
                # an '' entry would never match the callback's host check - the connection would fail
                # with a certificate error even though skip is on.
                $bypassHost = $Server
                if (-not $bypassHost) { try { $bypassHost = ([uri]$BaseUrl).Host } catch {} }
                if ($bypassHost) { [void]$script:HYCUBypassHosts.Add([string]$bypassHost) }
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                    param($sender, $certificate, $chain, $sslPolicyErrors)
                    if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
                    $h = $null
                    try {
                        if     ($sender -is [System.Net.HttpWebRequest]) { $h = $sender.RequestUri.Host }
                        elseif ($sender -is [System.Net.ServicePoint])   { $h = $sender.Address.Host }
                        elseif ($sender -is [string])                    { $h = $sender }
                    } catch {}
                    if ($h) { return $script:HYCUBypassHosts.Contains([string]$h) }
                    return $true   # host indeterminable: preserve connectivity (this process only calls HTTPS to HYCU)
                }
                Write-HYCUClientLog "Certificate validation bypassed for the HYCU host(s) only: $($script:HYCUBypassHosts -join ', ')." 'WARN'
            } catch { Write-HYCUClientLog "Could not configure TLS bypass: $_" 'WARN' }
        } else {
            # Also clear the recorded hosts so the state matches the (now removed) callback.
            try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null; $script:HYCUBypassHosts = $null } catch {}
        }
    }

    $session = [pscustomobject]@{
        BaseUri    = $BaseUrl
        Headers    = $headers
        AuthMode   = $AuthMode
        SkipCert   = $skip
        Server     = $Server
        Port       = $Port
        ApiVersion = $ApiVersion
    }

    if (-not $NoValidate) {
        try {
            [void](Invoke-HYCURest -Session $session -Path 'vms' -Query @{ pageSize = 1; pageNumber = 1 })
            Write-HYCUClientLog "Connected to HYCU controller: $BaseUrl ($AuthMode)." 'SUCCESS'
        } catch {
            throw "Failed to connect to HYCU ($BaseUrl): $_"
        }
    }
    return $session
}

function Disconnect-HYCUController {
    <#
    .SYNOPSIS  Clears the TLS certificate bypass installed by Connect-HYCUController (Windows PowerShell 5.1).
    .DESCRIPTION
      Removes the session's HYCU host from the cert-bypass set; when none remain, resets the global
      ServerCertificateValidationCallback to $null so normal validation resumes for the process. Safe to call
      on any platform / any session (no-op on PowerShell 7+ or if no bypass was installed).
    #>
    [CmdletBinding()]
    param([pscustomobject]$Session)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }
    try {
        if ($Session -and $Session.Server -and $script:HYCUBypassHosts) { [void]$script:HYCUBypassHosts.Remove([string]$Session.Server) }
        if (-not $script:HYCUBypassHosts -or $script:HYCUBypassHosts.Count -eq 0) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        }
    } catch {}
}

function Set-HYCUTls12 {
    # Windows PowerShell 5.1 / .NET Framework on older Windows (notably Server 2012 R2) negotiates
    # SSL3/TLS1.0 by default. Modern HYCU controllers refuse that and the .NET handshake dies with
    # "The underlying connection was closed: An unexpected error occurred on a send." Add TLS 1.2
    # (+1.1) to the allowed protocols so the handshake succeeds. No-op on PowerShell 7+ (OS default
    # already includes TLS 1.2 and per-call options are used instead).
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }
    try {
        $tls = [Net.ServicePointManager]::SecurityProtocol
        foreach ($name in 'Tls12','Tls11') {
            if ([Enum]::IsDefined([Net.SecurityProtocolType], $name)) {
                $tls = $tls -bor [Net.SecurityProtocolType]::$name
            }
        }
        [Net.ServicePointManager]::SecurityProtocol = $tls
    } catch { Write-HYCUClientLog "Could not raise the TLS protocol to 1.2: $_" 'WARN' }
}

# ----------------------------------------------------------------------------
# Low-level REST call (auth, certificate, readable errors)
# ----------------------------------------------------------------------------
function Invoke-HYCURest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Path,                 # relative to BaseUri, e.g. 'vms' or 'vms/{uuid}/backups'
        [ValidateSet('GET','POST','PUT','DELETE')][string]$Method = 'GET',
        [hashtable]$Query,
        $Body,
        [int]$TimeoutSec = 100
    )
    Set-HYCUTls12   # ensure TLS 1.2 before any HTTPS call (Server 2012 R2 / .NET Framework default is too old)
    $uri = "{0}/{1}" -f $Session.BaseUri, $Path.TrimStart('/')
    if ($Query -and $Query.Count) {
        $pairs = $Query.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
        }
        $uri = "$uri`?" + ($pairs -join '&')
    }

    # Transport selection. HYCU controllers commonly use self-signed certificates, and
    # Windows PowerShell 5.1 / .NET Framework can even fail the TLS *handshake* against
    # some controllers. curl.exe (built into Windows 10/11 and recent Server) negotiates
    # TLS reliably and handles self-signed certs with -k, so it is preferred by default.
    $transport = Get-HYCUConfigValue 'HycuTransport' 'Auto'
    $curlCmd   = Get-Command curl.exe -ErrorAction SilentlyContinue
    $useCurl   = ($transport -eq 'Curl') -or ($transport -eq 'Auto' -and $curlCmd)
    Write-HYCUClientLog ("REST $Method $uri (transport: {0})" -f $(if ($useCurl) { 'curl' } else { 'dotnet' })) 'DEBUG'

    if ($useCurl) {
        if (-not $curlCmd) { throw "Transport 'Curl' requested but curl.exe was not found." }
        return Invoke-HYCURestViaCurl -CurlPath $curlCmd.Source -Uri $uri -Method $Method `
                   -Headers $Session.Headers -SkipCert:$Session.SkipCert -Body $Body `
                   -TimeoutSec $TimeoutSec -Context "$Method $Path"
    }

    # --- .NET path (Invoke-RestMethod) -----------------------------------------
    $irm = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Session.Headers
        ContentType = 'application/json'
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $irm.Body = ($Body | ConvertTo-Json -Depth 12) }
    # PowerShell 7+: per-call certificate bypass (clean, no global state).
    if ($Session.SkipCert -and $PSVersionTable.PSVersion.Major -ge 6) { $irm.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @irm
    } catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $detail = if ($status) { "HTTP $status" } else { $_.Exception.Message }
        # A TLS handshake failure (no HTTP status, "unexpected error occurred on a send" / "could not
        # create SSL/TLS secure channel") on .NET usually means the old Windows/.NET TLS default.
        if (-not $status -and $detail -match 'underlying connection was closed|secure channel|unexpected error occurred on a send') {
            $hasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
            $detail += "  [TLS handshake failed. TLS 1.2 has been enabled; if this persists, this host's SChannel may lack the TLS 1.2 cipher suites the controller requires (common on stock Server 2012 R2). " +
                       $(if ($hasCurl) { "Prefer the curl transport (its own TLS stack bypasses SChannel cipher limits): Set-HYCUADConfig -HycuTransport Curl." }
                         else { "curl.exe (which uses its own TLS stack) is not present on this host - Server 2012 R2 ships without it; install curl.exe, apply the latest Windows TLS updates, or run the connection from a newer host where curl is used automatically." }) + "]"
        }
        throw "HYCU call failed ($Method $Path): $detail"
    }
}

function Invoke-HYCURestViaCurl {
    # Performs the HTTP call with curl.exe. The Authorization header and request body are
    # passed via a temporary curl config file (-K), NOT on the command line, so secrets are
    # not exposed in the process list. The temp files are deleted immediately afterwards.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurlPath,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        [switch]$SkipCert,
        $Body,
        [int]$TimeoutSec = 100,
        [string]$Context = ''
    )
    $cfg = [IO.Path]::GetTempFileName()
    $bodyFile = $null
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('url = "{0}"' -f $Uri)
        $lines.Add('request = "{0}"' -f $Method)
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                # Auth header values (base64 / tokens) contain no backslashes; escape quotes only.
                $v = ([string]$Headers[$k]) -replace '"','\"'
                $lines.Add(('header = "{0}: {1}"' -f $k, $v))
            }
        }
        if ($SkipCert) { $lines.Add('insecure') }
        $lines.Add('silent')
        $lines.Add('show-error')
        $lines.Add('max-time = {0}' -f $TimeoutSec)
        $lines.Add('write-out = "\n%{http_code}"')
        if ($null -ne $Body) {
            $bodyFile = [IO.Path]::GetTempFileName()
            # No-BOM UTF-8: a BOM would corrupt the JSON body sent to HYCU.
            [IO.File]::WriteAllText($bodyFile, ($Body | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
            $lines.Add('header = "Content-Type: application/json"')
            $lines.Add(('data-binary = "@{0}"' -f ($bodyFile -replace '\\','/')))
        }
        # No-BOM UTF-8: Set-Content -Encoding UTF8 (PS 5.1) would prepend a BOM that curl
        # would read as part of the first option (e.g. unknown option 'url').
        [IO.File]::WriteAllText($cfg, [string]::Join("`n", $lines), (New-Object System.Text.UTF8Encoding($false)))

        # curl emits UTF-8, but PS 5.1 decodes native stdout with the console OEM codepage
        # (CP850/CP437) - accents in VM names / job messages would be mojibake'd. Force UTF-8 for
        # the read and restore afterwards. Guarded: with no attached console (ps2exe -noConsole)
        # the property can throw - then we just proceed with the default decoding.
        $prevEnc = $null
        try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
        try {
            $text = (& $CurlPath --config $cfg 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        } finally {
            if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch {} }
        }
        if ($exit -ne 0) {
            if ($exit -eq 60) {
                throw "TLS certificate not trusted - the HYCU controller likely uses a self-signed certificate. Enable 'Self-signed cert' in the connection settings (or run Set-HYCUADConfig -HycuSkipCertCheck `$true), then retry."
            }
            $curlLine = (($text -split "`r?`n") | Where-Object { $_ -match 'curl:\s*\(\d+\)' } | Select-Object -First 1)
            $detail = if ($curlLine) { $curlLine.Trim() } else { (($text.Trim() -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) }
            throw "curl transport error (exit $exit): $detail"
        }

        # The body is followed by a final line carrying the HTTP status code (write-out).
        # Trim trailing blank lines. Guard with Count -gt 1 (NOT -gt 0): with a single blank element
        # the range 0..($Count-2) becomes 0..-1 = {0,-1}, which re-grows the array and spins forever.
        $allLines = @($text -split "`r?`n")
        while ($allLines.Count -gt 1 -and [string]::IsNullOrWhiteSpace($allLines[-1])) {
            $allLines = $allLines[0..($allLines.Count - 2)]
        }
        if ($allLines.Count -eq 1 -and [string]::IsNullOrWhiteSpace($allLines[0])) { $allLines = @() }
        $status = 0; $bodyText = ''
        if ($allLines.Count -ge 1) {
            [void][int]::TryParse($allLines[-1].Trim(), [ref]$status)
            if ($allLines.Count -ge 2) { $bodyText = ($allLines[0..($allLines.Count - 2)] -join "`n") }
        }

        if ($status -ge 400) {
            $detail = "HTTP $status"
            try { $j = $bodyText | ConvertFrom-Json; if ($j.message.title) { $detail = "HTTP $status ($($j.message.title))" } } catch {}
            throw "HYCU call failed ($Context): $detail"
        }
        if ([string]::IsNullOrWhiteSpace($bodyText)) { return $null }
        try { return ($bodyText | ConvertFrom-Json) }
        catch { throw "HYCU returned a non-JSON response (HTTP $status) for ${Context}: $($bodyText.Substring(0, [Math]::Min(200, $bodyText.Length)))" }
    } finally {
        # $cfg holds the Authorization header and $bodyFile the request body (which may contain the
        # restore-share password). Overwrite with zeros before deleting so the secret does not linger in
        # slack space. Best-effort - a hard process kill can still leave them, but the normal path is clean.
        foreach ($f in @($cfg, $bodyFile)) {
            if ($f -and (Test-Path -LiteralPath $f)) {
                try { $len = (Get-Item -LiteralPath $f).Length; if ($len -gt 0) { [IO.File]::WriteAllText($f, ('0' * [int]$len)) } } catch {}
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Generic pagination (pageSize / pageNumber, metadata.totalEntityCount)
# ----------------------------------------------------------------------------
function Get-HYCUAllPages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [int]$PageSize = 1000,
        [int]$MaxPages = 1000
    )
    $all   = New-Object System.Collections.Generic.List[object]
    $page  = 1
    $total = $null
    while ($page -le $MaxPages) {
        $q = @{} + $Query
        $q['pageSize']   = $PageSize
        $q['pageNumber'] = $page
        $resp = Invoke-HYCURest -Session $Session -Path $Path -Query $q

        # HYCU response shape: { metadata: { totalEntityCount, entityCount }, entities: [...] }.
        # Stay tolerant about the array name across versions.
        $entities = @( if ($resp.PSObject.Properties['entities']) { $resp.entities }
                       elseif ($resp.PSObject.Properties['data']) { $resp.data }
                       elseif ($resp -is [System.Collections.IEnumerable] -and $resp -isnot [string]) { $resp }
                       else { @() } )
        foreach ($e in $entities) { $all.Add($e) }
        if ($resp.PSObject.Properties['metadata'] -and $resp.metadata -and $resp.metadata.PSObject.Properties['totalEntityCount']) {
            $total = [int]$resp.metadata.totalEntityCount
        }
        $page++
        # An empty page always ends the loop (defensive: avoids spinning to MaxPages on a bad total).
        if ($entities.Count -eq 0) { break }
        # When the controller reports totalEntityCount, trust IT rather than the page fill: a server
        # that clamps the requested pageSize (e.g. caps 1000 at 100) returns "non-full" pages that
        # still have successors - breaking on fill alone silently truncated such listings.
        if ($null -ne $total) { if ($all.Count -ge $total) { break } }
        elseif ($entities.Count -lt $PageSize) { break }   # no total reported: non-full page = natural end
    }
    if ($page -gt $MaxPages) { Write-HYCUClientLog "Pagination hit the $MaxPages-page cap for '$Path' ($($all.Count) item(s)); there may be more results." 'WARN' }

    return $all.ToArray()
}

# ----------------------------------------------------------------------------
# Protected VMs
# ----------------------------------------------------------------------------
function Get-HYCUProtectedVM {
    <#
    .SYNOPSIS  Lists VMs known to HYCU (PROTECTED only by default).
    .EXAMPLE   Get-HYCUProtectedVM -Session $h -Name DC01
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [string]$Name,
        [switch]$IncludeUnprotected
    )
    $vms = Get-HYCUAllPages -Session $Session -Path 'vms'
    $out = foreach ($v in $vms) {
        $status = [string](Get-HYCUFirstProperty $v @('status','protectionStatus','compliancyStatus','complianceStatus'))
        [pscustomobject]@{
            Name      = [string](Get-HYCUFirstProperty $v @('vmName','name','entityName'))
            Uuid      = [string](Get-HYCUFirstProperty $v @('uuid','uid','vmUuid','id'))
            Status    = $status
            OS        = [string](Get-HYCUFirstProperty $v @('operatingSystem','osType','guestOs'))
            HasBackups= (Get-HYCUFirstProperty $v @('hasBackups'))
            LastBackup= (Get-HYCUFirstProperty $v @('lastBackupValidationBackupTime','lastBackupTimestamp','lastBackup'))
            Raw       = $v
        }
    }
    # NB: -eq (not -match) because 'UNPROTECTED' contains the substring 'PROTECTED'.
    if (-not $IncludeUnprotected) { $out = $out | Where-Object { $_.Status -eq 'PROTECTED' } }
    if ($Name) { $out = $out | Where-Object { $_.Name -like "*$Name*" } }
    Write-HYCUClientLog ("{0} VM(s) returned." -f @($out).Count) 'INFO'
    return @($out)
}

# ----------------------------------------------------------------------------
# HYCU applications (default: Active Directory domain controllers)
# ----------------------------------------------------------------------------
function Get-HYCUADApplication {
    <#
    .SYNOPSIS
      Lists HYCU application-aware entities, by default only the Active Directory ones
      (the domain controllers), each resolved to its linked VM.
    .DESCRIPTION
      HYCU exposes application-aware backups (Active Directory, Exchange, SQL, ...).
      An 'ACTIVE_DIRECTORY' application is a domain controller and carries the linked
      VM (vmUuid/vmName) used for the NTDS file-level restore. The returned objects are
      drop-in compatible with Get-HYCURestorePoint / Start-HYCUFileLevelRestore (the
      .Uuid / .Name fields point to the linked VM).
    .EXAMPLE
      Get-HYCUADApplication -Session $h                 # AD domain controllers only
    .EXAMPLE
      Get-HYCUADApplication -Session $h -AllTypes       # all applications
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [string]$Name,
        [string]$ApplicationType = 'ACTIVE_DIRECTORY',
        [switch]$AllTypes
    )
    $apps = Get-HYCUAllPages -Session $Session -Path 'applications'
    $out = foreach ($a in $apps) {
        [pscustomobject]@{
            Name        = [string](Get-HYCUFirstProperty $a @('vmName','name'))         # domain controller (linked VM)
            Uuid        = [string](Get-HYCUFirstProperty $a @('vmUuid','uuid'))          # VM uuid -> restore points / file-level restore
            Application = [string](Get-HYCUFirstProperty $a @('name'))                   # application name (e.g. hycu.ct)
            Type        = [string](Get-HYCUFirstProperty $a @('typeDisplayName','applicationType'))
            AppType     = [string](Get-HYCUFirstProperty $a @('applicationType'))
            Version     = [string](Get-HYCUFirstProperty $a @('applicationVersion'))
            Status      = [string](Get-HYCUFirstProperty $a @('status','compliancyStatus'))
            AppUuid     = [string](Get-HYCUFirstProperty $a @('uuid'))
            Raw         = $a
        }
    }
    if (-not $AllTypes) { $out = $out | Where-Object { $_.AppType -eq $ApplicationType } }
    if ($Name) { $out = $out | Where-Object { $_.Name -like "*$Name*" -or $_.Application -like "*$Name*" } }
    Write-HYCUClientLog ("{0} application(s) returned ({1})." -f @($out).Count, $(if ($AllTypes) { 'all types' } else { $ApplicationType })) 'INFO'
    return @($out)
}

# ----------------------------------------------------------------------------
# A VM's restore points
# ----------------------------------------------------------------------------
function Get-HYCURestorePoint {
    <#
    .SYNOPSIS  Lists a VM's restore points (backups).
    .DESCRIPTION
      Surfaces the consistency type (application vs crash): an application-consistent backup
      usually yields a ntds.dit already in 'Clean Shutdown' state.
    .EXAMPLE   Get-HYCURestorePoint -Session $h -VmUuid $vm.Uuid | Sort-Object Timestamp -Descending
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$VmUuid
    )
    $rps = Get-HYCUAllPages -Session $Session -Path ("vms/{0}/backups" -f $VmUuid)
    $out = foreach ($r in $rps) {
        $appConsistent = Get-HYCUFirstProperty $r @('appBackup','applicationConsistent','appConsistent','isApplicationConsistent')
        [pscustomobject]@{
            Uuid        = [string](Get-HYCUFirstProperty $r @('uuid','uid','id','restorePointUuid'))
            Timestamp   = (ConvertTo-HYCUDateTime (Get-HYCUFirstProperty $r @('restorePointInMillis','timeOfLastBackupInSeconds','restorePointTimestamp','creationTime','timestamp','backupTimestamp')))
            Tier        = [string](Get-HYCUFirstProperty $r @('primaryTargetName','archiveTargetName','secondaryTargetName','tier','restoreTier','backupTier'))
            Type        = [string](Get-HYCUFirstProperty $r @('type','backupType'))
            Consistency = if ($null -ne $appConsistent) {
                              if ([string]$appConsistent -match '^(?i:true|1|yes)$') { 'Application' } else { 'Crash' }
                          } else { 'Unknown' }
            Raw         = $r
        }
    }
    Write-HYCUClientLog ("{0} restore point(s) for VM {1}." -f @($out).Count, $VmUuid) 'INFO'
    return @($out)
}

# ----------------------------------------------------------------------------
# HYCU jobs (tracking)
# ----------------------------------------------------------------------------
function Get-HYCUJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$JobUuid
    )
    $j = Invoke-HYCURest -Session $Session -Path ("jobs/{0}" -f $JobUuid)
    # Some controllers wrap the job in the standard envelope.
    if ($j.PSObject.Properties['entities']) { $j = @($j.entities)[0] }
    [pscustomobject]@{
        Uuid     = [string](Get-HYCUFirstProperty $j @('uuid','uid','id'))
        Status   = [string](Get-HYCUFirstProperty $j @('status','state','jobStatus'))
        Progress = (Get-HYCUFirstProperty $j @('completitionPct','progressPercentage','progress','percentComplete'))
        Message  = [string](Get-HYCUFirstProperty $j @('taskExitMessage','message','statusMessage','errorMessage'))
        Name     = [string](Get-HYCUFirstProperty $j @('taskName','name'))
        Raw      = $j
    }
}

function Wait-HYCUJob {
    <#
    .SYNOPSIS  Waits for a HYCU job to finish (status polling).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$JobUuid,
        [int]$TimeoutSeconds = 3600,
        [int]$PollSeconds = 5,
        [string[]]$SuccessStates = @('OK','DONE','SUCCESS','COMPLETED','FINISHED'),
        [string[]]$FailureStates = @('ERROR','FAILED','ABORTED','CANCELED','CANCELLED'),
        [scriptblock]$OnProgress
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $job = Get-HYCUJob -Session $Session -JobUuid $JobUuid
        $msg = "Job $JobUuid : $($job.Status)" + $(if ($null -ne $job.Progress) { " ($($job.Progress)%)" } else { '' })
        Write-HYCUClientLog $msg 'DEBUG'
        if ($OnProgress) { & $OnProgress $msg }
        $st = ([string]$job.Status).ToUpper()   # null-safe (a missing/empty Status never throws on .ToUpper)
        if ($SuccessStates -contains $st) { Write-HYCUClientLog "Job finished: $($job.Status)." 'SUCCESS'; return $job }
        if ($FailureStates -contains $st) { throw "HYCU job failed ($($job.Status)): $($job.Message)" }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for HYCU job $JobUuid."
}

# ----------------------------------------------------------------------------
# Watch the target share until ntds.dit is available
# ----------------------------------------------------------------------------
function Wait-HYCURestoredNtds {
    <#
    .SYNOPSIS
      Watches a folder (the HYCU file-level restore destination share) until ntds.dit
      appears and its size is stable.
    .DESCRIPTION
      Returns the path of the folder containing ntds.dit (ready for
      Connect-HYCUADSnapshot -SourcePath). Searches for ntds.dit recursively, since HYCU
      often recreates the tree (...\Windows\NTDS\ntds.dit).
    .EXAMPLE
      $ntds = Wait-HYCURestoredNtds -Path '\\nas\HYCU_Restore\DC01' -TimeoutSeconds 1800
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 1800,
        [int]$StableSeconds = 10,
        [int]$PollSeconds = 5,
        # Snapshot of ntds.dit files that were ALREADY on the share before the restore started
        # (path -> "lastWriteTicks:length"). A hit on one of these paths is accepted only once the
        # file actually changed - otherwise the watcher would latch onto stale leftovers from an
        # earlier run (or an operator's own copy), return old data as "restored", and the share
        # cleanup would then delete it.
        [hashtable]$IgnoreExisting,
        [scriptblock]$OnProgress
    )
    $report = {
        param($m)
        Write-HYCUClientLog $m 'INFO'
        if ($OnProgress) { & $OnProgress $m }
    }
    & $report "Watching '$Path' (waiting for ntds.dit)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $dit = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            $cands = @(Get-ChildItem -Path $Path -Filter 'ntds.dit' -File -Recurse -ErrorAction SilentlyContinue)
            foreach ($c in $cands) {
                if ($IgnoreExisting -and $IgnoreExisting.ContainsKey($c.FullName)) {
                    $sig = '{0}:{1}' -f $c.LastWriteTimeUtc.Ticks, $c.Length
                    if ($sig -eq $IgnoreExisting[$c.FullName]) { continue }   # untouched pre-existing copy: not ours
                }
                $dit = $c; break
            }
            if ($dit) { break }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    if (-not $dit) { throw "ntds.dit did not appear in '$Path' before the timeout ($TimeoutSeconds s)." }

    & $report "ntds.dit found: $($dit.FullName). Waiting for the copy to stabilize..."
    # Stability wait: ntds.dit size must stop changing for StableSeconds. Reaching the deadline
    # without stability is an ERROR (the file is still being written - copying it would yield a
    # torn database), not a silent fall-through.
    $lastSize = -1; $stableSince = $null; $stable = $false
    while ((Get-Date) -lt $deadline) {
        $cur = (Get-Item $dit.FullName -ErrorAction SilentlyContinue).Length
        if ($null -eq $cur) {
            # The file vanished (replaced/renamed mid-restore): reset and keep watching. Without this,
            # two consecutive $null reads compared equal and a nonexistent file passed as "stable".
            $lastSize = -1; $stableSince = $null
        } elseif ($cur -eq $lastSize) {
            if (-not $stableSince) { $stableSince = Get-Date }
            elseif (((Get-Date) - $stableSince).TotalSeconds -ge $StableSeconds) { $stable = $true; break }
        } else {
            $lastSize = $cur; $stableSince = $null
            & $report ("Copying... ntds.dit = {0} MB" -f [math]::Round($cur/1MB,1))
        }
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($PollSeconds, $StableSeconds)))
    }
    if (-not $stable) { throw "ntds.dit did not stabilize in '$Path' before the timeout ($TimeoutSeconds s) - the restore may still be writing." }

    $folder = Split-Path $dit.FullName -Parent
    $logCount = @(Get-ChildItem -Path $folder -Filter 'edb*.log' -File -ErrorAction SilentlyContinue).Count
    & $report ("Database ready in: $folder ({0} edb*.log journal(s))." -f $logCount)
    if ($logCount -eq 0) {
        Write-HYCUClientLog "No edb*.log journal found: if the database is 'Dirty', soft recovery will fail. Also restore the logs." 'WARN'
    }
    return $folder
}

# ----------------------------------------------------------------------------
# File-level restore via the HYCU mount + restore-items API (no HYCU console).
# Verified against a live controller:
#   POST /vms/{vmUuid}/backups/{backupUuid}/mount   -> mount the backup (async)
#   GET  /mounts                                     -> list of mount UUIDs (strings)
#   GET  /mounts/{mountUuid}                         -> MountDTO (mounted, windowsOs, ...)
#   GET  /mounts/{mountUuid}/browse?path=/C/Windows/NTDS  -> file listing
#   POST /mounts/{mountUuid}/restoreitems           -> restore items to a target UNC + creds
#   DELETE /vms/{vmUuid}/backups/{backupUuid}/mount -> unmount
# The controller does NOT expose an SMB share to read directly; instead HYCU restores the
# selected items to a UNC share that the operator provides (user/password), which the tool
# then reads. Browse paths look like '/C/Windows/NTDS'.
# ----------------------------------------------------------------------------
function Mount-HYCUBackup {
    <#
    .SYNOPSIS  Mounts a VM backup (file-level) and returns the active mount UUID.
    .OUTPUTS   { MountUuid, WindowsOs, Raw }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$VmUuid,
        [Parameter(Mandatory)][string]$BackupUuid,
        [int]$TimeoutSeconds = 1800,
        [scriptblock]$OnProgress
    )
    $report = { param($m) Write-HYCUClientLog $m 'INFO'; if ($OnProgress) { & $OnProgress $m } }

    & $report "Requesting a HYCU file-level mount of the backup..."
    $resp = Invoke-HYCURest -Session $Session -Method POST -Path "vms/$VmUuid/backups/$BackupUuid/mount" -Body @{}

    # The POST response's entities[0] is the mount JOB uuid (a plain string).
    $jobUuid = $null
    if ($resp -and $resp.PSObject.Properties['entities']) {
        $e0 = @($resp.entities)[0]
        $jobUuid = if ($e0 -is [string]) { $e0 } else { [string](Get-HYCUFirstProperty $e0 @('uuid','jobUuid','id')) }
    }
    if (-not $jobUuid) { throw "The mount request did not return a job id." }

    # Resolve the mount UUID from the job report ('Mount UUID: <uuid>') - the supported FLR workflow.
    & $report "Mount job $jobUuid - waiting for the mount point..."
    $deadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSeconds, 600))
    $lastErr = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 8
        try {
            $rep = Invoke-HYCURest -Session $Session -Path "jobs/$jobUuid/report"
            $txt = if ($rep -and $rep.PSObject.Properties['entities']) { [string](@($rep.entities)[0]) } else { [string]$rep }
            $mm = [regex]::Match($txt, 'Mount UUID:\s*(\S+)')
            if ($mm.Success) {
                $mu = $mm.Groups[1].Value.Trim()
                & $report "Mount ready (mountUuid $mu)."
                return [pscustomobject]@{ MountUuid = $mu; JobUuid = $jobUuid; Raw = $rep }
            }
            # No mount UUID yet: fail fast if the mount job itself has failed, instead of polling
            # the report for up to 10 minutes and throwing a generic message.
            $mj = Get-HYCUJob -Session $Session -JobUuid $jobUuid
            $st = ([string]$mj.Status).ToUpper()
            if (@('ERROR','FAILED','ABORTED','CANCELED','CANCELLED') -contains $st) {
                throw "HYCU mount job failed ($($mj.Status)): $($mj.Message)"
            }
        } catch {
            if ("$_" -match 'mount job failed') { throw }
            $lastErr = "$_"; Write-HYCUClientLog "mount report poll: $_" 'DEBUG'
        }
    }
    throw ("Mount UUID not found in the job report in time." + $(if ($lastErr) { " Last error: $lastErr" }))
}

function Dismount-HYCUBackup {
    <#  .SYNOPSIS  Unmounts a HYCU file-level backup mount.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$VmUuid,
        [Parameter(Mandatory)][string]$BackupUuid,
        [scriptblock]$OnProgress
    )
    $report = { param($m) Write-HYCUClientLog $m 'INFO'; if ($OnProgress) { & $OnProgress $m } }
    try {
        & $report "Unmounting the HYCU backup..."
        Invoke-HYCURest -Session $Session -Method DELETE -Path "vms/$VmUuid/backups/$BackupUuid/mount" | Out-Null
        & $report "Backup unmounted."
    } catch { Write-HYCUClientLog "Unmount warning: $_" 'WARN' }
}

function Find-HYCUNtdsVolume {
    # Browses a mount to find the volume whose \Windows\NTDS contains ntds.dit.
    # Returns the volume browse-root (e.g. '/C'), or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Session, [Parameter(Mandatory)][string]$MountUuid)
    $root = Invoke-HYCURest -Session $Session -Path "mounts/$MountUuid/browse" -Query @{ pageSize = 200 }
    foreach ($v in @($root.entities | Where-Object { $_.directory })) {
        $vol = ([string]$v.fullItemName).TrimEnd('/')
        try {
            $ntds = Invoke-HYCURest -Session $Session -Path "mounts/$MountUuid/browse" -Query @{ pageSize = 200; path = "$vol/Windows/NTDS" }
            if (@($ntds.entities | Where-Object { $_.displayName -eq 'ntds.dit' }).Count -gt 0) { return $vol }
        } catch { }
    }
    return $null
}

function Invoke-HYCURestoreItems {
    <#
    .SYNOPSIS  Restores selected items from a mount to an SMB share (POST /mounts/{uuid}/restoreitems).
    .DESCRIPTION
      Payload matches the supported HYCU file-level restore-to-SMB workflow: selectedItems, vmUuid,
      restoreTargetPath, isSharedLocation, username/password, sharedType, restoreItemType.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$MountUuid,
        [Parameter(Mandatory)][string[]]$SelectedItems,
        [Parameter(Mandatory)][string]$VmUuid,
        [Parameter(Mandatory)][string]$TargetPath,        # UNC, e.g. \\server\share
        [string]$Domain = '',
        [string]$Username = '',
        [System.Security.SecureString]$Password,          # SecureString end-to-end; see note below
        [string]$SharedType = 'SMB',
        [string]$RestoreItemType = 'FILESYSTEM',
        [int]$TimeoutSeconds = 1800,
        [scriptblock]$OnProgress
    )
    # The HYCU REST API takes the share password as plain text in the JSON body - that is the ONE
    # unavoidable point where the secret materializes. It lives only in this local body hashtable
    # for the duration of the call; everywhere upstream it stays a SecureString.
    $body = @{
        selectedItems     = @($SelectedItems)
        vmUuid            = $VmUuid
        restoreTargetPath = $TargetPath
        isSharedLocation  = $true
        username          = $Username
        password          = (ConvertFrom-HYCUSecureString $Password)
        sharedType        = $SharedType
        restoreItemType   = $RestoreItemType
    }
    if ($Domain) { $body.domain = $Domain }
    $resp = Invoke-HYCURest -Session $Session -Method POST -Path "mounts/$MountUuid/restoreitems" -Body $body
    # A restore job id may come back (entities[0] as a string) - wait for it best-effort.
    $jobUuid = $null
    if ($resp -and $resp.PSObject.Properties['entities']) {
        $e0 = @($resp.entities)[0]
        $jobUuid = if ($e0 -is [string]) { $e0 } else { [string](Get-HYCUFirstProperty $e0 @('uuid','jobUuid','id')) }
    }
    if ($jobUuid) {
        try { Wait-HYCUJob -Session $Session -JobUuid $jobUuid -TimeoutSeconds $TimeoutSeconds -OnProgress $OnProgress | Out-Null }
        catch {
            # A DEFINITIVE job failure (ERROR/FAILED/ABORTED - e.g. the controller cannot write the
            # target share) must surface now: swallowing it used to send the caller into a 30-minute
            # wait for an ntds.dit that would never arrive. Polling glitches and a slow job that
            # outlives the wait stay best-effort (the downstream file watcher still decides).
            if ("$_" -match 'HYCU job failed') { throw }
            Write-HYCUClientLog "restore job wait (non-fatal): $_" 'WARN'
        }
    }
    return $resp
}

function Remove-HYCURestoredShareFiles {
    <#
    .SYNOPSIS
      Removes the NTDS/SYSVOL files HYCU restored to the operator's share, once they have been
      copied locally - so the (multi-GB) restore data does not linger on the share.
    .DESCRIPTION
      Deletes only the restored leaf folders (the NTDS folder that holds ntds.dit and, if it was
      restored, its sibling SYSVOL), then prunes the now-empty parent folders (e.g. Windows, the
      volume folder) UP TO BUT NEVER INCLUDING the share root. A non-empty parent stops the prune,
      so any pre-existing operator data on the share is left untouched. Best-effort + honors -WhatIf.
    .EXAMPLE
      Remove-HYCURestoredShareFiles -NtdsFolder 'HYCUTGT:\C\Windows\NTDS' -ShareRoot 'HYCUTGT:\'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$NtdsFolder,    # folder containing ntds.dit on the share
        [string]$SysvolFolder,                         # optional sibling SYSVOL folder we restored
        [Parameter(Mandatory)][string]$ShareRoot,      # the prune stops here (share root, never removed)
        [scriptblock]$OnProgress
    )
    $report  = { param($m) Write-HYCUClientLog $m 'INFO'; if ($OnProgress) { & $OnProgress $m } }
    $removed = @()
    $rootNorm = $ShareRoot.TrimEnd('\')
    # Safety invariant: a path we may delete must be STRICTLY below the share root. This guards
    # against ever recursing the share root itself (e.g. if ntds.dit unexpectedly sat at the root).
    $isUnderRoot = {
        param($p)
        $n = $p.TrimEnd('\')
        ($n.Length -gt $rootNorm.Length) -and $n.StartsWith($rootNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)
    }

    # 1. Remove the leaf folders we restored (recursively).
    foreach ($leaf in @($NtdsFolder, $SysvolFolder)) {
        if (-not $leaf -or -not (Test-Path -LiteralPath $leaf)) { continue }
        if (-not (& $isUnderRoot $leaf)) { & $report "Skipped (not under share root): $leaf"; continue }
        if ($PSCmdlet.ShouldProcess($leaf, "Remove restored folder from share")) {
            try {
                Remove-Item -LiteralPath $leaf -Recurse -Force -ErrorAction Stop
                & $report "Removed from share: $leaf"
                $removed += $leaf
            } catch { & $report "Could not remove '$leaf' from share: $_" }
        }
    }

    # 2. Prune now-empty parent folders up to (not including) the share root.
    $parent = Split-Path $NtdsFolder -Parent
    while ($parent -and (& $isUnderRoot $parent)) {
        $children = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)
        if ($children.Count -ne 0) { break }   # operator data present -> stop, never delete it
        if ($PSCmdlet.ShouldProcess($parent, "Remove empty restored folder from share")) {
            try { Remove-Item -LiteralPath $parent -Force -ErrorAction Stop; $removed += $parent }
            catch { & $report "Could not remove empty folder '$parent': $_"; break }
        }
        $parent = Split-Path $parent -Parent
    }
    return $removed
}

# ----------------------------------------------------------------------------
# Orchestrator: mount -> restore NTDS to the operator's UNC -> read it locally -> unmount
# ----------------------------------------------------------------------------
function Start-HYCUFileLevelRestore {
    <#
    .SYNOPSIS
      Drives the whole NTDS retrieval from this tool (no HYCU console): mounts the backup,
      restores C:\Windows\NTDS (+optionally SYSVOL) to the UNC share you provide, reads
      ntds.dit back from that share into a local folder, then unmounts.
    .EXAMPLE
      $ntds = Start-HYCUFileLevelRestore -Session $h -Vm $dc -RestorePoint $rp `
                  -TargetUnc '\\nas\Restore\DC01' -TargetUsername 'svc' -TargetPassword $pw
      $s = Connect-HYCUADSnapshot -SourcePath $ntds
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][pscustomobject]$Vm,
        [Parameter(Mandatory)][pscustomobject]$RestorePoint,
        [Parameter(Mandatory)][string]$TargetUnc,             # UNC where HYCU restores the files
        [string]$TargetDomain = '',
        [string]$TargetUsername = '',
        [System.Security.SecureString]$TargetPassword,        # kept protected until the REST body needs it
        [string]$DestinationPath,                             # local copy target (default: staging\flr_<stamp>)
        [switch]$IncludeSysvol,
        [bool]$CleanupShare = [bool](Get-HYCUConfigValue 'ShareCleanup' $true),  # delete restored files from the share after the local copy
        [int]$TimeoutSeconds = 1800,
        [scriptblock]$OnProgress
    )
    $report = { param($m) Write-HYCUClientLog $m 'INFO'; if ($OnProgress) { & $OnProgress $m } }
    if (-not $TargetUnc) { throw "Provide -TargetUnc (the UNC share where HYCU restores the files)." }
    $TargetUnc = $TargetUnc.Trim()
    if ($TargetUnc -notmatch '^\\\\[A-Za-z0-9._-]+\\[^\\]') {
        throw "Target UNC '$TargetUnc' is not a valid \\server\share path (check for typos - e.g. a ';' instead of '.' in the host)."
    }
    if (-not $DestinationPath) {
        $root = Get-HYCUConfigValue 'StagingRoot' (Join-Path $env:ProgramData 'HYCU\ADRecoveryTool\staging')
        $DestinationPath = Join-Path $root ("flr_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not $PSCmdlet.ShouldProcess($Vm.Name, "Mount HYCU backup and restore NTDS to $TargetUnc")) { return }

    # Prune older multi-GB staging copies before this restore drops a new one. Best-effort:
    # delegate to the engine's Clear-HYCUADStaging when the module is loaded; never block the restore.
    if ([bool](Get-HYCUConfigValue 'StagingAutoClean' $true) -and (Get-Command -Name Clear-HYCUADStaging -ErrorAction SilentlyContinue)) {
        try { Clear-HYCUADStaging | Out-Null } catch { & $report "Staging auto-clean skipped: $_" }
    }

    $mount = $null
    try {
        $mount = Mount-HYCUBackup -Session $Session -VmUuid $Vm.Uuid -BackupUuid $RestorePoint.Uuid -TimeoutSeconds $TimeoutSeconds -OnProgress $OnProgress

        & $report "Locating the NTDS folder in the backup..."
        $vol = Find-HYCUNtdsVolume -Session $Session -MountUuid $mount.MountUuid
        if (-not $vol) { throw "Could not locate \Windows\NTDS in the backup (browse returned nothing)." }
        $items = @("$vol/Windows/NTDS")
        if ($IncludeSysvol) { $items += "$vol/Windows/SYSVOL" }

        # Map the target share FIRST: it validates the destination credentials early and lets us
        # snapshot any ntds.dit already present, so the watcher below cannot latch onto stale data
        # (leftovers of an earlier run whose cleanup failed, or the operator's own reference copy -
        # which the share cleanup would then have DELETED after "retrieving" it).
        $cred = $null
        # Require BOTH: a username with an empty password would make the PSCredential constructor throw.
        # The SecureString is used as-is (never converted to a plain string here).
        if ($TargetUsername -and $TargetPassword -and $TargetPassword.Length -gt 0) {
            $u = if ($TargetDomain) { "$TargetDomain\$TargetUsername" } else { $TargetUsername }
            $cred = New-Object System.Management.Automation.PSCredential($u, $TargetPassword)
        }
        $name = 'HYCUTGT'
        $nd = @{ Name = $name; PSProvider = 'FileSystem'; Root = $TargetUnc; ErrorAction = 'Stop' }
        if ($cred) { $nd.Credential = $cred }
        New-PSDrive @nd | Out-Null
        try {
            $pre = @{}
            Get-ChildItem -Path "${name}:\" -Filter 'ntds.dit' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $pre[$_.FullName] = '{0}:{1}' -f $_.LastWriteTimeUtc.Ticks, $_.Length
            }
            if ($pre.Count -gt 0) {
                & $report ("{0} pre-existing ntds.dit file(s) found on the share - ignored unless the restore overwrites them." -f $pre.Count)
            }

            & $report "Restoring $($items -join ', ') to $TargetUnc (HYCU restore)..."
            try {
                Invoke-HYCURestoreItems -Session $Session -MountUuid $mount.MountUuid -SelectedItems $items `
                    -VmUuid $Vm.Uuid -TargetPath $TargetUnc -Domain $TargetDomain -Username $TargetUsername -Password $TargetPassword `
                    -TimeoutSeconds $TimeoutSeconds -OnProgress $OnProgress | Out-Null
            } catch {
                throw ("HYCU could not restore the files to '$TargetUnc'. The controller must be able to REACH and WRITE that share. Check: " +
                       "(1) the server/share are correct and resolve from the HYCU controller's network, (2) the username/password" +
                       "$(if ($TargetDomain) { " (domain $TargetDomain)" }) can write to it, (3) the share exists. Underlying error: $_")
            }

            # The restore is asynchronous: wait for ntds.dit to land on the mapped share.
            & $report "Restore started. Waiting for ntds.dit to appear on $TargetUnc ..."
            $srcNtds = Wait-HYCURestoredNtds -Path "${name}:\" -TimeoutSeconds $TimeoutSeconds -IgnoreExisting $pre -OnProgress $OnProgress
            $dstNtds = Join-Path $DestinationPath 'NTDS'
            New-Item -ItemType Directory -Path $dstNtds -Force | Out-Null
            & $report "Copying the NTDS database + journals locally..."
            # Copy only what dsamain/esentutl need. Skip edbres*.jrs (pre-allocated RESERVE logs,
            # useless for recovery) and temp.edb - they are large and slow to pull over SMB.
            Get-ChildItem -Path $srcNtds -File |
                Where-Object { $_.Name -match '^(ntds\.dit|ntds\.jfm|edb.*\.log|edb\.chk)$' } |
                ForEach-Object {
                    Copy-Item $_.FullName -Destination $dstNtds -Force
                    & $report ("  copied {0} ({1} MB)" -f $_.Name, [math]::Round($_.Length/1MB,1))
                }
            if ($IncludeSysvol) {
                $sv = Join-Path (Split-Path $srcNtds -Parent) 'SYSVOL'
                if (Test-Path $sv) { Copy-Item $sv -Destination (Join-Path $DestinationPath 'SYSVOL') -Recurse -Force -ErrorAction SilentlyContinue }
            }
            & $report "NTDS database retrieved locally: $dstNtds"

            # Now that the database is safely copied locally, remove the restored files from the
            # operator's share so the multi-GB data does not linger there. Best-effort: a failure
            # here must not discard the local copy we already have.
            if ($CleanupShare) {
                & $report "Cleaning up the restored files on the share..."
                try {
                    $svShare = Join-Path (Split-Path $srcNtds -Parent) 'SYSVOL'
                    $svArg   = if ($IncludeSysvol -and (Test-Path $svShare)) { $svShare } else { '' }
                    # Use the UNC root, not the PSDrive ("HYCUTGT:\"): $srcNtds resolves to its underlying
                    # UNC path (e.g. \\host\share\NTDS), so the share root must be in the SAME namespace
                    # ($TargetUnc) or the "is it under the root?" guard fails and cleanup is skipped.
                    Remove-HYCURestoredShareFiles -NtdsFolder $srcNtds -SysvolFolder $svArg `
                        -ShareRoot $TargetUnc -OnProgress $OnProgress | Out-Null
                } catch { & $report "Share cleanup skipped: $_" }
            }
            return $dstNtds
        } finally { Remove-PSDrive -Name $name -Force -ErrorAction SilentlyContinue }
    }
    finally {
        if ($mount) { Dismount-HYCUBackup -Session $Session -VmUuid $Vm.Uuid -BackupUuid $RestorePoint.Uuid -OnProgress $OnProgress }
    }
}

function Invoke-HYCUADRestorabilityTest {
    <#
    .SYNOPSIS
      End-to-end "is my AD backup usable?" check: latest restore point -> retrieve -> mount -> count -> report.
    .DESCRIPTION
      Chains the proven building blocks: finds the VM, takes its LATEST restore point, retrieves the
      NTDS files through the controller to your staging share, then hands the copy to
      Test-HYCUADSnapshotHealth (esentutl state + real dsamain mount + LDAP object counts + PASS/FAIL
      HTML report). Nothing is written to production AD. Schedule this to prove, continuously, that
      the AD backup can actually be mounted - see the README recipe.
    .OUTPUTS  The Test-HYCUADSnapshotHealth result object ({Ok, counts, ReportPath, ...}).
    .EXAMPLE
      $h = Connect-HYCUController -Server hycu.corp.local -Credential $cred
      Invoke-HYCUADRestorabilityTest -Session $h -VmName DC01 -TargetUnc \\nas\Restore -TargetUsername svc -TargetPassword $sec
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$TargetUnc,
        [string]$TargetDomain = '',
        [string]$TargetUsername = '',
        [System.Security.SecureString]$TargetPassword,
        [string]$ReportDirectory,
        [int]$TimeoutSeconds = 1800
    )
    # The health check lives in the AD engine module; fail with a clear message if only the client is loaded.
    if (-not (Get-Command -Name Test-HYCUADSnapshotHealth -ErrorAction SilentlyContinue)) {
        throw "Test-HYCUADSnapshotHealth is not available - import the full module (Import-Module .\HYCUADRecovery.psd1)."
    }
    $vm = Get-HYCUProtectedVM -Session $Session -Name $VmName | Select-Object -First 1
    if (-not $vm) { throw "VM '$VmName' not found on the HYCU controller." }
    # -VmUuid (the function's identity parameter) and Timestamp (the property it actually emits):
    # the previous call used a nonexistent -Vm parameter (bound to nothing -> hard failure) and
    # sorted on properties that are not on the output objects (no-op sort -> arbitrary point).
    $rp = Get-HYCURestorePoint -Session $Session -VmUuid $vm.Uuid | Sort-Object Timestamp -Descending | Select-Object -First 1
    if (-not $rp) { throw "No restore point found for VM '$VmName'." }
    Write-HYCUClientLog "Restorability test: VM $VmName, latest restore point selected." 'INFO'
    if (-not $PSCmdlet.ShouldProcess($VmName, "Retrieve the latest backup to $TargetUnc and verify it mounts")) { return }
    $ntds = Start-HYCUFileLevelRestore -Session $Session -Vm $vm -RestorePoint $rp -TargetUnc $TargetUnc `
        -TargetDomain $TargetDomain -TargetUsername $TargetUsername -TargetPassword $TargetPassword `
        -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    $label = "VM $VmName - latest restore point (retrieved $(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    Test-HYCUADSnapshotHealth -SourcePath $ntds -ReportDirectory $ReportDirectory -BackupLabel $label
}

# ----------------------------------------------------------------------------
Export-ModuleMember -Function `
    Connect-HYCUController, Disconnect-HYCUController, Invoke-HYCURest, Get-HYCUAllPages, `
    Get-HYCUProtectedVM, Get-HYCUADApplication, Get-HYCURestorePoint, Get-HYCUJob, Wait-HYCUJob, `
    Wait-HYCURestoredNtds, Mount-HYCUBackup, Dismount-HYCUBackup, Invoke-HYCURestoreItems, `
    Remove-HYCURestoredShareFiles, Start-HYCUFileLevelRestore, Invoke-HYCUADRestorabilityTest

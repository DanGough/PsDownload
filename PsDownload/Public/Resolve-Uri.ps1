<#
.SYNOPSIS
Resolve-Uri resolves a URI and retrieves information such as file size, last modified date, and filename.

.DESCRIPTION
The Resolve-Uri function resolves the given URI and retrieves information such as file size, last modified date, and filename. It sends a GET request to the URL and retrieves the headers to extract the required information.

.PARAMETER Uri
The URI to resolve. This parameter is mandatory. URL is accepted as an alias.

.PARAMETER UserAgent
The user agent string to use for the request. By default, it uses two user agent strings: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36' and 'Googlebot/2.1 (+http://www.google.com/bot.html)'. You can specify multiple user agent strings as an array.

.PARAMETER Headers
Additional headers to include in the request. Default is @{'accept' = '*/*'}, which is needed to trick some servers into serving a download, such as from FileZilla.

.PARAMETER TimeoutSeconds
Maximum number of seconds to wait for URI resolution. If the timeout is exceeded, the function throws a terminating timeout error with diagnostic details.

.OUTPUTS
The function outputs a custom object with the following properties:
- Uri: The original URL.
- AbsoluteUri: The resolved URL after any redirections.
- FileName: The extracted filename from the URL or headers.
- FileSizeBytes: The file size in bytes.
- FileSizeReadable: The file size in a human-readable format.
- LastModified: The last modified date of the file.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt'
Resolves the URL 'https://example.com/file.txt' and retrieves the file information.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt' -UserAgent 'My User Agent'
Resolves the URL 'https://example.com/file.txt' using the specified user agent string.

.EXAMPLE
Resolve-Uri -Uri 'https://example.com/file.txt' -Headers @{ 'Authorization' = 'Bearer token' }
Resolves the URL 'https://example.com/file.txt' and includes the 'Authorization' header in the request.

#>
function Resolve-Uri {

    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [Alias('Url')]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [string[]]$UserAgent = @($null, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36', 'Googlebot/2.1 (+http://www.google.com/bot.html)'),

        [hashtable]$Headers = @{accept = '*/*' },

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 60
    )

    begin {
        # Required on Windows Powershell only
        if ($PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName System.Net.Http
            Add-Type -AssemblyName System.Web
        }

        # Enable TLS 1.2 in addition to whatever is pre-configured
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # Create one single client object for the pipeline
        $HttpClientHandler = [System.Net.Http.HttpClientHandler]::new()
        $HttpClientHandler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $HttpClient = [System.Net.Http.HttpClient]::new($HttpClientHandler)
        # Use cancellation tokens for timeout control instead of HttpClient's internal timeout.
        $HttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

        if ($null -ne $Headers) {
            foreach ($Header in $Headers.GetEnumerator()) {
                $HttpClient.DefaultRequestHeaders.Add($Header.Key, $Header.Value)
            }
        }

        # File names that are technically valid but carry no useful information. When a URL path
        # resolves to one of these we prefer to keep looking for a better source.
        $UninformativeFileNames = @('download', 'downloads', 'get', 'file', 'files', 'index.html', 'index.htm', 'index.php', 'default.html', 'default.htm')

        # Strip any path portion, replace invalid characters with spaces and trim.
        # Callers are responsible for URL-decoding sources that require it (see call sites).
        function ConvertTo-SafeFileName {
            param([string]$Name)
            if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
            $Name = [System.IO.Path]::GetFileName($Name)
            if ([string]::IsNullOrEmpty($Name)) { return $null }
            foreach ($InvalidChar in [System.IO.Path]::GetInvalidFileNameChars()) {
                $Name = $Name.Replace($InvalidChar, ' ')
            }
            $Name = $Name.Trim()
            if ([string]::IsNullOrEmpty($Name)) { return $null }
            return $Name
        }

        # Extract a filename from a Content-Disposition header value. Prefers the strongly typed
        # .NET parser (which handles RFC 6266 / RFC 5987 'filename*' and charset decoding), and
        # falls back to a regex for malformed headers the parser rejects.
        function Get-FileNameFromContentDisposition {
            param([string]$HeaderValue)
            if ([string]::IsNullOrWhiteSpace($HeaderValue)) { return $null }
            try {
                $Parsed = [System.Net.Http.Headers.ContentDispositionHeaderValue]::Parse($HeaderValue)
                # filename* (FileNameStar) takes precedence over filename per RFC 6266 and is
                # already charset-decoded by the parser.
                if (-not [string]::IsNullOrEmpty($Parsed.FileNameStar)) {
                    return $Parsed.FileNameStar
                }
                if (-not [string]::IsNullOrEmpty($Parsed.FileName)) {
                    return $Parsed.FileName.Trim('"')
                }
            }
            catch {
                Write-Verbose "$($MyInvocation.MyCommand): Typed Content-Disposition parse failed, falling back to regex"
            }
            $ContentDispositionRegEx = @'
^.*filename\*?\s*=\s*"?(?:UTF-8|iso-8859-1)?(?:'[^']*?')?([^";]+)
'@
            if ($HeaderValue -match $ContentDispositionRegEx) {
                return [System.Web.HttpUtility]::UrlDecode($matches[1])
            }
            return $null
        }

        # Extract a filename from a URL's query string. Handles cloud storage presigned URLs
        # (S3 / GCS / CloudFront) that carry 'response-content-disposition', as well as common
        # ?filename= / ?file= style parameters. Returned values are already URL-decoded.
        function Get-FileNameFromQuery {
            param([string]$UriString)
            if ([string]::IsNullOrWhiteSpace($UriString)) { return $null }
            try { $ParsedUri = [System.Uri]$UriString } catch { return $null }
            if ([string]::IsNullOrEmpty($ParsedUri.Query)) { return $null }
            $QueryParams = [System.Web.HttpUtility]::ParseQueryString($ParsedUri.Query)
            $DispositionParam = $QueryParams['response-content-disposition']
            if (-not [string]::IsNullOrWhiteSpace($DispositionParam)) {
                $FromDisposition = Get-FileNameFromContentDisposition $DispositionParam
                if (-not [string]::IsNullOrEmpty($FromDisposition)) { return $FromDisposition }
            }
            foreach ($Key in 'filename', 'fileName', 'file', 'name', 'download') {
                $Value = $QueryParams[$Key]
                if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
            }
            return $null
        }

        # Map a Content-Type media type to a file extension for the common download types.
        # Returns $null for generic types (e.g. application/octet-stream) so no extension is added.
        function Get-ExtensionFromContentType {
            param([string]$ContentType)
            if ([string]::IsNullOrWhiteSpace($ContentType)) { return $null }
            $MimeType = $ContentType.Split(';')[0].Trim().ToLowerInvariant()
            $MimeMap = @{
                'application/pdf'                               = '.pdf'
                'application/zip'                               = '.zip'
                'application/x-zip-compressed'                  = '.zip'
                'application/gzip'                              = '.gz'
                'application/x-gzip'                            = '.gz'
                'application/x-tar'                             = '.tar'
                'application/x-7z-compressed'                   = '.7z'
                'application/x-rar-compressed'                  = '.rar'
                'application/x-msdownload'                      = '.exe'
                'application/vnd.microsoft.portable-executable' = '.exe'
                'application/x-msi'                             = '.msi'
                'application/x-apple-diskimage'                 = '.dmg'
                'application/vnd.debian.binary-package'         = '.deb'
                'application/x-rpm'                             = '.rpm'
                'application/json'                              = '.json'
                'application/xml'                               = '.xml'
                'text/xml'                                      = '.xml'
                'text/plain'                                    = '.txt'
                'text/html'                                     = '.html'
                'text/csv'                                      = '.csv'
                'image/png'                                     = '.png'
                'image/jpeg'                                    = '.jpg'
                'image/gif'                                     = '.gif'
                'image/webp'                                    = '.webp'
                'image/svg+xml'                                 = '.svg'
            }
            if ($MimeMap.ContainsKey($MimeType)) { return $MimeMap[$MimeType] }
            return $null
        }

    }

    process {

        # Reset variables
        $FileName = $FileSizeBytes = $FileSizeReadable = $LastModified = $null

        Write-Verbose "$($MyInvocation.MyCommand): Requesting headers from URL '$Uri'"

        $Timeout = [System.TimeSpan]::FromSeconds($TimeoutSeconds)
        $CancellationTokenSource = [System.Threading.CancellationTokenSource]::new($Timeout)
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $ResponseHeader = $null

        try {
            foreach ($UserAgentString in $UserAgent) {
                $HttpClient.DefaultRequestHeaders.Remove('User-Agent') | Out-Null
                if ($UserAgentString) {
                    Write-Verbose "$($MyInvocation.MyCommand): Using UserAgent '$UserAgentString'"
                    $HttpClient.DefaultRequestHeaders.Add('User-Agent', $UserAgentString)
                }

                # This sends a GET request but only retrieves the headers
                try {
                    $ResponseHeader = $HttpClient.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $CancellationTokenSource.Token).GetAwaiter().GetResult()
                }
                catch [System.OperationCanceledException] {
                    if ($CancellationTokenSource.IsCancellationRequested) {
                        $errorData = [ordered]@{
                            Uri            = $Uri
                            TimeoutSeconds = $TimeoutSeconds
                            ElapsedSeconds = [Math]::Round($Stopwatch.Elapsed.TotalSeconds, 2)
                            Stage          = 'requesting response headers'
                        }
                        $message = "$($MyInvocation.MyCommand): Timeout exceeded while resolving '$Uri'. Details: $($errorData | ConvertTo-Json -Compress)"
                        $timeoutException = [System.TimeoutException]::new($message, $_.Exception)
                        $errorRecord = [System.Management.Automation.ErrorRecord]::new($timeoutException, 'ResolveUri.Timeout', [System.Management.Automation.ErrorCategory]::OperationTimeout, $Uri)
                        $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($message)
                        $PSCmdlet.ThrowTerminatingError($errorRecord)
                    }

                    throw
                }

                # Exit the foreach if success
                if ($ResponseHeader.IsSuccessStatusCode) {
                    break
                }
            }

            if ($ResponseHeader.IsSuccessStatusCode) {
                Write-Verbose "$($MyInvocation.MyCommand): Successfully retrieved headers"

                if ($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri -ne $Uri) {
                    Write-Verbose "$($MyInvocation.MyCommand): URL '$Uri' redirects to '$($ResponseHeader.RequestMessage.RequestUri.AbsoluteUri)'"
                }

                try {
                    $FileSizeBytes = $null
                    $FileSizeBytes = [long]$ResponseHeader.Content.Headers.GetValues('Content-Length')[0]
                    Write-Verbose "$($MyInvocation.MyCommand): File size from Content-Length header: $FileSizeBytes bytes"
                }
                catch {
                    Write-Verbose "$($MyInvocation.MyCommand): Unable to determine file size from Content-Length header"
                }

                # Try to get the last modified date from the "Last-Modified" header, use error handling in case string is in invalid format
                try {
                    $LastModified = $null
                    $LastModified = [DateTime]::ParseExact($ResponseHeader.Content.Headers.GetValues('Last-Modified')[0], 'r', [System.Globalization.CultureInfo]::InvariantCulture)
                    Write-Verbose "$($MyInvocation.MyCommand): Last modified: $($LastModified.ToString())"
                }
                catch {
                    Write-Verbose "$($MyInvocation.MyCommand): Last-Modified header not found"
                }

                # Some servers do not return a Content-Length header on a normal request.
                # A ranged request for the first byte often reveals the total file size via the Content-Range header without downloading the entire file.
                if ($null -eq $FileSizeBytes) {
                    Write-Verbose "$($MyInvocation.MyCommand): File size unavailable from initial response, attempting ranged request"
                    $RangeRequest = $null
                    $RangeResponse = $null
                    try {
                        $RangeRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $ResponseHeader.RequestMessage.RequestUri)
                        $RangeRequest.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 0)
                        $RangeResponse = $HttpClient.SendAsync($RangeRequest, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $CancellationTokenSource.Token).GetAwaiter().GetResult()

                        if ($RangeResponse.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent) {
                            if ($null -ne $RangeResponse.Content.Headers.ContentRange -and $RangeResponse.Content.Headers.ContentRange.HasLength) {
                                $FileSizeBytes = [long]$RangeResponse.Content.Headers.ContentRange.Length
                                Write-Verbose "$($MyInvocation.MyCommand): File size from Content-Range header: $FileSizeBytes bytes"
                            }
                        }
                        else {
                            Write-Verbose "$($MyInvocation.MyCommand): Ranged request did not return partial content (status $([int]$RangeResponse.StatusCode))"
                        }
                    }
                    catch [System.OperationCanceledException] {
                        if ($CancellationTokenSource.IsCancellationRequested) {
                            $errorData = [ordered]@{
                                Uri            = $Uri
                                TimeoutSeconds = $TimeoutSeconds
                                ElapsedSeconds = [Math]::Round($Stopwatch.Elapsed.TotalSeconds, 2)
                                Stage          = 'requesting ranged response headers'
                            }
                            $message = "$($MyInvocation.MyCommand): Timeout exceeded while resolving '$Uri'. Details: $($errorData | ConvertTo-Json -Compress)"
                            $timeoutException = [System.TimeoutException]::new($message, $_.Exception)
                            $errorRecord = [System.Management.Automation.ErrorRecord]::new($timeoutException, 'ResolveUri.Timeout', [System.Management.Automation.ErrorCategory]::OperationTimeout, $Uri)
                            $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($message)
                            $PSCmdlet.ThrowTerminatingError($errorRecord)
                        }

                        throw
                    }
                    catch {
                        Write-Verbose "$($MyInvocation.MyCommand): Ranged request failed: $_"
                    }
                    finally {
                        if ($RangeRequest) { $RangeRequest.Dispose() }
                        if ($RangeResponse) { $RangeResponse.Dispose() }
                    }
                }

                # Format a human-readable file size once the size has been determined by whichever method
                if ($null -ne $FileSizeBytes) {
                    $FileSizeReadable = switch ($FileSizeBytes) {
                        { $_ -gt 1TB } { '{0:n2} TB' -f ($_ / 1TB); Break }
                        { $_ -gt 1GB } { '{0:n2} GB' -f ($_ / 1GB); Break }
                        { $_ -gt 1MB } { '{0:n2} MB' -f ($_ / 1MB); Break }
                        { $_ -gt 1KB } { '{0:n2} KB' -f ($_ / 1KB); Break }
                        default { '{0} B' -f $_ }
                    }
                    Write-Verbose "$($MyInvocation.MyCommand): File size: $FileSizeBytes bytes ($FileSizeReadable)"
                }

                if ($FileName) {
                    $FileName = $FileName.Trim()
                    Write-Verbose "$($MyInvocation.MyCommand): Will use supplied filename '$FileName'"
                }
                else {
                    $ResolvedUri = $ResponseHeader.RequestMessage.RequestUri.AbsoluteUri

                    # 1. Content-Disposition header - the server's explicit filename intent.
                    try {
                        $ContentDispositionHeader = $null
                        $ContentDispositionHeader = $ResponseHeader.Content.Headers.GetValues('Content-Disposition')[0]
                        Write-Verbose "$($MyInvocation.MyCommand): Content-Disposition header found: $ContentDispositionHeader"
                    }
                    catch {
                        Write-Verbose "$($MyInvocation.MyCommand): Content-Disposition header not found"
                    }
                    if ($ContentDispositionHeader) {
                        $FileName = ConvertTo-SafeFileName (Get-FileNameFromContentDisposition $ContentDispositionHeader)
                        if ($FileName) {
                            Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from Content-Disposition header"
                        }
                        else {
                            Write-Verbose "$($MyInvocation.MyCommand): Failed to extract filename from Content-Disposition header"
                        }
                    }

                    # 2. Query string parameters on the resolved URL, then the original URL.
                    #    Covers S3/GCS/CloudFront 'response-content-disposition' and ?filename=/?file= links.
                    if ([string]::IsNullOrEmpty($FileName)) {
                        $FileName = ConvertTo-SafeFileName (Get-FileNameFromQuery $ResolvedUri)
                        if ([string]::IsNullOrEmpty($FileName) -and $ResolvedUri -ne $Uri) {
                            $FileName = ConvertTo-SafeFileName (Get-FileNameFromQuery $Uri)
                        }
                        if ($FileName) {
                            Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from query string"
                        }
                    }

                    # 3. Content-Location header - some servers point at the canonical resource here.
                    if ([string]::IsNullOrEmpty($FileName)) {
                        try {
                            $ContentLocationHeader = $null
                            $ContentLocationHeader = $ResponseHeader.Content.Headers.GetValues('Content-Location')[0]
                        }
                        catch {
                            Write-Verbose "$($MyInvocation.MyCommand): Content-Location header not found"
                        }
                        if ($ContentLocationHeader) {
                            $FileName = ConvertTo-SafeFileName ([System.Web.HttpUtility]::UrlDecode($ContentLocationHeader.Split('?')[0]))
                            if ($FileName) {
                                Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from Content-Location header"
                            }
                        }
                    }

                    # 4. File name from the resolved (redirected) URL path, skipping uninformative names.
                    if ([string]::IsNullOrEmpty($FileName)) {
                        $Candidate = ConvertTo-SafeFileName ([System.Web.HttpUtility]::UrlDecode($ResolvedUri.Split('?')[0]))
                        if ($Candidate -and $UninformativeFileNames -notcontains $Candidate.ToLowerInvariant()) {
                            $FileName = $Candidate
                            Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from absolute URL '$ResolvedUri'"
                        }
                    }
                }

            }
            else {
                if ($ResponseHeader) {
                    throw "$($MyInvocation.MyCommand): Failed to retrieve headers from $($Uri): $([int]$ResponseHeader.StatusCode): $($ResponseHeader.ReasonPhrase)"
                }

                throw "$($MyInvocation.MyCommand): Failed to retrieve headers from $($Uri): no response was received"
            }

            if ([string]::IsNullOrEmpty($FileName)) {
                # Last resort: extract the file name from the original URL (any value is better than none).
                # GetFileName ensures we are not getting a full path with slashes. UrlDecode will convert characters like %20 back to spaces. The URL is split with ? to ensure we can strip off any API parameters.
                $FileName = ConvertTo-SafeFileName ([System.Web.HttpUtility]::UrlDecode($Uri.Split('?')[0]))
                Write-Verbose "$($MyInvocation.MyCommand): Extracted filename '$FileName' from original URL '$Uri'"
            }

            # If the resolved filename has no extension, try to infer one from the Content-Type header.
            if (-not [string]::IsNullOrEmpty($FileName) -and [string]::IsNullOrEmpty([System.IO.Path]::GetExtension($FileName))) {
                $ContentTypeHeader = $null
                if ($ResponseHeader.Content.Headers.ContentType) {
                    $ContentTypeHeader = $ResponseHeader.Content.Headers.ContentType.MediaType
                }
                $Extension = Get-ExtensionFromContentType $ContentTypeHeader
                if ($Extension) {
                    $FileName = $FileName + $Extension
                    Write-Verbose "$($MyInvocation.MyCommand): Appended extension '$Extension' inferred from Content-Type '$ContentTypeHeader'"
                }
            }

            [PSCustomObject]@{
                Uri              = $Uri
                AbsoluteUri      = $ResponseHeader.RequestMessage.RequestUri.AbsoluteUri
                FileName         = $FileName
                FileSizeBytes    = $FileSizeBytes
                FileSizeReadable = $FileSizeReadable
                LastModified     = $LastModified
            }
        }
        catch {
            # A terminating error in process skips the end block, so dispose the
            # reused HttpClient here to avoid leaking its socket/connection pool.
            if ($HttpClient) { $HttpClient.Dispose() }
            throw
        }
        finally {
            $Stopwatch.Stop()
            $CancellationTokenSource.Dispose()
            if ($ResponseHeader) {
                $ResponseHeader.Dispose()
            }
        }

    }

    end {
        if ($HttpClient) { $HttpClient.Dispose() }
    }
}